#!/usr/bin/env python3
"""Тест прерывания набора (§4.6 плана, приёмка NN-P1): набор `chaos` (8 случаев) во временном AIR_NN_DATA.

1. Эталон: `run --dataset chaos` без прерываний (отдельный корень данных).
2. Тот же набор в другом корне, с паузами в узких местах записи (AIRNN_P1_TEST_PAUSE): kill -9 в случайный момент счёта,
   kill -9 между записью временного файла и переименованием, kill -9 между переименованием и статусом done,
   SIGINT (мягкая остановка, ждём код 2), ещё kill -9 в случайный момент, затем run до конца (код 0).
3. Сравнение: файлы побитно равны эталону (sha256), у каждого случая ровно одна строка done и файл, нет running,
   нет недописанных *.part, лишних файлов нет; контрактный тест на обоих корнях.
Итог — tests/out/interrupt_result.json. Убивает только процессы, которые запустил сам (по PID).

  .venv/bin/python tests/test_interrupt.py [--seed N] [--keep]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import dataset as DS  # noqa: E402
import test_contract_sample as TC  # noqa: E402

PY = str(HERE / ".venv/bin/python")
NAME = "chaos"
PAUSE = 2.0


def run_cmd(root, log, extra_env=None):
    env = dict(os.environ)
    env.pop("AIR_NN_DATA", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.Popen([PY, str(HERE / "dataset.py"), "run", "--dataset", NAME, "--data-root", str(root),
                             "--log", str(log)], cwd=HERE, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def wait_marker(proc, log, pat, start_at, timeout=1800, nth=1):
    """Ждать nth-ю строку с pat в логе после байта start_at; None — процесс завершился раньше."""
    t0 = time.time()
    pb = pat.encode()
    while time.time() - t0 < timeout:
        txt = log.read_bytes() if log.exists() else b""
        if txt[start_at:].count(pb) >= nth:
            return True
        if proc.poll() is not None:
            return None
        time.sleep(0.05)
    raise TimeoutError(pat)


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=int(time.time()) % 100000)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    base = Path(os.environ.get("AIR_NN_DATA") or cfg["data_root"]) / "pilot" / "tmp" / f"chaos_{os.getpid()}"
    ref_root, run_root = base / "ref", base / "run"
    logs = base / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    steps = []
    t_all = time.time()

    # 1. эталон
    p = run_cmd(ref_root, logs / "ref.log")
    rc = p.wait()
    assert rc == 0, f"эталон: код {rc}\n{p.stderr.read().decode()[-2000:]}"
    steps.append(dict(step="эталон без прерываний", rc=rc))

    # 2. прерывания
    log = logs / "run.log"
    # (как, где, какое по счёту вхождение метки в этом запуске)
    plan_ = [("kill9", "random", 1), ("kill9", "before-rename", 2), ("kill9", "before-done", 1), ("sigint", "random", 1),
             ("kill9", "random", 1)]
    env = {"AIRNN_P1_TEST_PAUSE": str(PAUSE)}
    for how, where, nth in plan_:
        pos = log.stat().st_size if log.exists() else 0
        p = run_cmd(run_root, log, env)
        ok = wait_marker(p, log, "замок GPU получен", pos)
        assert ok, f"процесс завершился до счёта (код {p.returncode}) — мало случаев для теста"
        if where == "random":
            delay = rnd.uniform(3.0, 20.0)
            t_end = time.time() + delay
            while time.time() < t_end and p.poll() is None:
                time.sleep(0.02)
            detail = f"через {delay:.1f} с после замка GPU"
        else:
            ok = wait_marker(p, log, f"[test] pause {where}", pos, nth=nth)
            assert ok, f"процесс завершился до метки {where}"
            time.sleep(PAUSE * rnd.uniform(0.2, 0.8))
            detail = f"на паузе {where} (случай {nth} запуска)"
        assert p.poll() is None, "процесс уже завершился — мало случаев для теста"
        if how == "kill9":
            os.kill(p.pid, signal.SIGKILL)
            rc = p.wait()
        else:
            os.kill(p.pid, signal.SIGINT)
            rc = p.wait(timeout=120)
            assert rc == DS.EXIT_SIGNAL, f"SIGINT: код {rc}, ждали {DS.EXIT_SIGNAL}"
        con = sqlite3.connect(run_root / "pilot/datasets" / DS.solver_version() / NAME / "state.sqlite")
        n_done = con.execute("SELECT COUNT(*) FROM cases WHERE status='done'").fetchone()[0]
        con.close()
        steps.append(dict(step=f"{how} {detail}", rc=rc, done_after=n_done))
        print(steps[-1], flush=True)

    # 3. до конца
    pos = log.stat().st_size
    p = run_cmd(run_root, log)
    rc = p.wait()
    assert rc == 0, f"продолжение: код {rc}\n{p.stderr.read().decode()[-2000:]}"
    steps.append(dict(step="продолжение до конца", rc=rc))
    tail = log.read_text()[pos:]

    # 4. сравнение
    Lr = DS.Layout(cfg, ref_root, NAME)
    Lx = DS.Layout(cfg, run_root, NAME)
    plan = json.loads(Lr.plan.read_text())
    ids = [c["id"] for c in plan["cases"]]
    assert Lr.plan.read_bytes() == Lx.plan.read_bytes(), "plan.json различаются"
    diff, missing = [], []
    for cid in ids:
        fr, fx = Lr.case_file(cid), Lx.case_file(cid)
        if not fx.exists():
            missing.append(cid)
        elif sha(fr) != sha(fx):
            diff.append(cid)
    extra = sorted({p.stem for p in Lx.cases.glob("*.npz")} - set(ids))
    con = sqlite3.connect(Lx.db)
    st = dict(con.execute("SELECT status, COUNT(*) FROM cases GROUP BY status").fetchall())
    dup = con.execute("SELECT COUNT(*) - COUNT(DISTINCT id) FROM cases").fetchone()[0]
    bad_sha = [r[0] for r in con.execute("SELECT id, sha256 FROM cases WHERE status='done'")
               if not Lx.case_file(r[0]).exists() or sha(Lx.case_file(r[0])) != r[1]]
    ev = dict(con.execute("SELECT kind, COUNT(*) FROM events GROUP BY kind").fetchall())
    att = dict(con.execute("SELECT id, attempts FROM cases").fetchall())
    con.close()
    parts = [str(p) for p in Lx.tmp.glob("*.part")]
    n_ref = TC.check(NAME, ref_root)
    n_run = TC.check(NAME, run_root)
    res = dict(seed=a.seed, cases=len(ids), steps=steps, identical=len(ids) - len(diff) - len(missing), differ=diff,
               missing=missing, extra_files=extra, statuses=st, duplicate_rows=dup, done_without_file_or_sha=bad_sha,
               leftover_parts=parts, events=ev, attempts=att, contract_ref=n_ref, contract_run=n_run,
               minutes=round((time.time() - t_all) / 60, 1), solver_version=DS.solver_version(),
               recovered_lines=[ln for ln in log.read_text().splitlines() if "продолжение:" in ln])
    ok = (not diff and not missing and not extra and st == {"done": len(ids)} and dup == 0 and not bad_sha and not parts)
    res["ok"] = ok
    out = HERE / "tests/out/interrupt_result.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(res, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps(res, ensure_ascii=False, indent=1))
    if ok and not a.keep:
        shutil.copy(log, HERE / "tests/out/interrupt_run.log")
        shutil.rmtree(base)
    print("ИТОГ:", "ok — набор после прерываний побитно равен непрерванному" if ok else "ПРОВАЛ")
    _ = tail
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
