#!/usr/bin/env python3
"""Тест прерываний (план §4.6, приёмка NN-P2 п. 2) на smoke-конфиге:

  A. непрерванный прогон `run_pilot.sh --smoke --name itest_ref` до отчёта;
  B. `--name itest_cut`: kill -9 управляющего посреди обучения основной сети → повтор; SIGINT посреди обучения
     (ожидается код 130, мягкая остановка с чекпойнтом) → повтор; kill -9 во время записи чекпойнта (пауза между
     записью временного файла и rename — PILOT_TEST_CKPT_PAUSE) → повтор; kill -9 посреди кривой → повтор до отчёта;
  сравнение: metrics.json B против A (все числа, кроме времени), без дублей каталогов и временных файлов.
Убивает только PID, которые запустил сам. Результат → tests/out/interrupt_result.json.

  .venv/bin/python tests/test_interrupt.py [--keep]
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402

CMD = [str(HERE / "run_pilot.sh"), "--smoke"]
SKIP_KEYS = ("t_", "time_ms", "path", "cpu", "date", "t_eval_s", "root")


def dirs(name):
    cfg = C.load_config(HERE / "config.yaml", smoke=True)
    return C.run_dirs(cfg, name)


def start(name, env_extra=None):
    env = dict(os.environ, **(env_extra or {}))
    return subprocess.Popen(CMD + ["--name", name], cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=env)


def wait_until(pred, proc, timeout=900):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if pred():
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.1)
    raise TimeoutError


def progress(d: Path):
    js = C.read_json(d / "progress.json")
    return js["done"] if js else 0.0


def finish(name, timeout=1800):
    p = start(name)
    return p.wait(timeout)


def flat(x, pre=""):
    out = {}
    if isinstance(x, dict):
        for k, v in x.items():
            if any(str(k).startswith(s) or str(k) == s for s in SKIP_KEYS):
                continue
            out.update(flat(v, f"{pre}/{k}"))
    elif isinstance(x, list):
        for i, v in enumerate(x):
            out.update(flat(v, f"{pre}[{i}]"))
    elif isinstance(x, (int, float)) and not isinstance(x, bool):
        out[pre] = float(x)
    return out


def compare(a, b):
    fa, fb = flat(a), flat(b)
    keys = sorted(set(fa) | set(fb))
    missing = [k for k in keys if k not in fa or k not in fb]
    worst, worst_k, n_diff = 0.0, None, 0
    for k in keys:
        if k in fa and k in fb:
            x, y = fa[k], fb[k]
            if math.isnan(x) and math.isnan(y):
                continue
            d = abs(x - y) / max(abs(x), abs(y), 1e-9)
            if d > 0:
                n_diff += 1
            if d > worst:
                worst, worst_k = d, k
    return dict(n_numbers=len(keys), n_missing=len(missing), missing=missing[:10], n_different=n_diff,
                max_rel_diff=worst, max_rel_key=worst_k)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="не удалять прежние каталоги itest_* (продолжить)")
    a = ap.parse_args()
    log = []
    for name in ("itest_ref", "itest_cut"):
        run, rep, _ = dirs(name)
        if not a.keep:
            shutil.rmtree(run, ignore_errors=True)
            shutil.rmtree(rep, ignore_errors=True)
    t0 = time.time()
    rc = finish("itest_ref")
    log.append(dict(step="A: непрерванный", rc=rc, t=round(time.time() - t0, 1)))
    print(log[-1], flush=True)
    assert rc == 0
    run, rep, _ = dirs("itest_cut")
    main_d = run / "main"
    # 1. kill -9 посреди обучения
    p = start("itest_cut")
    assert wait_until(lambda: progress(main_d) >= 25, p)
    p.send_signal(signal.SIGKILL); p.wait()
    log.append(dict(step="kill -9 посреди обучения", at_epoch=progress(main_d), rc=p.returncode))
    print(log[-1], flush=True)
    time.sleep(1.0)
    # 2. SIGINT посреди обучения
    p = start("itest_cut")
    e0 = progress(main_d)
    assert wait_until(lambda: progress(main_d) >= e0 + 30, p)
    at = progress(main_d)
    p.send_signal(signal.SIGINT)
    rc = p.wait(120)
    log.append(dict(step="SIGINT посреди обучения", at_epoch=at, rc=rc, ckpt=(main_d / "ckpt" / "last.pt").exists()))
    print(log[-1], flush=True)
    assert rc == C.EXIT_SIGINT
    # 3. kill -9 во время записи чекпойнта (между временным файлом и rename)
    plog = run / "pilot.log"
    n0 = plog.read_text().count("CKPT_TMP_WRITTEN")
    p = start("itest_cut", {"PILOT_TEST_CKPT_PAUSE": "5"})
    assert wait_until(lambda: plog.read_text().count("CKPT_TMP_WRITTEN") > n0, p, 600)
    time.sleep(0.5)
    tmps = [x.name for x in (main_d / "ckpt").glob("*.tmp*")]
    p.send_signal(signal.SIGKILL); p.wait()
    log.append(dict(step="kill -9 при записи чекпойнта", at_epoch=progress(main_d), tmp_files_at_kill=tmps))
    print(log[-1], flush=True)
    time.sleep(1.0)
    # 4. kill -9 посреди кривой
    p = start("itest_cut")
    cdirs = sorted(run.glob("curve_*"))
    ok = wait_until(lambda: any(progress(d) >= 3 for d in sorted(run.glob("curve_*"))), p)
    if ok:
        p.send_signal(signal.SIGKILL); p.wait()
        log.append(dict(step="kill -9 посреди кривой", curve=[(d.name, progress(d)) for d in sorted(run.glob("curve_*"))]))
    else:
        log.append(dict(step="kill -9 посреди кривой: не успел (шаг закончился)", rc=p.returncode))
    print(log[-1], flush=True)
    time.sleep(1.0)
    # 5. до конца
    rc = finish("itest_cut")
    log.append(dict(step="повтор до отчёта", rc=rc))
    print(log[-1], flush=True)
    assert rc == 0
    # 6. повтор готового — ничего не пересчитывает
    t1 = time.time()
    rc = finish("itest_cut")
    log.append(dict(step="повтор готового прогона", rc=rc, t=round(time.time() - t1, 1)))
    print(log[-1], flush=True)
    # сравнение
    ra, repa, _ = dirs("itest_ref")
    A = json.loads((repa / "metrics.json").read_text())
    B = json.loads((rep / "metrics.json").read_text())
    cmp_all = compare(A, B)
    hist_a = [h["val"] for h in A["main"]["history"]]
    hist_b = [h["val"] for h in B["main"]["history"]]
    base = C.expand(C.load_config(HERE / "config.yaml", smoke=True)["paths"]["base"],
                    C.load_config(HERE / "config.yaml", smoke=True))
    dup = dict(runs=[x.name for x in (base / "runs").glob("*itest_cut")], reports=[x.name for x in (base / "reports").glob("*itest_cut")],
               tmp_left=[str(x) for x in run.rglob("*.tmp*")] + [str(x) for x in rep.rglob("*.tmp*")])
    res = dict(log=log, compare=cmp_all, val_history_equal=hist_a == hist_b,
               val_history_max_abs=max(abs(x - y) for x, y in zip(hist_a, hist_b)) if len(hist_a) == len(hist_b) else None,
               epochs=(len(hist_a), len(hist_b)), layout=dup, verdict_a=C.read_json(repa / "manifest.json")["verdict"],
               verdict_b=C.read_json(rep / "manifest.json")["verdict"])
    out = HERE / "tests" / "out"
    out.mkdir(exist_ok=True)
    C.atomic_write_json(out / "interrupt_result.json", res)
    print(json.dumps(res["compare"], ensure_ascii=False, indent=1))
    print("история проверки совпадает:", res["val_history_equal"], "; max |Δ| =", res["val_history_max_abs"])
    print("каталоги:", dup)
    assert len(dup["runs"]) == 1 and len(dup["reports"]) == 1 and not dup["tmp_left"]
    print("ok")


if __name__ == "__main__":
    main()
