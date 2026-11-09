"""Строки/сводки SWG2 по результатам расчёта: rows, summary, masts, decomp, scan (формат docs/contracts/sw-ground.md)."""
from __future__ import annotations

import math
from collections import defaultdict

import numpy as np

from . import common as K


def rel_row(case, variant, id_, typ, z, ref_kind, s_ref, s_pan):
    rel = (s_pan - s_ref) / s_ref
    use = "справочно" if (ref_kind != "mast" and z < 50.0) else "эталон"
    return dict(case=case, variant=variant, id=id_, type=typ, z_agl=float(z), ref_kind=ref_kind, ref_use=use,
                s_ref=float(s_ref), s_pan=float(s_pan), rel_err=float(rel), within_tol=bool(abs(rel) <= K.TOL + 1e-12))


def summarize(rows):
    g = defaultdict(list)
    for r in rows:
        if r["ref_kind"] == "mast":
            continue
        g[(r["case"], r["variant"], r["type"], r["z_agl"], r["ref_kind"])].append(r)
    out = []
    for (c, v, t, z, rk), rr in sorted(g.items()):
        rel = np.array([r["rel_err"] for r in rr])
        out.append(dict(case=c, variant=v, type=t, z_agl=z, ref_kind=rk, n=len(rr),
                        frac_tol=float(np.mean([r["within_tol"] for r in rr])), mean_rel=float(rel.mean()),
                        median_rel=float(np.median(rel))))
    return out


def mast_stats(rows):
    g = defaultdict(list)
    for r in rows:
        if r["ref_kind"] == "mast":
            g[(r["case"], r["variant"], r["type"])].append(r)
            g[(r["case"], r["variant"], "all")].append(r)
    out = []
    for (c, v, t), rr in sorted(g.items()):
        d = np.array([r["s_pan"] - r["s_ref"] for r in rr])
        out.append(dict(case=c, variant=v, type=t, n=len(rr), rmse_s=float(np.sqrt(np.mean(d * d))),
                        frac_tol=float(np.mean([r["within_tol"] for r in rr]))))
    return out


def finite_rows(rows):
    return [r for r in rows if all(math.isfinite(r[k]) for k in ("s_ref", "s_pan", "rel_err"))]
