#!/usr/bin/env python3
"""Сводка пробы П1 v3 (NN-17): доля max, late_spread60_p90 по max-решениям, время случая v3 против v2.

Вход: набор probe (П1 v3, корень данных по умолчанию) и probe_v2 (та же проба без late_mean, корень --v2-root).
Время — t_wall случая (решение h и m + снимки + запись), по группам: «сошедшиеся» (оба решения ok) и «есть max».
Проверка побитности: у сошедшихся решений d400_* v3 = v2.

  .venv/bin/python tests/probe_v3_summary.py --v2-root DIR    → tests/out/probe_v3.json
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


def rows(L):
    con = sqlite3.connect(f"file:{L.db}?mode=ro", uri=True)
    out = {cid: dict(t_wall=t, runs=json.loads(r)) for cid, t, r in
           con.execute("SELECT id, t_wall, runs FROM cases WHERE status='done'")}
    con.close()
    return out


def st(x):
    x = np.asarray(x, float)
    if not len(x):
        return None
    return dict(n=int(len(x)), median=round(float(np.median(x)), 4), p90=round(float(np.percentile(x, 90)), 4),
                mean=round(float(np.mean(x)), 4), max=round(float(np.max(x)), 4))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--v2-root", required=True)
    a = ap.parse_args()
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    root = os.environ.get("AIR_NN_DATA") or cfg["data_root"]
    L3, L2 = DS.Layout(cfg, root, "probe"), DS.Layout(cfg, a.v2_root, "probe_v2")
    r3, r2 = rows(L3), rows(L2)
    common = sorted(set(r3) & set(r2))
    sols = [(cid, t, r3[cid]["runs"][f"d400_{t}"]) for cid in sorted(r3) for t in "hm"]
    mx = [s for s in sols if s[2]["status"] == "max"]
    spread = {t: [s[2]["late_spread60_p90"] for s in mx if s[1] == t] for t in "hm"}
    grp = {"ok": [], "max": []}
    bitwise = []
    for cid in common:
        g = "ok" if all(r3[cid]["runs"][f"d400_{t}"]["status"] == "ok" for t in "hm") else "max"
        grp[g].append((r3[cid]["t_wall"], r2[cid]["t_wall"],
                       sum(r3[cid]["runs"][f"d400_{t}"]["t_solve"] for t in "hm"),
                       sum(r2[cid]["runs"][f"d400_{t}"]["t_solve"] for t in "hm")))
        with np.load(L3.case_file(cid)) as z3, np.load(L2.case_file(cid)) as z2:
            for t in "hm":
                same = (r3[cid]["runs"][f"d400_{t}"]["status"], r3[cid]["runs"][f"d400_{t}"]["iters"]) == \
                       (r2[cid]["runs"][f"d400_{t}"]["status"], r2[cid]["runs"][f"d400_{t}"]["iters"])
                eq = bool(np.array_equal(z3[f"d400_{t}"].view(np.uint16), z2[f"d400_{t}"].view(np.uint16)))
                bitwise.append(dict(case=cid, sol=t, status=r3[cid]["runs"][f"d400_{t}"]["status"], same_iters=same,
                                    bitwise=eq))
    tm = {}
    for g, v in grp.items():
        if not v:
            continue
        v = np.asarray(v)
        tm[g] = dict(n=len(v), t_wall_v3=round(float(v[:, 0].mean()), 2), t_wall_v2=round(float(v[:, 1].mean()), 2),
                     ratio_wall=round(float(v[:, 0].sum() / v[:, 1].sum()), 3),
                     t_solve_v3=round(float(v[:, 2].mean()), 2), t_solve_v2=round(float(v[:, 3].mean()), 2))
    ok_bit = all(b["bitwise"] for b in bitwise if b["status"] == "ok")
    max_diff = all(not b["bitwise"] for b in bitwise if b["status"] == "max")
    out = dict(
        n_cases=len(r3), n_solutions=len(sols), n_max=len(mx),
        frac_max_solutions=round(len(mx) / max(len(sols), 1), 3),
        frac_cases_with_max=round(sum(any(r3[c]["runs"][f"d400_{t}"]["status"] == "max" for t in "hm") for c in r3) / max(len(r3), 1), 3),
        late_n=sorted({s[2]["late_n"] for s in mx}),
        late_spread60_p90_max=dict(all=st(spread["h"] + spread["m"]), h=st(spread["h"]), m=st(spread["m"])),
        per_max=[dict(case=c, sol=t, spread=s["late_spread60_p90"], iters=s["iters"]) for c, t, s in mx],
        time=tm, converged_bitwise_v3_eq_v2=ok_bit, max_differs_from_v2=max_diff, bitwise=bitwise,
        statuses_same_v3_v2=all(b["same_iters"] for b in bitwise),
        roots=dict(v3=str(L3.dir), v2=str(L2.dir)))
    p = HERE / "tests/out/probe_v3.json"
    p.parent.mkdir(exist_ok=True)
    p.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps({k: v for k, v in out.items() if k not in ("bitwise", "per_max")}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
