#!/usr/bin/env python3
"""Пилот air-nn одной командой: досчёт наборов → подготовка → обучение основной сети → кривая (в) → оценка → отчёт.

  ./run_pilot.sh [--smoke | --profile ИМЯ] [--name ИМЯ] [--config config.yaml]  — запуск или продолжение
  ./run_pilot.sh status [--smoke | --profile ИМЯ] [--name ИМЯ]                  — где прогон, что готово

Наборы — список `config.yaml → datasets` (main v1 + terrain v2), индекс мест П6 — `terrain_index`; деление v3
(`pilotnn/split.py`), кеш подготовки — по набору. Точка кривой с полным пулом П6 = основная сеть (не обучается).

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
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402
from pilotnn.data import Datasets, read_p6_index, solver_status  # noqa: E402
from pilotnn.split import make_split  # noqa: E402

PY = sys.executable
STEPS = ("досчёт наборов", "подготовка тензоров", "обучение основной сети", "кривая (в): обучение по числу рельефов",
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
            sys.stdout.write("\r\033[K" + (s[: cols - 1] if cols > 1 else s))
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
    """Оставшееся время по скорости за последние WINDOW с (ожидание замка GPU и пауза шага не тянут оценку за собой)."""
    WINDOW = 180.0

    def __init__(self):
        self.hist = []

    def line(self, done, total, unit, extra="", eta_s=None):
        now = time.time()
        if not self.hist or done != self.hist[-1][1]:
            self.hist.append((now, done))
        while len(self.hist) > 2 and now - self.hist[0][0] > self.WINDOW:
            self.hist.pop(0)
        t0, d0 = self.hist[0]
        rate = (done - d0) / (now - t0) if now - t0 > 3 and done > d0 else None
        if total and done >= total:
            eta = "завершение…"
        else:
            if eta_s is not None:                      # оценка самого шага (генератор NN-P1: по видам случаев)
                eta = f"осталось ~{C.fmt_dur(eta_s)}"
            else:
                eta = f"осталось ~{C.fmt_dur((total - done) / rate)}" if rate else "осталось: оценка скорости…"
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

    def wait(self, seconds, progress_fn, extra=""):
        """Пауза без процесса-шага с обновлением прогресса; сигнал — выход с его кодом."""
        eta = Eta()
        t0 = time.time()
        while time.time() - t0 < seconds:
            if self.signum is not None:
                self.ui.end_progress()
                return C.EXIT_SIGINT if self.signum == signal.SIGINT else C.EXIT_SIGTERM
            pr = progress_fn()
            if pr:
                self.ui.progress(eta.line(pr[0], pr[1], pr[2], ", ".join(x for x in (pr[3], extra) if x),
                                          pr[4] if len(pr) > 4 else None))
            time.sleep(0.5)
        return 0

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
                self.ui.progress(eta.line(pr[0], pr[1], pr[2] or unit_default, pr[3], pr[4] if len(pr) > 4 else None))
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


def p1(*args, timeout=120):
    """Команда генератора NN-P1 (dataset.py) → stdout."""
    r = subprocess.run([PY, str(HERE / "dataset.py"), *map(str, args)], cwd=HERE, capture_output=True, text=True,
                       timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"dataset.py {' '.join(map(str, args))}: код {r.returncode}: {r.stdout[-500:]}{r.stderr[-500:]}")
    return r.stdout


class DatasetProgress:
    """Сделано/всего для досчёта набора — из `dataset.py status --json` (NN-P1), не чаще раза в 10 с."""

    def __init__(self, name):
        self.name, self.t, self.v, self.js = name, 0.0, None, {}

    def __call__(self):
        if time.time() - self.t > 10:
            self.t = time.time()
            try:
                js = json.loads(p1("status", "--dataset", self.name, "--json").strip().splitlines()[-1])
                extra = []
                if js.get("failed"):
                    extra.append(f"ошибок {js['failed']}")
                if js.get("max"):
                    extra.append(f"max {js['max']}")
                eta = js.get("eta_h")
                self.js = js
                self.v = (js["done"], js["total"], "решений", ", ".join(extra), eta * 3600 if eta is not None else None)
            except Exception:  # noqa: BLE001
                pass
        return self.v


def dataset_progress(spec):
    if spec.get("root"):
        return None
    try:
        return DatasetProgress(spec["name"])()
    except Exception:  # noqa: BLE001
        return None


def resolve_dataset(spec, cfg):
    """Каталог набора: явный root или `dataset.py path --dataset <name>`. → (Path | None, ошибка)."""
    root = spec.get("root")
    if root:
        p = C.expand(root, cfg)
    else:
        try:
            p = Path(p1("path", "--dataset", spec["name"]).strip().splitlines()[-1])
        except Exception as e:  # noqa: BLE001
            return None, f"набор {spec['name']}: {e}"
    if not p.exists():
        return None, f"набор {spec['name']}: нет каталога {p}"
    return p, ""


def gen_dataset(cfg, name, rn: "Runner", ui: "UI"):
    """Досчёт набора генератором (dataset.py, с продолжения). Код 5 (досчёт уже идёт другим процессом) — ждать его
    с прогрессом по status --json и повторять. → код выхода пилота."""
    log_dir = C.expand(cfg["dataset"]["log_dir"], cfg)
    log_dir.mkdir(parents=True, exist_ok=True)
    glog = log_dir / f"dataset_{name}.log"
    ui.say(f"  журнал досчёта: {glog}")
    prog = DatasetProgress(name)
    said = False
    while True:
        rc = rn.run([HERE / "dataset.py", "run", "--dataset", name, "--log", glog], prog)
        if rc == 5:
            if not said:
                ui.say("  досчёт этого набора уже идёт в другом процессе — жду его (прогресс — по status --json)")
                said = True
            idle = 0
            while idle < 2:                          # повтор run — когда чужой досчёт закончился или стоит
                rc = rn.wait(15, prog, "ожидание чужого досчёта")
                if rc:
                    return rc
                prog.t = 0.0
                prog()
                js = prog.js or {}
                idle = idle + 1 if (js.get("complete") or not js.get("running")) else 0
            continue
        if rc == 0:
            return C.EXIT_OK
        if rc == 2:
            return C.EXIT_SIGINT if rn.signum in (None, signal.SIGINT) else C.EXIT_SIGTERM
        if rc == 3:
            return C.EXIT_NOSPACE
        if rc == 4:
            ui.say(f"  в наборе есть окончательно упавшие случаи (код 4) — продолжаю с готовыми; см. {glog}")
            return C.EXIT_OK
        if rc in (C.EXIT_SIGINT, C.EXIT_SIGTERM):
            return rc
        ui.say(f"  досчёт: код {rc}; см. {glog}")
        return C.EXIT_ERROR


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="run", choices=("run", "status"))
    ap.add_argument("--smoke", action="store_true", help="мини-прогон: профиль smoke (набор smoke NN-P1)")
    ap.add_argument("--profile", default=None, help="профиль из config.yaml → profiles (smoke)")
    ap.add_argument("--name", default=None)
    ap.add_argument("--config", default=str(HERE / "config.yaml"))
    a = ap.parse_args()
    profile = a.profile or ("smoke" if a.smoke else None)
    cfg = C.load_config(a.config, profile)
    name = a.name or profile or "pilot"
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
    ui.say(f"пилот air-nn: прогон {run.name}{f' (профиль {profile})' if profile else ''}")
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

    # 1. наборы
    head(1)
    specs = cfg["datasets"]
    for spec in specs:
        if spec.get("gen") and not spec.get("root"):
            ui.say(f"  набор {spec['name']}: досчёт")
            rc = gen_dataset(cfg, spec["name"], rn, ui)
            if rc:
                return fin(rc, STEPS[0])
    roots = []
    for spec in specs:
        r, err = resolve_dataset(spec, cfg)
        if r is None:
            ui.say("  " + err)
            return C.EXIT_NODATA
        roots.append((spec["name"], r))
    dss = Datasets(roots)
    allowed = set(cfg["dataset"]["allowed_status"])
    try:
        all_rows = dss.case_rows()
    except ValueError as e:
        ui.say(f"  наборы несовместимы: {e}")
        return C.EXIT_NODATA
    rows = [r for r in all_rows if solver_status(r) in allowed]
    for name_ds, r in roots:
        d = dss.sets[name_ds]
        n_all = sum(x["ds"] == name_ds for x in all_rows)
        n_ok = sum(x["ds"] == name_ds for x in rows)
        ui.say(f"  набор {name_ds} ({d.contract}) {r}: готовых случаев {n_all}, пригодных (статусы {sorted(allowed)}) {n_ok}")
    if len(rows) < cfg["dataset"]["min_cases"]:
        ui.say(f"  мало случаев (< {cfg['dataset']['min_cases']})")
        return C.EXIT_NODATA
    p6_path = C.expand(cfg["terrain_index"], cfg)
    p6_all = read_p6_index(p6_path)
    t_locs = sorted({r["loc"] for r in rows if r["loc"].startswith("t_")})
    if t_locs and not p6_all:
        ui.say(f"  в наборах есть места t_*, но нет индекса П6 {p6_path}")
        return C.EXIT_NODATA
    p6 = {l: p6_all[l] for l in t_locs if l in p6_all}
    try:
        split = make_split(rows, cfg["split"], p6)
    except ValueError as e:
        ui.say(f"  деление: {e}")
        return C.EXIT_NODATA
    C.atomic_write_json(run / "config.json", cfg)
    C.atomic_write_json(run / "split.json", split)
    C.atomic_write_json(run / "p6.json", dict(path=str(p6_path), places=p6))
    ui.say(f"  индекс П6: {p6_path} — мест в наборах {len(p6)} из {len(p6_all)}")
    ui.say(f"  деление: обучение {len(split['train_ids'])}, проверка {len(split['val_ids'])}, (а) {len(split['newcond_ids'])}, "
           f"(г) {len(split['holdout_sys_ids'])} ({len(split['holdout_sys'])} мест), (б) {len(split['holdout_place_ids'])} "
           f"{split['holdout_places']}, (б′) {len(split['holdout_proc_ids'])} {split['holdout_proc']}; кривая "
           f"{[c['n_places'] for c in split['curve']]} мест П6 (+ {len(split['curve_base'])} прочих)")
    # 2. подготовка (кеш — по набору)
    head(2)
    from pilotnn import prep as P
    ph = C.code_hash(Path(P.__file__), HERE / "pilotnn" / "prepstep.py")
    ids = set(split["train_ids"] + split["val_ids"] + split["newcond_ids"] + split["holdout_place_ids"]
              + split["holdout_sys_ids"] + split["holdout_proc_ids"])
    ds_info = []
    for name_ds, ds_root in roots:
        d = dss.sets[name_ds]
        ver = ds_root.parent.name if d.layout == "pilot" else "dev"
        prep_dir = prep_base / ver / f"{ds_root.name}_{C.sha(str(ds_root))[:6]}_p{ph[:8]}"
        mine = sorted(r["id"] for r in rows if r["ds"] == name_ds and r["id"] in ids)
        ds_info.append(dict(name=name_ds, root=str(ds_root), contract=d.contract, prep_dir=str(prep_dir), n_cases=len(mine)))
        if not mine:
            continue
        prep_dir.mkdir(parents=True, exist_ok=True)
        idf = run / f"prep_ids_{name_ds}.json"
        C.atomic_write_json(idf, mine)
        C.check_space(prep_dir, 1.0 + 0.0019 * len(mine))
        ui.say(f"  набор {name_ds}: {len(mine)} случаев → {prep_dir}")
        rc = rn.run(["-m", "pilotnn.prepstep", prep_dir, ds_root, idf], progress_file(prep_dir / "progress.json"))
        if rc:
            return fin(rc, STEPS[1])
    prep_dirs = [x["prep_dir"] for x in ds_info if x["n_cases"]]
    info = dict(datasets=ds_info, prep_dirs=prep_dirs, p6_index=str(p6_path), agl=list(dss.agl), smoke=bool(profile),
                profile=profile or "", name=name,
                curve=[dict(dir="main" if c["is_main"] else f"curve_{c['n_places']:03d}", n=c["n"], n_places=c["n_places"],
                            is_main=c["is_main"], places=c["places"], curve_places=c["curve_places"],
                            train_ids=c["train_ids"]) for c in split["curve"]])
    C.atomic_write_json(run / "run_info.json", info)
    C.write_manifest(run, "прогон пилота air-nn (обучение)", C.sha(dict(cfg=cfg, split=split)), False,
                     datasets=ds_info)

    def task(d: Path, label, train_ids, val_ids, over=None):
        d.mkdir(parents=True, exist_ok=True)
        tc = C.deep_update(cfg["train"], over or {})
        t = dict(label=label, train=tc, prep_dirs=prep_dirs, train_ids=train_ids, val_ids=val_ids)
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
    todo = [(i, c) for i, c in enumerate(split["curve"]) if not c["is_main"]]   # полный пул = основная сеть
    K = len(todo)
    for i, (ci, c) in enumerate(todo):
        dc = task(run / info["curve"][ci]["dir"], f"кривая: {c['n_places']} рельефов", c["train_ids"],
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
                     datasets=ds_info)
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
    for spec in cfg["datasets"]:
        ds_root, err = resolve_dataset(spec, cfg)
        if ds_root:
            pr = dataset_progress(spec)
            print(f"  набор {spec['name']}: {ds_root}" + (f" — решений {pr[0]}/{pr[1]}" + (f" ({pr[3]})" if pr[3] else "")
                                                       if pr else ""))
        else:
            print(f"  {err}")
    if not run.exists():
        print("  прогон ещё не запускался")
        return C.EXIT_OK
    try:
        f = open(run / ".lock", "w")
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(f, fcntl.LOCK_UN)
        print("  сейчас: не запущен")
    except BlockingIOError:
        print("  сейчас: идёт (процесс держит замок прогона)")
    info = C.read_json(run / "run_info.json", {})
    for x in info.get("datasets", []):
        pp = C.read_json(Path(x["prep_dir"]) / "progress.json")
        if pp:
            print(f"  подготовка {x['name']}: {pp['done']}/{pp['total']} случаев")

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
        print(f"  кривая {c['n_places']:>3} мест П6: " + ("= основная сеть" if c.get("is_main") else st(run / c["dir"])))
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
