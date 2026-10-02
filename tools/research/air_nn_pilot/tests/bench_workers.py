#!/usr/bin/env python3
"""Кривая «случаев в час от числа воркеров N = 1…4» (NN-P6) на 12 случаях main «только область» (набор bench12:
4 max + 8 ok, предел terrain.max_outer) с проверкой побитности.

Для каждого N — свой временный корень данных, `dataset.py run --dataset bench12 --workers N --batch-s 1e6`: одна
пачка — замок GPU держится на весь прогон N (чужое обучение не искажает время); воркеры готовятся (импорт, CUDA)
до замка. Скорость — n / (конец − начало пачки) из таблицы batches. Во время пачки — nvidia-smi раз в 0,5 с
(загрузка GPU, память). Побитность: sha256 файлов случаев одинаковы при всех N; d400_* случаев, у которых оба
решения в main сошлись раньше предела, равны файлу main.

  .venv/bin/python tests/bench_workers.py [--ns 1,2,3,4] [--keep]   → tests/out/workers_bench.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import dataset as DS  # noqa: E402

PY = str(HERE / ".venv/bin/python")
NAME = "bench12"


class Smi(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.rows, self.stop = [], False

    def run(self):
        while not self.stop:
            try:
                o = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu,memory.used", "--format=csv,noheader,nounits"],
                                   capture_output=True, text=True, timeout=5).stdout.strip().split(",")
                self.rows.append((time.time(), float(o[0]), float(o[1])))
            except Exception:  # noqa: BLE001
                pass
            time.sleep(0.5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ns", default="1,2,3,4")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    root = Path(os.environ.get("AIR_NN_DATA") or cfg["data_root"])
    Lm = DS.Layout(cfg, root, "main")
    con = sqlite3.connect(f"file:{Lm.db}?mode=ro", uri=True)
    ids = cfg["datasets"][NAME]["ids"]
    cap = int(cfg["terrain"]["max_outer"])
    main_runs = {cid: json.loads(con.execute("SELECT runs FROM cases WHERE id=?", (cid,)).fetchone()[0]) for cid in ids}
    con.close()
    res, files = [], {}
    for n in [int(x) for x in a.ns.split(",")]:
        r = root / "pilot/tmp" / f"nnp6_bench_n{n}"
        shutil.rmtree(r, ignore_errors=True)
        log = r / "run.log"
        env = dict(os.environ)
        env.pop("AIR_NN_DATA", None)
        smi = Smi()
        smi.start()
        t0 = time.time()
        p = subprocess.run([PY, str(HERE / "dataset.py"), "run", "--dataset", NAME, "--data-root", str(r), "--workers",
                            str(n), "--batch-s", "1000000", "--log", str(log)], cwd=HERE, env=env)
        smi.stop = True
        smi.join()
        assert p.returncode == 0, f"N={n}: код {p.returncode}"
        L = DS.Layout(cfg, r, NAME)
        c = sqlite3.connect(L.db)
        b = c.execute("SELECT t_start, t_end, lock_wait, n_cases FROM batches").fetchall()
        rows = c.execute("SELECT id, t_wall, solve_status, sha256, runs FROM cases").fetchall()
        c.close()
        assert len(b) == 1 and b[0][3] == len(ids), f"N={n}: пачек {len(b)}, {b}"
        t_b = b[0][1] - b[0][0]
        u = [x for x in smi.rows if b[0][0] <= x[0] <= b[0][1]]
        files[n] = {cid: sha for cid, _, _, sha, _ in rows}
        res.append(dict(n=n, cases=len(rows), batch_s=round(t_b, 1), rate_per_h=round(len(rows) / t_b * 3600, 1),
                        lock_wait_s=round(b[0][2], 1), wall_total_s=round(time.time() - t0, 1),
                        case_t_wall_mean_s=round(float(np.mean([x[1] for x in rows])), 2),
                        n_max=sum(x[2] == "max" for x in rows),
                        gpu_util_mean=round(float(np.mean([x[1] for x in u])), 1) if u else None,
                        gpu_mem_peak_mb=max((x[2] for x in u), default=None)))
        print(res[-1], flush=True)
        if n == 1:
            ref_dir = L
    # побитность
    ns = sorted(files)
    same_n = all(files[n] == files[ns[0]] for n in ns)
    vs_main = {}
    for cid in ids:
        mr = main_runs[cid]
        if all(mr[f"d400_{t}"]["status"] == "ok" and mr[f"d400_{t}"]["iters"] < cap for t in "hm"):
            with np.load(ref_dir.case_file(cid)) as z1, np.load(Lm.case_file(cid)) as z0:
                vs_main[cid] = all(np.array_equal(z1[k].view(np.uint16), z0[k].view(np.uint16))
                                   for k in ("d400_h", "d400_m", "d400_hc", "d400_H", "d400_hbl"))
    bitwise = same_n and all(vs_main.values()) and len(vs_main) >= 6
    best = max(r["rate_per_h"] for r in res)
    chosen = min(r["n"] for r in res if r["rate_per_h"] >= 0.95 * best)
    out = dict(what="случаев в час от числа воркеров на 12 случаях main «только область» (bench12), предел "
                    f"{cap} итераций; замок GPU — на весь прогон N", ids=ids, max_outer=cap, curve=res,
               bitwise=bitwise, same_files_all_n=same_n, equal_to_main_ok_cases=vs_main,
               chosen_n=chosen, rule="наименьшее N со скоростью ≥ 95 % лучшей",
               speedup={r["n"]: round(r["rate_per_h"] / res[0]["rate_per_h"], 2) for r in res})
    o = HERE / "tests/out/workers_bench.json"
    o.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps({k: out[k] for k in ("chosen_n", "bitwise", "speedup")}, ensure_ascii=False))
    if not a.keep:
        for n in ns:
            shutil.rmtree(root / "pilot/tmp" / f"nnp6_bench_n{n}", ignore_errors=True)
    return 0 if bitwise else 1


if __name__ == "__main__":
    sys.exit(main())
