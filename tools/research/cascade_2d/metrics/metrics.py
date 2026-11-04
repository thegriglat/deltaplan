#!/usr/bin/env python3
"""Метрики M1 модуля cascade-2d: сравнение поля F1 с эталоном P25, базовые линии B_k.

  py metrics/metrics.py --case C1 [--ref <F1 P25>] [--fields <каталог или F1 ...>]
        [--baselines 400,200,100,50] [--out tools/research/cascade_2d/out/metrics]

Определения — docs/plan/cascade-2d.md «Метрики», форма вывода — docs/contracts/cascade-2d.md (M1 v1).
Все метрики считаются на сетке эталона (по клеткам воздуха эталона); поле другой сетки пересчитывается
линейной интерполяцией u (по x-граням и z-центрам), w (по x-центрам и z-граням), в земле эталона 0.
"""
import argparse
import csv
import glob
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "contract"))
import cascade2d_io as io  # noqa: E402

CASE_L = {"C0": 500.0, "C1": 500.0, "C2": 300.0, "C3": 500.0}
Z_I_C3 = 1500.0
ZS_SIGMA = np.arange(25.0, 300.0 + 1e-9, 25.0)
DEFAULT_OUT = os.path.join(HERE, "..", "out", "metrics")
SCALAR_KEYS = ("E_u", "E_w", "E_u_lee", "dS", "r_w", "L_rec", "L_rec_ref", "w_max", "w_max_ref",
               "F_up", "F_up_ref", "max_rel_div", "max_speed")


# ---------------- сетка и скорости ----------------

def centers(meta):
    xc = meta["x0"] + (np.arange(meta["nx"]) + 0.5) * meta["dx"]
    zc = meta["z0"] + (np.arange(meta["nz"]) + 0.5) * meta["dz"]
    return xc, zc


def cell_vel(arr):
    """Скорости клеток — среднее двух граней (float64)."""
    u = arr["u"].astype(np.float64)
    w = arr["w"].astype(np.float64)
    return 0.5 * (u[:, :-1] + u[:, 1:]), 0.5 * (w[:-1, :] + w[1:, :])


def z_agl(meta, arr):
    _, zc = centers(meta)
    return zc[:, None] - arr["h"].astype(np.float64)[None, :]


def same_grid(a, b):
    return (a["nx"] == b["nx"] and a["nz"] == b["nz"] and abs(a["dx"] - b["dx"]) < 1e-9
            and abs(a["dz"] - b["dz"]) < 1e-9 and abs(a["z0"] - b["z0"]) < 1e-9
            and abs(a["x0"] - b["x0"]) < 1e-9)


def _lin_axis(a, src0, ds, dst, axis):
    """Линейная интерполяция вдоль оси на равномерной сетке src0+i·ds, с линейной экстраполяцией."""
    n = a.shape[axis]
    t = (np.asarray(dst, np.float64) - src0) / ds
    if n == 1:
        i0 = np.zeros(t.shape, int)
        f = np.zeros(t.shape)
        a1 = a0 = np.take(a, i0, axis)
    else:
        i0 = np.clip(np.floor(t + 1e-9).astype(int), 0, n - 2)
        f = t - i0
        a0 = np.take(a, i0, axis)
        a1 = np.take(a, i0 + 1, axis)
    sh = [1] * a.ndim
    sh[axis] = -1
    f = f.reshape(sh)
    return a0 * (1 - f) + a1 * f


def _faces_x(m):
    return m["x0"] + np.arange(m["nx"] + 1) * m["dx"]


def _faces_z(m):
    return m["z0"] + np.arange(m["nz"] + 1) * m["dz"]


def resample(meta, arr, tmeta, tarr):
    """Поле F1 (meta, arr) на сетку эталона (tmeta, tarr): интерполяция u, w, th; в земле эталона
    (tu/tw = 0) скорость 0; cell, tu, tw, h — эталона. Возвращает (meta', arrays')."""
    xc, zc = centers(meta)
    txf, txc = _faces_x(tmeta), centers(tmeta)[0]
    tzf, tzc = _faces_z(tmeta), centers(tmeta)[1]
    u = _lin_axis(_lin_axis(arr["u"].astype(np.float64), meta["z0"] + 0.5 * meta["dz"], meta["dz"], tzc, 0),
                  meta["x0"], meta["dx"], txf, 1)
    w = _lin_axis(_lin_axis(arr["w"].astype(np.float64), meta["z0"], meta["dz"], tzf, 0),
                  meta["x0"] + 0.5 * meta["dx"], meta["dx"], txc, 1)
    th = _lin_axis(_lin_axis(arr["th"].astype(np.float64), meta["z0"] + 0.5 * meta["dz"], meta["dz"], tzc, 0),
                   meta["x0"] + 0.5 * meta["dx"], meta["dx"], txc, 1)
    u = u * (tarr["tu"] > 0)
    w = w * (tarr["tw"] > 0)
    nm = dict(meta)
    for k in ("dx", "dz", "nx", "nz", "x0", "z0"):
        nm[k] = tmeta[k]
    na = dict(u=u, w=w, th=th, cell=tarr["cell"], tu=tarr["tu"], tw=tarr["tw"], h=tarr["h"])
    return nm, na


def to_ref_grid(meta, arr, rmeta, rarr):
    if same_grid(meta, rmeta):
        return meta, arr
    return resample(meta, arr, rmeta, rarr)


def make_baseline(meta, arr, rmeta, rarr):
    """B_k: поле грубого Пикара (dx_k) на сетке эталона."""
    m, a = resample(meta, arr, rmeta, rarr)
    m["source"], m["variant"] = "baseline", f"B{meta['dx']}"
    m["parent_dx"], m["seed"] = None, None
    return m, a


# ---------------- профили ----------------

def col_interp(meta, arr, val, x, zq):
    """Значение величины клеток val (nz, nx) на высотах zq (z_agl) в точке x: линейно по z_agl внутри
    колонны (только клетки воздуха), линейно по x между центрами двух колонн. nan — нет воздуха."""
    xs, _ = centers(meta)
    t = (x - xs[0]) / meta["dx"]
    i0 = int(np.clip(np.floor(t + 1e-9), 0, meta["nx"] - 2))
    f = float(np.clip(t - i0, 0.0, 1.0))
    za = z_agl(meta, arr)
    out = 0.0
    for i, wgt in ((i0, 1 - f), (i0 + 1, f)):
        if wgt == 0.0:
            continue
        air = arr["cell"][:, i] > 0.5
        if not air.any():
            return np.full(np.shape(zq), np.nan)
        out = out + wgt * np.interp(zq, za[air, i], val[air, i])
    return out


def u_ref_value(meta, arr, x=-4800.0, z=100.0):
    ucell, _ = cell_vel(arr)
    return float(col_interp(meta, arr, np.abs(ucell), x, np.array([z]))[0])


# ---------------- метрики ----------------

def _f(v):
    if v is None:
        return None
    v = float(v)
    return v if math.isfinite(v) else None


def _regions(meta, arr, xc, L):
    xs, _ = centers(meta)
    za = z_agl(meta, arr)
    air = arr["cell"] > 0.5
    X = xs[None, :]
    roi = air & (za > 0) & (za <= 300) & (np.abs(X - xc) <= 3 * L)
    lee = air & (za > 0) & (za <= 300) & (X > xc) & (X <= xc + 6 * L)
    slope = air & (za >= 25) & (za <= 75) & (X >= xc - 2 * L) & (X <= xc)
    return roi, lee, slope


def l_rec(meta, arr, xc, L):
    """Длина самого длинного участка подряд колонн за гребнем (xc < x ≤ xc+6L), где u клетки нижнего
    ряда воздуха (z_agl ≤ 25 м) < 0, м (число колонн · dx); нет возврата — None."""
    ucell, _ = cell_vel(arr)
    xs, _ = centers(meta)
    za = z_agl(meta, arr)
    air = arr["cell"] > 0.5
    best = run = 0
    for i in range(meta["nx"]):
        neg = False
        if xc < xs[i] <= xc + 6 * L:
            ks = np.nonzero(air[:, i])[0]
            if ks.size and za[ks[0], i] <= 25.0 and ucell[ks[0], i] < 0:
                neg = True
        run = run + 1 if neg else 0
        best = max(best, run)
    return best * meta["dx"] if best else None


def thermal(meta, arr, xc, L):
    """(w_max по столбу |x − xc| ≤ 3L на всех высотах воздуха до z = 2000 м, F_up = Σ max(w,0)·dx на z = z_i/2 по |x − xc| ≤ 3L)."""
    _, wcell = cell_vel(arr)
    xs, zc = centers(meta)
    col = (np.abs(xs - xc) <= 3 * L)[None, :] & (arr["cell"] > 0.5) & (zc[:, None] <= 2000.0)
    wmax = float(wcell[col].max()) if col.any() else None
    zf = _faces_z(meta)
    zq = Z_I_C3 / 2
    t = (zq - zf[0]) / meta["dz"]
    k0 = int(np.clip(np.floor(t + 1e-9), 0, meta["nz"] - 1))
    fz = t - k0
    wl = arr["w"][k0].astype(np.float64) * (1 - fz) + arr["w"][k0 + 1].astype(np.float64) * fz
    sel = np.abs(xs - xc) <= 3 * L
    fup = float(np.maximum(wl[sel], 0).sum() * meta["dx"])
    return wmax, fup


def sigma_profiles(fields, xc, L):
    """fields — список (meta, arr) на общей сетке (V3h, разные seed). σ по ансамблю: на каждой z_agl
    (25…300 через 25) СКО отклонения от среднего по seed, усреднённое по колоннам ROI (с ddof=1 по seed).
    -> (sigma_u, sigma_w) списки; меньше двух полей — (None, None)."""
    n = len(fields)
    if n < 2:
        return None, None
    m0 = fields[0][0]
    xs, _ = centers(m0)
    cols = np.nonzero(np.abs(xs - xc) <= 3 * L)[0]
    res = []
    for comp in (0, 1):
        data = np.full((n, len(cols), len(ZS_SIGMA)), np.nan)
        for s, (m, a) in enumerate(fields):
            vel = cell_vel(a)[comp]
            for c, i in enumerate(cols):
                data[s, c, :] = col_interp(m, a, vel, xs[i], ZS_SIGMA)
        dev = data - np.nanmean(data, axis=0, keepdims=True)
        var = np.nansum(dev ** 2, axis=0) / (n - 1)  # (cols, z)
        res.append([_f(v) for v in np.sqrt(np.nanmean(var, axis=0))])
    return res[0], res[1]


def compute_metrics(meta, arr, rmeta, rarr, xc, L, U_ref, case, native=None):
    """Метрики поля (meta, arr — уже на сетке эталона) против эталона (rmeta, rarr). native — (meta, arr)
    поля на его собственной сетке, для баланса и max_speed."""
    uc, wc = cell_vel(arr)
    ur, wr = cell_vel(rarr)
    roi, lee, slope = _regions(rmeta, rarr, xc, L)
    out = {}
    out["E_u"] = _f(np.sqrt(np.mean((uc[roi] - ur[roi]) ** 2)) / U_ref) if roi.any() else None
    out["E_w"] = _f(np.sqrt(np.mean((wc[roi] - wr[roi]) ** 2)) / U_ref) if roi.any() else None
    out["E_u_lee"] = _f(np.sqrt(np.mean((uc[lee] - ur[lee]) ** 2)) / U_ref) if lee.any() else None
    zs = np.array([25.0, 50.0, 100.0])
    d = {}
    for name, (m, a, c) in (("f", (rmeta, arr, uc)), ("r", (rmeta, rarr, ur))):
        den = col_interp(m, a, np.abs(c), -4800.0, zs)
        num = col_interp(m, a, np.abs(c), xc, zs)
        d[name] = num / den - 1.0
    dd = np.abs(d["f"] - d["r"])
    out["dS"] = {"25": _f(dd[0]), "50": _f(dd[1]), "100": _f(dd[2]), "mean": _f(dd.mean())}
    wrm = wr[slope].mean() if slope.any() else 0.0
    out["r_w"] = _f(wc[slope].mean() / wrm) if slope.any() and abs(wrm) >= 1e-3 else None
    out["L_rec"] = l_rec(rmeta, arr, xc, L)
    out["L_rec_ref"] = l_rec(rmeta, rarr, xc, L)
    if case == "C3":
        out["w_max"], out["F_up"] = thermal(rmeta, arr, xc, L)
        out["w_max_ref"], out["F_up_ref"] = thermal(rmeta, rarr, xc, L)
    else:
        out["w_max"] = out["F_up"] = out["w_max_ref"] = out["F_up_ref"] = None
    nm, na = native if native is not None else (meta, arr)
    rd = io.rel_div(io.div2d(nm, na), nm["dx"], U_ref)
    out["max_rel_div"] = _f(rd.max())
    nu, nw = cell_vel(na)
    air = na["cell"] > 0.5
    out["max_speed"] = _f(np.sqrt(nu ** 2 + nw ** 2)[air].max()) if air.any() else 0.0
    return out


# ---------------- случай и каталоги ----------------

def case_xc_L(case):
    if case in CASE_L:
        return 0.0, CASE_L[case]
    if case == "C4":
        for p in sorted(glob.glob(os.path.join(io.data_dir(), "cases", "C4_d*.json"))):
            with open(p) as f:
                cp = (json.load(f) or {}).get("case_params") or {}
            if "x_c" in cp and "L" in cp:
                return float(cp["x_c"]), float(cp["L"])
        raise SystemExit("C4: нет case_params.x_c/L в cases/C4_d*.json (передайте --xc --L)")
    raise SystemExit(f"неизвестный случай {case}")


def find_fields(case, items):
    paths = []
    for it in items:
        if os.path.isdir(it):
            paths += sorted(glob.glob(os.path.join(it, "*.json")))
        else:
            paths.append(it)
    out = []
    for p in paths:
        try:
            with open(p) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(d, dict) and d.get("format") == "cascade2d-field" and d.get("case") == case:
            out.append(os.path.abspath(p))
    return out


def picard_path(case, dx):
    return os.path.join(io.data_dir(), "fields", case, f"picard_none_d{dx}.json")


# ---------------- главная часть ----------------

def run(case, ref_path, field_items, baselines, out_dir, xc=None, L=None):
    notes = []
    if xc is None or L is None:
        xc0, L0 = case_xc_L(case)
        xc = xc0 if xc is None else xc
        L = L0 if L is None else L
    ref_path = os.path.abspath(ref_path)
    rmeta, rarr = io.read_f1(ref_path)
    io.check_f1_arrays(rmeta, rarr)
    if rmeta["case"] != case or rmeta["source"] != "picard":
        raise SystemExit(f"ref {ref_path}: не picard случая {case}")
    if rmeta["dx"] != 25:
        notes.append(f"эталон P{rmeta['dx']} (P25 нет), метрики на сетке {rmeta['dx']} м")
    U_ref = u_ref_value(rmeta, rarr)
    if not U_ref > 0:
        raise SystemExit("U_ref <= 0")
    notes.append("U_ref: |u| клетки на 100 м над землёй, x=-4800 м (интерполяция между центрами колонн)")
    ref_dx = rmeta["dx"]

    entries = []  # (path, meta, arrays-native, is_baseline_mem)
    fpaths = find_fields(case, field_items)
    disk_variants = set()
    for p in fpaths:
        if p == ref_path:
            continue
        m, a = io.read_f1(p)
        if m["source"] == "picard":
            continue  # грубый Пикар представлен строками B_k
        io.check_f1_arrays(m, a)
        entries.append((p, m, a, False))
        if m["source"] == "baseline":
            disk_variants.add(m["variant"])
    for k in baselines:
        if k <= ref_dx or f"B{k}" in disk_variants:
            continue
        bp = picard_path(case, k)
        if not os.path.exists(bp):
            notes.append(f"нет {os.path.basename(bp)} — B{k} не построена")
            continue
        m, a = io.read_f1(bp)
        entries.append((bp, m, a, True))

    rows = []
    v3h = {}
    resampled = {}
    for p, m, a, is_b in entries:
        nat = (m, a)
        if is_b:
            rm, ra = make_baseline(m, a, rmeta, rarr)
        else:
            rm, ra = to_ref_grid(m, a, rmeta, rarr)
        met = compute_metrics(rm, ra, rmeta, rarr, xc, L, U_ref, case, native=nat)
        row = dict(field=p, source=rm["source"], variant=rm["variant"], dx=m["dx"],
                   parent_dx=rm["parent_dx"], seed=rm["seed"], **met, sigma_u=None, sigma_w=None)
        rows.append(row)
        if rm["variant"] == "V3h":
            v3h.setdefault((m["dx"], rm["parent_dx"]), []).append((row, rm, ra))
        resampled[p] = (rm, ra)
    for grp in v3h.values():
        seeds = {r["seed"] for r, _, _ in grp}
        if len(seeds) < 2:
            continue
        su, sw = sigma_profiles([(m, a) for _, m, a in grp], xc, L)
        for r, _, _ in grp:
            r["sigma_u"], r["sigma_w"] = su, sw

    E_ref = {}
    if ref_dx == 25 and 50 in baselines:
        bp = picard_path(case, 50)
        if os.path.exists(bp):
            m, a = io.read_f1(bp)
            bm, ba = make_baseline(m, a, rmeta, rarr)
            E_ref = compute_metrics(bm, ba, rmeta, rarr, xc, L, U_ref, case, native=(m, a))
        else:
            notes.append("нет picard_none_d50 — E_ref пуст")
    else:
        notes.append("E_ref пуст: нужна пара B50 против P25")
    rows.sort(key=lambda r: (r["source"], r["variant"] or "", -r["dx"], r["seed"] if r["seed"] is not None else -1))
    m1 = dict(format="cascade2d-metrics", version=1, case=case, ref=ref_path, U_ref=U_ref,
              E_ref=E_ref, rows=rows, notes=notes, x_c=xc, L=L)
    io.validate_m1(m1)
    write_outputs(m1, out_dir)
    return m1


def _atomic(path, writer):
    tmp = path + ".tmp"
    with open(tmp, "w", newline="") as f:
        writer(f)
    os.replace(tmp, path)


def write_outputs(m1, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    c = m1["case"]
    _atomic(os.path.join(out_dir, f"{c}.json"), lambda f: json.dump(m1, f, ensure_ascii=False, indent=1))
    cols = ["field", "source", "variant", "dx", "parent_dx", "seed", "E_u", "E_w", "E_u_lee",
            "dS_25", "dS_50", "dS_100", "dS_mean", "r_w", "L_rec", "L_rec_ref", "w_max", "w_max_ref",
            "F_up", "F_up_ref", "max_rel_div", "max_speed"]

    def wr(f):
        w = csv.writer(f)
        w.writerow(cols)
        for r in m1["rows"]:
            flat = dict(r)
            for k in ("25", "50", "100", "mean"):
                flat[f"dS_{k}"] = r["dS"][k]
            w.writerow(["" if flat.get(k) is None else flat[k] for k in cols])
    _atomic(os.path.join(out_dir, f"{c}.csv"), wr)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", required=True)
    ap.add_argument("--ref")
    ap.add_argument("--fields", nargs="+")
    ap.add_argument("--baselines", default="400,200,100,50")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--xc", type=float)
    ap.add_argument("--L", type=float)
    a = ap.parse_args(argv)
    ref = a.ref
    if ref is None:
        ref = picard_path(a.case, 25)
        if not os.path.exists(ref):
            ref = picard_path(a.case, 50)
    if not os.path.exists(ref):
        raise SystemExit(f"нет эталона {ref}")
    items = a.fields or [os.path.join(io.data_dir(), "fields", a.case)]
    bl = [int(s) for s in a.baselines.split(",") if s.strip()]
    m1 = run(a.case, ref, items, bl, a.out, a.xc, a.L)
    print(f"{a.case}: U_ref={m1['U_ref']:.4g}, строк {len(m1['rows'])} -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
