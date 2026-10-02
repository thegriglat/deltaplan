#!/usr/bin/env python3
"""Область без окон = d400_* того же случая, посчитанного с окнами, побитно (П1 v2, тест NN-P6).

Случаи набора main (П1 v1: с окнами, предел ref_study.MAXIT = 3000) пересчитываются `solve_case(c, [],
max_outer=3000)` — только область, тот же предел; d400_h, d400_m, d400_hc, d400_H, d400_hbl должны совпасть с
файлом main побитно (float16), статусы и итерации решений области — с метаданными main. Случаи: 1 max (оба решения
не сошлись — 3000 итераций), 2 ok (одно — медленно сходящееся). Второй предел (terrain.max_outer) проверяется на
ok-случае, сошедшемся раньше предела: тот же результат.

  .venv/bin/python tests/test_region_only.py [--ids a,b,c]
GPU — под замком пилота (на всё время теста, ~2 мин). Итог — tests/out/region_only.json.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import dataset as DS  # noqa: E402

KEYS = ("d400_h", "d400_m", "d400_hc", "d400_H", "d400_hbl")


def default_ids(con):
    rows = con.execute("SELECT id, runs FROM cases WHERE status='done' ORDER BY ord").fetchall()
    mx = ok_fast = ok_slow = None
    for cid, runs in rows:
        R = json.loads(runs)
        h, m = R["d400_h"], R["d400_m"]
        if mx is None and h["status"] == m["status"] == "max" and cid.startswith(("altai", "ongudai")):
            mx = cid
        if ok_fast is None and h["status"] == m["status"] == "ok" and max(h["iters"], m["iters"]) < 200 and cid.startswith("aushkul"):
            ok_fast = cid
        if ok_slow is None and h["status"] == m["status"] == "ok" and 500 < max(h["iters"], m["iters"]) < 900:
            ok_slow = cid
    return [mx, ok_fast, ok_slow]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", default="")
    a = ap.parse_args()
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    root = os.environ.get("AIR_NN_DATA") or cfg["data_root"]
    L = DS.Layout(cfg, root, "main")
    con = sqlite3.connect(f"file:{L.db}?mode=ro", uri=True)
    plan = json.loads(L.plan.read_text())
    conds = {c["id"]: c for c in plan["cases"]}
    ids = [s for s in a.ids.split(",") if s] or default_ids(con)
    cap2 = int(cfg["terrain"]["max_outer"])
    import procedural as PR
    PR.configure(plan["proc"]["seed"])
    import airlite_gen as G
    res, ok = [], True
    with DS.GpuLock(DS.Stopper(False)):
        for cid in ids:
            runs = json.loads(con.execute("SELECT runs FROM cases WHERE id=?", (cid,)).fetchone()[0])
            caps = [3000]
            if all(runs[f"d400_{t}"]["status"] == "ok" and runs[f"d400_{t}"]["iters"] < cap2 for t in "hm"):
                caps.append(cap2)
            with np.load(L.case_file(cid)) as z:
                ref = {k: z[k] for k in KEYS}
            for cap in caps:
                meta, arr = G.solve_case(conds[cid], [], max_outer=cap)
                assert list(arr) == ["d400_h", "d400_hc", "d400_H", "d400_hbl", "d400_m"], list(arr)
                eq = {k: bool(arr[k].dtype == np.float16 and np.array_equal(arr[k].view(np.uint16), ref[k].view(np.uint16)))
                      for k in KEYS}
                its = {t: (meta["runs"][f"d400_{t}"]["status"], meta["runs"][f"d400_{t}"]["iters"]) for t in "hm"}
                its_ref = {t: (runs[f"d400_{t}"]["status"], runs[f"d400_{t}"]["iters"]) for t in "hm"}
                good = all(eq.values()) and its == its_ref
                ok &= good
                res.append(dict(case=cid, max_outer=cap, equal=eq, runs=its, runs_main=its_ref, ok=good))
                print(f"{cid} предел {cap}: {'побитно равно' if good else 'РАЗЛИЧИЕ'} {eq} {its}", flush=True)
    out = HERE / "tests/out/region_only.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(dict(ok=ok, cases=res, solver_version=DS.solver_version()), ensure_ascii=False, indent=1) + "\n")
    print("ИТОГ:", "ok — область без окон = d400_* с окнами побитно" if ok else "ПРОВАЛ")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
