#!/usr/bin/env python3
"""Пилот air-nn одной командой: досчёт набора → подготовка → обучение основной сети → кривая (в) → оценка → отчёт.

  ./run_pilot.sh [--smoke] [--name ИМЯ] [--config config.yaml]     — запуск или продолжение
  ./run_pilot.sh status [--smoke] [--name ИМЯ]                     — где прогон, что готово

Терминал: строка этапа «этап n из N: …» и одна обновляемая строка прогресса (сделано/всего, %, осталось);
подробный лог шагов — в <прогон>/pilot.log (путь печатается в начале). Повтор той же команды продолжает с места
(готовые шаги пропускаются по manifest.json, обучение — с чекпойнта). Начать с нуля — другое --name (набор и кеш
подготовки не пересчитываются). Коды выхода — README.
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import fcntl
import glob
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402
from pilotnn.data import Dataset, solver_status  # noqa: E402
from pilotnn.split import make_split  # noqa: E402

PY = sys.executable
STEPS = ("досчёт набора", "подготовка тензоров", "обучение основной сети", "кривая (в): обучение по числу рельефов",
         "оценка и ONNX", "отчёт")


class UI:
    """Терминал: строка этапа + одна обновляемая строка прогресса; лог — в файл."""

    def __init__(self, log_path: Path):
        self.log = open(log_path, "a", buffering=1)
        self.tty = sys.stdout.isatty()
        self.t_print = 0.0
        self.cur = ""

    def logline(self, s):
        self.log.write(f"[{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {s}\n")

    def say(self, s):
        self.end_progress()
        print(s, flush=True)
        self.logline(s)

    def progress(self, s):
        self.cur = s
        if self.tty:
            cols = 160
            try:
                cols = os.get_terminal_size().columns
            except OSError:
                pass
            sys.stdout.write("\r\033[K" + s[: cols - 1])
            sys.stdout.flush()
        elif time.time() - self.t_print > 30:
            self.t_print = time.time()
            print(s, flush=True)

    def end_progress(self):
        if self.tty and self.cur:
            sys.stdout.write("\r\033[K" + self.cur + "\n")
            sys.stdout.flush()
        self.cur = ""


class Eta:
    def __init__(self):
        self.t0 = None
        self.d0 = None

    def line(self, done, total, unit, extra=""):
        now = time.time()
        if self.t0 is None:
            self.t0, self.d0 = now, done
        rate = (done - self.d0) / (now - self.t0) if now - self.t0 > 3 and done > self.d0 else None
        eta = f"осталось ~{C.fmt_dur((total - done) / rate)}" if rate else "осталось: оценка…"
        p = 100 * done / total if total else 0
        dd = f"{done:.1f}" if isinstance(done, float) and not float(done).is_integer() else f"{int(done)}"
        return f"  {unit} {dd}/{total} ({p:.0f} %){' · ' + extra if extra else ''} · {eta}"


def _pdeathsig():
    """Ребёнок получает SIGKILL, если умер pilot.py (kill -9 управляющего не оставляет сирот на GPU)."""
    try:
        ctypes.CDLL("libc.so.6").prctl(1, signal.SIGKILL)
    except Exception:  # noqa: BLE001
        pass


class Runner:
    def __init__(self, ui: UI):
        self.ui = ui
        self.child = None
        self.signum = None
        signal.signal(signal.SIGINT, self._sig)
        signal.signal(signal.SIGTERM, self._sig)

    def _sig(self, signum, frame):
        first = self.signum is None
        self.signum = signum
        if self.child is not None and self.child.poll() is None:
            self.child.send_signal(signum)              # шаг сам дописывает состояние; второй сигнал — сразу
            self.ui.say(f"сигнал {signum}: передан шагу ({'мягкая остановка' if first else 'немедленно'})")
        elif first:
            self.ui.say(f"сигнал {signum}: остановка")

    def run(self, args, progress_fn, unit_default="", poll=0.5):
        """Запуск шага как процесса; progress_fn() → (done, total, unit, extra) | None. → код выхода шага."""
        if self.signum is not None:
            return C.EXIT_SIGINT if self.signum == signal.SIGINT else C.EXIT_SIGTERM
        self.ui.logline("запуск: " + " ".join(map(str, args)))
        self.ui.log.flush()
        env = dict(os.environ, PYTHONUNBUFFERED="1")
        self.child = subprocess.Popen([PY, *map(str, args)], cwd=HERE, stdout=self.ui.log, stderr=subprocess.STDOUT,
                                      start_new_session=True, preexec_fn=_pdeathsig, env=env)
        eta = Eta()
        while True:
            rc = self.child.poll()
            try:
                pr = progress_fn()
            except Exception:  # noqa: BLE001
                pr = None
            if pr:
                done, total, unit, extra = pr
                self.ui.progress(eta.line(done, total, unit or unit_default, extra))
            if rc is not None:
                break
            time.sleep(poll)
        self.child = None
        self.ui.end_progress()
        return rc


def progress_file(p: Path):
    def f():
        js = C.read_json(p)
        if not js:
            return None
        return js["done"], js["total"], js.get("unit", ""), js.get("extra", "")
    return f


def dataset_progress(root: Path):
    """Сделано/всего для досчёта набора — из state.sqlite набора П1 (только чтение).
    TODO(после слияния P1): брать из его команды `status` (машиночитаемый вывод), а не из базы напрямую."""
    db = root / "state.sqlite"
    if not db.exists():
        return None
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    try:
        rows = dict(con.execute("SELECT status, COUNT(*) FROM cases GROUP BY status").fetchall())
    finally:
        con.close()
    total = sum(rows.values())
    done = rows.get("done", 0)
    return done, total, "решений", f"ошибок {rows.get('failed', 0)}" if rows.get("failed") else ""


def resolve_dataset(cfg):
    pat = str(C.expand(cfg["dataset"]["root_glob"], cfg))
    found = sorted(glob.glob(pat))
    if len(found) != 1:
        return None, f"набор: по шаблону {pat} найдено {len(found)} каталогов: {found}"
    return Path(found[0]), ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="run", choices=("run", "status"))
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--name", default=None)
    ap.add_argument("--config", default=str(HERE / "config.yaml"))
    a = ap.parse_args()
    cfg = C.load_config(a.config, a.smoke)
    name = a.name or ("smoke" if a.smoke else "pilot")
    if not name.replace("_", "").replace("-", "").isalnum():
        print("имя прогона: буквы, цифры, _ и -")
        return C.EXIT_USAGE
    run, rep, prep_base = C.run_dirs(cfg, name)
    if a.cmd == "status":
        return status(cfg, run, rep)
    run.mkdir(parents=True, exist_ok=True)
    lockf = open(run / ".lock", "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"прогон {run} уже идёт в другом процессе")
        return C.EXIT_ERROR
    ui = UI(run / "pilot.log")
    rn = Runner(ui)
    ui.say(f"пилот air-nn: прогон {run.name}{' (smoke)' if a.smoke else ''}")
    ui.say(f"  лог: {run / 'pilot.log'}")
    ui.say(f"  отчёт будет: {rep / 'report.md'}")
    C.check_space(run, 3.0)
    N = len(STEPS)

    def head(i):
        ui.say(f"этап {i} из {N}: {STEPS[i - 1]}")

    def fin(rc, what):
        if rc in (C.EXIT_SIGINT, C.EXIT_SIGTERM):
            ui.say(f"прервано на шаге «{what}» (код {rc}); продолжить — та же команда")
        elif rc != 0:
            ui.say(f"ошибка на шаге «{what}» (код {rc}); подробности — {run / 'pilot.log'}")
        return rc

    # 1. набор
    head(1)
    ds_root, err = resolve_dataset(cfg)
    gen = cfg["dataset"].get("gen_cmd") or []
    if gen:
        rc = rn.run(gen, lambda: dataset_progress(ds_root) if ds_root else None)
        if rc:
            return fin(rc, STEPS[0])
        ds_root, err = resolve_dataset(cfg)
    if ds_root is None:
        ui.say(err)
        return C.EXIT_NODATA
    ds = Dataset(ds_root)
    allowed = set(cfg["dataset"]["allowed_status"])
    all_rows = ds.case_rows()
    rows = [r for r in all_rows if solver_status(r) in allowed]
    ui.say(f"  набор {ds_root}: готовых случаев {len(all_rows)}, пригодных (статусы {sorted(allowed)}) {len(rows)}")
    if len(rows) < cfg["dataset"]["min_cases"]:
        ui.say(f"  мало случаев (< {cfg['dataset']['min_cases']})")
        return C.EXIT_NODATA
    split = make_split(rows, cfg["split"])
    C.atomic_write_json(run / "config.json", cfg)
    C.atomic_write_json(run / "split.json", split)
    ui.say(f"  деление: обучение {len(split['train_ids'])}, проверка {len(split['val_ids'])}, (а) {len(split['newcond_ids'])}, "
           f"(б) {len(split['holdout_place_ids'])} {split['holdout_places']}, (б′) {len(split['holdout_proc_ids'])} "
           f"{split['holdout_proc']}; кривая {[c['n_places'] for c in split['curve']]} рельефов")
    # 2. подготовка
    head(2)
    from pilotnn import prep as P
    from pilotnn.train import CODE_FILES as TRAIN_CODE
    ph = C.code_hash(Path(P.__file__), HERE / "pilotnn" / "prepstep.py")
    ver = ds_root.parent.name if ds.layout == "pilot" else "dev"
    prep_dir = prep_base / ver / f"{ds_root.name}_{C.sha(str(ds_root))[:6]}_p{ph[:8]}"
    ids = sorted(set(split["train_ids"] + split["val_ids"] + split["newcond_ids"] + split["holdout_place_ids"]
                     + split["holdout_proc_ids"]))
    prep_dir.mkdir(parents=True, exist_ok=True)
    C.atomic_write_json(run / "prep_ids.json", ids)
    C.check_space(prep_dir, 1.0 + 0.0019 * len(ids))
    rc = rn.run(["-m", "pilotnn.prepstep", prep_dir, ds_root, run / "prep_ids.json"], progress_file(prep_dir / "progress.json"))
    if rc:
        return fin(rc, STEPS[1])
    info = dict(dataset_root=str(ds_root), prep_dir=str(prep_dir), agl=list(ds.agl), smoke=a.smoke, name=name,
                curve=[dict(dir=f"curve_{c['n_places']:02d}", n=c["n"], n_places=c["n_places"], places=c["places"],
                            train_ids=c["train_ids"]) for c in split["curve"]])
    C.atomic_write_json(run / "run_info.json", info)
    C.write_manifest(run, "прогон пилота air-nn (обучение)", C.sha(dict(cfg=cfg, split=split)), False,
                     dataset=str(ds_root), prep=str(prep_dir))

    def task(d: Path, label, train_ids, val_ids, over=None):
        d.mkdir(parents=True, exist_ok=True)
        tc = C.deep_update(cfg["train"], over or {})
        t = dict(label=label, train=tc, prep_dir=str(prep_dir), train_ids=train_ids, val_ids=val_ids)
        old = C.read_json(d / "task.json")
        if old != t:
            C.atomic_write_json(d / "task.json", t)
        return d

    # 3. основная сеть
    head(3)
    dm = task(run / "main", "основная сеть", split["train_ids"], split["val_ids"])
    rc = rn.run(["-m", "pilotnn.train", dm], progress_file(dm / "progress.json"))
    if rc:
        return fin(rc, STEPS[2])
    # 4. кривая
    head(4)
    K = len(split["curve"])
    for i, c in enumerate(split["curve"]):
        dc = task(run / info["curve"][i]["dir"], f"кривая: {c['n_places']} рельефов", c["train_ids"],
                  c["val_ids"] or split["val_ids"],   # мало случаев у мест точки — проверка по всему пулу
                  dict(max_epochs=cfg.get("curve", {}).get("max_epochs", cfg["train"]["max_epochs"])))
        pf = progress_file(dc / "progress.json")

        def prog(i=i, pf=pf, c=c):
            x = pf()
            frac = (x[0] / x[1]) if x else 0.0
            ep = f"{c['n_places']} рельефов, эпоха {x[0]:.1f}/{x[1]}" if x else f"{c['n_places']} рельефов"
            return i + frac, K, "прогонов", ep
        rc = rn.run(["-m", "pilotnn.train", dc], prog)
        if rc:
            return fin(rc, STEPS[3])
    C.write_manifest(run, "прогон пилота air-nn (обучение)", C.sha(dict(cfg=cfg, split=split)), True,
                     dataset=str(ds_root), prep=str(prep_dir))
    # 5. оценка
    head(5)
    rc = rn.run(["-m", "pilotnn.evaluate", "eval", run, rep], progress_file(rep / "progress.json"))
    if rc:
        return fin(rc, STEPS[4])
    # 6. отчёт
    head(6)
    rc = rn.run(["-m", "pilotnn.evaluate", "report", run, rep], progress_file(rep / "progress.json"))
    if rc:
        return fin(rc, STEPS[5])
    m = C.read_json(rep / "manifest.json", {})
    ui.say(f"готово: {rep / 'report.md'}")
    ui.say(f"  {m.get('verdict', '')}")
    return C.EXIT_OK


def status(cfg, run, rep):
    print(f"прогон: {run}")
    if not run.exists():
        print("  ещё не запускался")
        return C.EXIT_OK
    try:
        f = open(run / ".lock", "w")
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(f, fcntl.LOCK_UN)
        print("  сейчас: не запущен")
    except BlockingIOError:
        print("  сейчас: идёт (процесс держит замок прогона)")
    info = C.read_json(run / "run_info.json", {})
    ds_root, _ = resolve_dataset(cfg)
    if ds_root:
        pr = dataset_progress(ds_root)
        print(f"  набор: {ds_root}" + (f" — решений {pr[0]}/{pr[1]}" if pr else ""))
    if info:
        pp = C.read_json(Path(info["prep_dir"]) / "progress.json")
        if pp:
            print(f"  подготовка: {pp['done']}/{pp['total']} случаев")

    def st(d: Path):
        m = C.read_json(d / "manifest.json")
        p = C.read_json(d / "progress.json")
        if m and m.get("complete"):
            b = m.get("best")
            return "готово" + (f" (эпох {m.get('epochs')}, лучшая проверка {b['val']:.4g} @ {b['epoch'] + 1})" if b else "")
        if p:
            return f"в работе: {p['done']:.1f}/{p['total']} {p.get('unit', '')} {p.get('extra', '')}"
        return "не начато"
    print(f"  основная сеть: {st(run / 'main')}")
    for c in info.get("curve", []):
        print(f"  кривая {c['n_places']:>2} рельефов: {st(run / c['dir'])}")
    m = C.read_json(rep / "manifest.json")
    if m and m.get("report_built"):
        print(f"  отчёт: {rep / 'report.md'}\n  {m.get('verdict', '')}")
    elif m:
        print(f"  оценка: {'готова' if m.get('complete') else 'в работе'}; отчёт не построен")
    else:
        print("  отчёт: нет")
    print(f"  лог: {run / 'pilot.log'}")
    return C.EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
