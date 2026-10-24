#!/usr/bin/env python3
"""R7 v1 check: residual -> field deviation summary (picard-rs, PR-n). Stdlib only.

Usage: check_residual.py <summary.json>
Exit 0 and prints `ok series=<n> points=<m>` when the file follows R7 v1.
"""
import json
import math
import sys

REGIONS = ["domain", "launch", "agl_10_50", "agl_50_100", "agl_100_200", "agl_200_400", "thermals", "slopes"]
COLD = ["ongudai_d400_u3_heat", "ongudai_d400_u3_mech", "ongudai_d400_u0_heat", "ongudai_d400_u6_heat"]
WARM = {"ongudai_d400_u3_heat_h1215": "ongudai_d400_u3_heat_h1200"}
COLD_N = [30, 50, 100, 150]
WARM_N = [10, 20, 30, 50]
TOL = [3.0, 10.0, 30.0]
RES = ["mom_rms", "div_rms", "th_rms"]
DEV = ["du_max", "du_rms", "dw_max", "dw_rms"]
FLOWS = ["thermal_w_peak_err", "thermal_w_mean_err", "slope_w_mean_err"]


def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def check_point(errs, where, p, ref_iters):
    by = p.get("by")
    if by not in ("iter", "tol_scale"):
        errs.append(f"{where}: by={by!r}")
        return
    if not isinstance(p.get("N"), int) or p["N"] < 1:
        errs.append(f"{where}: N")
    if by == "tol_scale" and not num(p.get("tol_scale")):
        errs.append(f"{where}: tol_scale")
    if not num(p.get("t_s")) or p["t_s"] < 0:
        errs.append(f"{where}: t_s")
    r = p.get("residuals") or {}
    errs += [f"{where}: residuals.{k}" for k in RES if not num(r.get(k))]
    dev = p.get("dev") or {}
    for reg in REGIONS:
        d = dev.get(reg)
        if not isinstance(d, dict):
            errs.append(f"{where}: dev.{reg}")
            continue
        errs += [f"{where}: dev.{reg}.{k}" for k in DEV if not num(d.get(k)) or d[k] < 0]
        if all(num(d.get(k)) for k in DEV) and (d["du_rms"] > d["du_max"] * (1 + 1e-6) or d["dw_rms"] > d["dw_max"] * (1 + 1e-6)):
            errs.append(f"{where}: dev.{reg} rms > max")
    f = p.get("flows") or {}
    errs += [f"{where}: flows.{k}" for k in FLOWS if not num(f.get(k))]


def check_series(errs, s, need_n, need_tol):
    where = f"{s.get('case')}/{s.get('start')}"
    ref = s.get("ref") or {}
    if not isinstance(ref.get("iters"), int) or not num(ref.get("t_s")):
        errs.append(f"{where}: ref.iters/t_s")
    rr = ref.get("residuals") or {}
    errs += [f"{where}: ref.residuals.{k}" for k in RES if not num(rr.get(k))]
    pts = s.get("points") or []
    ref_iters = ref.get("iters") if isinstance(ref.get("iters"), int) else 10**9
    for i, p in enumerate(pts):
        check_point(errs, f"{where}#{i}", p, ref_iters)
    have_n = {p.get("N") for p in pts if p.get("by") == "iter"}
    for n in need_n:
        if n < ref_iters and n not in have_n:
            errs.append(f"{where}: no point by iter N={n}")
    have_t = {p.get("tol_scale") for p in pts if p.get("by") == "tol_scale"}
    for t in need_tol:
        if t not in have_t:
            errs.append(f"{where}: no point by tol_scale {t}")
    return len(pts)


def main(path):
    d = json.load(open(path))
    errs = []
    if d.get("version") != 1:
        errs.append("version != 1")
    if d.get("threads") != 8:
        errs.append("threads != 8")
    if not (d.get("host") or {}).get("git"):
        errs.append("host.git")
    regs = d.get("regions") or {}
    errs += [f"regions.{r}" for r in REGIONS if not isinstance(regs.get(r), str) or not regs[r].strip()]
    series = d.get("series") or []
    by_key = {(s.get("case"), s.get("start")): s for s in series}
    npts = 0
    for c in COLD:
        s = by_key.get((c, "cold"))
        if s is None:
            errs.append(f"no cold series {c}")
            continue
        npts += check_series(errs, s, COLD_N, TOL)
    for c, src in WARM.items():
        s = by_key.get((c, "warm"))
        if s is None:
            errs.append(f"no warm series {c}")
            continue
        if s.get("warm_from") != src:
            errs.append(f"{c}: warm_from != {src}")
        npts += check_series(errs, s, WARM_N, TOL)
    th = d.get("threshold") or {}
    if not isinstance(th.get("text"), str) or len(th["text"].strip()) < 40:
        errs.append("threshold.text")
    errs += [f"threshold.{k}" for k in ("launch_dw_max", "launch_du_max", "slopes_dw_max") if not num(th.get(k))]
    if not isinstance(th.get("residual"), dict) and not num(th.get("tol_scale")):
        errs.append("threshold.residual or threshold.tol_scale")
    src = th.get("sources") or []
    if not isinstance(src, list) or len([x for x in src if isinstance(x, str) and " — " in x]) < 2:
        errs.append("threshold.sources: >= 2 lines 'path[:line] — what'")
    if errs:
        print("\n".join(f"FAIL {e}" for e in errs))
        return 1
    print(f"ok series={len(series)} points={npts}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
