"""Общее: конфиг, пути, манифесты, атомарная запись, замок GPU, сигналы, коды выхода."""
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
PILOT = HERE.parent                       # tools/research/air_nn_pilot
REPO = PILOT.parents[2]
GPU_LOCK = "/tmp/heat_ca_gpu.lock"

# коды выхода (README → «Коды выхода»)
EXIT_OK, EXIT_ERROR, EXIT_USAGE, EXIT_NOSPACE, EXIT_NODATA = 0, 1, 2, 3, 4
EXIT_SIGINT, EXIT_SIGTERM = 130, 143


class StopRequested(Exception):
    """Мягкая остановка по SIGINT/SIGTERM: шаг сохранил состояние и выходит."""

    def __init__(self, signum):
        super().__init__(f"сигнал {signum}")
        self.code = EXIT_SIGINT if signum == signal.SIGINT else EXIT_SIGTERM


class Signals:
    """Первый SIGINT/SIGTERM — флаг (шаг сам дописывает чекпойнт и выходит), второй — немедленный выход."""

    def __init__(self):
        self.signum = None
        signal.signal(signal.SIGINT, self._h)
        signal.signal(signal.SIGTERM, self._h)

    def _h(self, signum, frame):
        if self.signum is not None:
            print(f"\nповторный сигнал {signum} — немедленный выход", flush=True)
            os._exit(EXIT_SIGINT if signum == signal.SIGINT else EXIT_SIGTERM)
        self.signum = signum
        print(f"\nсигнал {signum}: мягкая остановка (дописываю состояние; повторный сигнал — сразу)", flush=True)

    def check(self):
        if self.signum is not None:
            raise StopRequested(self.signum)


def deep_update(a: dict, b: dict) -> dict:
    out = dict(a)
    for k, v in (b or {}).items():
        out[k] = deep_update(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load_config(path, smoke=False):
    cfg = yaml.safe_load(Path(path).read_text())
    if smoke:
        cfg = deep_update(cfg, cfg.get("smoke_overrides", {}))
    cfg.pop("smoke_overrides", None)
    cfg["smoke"] = bool(smoke)
    cfg["data_root"] = os.environ.get("AIR_NN_DATA", cfg.get("data_root_default", "/home/greg/air_nn_data"))
    return cfg


def expand(s: str, cfg) -> Path:
    return Path(str(s).replace("${AIR_NN_DATA}", cfg["data_root"]).replace("$AIR_NN_DATA", cfg["data_root"]))


def sha(obj) -> str:
    if isinstance(obj, (bytes, bytearray)):
        b = bytes(obj)
    else:
        b = json.dumps(obj, sort_keys=True, ensure_ascii=False, default=str).encode()
    return hashlib.sha256(b).hexdigest()[:16]


def code_hash(*files) -> str:
    h = hashlib.sha256()
    for f in sorted(Path(x) for x in files):
        h.update(f.name.encode())
        h.update(Path(f).read_bytes())
    return h.hexdigest()[:16]


def git_commit() -> str:
    try:
        return subprocess.run(["git", "-C", str(PILOT), "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, timeout=10).stdout.strip()
    except Exception:  # noqa: BLE001
        return "?"


def fsync_dir(d: Path):
    try:
        fd = os.open(str(d), os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def atomic_write_bytes(path: Path, data: bytes):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp{os.getpid()}")
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fsync_dir(path.parent)


def atomic_write_json(path: Path, obj):
    atomic_write_bytes(path, json.dumps(obj, ensure_ascii=False, indent=1, default=float).encode())


def clean_tmp(d: Path):
    """Остатки недописанных файлов (обрыв посреди записи) — свои, удаляются без вопросов."""
    if d.exists():
        for p in d.glob("*.tmp*"):
            if p.is_file():
                p.unlink()


def read_json(path, default=None):
    p = Path(path)
    if not p.exists():
        return default
    return json.loads(p.read_text())


def write_manifest(d: Path, what: str, inputs_hash: str, complete: bool, **extra):
    m = dict(what=what, inputs_hash=inputs_hash, complete=complete, commit=git_commit(),
             command=" ".join(sys.argv), date=dt.datetime.now().isoformat(timespec="seconds"))
    old = read_json(d / "manifest.json", {}) or {}
    if "created" in old:
        m["created"] = old["created"]
    else:
        m["created"] = m["date"]
    m.update(extra)
    atomic_write_json(d / "manifest.json", m)
    return m


def step_state(d: Path, inputs_hash: str):
    """→ 'done' (complete, те же входы) | 'resume' (есть, не завершён, те же входы) | 'new' | 'changed'."""
    m = read_json(Path(d) / "manifest.json")
    if m is None:
        return "new"
    if m.get("inputs_hash") != inputs_hash:
        return "changed"
    return "done" if m.get("complete") else "resume"


def check_space(path: Path, need_gb: float):
    path = Path(path)
    p = path
    while not p.exists():
        p = p.parent
    free = shutil.disk_usage(p).free / 1e9
    if free < need_gb:
        print(f"нет места: свободно {free:.1f} ГБ на {p}, нужно ≥ {need_gb:.1f} ГБ", flush=True)
        sys.exit(EXIT_NOSPACE)


class GpuLock:
    """flock на общем файле замка GPU (как остальные исследования); снимается ОС при смерти процесса."""

    def __init__(self):
        self.f = None
        self.t_acq = 0.0
        self.waited = 0.0

    def acquire(self):
        if self.f is None:
            self.f = open(GPU_LOCK, "w")
            t0 = time.perf_counter()
            fcntl.flock(self.f, fcntl.LOCK_EX)
            self.waited += time.perf_counter() - t0
            self.t_acq = time.perf_counter()

    def release(self):
        if self.f is not None:
            fcntl.flock(self.f, fcntl.LOCK_UN)
            self.f.close()
            self.f = None

    def held_for(self):
        return time.perf_counter() - self.t_acq if self.f is not None else 0.0

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *exc):
        self.release()


def fmt_dur(s):
    s = max(0, int(s))
    h, r = divmod(s, 3600)
    m, s = divmod(r, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def run_dirs(cfg, name):
    """Каталоги прогона: runs/<дата>_<имя>, reports/<дата>_<имя>. Дата — первой попытки (повтор находит тот же)."""
    base = expand(cfg["paths"]["base"], cfg)
    runs = base / "runs"
    found = sorted(runs.glob(f"????-??-??_{name}")) if runs.exists() else []
    if len(found) > 1:
        raise SystemExit(f"несколько каталогов прогона '{name}': {found}")
    tag = found[0].name if found else f"{dt.date.today().isoformat()}_{name}"
    return base / "runs" / tag, base / "reports" / tag, base / "prep"
