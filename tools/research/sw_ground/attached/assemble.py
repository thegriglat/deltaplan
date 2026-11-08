"""SWG-9: сборка out/swg-9/ground.json (SWG2 v1), diag.json (разбор с размерными числами) и tables.md из raw/probe_*.json.

Варианты: potential, potential_jh (база SWG-1, пересчитана здесь, проверка побитно), attached_jh (правило APG Таунсенда —
HLR 1988), attached_jh_nl (нелинейный Бернулли среднего слоя). Маска «в зоне / вне зоны» — zone_h > 0 по SWG-7
(out/swg-7/raw/pts_<case>.json; та же геометрия, что wake.run.make_grid(case, 'slope') + sheet.core.SheetGeom).
"""
from __future__ import annotations

import json
import math
from collections import defaultdict

import h5py
import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import model as M
from ground import tables as T
from panels3d.jh import KAPPA, L_FLAT, hill_length, inner_depth

from . import core as AC
from .run import OUT, RAW

ZS = (10.0, 50.0, 300.0)
SW7 = K.SG / "out" / "swg-7" / "raw"
CS = {"ASK_TU03B": "ASK", "PERD_NE": "NE", "PERD_SW": "SW"}
VARIANTS = {
    "potential": "SWD2 v5 потенциал: панели 3D + лог-фон, σ 40 м, ds_min 25 м, z0 — медиана растра, σ земли фона 250 м; "
                 "группы ≤ 40 (x, y) с фокусом ds_min 25 м (как SWG-1; пересчитано здесь)",
    "potential_jh": "SWD2 v5 потенциал + внутренний слой Jackson–Hunt (ground.model.jh_parts = velocity_jh); база SWG-1 "
                    "(пересчитано здесь, совпадает с out/swg-1 — base_check)",
    "attached_jh": "potential_jh + правило APG внутреннего слоя (основное): у колонок с гребнем (L < L_FLAT) ниже l равновесный слой Таунсенда τ/ρ = u*_w² + "
                   "G·z, G = −u0(h_m)²·∂ΔS/∂s (давление JH, ΔS однородного потенциала на высоте l, разность ±25 м вдоль "
                   "ветра), du/dz = √max(τ/ρ, 0)/(κz), u(z0) = 0, u(l) = u_JH(l) (сшивка задаёт u*_w); выше l — "
                   "potential_jh; G = 0 → potential_jh тождественно; Townsend 1961, Hunt, Leibovich & Richards 1988; "
                   "констант подбора нет",
    "attached_jh_nl": "potential_jh, но u_in = u0·√max(0, 1 + A((1+ΔS)² − 1)) вместо u0(1 + A·ΔS) — нелинейный Бернулли "
                      "невязкого среднего слоя (HLR 1988; JH — его линеаризация), без возврата скорости при 1 + A·ΔS < 0; "
                      "ΔS = 0 → potential_jh",
}
NEW = ("attached_jh", "attached_jh_nl")


def load(p):
    return json.load(open(p))


def fin(v):
    return v is not None and math.isfinite(v)


def arr(v):
    return np.array([np.nan if x is None else x for x in v], float)


# ---------------- Пикар в произвольной точке ----------------
class Picard:
    def __init__(self, case, s_norm_speed):
        with h5py.File(K.REFS / f"{case}.h5", "r") as h:
            g = h["picard_nom"]
            self.x, self.y, self.z = g["x"][:], g["y"][:], g["z_agl"][:].astype(float)
            sc = float(g["u"].attrs["scale"])
            u = g["u"][:].astype(float) * sc + float(g["u"].attrs["offset"])
            v = g["v"][:].astype(float) * sc + float(g["v"].attrs["offset"])
            self.e = np.array(h.attrs["wind_to"], float)
        self.sp = np.hypot(u, v)
        self.upar = (u * self.e[0] + v * self.e[1]) / np.hypot(*self.e)
        self.nsp = s_norm_speed

    def ij(self, x, y):
        i = np.clip(np.rint((np.asarray(x) - self.x[0]) / (self.x[1] - self.x[0])).astype(int), 0, self.x.size - 1)
        j = np.clip(np.rint((np.asarray(y) - self.y[0]) / (self.y[1] - self.y[0])).astype(int), 0, self.y.size - 1)
        return i, j

    def s(self, x, y, z):
        """s Пикара (линейно по z между уровнями SWD1, ближайшая клетка)."""
        i, j = self.ij(x, y)
        col = self.sp[:, j, i]                       # (nz, n)
        z = np.broadcast_to(np.asarray(z, float), np.shape(i))
        out = np.array([np.interp(zz, self.z, col[:, k]) for k, zz in enumerate(np.ravel(z))])
        return out / self.nsp

    def profile(self, x, y):
        i, j = self.ij(x, y)
        return (self.sp[:, j, i] / self.nsp).T       # (n, nz)

    def reverse10(self, x, y):
        i, j = self.ij(x, y)
        k = int(np.argmin(np.abs(self.z - 10.0)))
        return self.upar[k, j, i] < 0


# ---------------- геометрия колонок ----------------
def geometry(case, cx, cy):
    """Расстояние от ближайшего гребня вдоль ветра (м, > 0 — за гребнем), перепад гребень − точка (м), уклон земли вдоль
    ветра (σ 40 м, ±10 м), расстояние за точкой присоединения x_r ближайшей зоны SWG-4 на профиле (м; нет — nan)."""
    from wake.run import make_grid
    Tr, wt = M.C.load_terrain(case, M.C.SMOOTH_MAIN)
    e = np.asarray(wt, float)
    e = e / np.hypot(*e)
    dc, drop = np.full(cx.size, np.nan), np.full(cx.size, np.nan)
    zg = Tr.height(cx, cy)
    for k, (x, y) in enumerate(zip(cx, cy)):
        h = hill_length(Tr, x, y, wt)
        if h is not None:
            dc[k] = (x - h["x_c"]) * e[0] + (y - h["y_c"]) * e[1]
            drop[k] = h["z_c"] - zg[k]
    d = 10.0
    slope = (Tr.height(cx + d * e[0], cy + d * e[1]) - Tr.height(cx - d * e[0], cy - d * e[1])) / (2 * d)
    grid = make_grid(case, "slope")
    c, a = grid.rot(cx, cy)
    past = np.full(cx.size, np.nan)
    segs = [q for q in grid.segs if q["gated"] and q.get("s_r") is not None]
    if segs:
        qc = np.array([q["c"] for q in segs])
        qr = np.array([q["s_r"] for q in segs])
        for k in range(cx.size):
            m = np.abs(qc - c[k]) <= 0.5 * grid.dc + 1e-9
            dd = a[k] - qr[m]
            dd = dd[dd >= 0]
            if dd.size:
                past[k] = dd.min()
    return dict(dist_crest=dc, drop=drop, slope=slope, past_xr=past)


# ---------------- правила в точках ----------------
def rule_ratio(q, z0, rule, dSdx=None, u0hm=None, z_agl=None):
    """Отношение |скорость правила| / |скорость potential_jh| по величинам JH q (uin, uh, t, A, dS, u0, l — в долях
    U_ref; скаляры или массивы). Смешение (1 − t)·u_in + t·u_h — сонаправленно (точно при t = 0 и t = 1; внутри l t = 0)."""
    uin, uh, t, A, dS, u0, l = (np.asarray(q[k], float) for k in ("uin", "uh", "t", "A", "dS", "u0", "l"))
    info = {}
    if rule == "attached_jh":
        zz = np.maximum(np.asarray(z_agl, float), z0)
        # где гребня нет (L = L_FLAT, «ровная земля» JH), l — не высота слоя холма: правило не применяется
        hill = l < inner_depth(L_FLAT, z0) * (1 - 1e-9)
        inside = (zz < l) & (uin > 0) & hill
        uin_l = np.where(inside, uin * np.log(l / z0) / np.log(np.maximum(zz, 1.0001 * z0) / z0), 1.0)
        g = np.where(inside, AC.g_of(np.asarray(dSdx, float), np.asarray(u0hm, float), uin_l, l, z0), 0.0)
        fac, a = AC.apg_factor(np.where(inside, zz, l), np.where(inside, l, 1.0), z0, g)
        fac = np.where(inside, fac, 1.0)
        new = uin * fac
        info = dict(fac=fac, a=np.where(inside, a, np.nan), gl=np.where(inside, g * l, np.nan), inside=inside)
    elif rule == "attached_jh_nl":
        new = u0 * AC.nl_factor(A, dS)
    else:
        raise ValueError(rule)
    den = np.abs((1 - t) * uin + t * uh)
    num = np.abs((1 - t) * new + t * uh)
    r = np.where(den > 1e-9, num / np.maximum(den, 1e-12), 1.0)
    return r, info


def main():
    refs = E.load_refs()
    pts = load(K.OUT_POINTS)
    rows, decomp, diag = [], [], {}
    base_check, norm_info = {}, {}
    for case in K.CASES:
        pl = E.case_points(case, refs, pts)
        d = load(RAW / f"probe_{case}.json")
        assert d["ids"] == [p["id"] for p in pl]
        n = len(pl)
        P = {k: arr(v) for k, v in d["pt"].items()}
        z0 = d["z0"]
        col = np.array(d["col_of"])
        cx, cy = arr(d["col_x"]), arr(d["col_y"])
        C1 = {k: arr(d[k]) for k in ("l", "hm", "L", "u0hm", "dSdx")}
        line = np.array([arr(r) for r in d["dS_line"]])
        prof_jh = np.array([arr(r) for r in d["s_jh"]])
        zp = np.asarray(d["ZP"])
        off = np.asarray(d["OFF"])
        # база против SWG-1 (побитно)
        old = load(K.OUT_TASK / "raw" / f"base_{case}.json")
        oo = dict(zip(old["ids"], old["s_jh"]))
        dif = [abs(s - oo[i]) for i, s in zip(d["ids"], P["s_jh"]) if fin(s) and fin(oo.get(i))]
        base_check[case] = float(max(dif)) if dif else None
        # правила в точках и в опорной точке (по группам)
        zagl = np.array([p["z_agl"] for p in pl])
        S = {"potential": P["s_pot"], "potential_jh": P["s_jh"]}
        RI = {}
        for rule in NEW:
            r, info = rule_ratio(P, z0, rule, C1["dSdx"][col], C1["u0hm"][col], zagl)
            rn = np.full(n, np.nan)
            nr = []
            for gm in d["groups"]:
                q = gm["norm"]
                rr, _ = rule_ratio({k: q[k] for k in ("uin", "uh", "t", "A", "dS", "u0", "l")}, z0, rule,
                                   q["dSdx"], q["u0hm"], q["z_agl"])
                rn[gm["idx"]] = float(rr)
                nr.append(float(rr))
            S[rule] = P["s_jh"] * r / rn
            RI[rule] = info
            norm_info.setdefault(case, {})[rule] = dict(mean=float(np.mean(nr)), min=float(np.min(nr)),
                                                        max=float(np.max(nr)))
        for var, s in S.items():
            for i, p in enumerate(pl):
                if fin(s[i]) and p["s_ref"] > 0:
                    rows.append(T.rel_row(case, var, p["id"], p["type"], p["z_agl"], p["kind"], p["s_ref"], float(s[i])))
        # маска зоны SWG-7
        s7 = load(SW7 / f"pts_{case}.json")
        zh7 = dict(zip(s7["ids"], s7["zone_h"]))
        zone = np.array([(zh7.get(p["id"]) or 0.0) > 0 for p in pl])
        # Пикар: s в точке и профиль колонки
        prow = [r for r in pts["rows"] if r["case"] == case]
        nsp = float(np.median([r["speed_nom"] / r["s_nom"] for r in prow]))
        pic = Picard(case, nsp)
        geo = geometry(case, cx, cy)
        ppro = pic.profile(cx, cy)                    # (nc, nz)
        rev10 = pic.reverse10(cx, cy)
        # запаздывание (гипотеза «в»): ΔS на l, экспоненциальное окно против ветра с λ = l·ln(l/z0)/κ² (= 2L по
        # определению l JH) — без подбора
        lam = C1["l"] * np.log(C1["l"] / z0) / KAPPA ** 2
        w = np.where(off[None, :] <= 0, np.exp(off[None, :] / lam[:, None]), 0.0)
        dS_lag = np.nansum(w * line, 1) / np.nansum(np.where(np.isfinite(line), w, 0), 1)
        i0 = int(np.argmin(np.abs(off)))
        dS_loc = line[:, i0]
        sref = np.array([p["s_ref"] for p in pl])
        kind = np.array([p["kind"] for p in pl])
        typ = np.array([p["type"] for p in pl])
        dg = diag.setdefault(case, {})

        def add(t_, z, term, val, unit, note):
            if val is not None and np.isfinite(val):
                decomp.append(dict(case=case, type=t_, z_agl=float(z), term=term, value=float(val), unit=unit, note=note))

        for t_ in K.TYPES:
            for z in ZS:
                base = (kind == "picard_nom") & (typ == t_) & (zagl == z)
                if not base.any():
                    continue
                for sub, msk in (("", base), ("out_", base & ~zone)):
                    if not msk.any():
                        continue
                    nn = f"n={int(msk.sum())}; Пикар nom" + ("; вне зоны (zone_h SWG-7 = 0)" if sub else "")
                    rel = {v: (S[v][msk] - sref[msk]) / sref[msk] for v in S}
                    add(t_, z, sub + "total_jh", np.mean(rel["potential_jh"]), "rel", f"среднее rel_err potential_jh; {nn}")
                    add(t_, z, sub + "median_jh", np.median(rel["potential_jh"]), "rel", f"медиана rel_err potential_jh; {nn}")
                    add(t_, z, sub + "ds_jh", np.mean(S["potential_jh"][msk] - sref[msk]), "s",
                        f"среднее s_potential_jh − s_ref (абсолютно, без деления на малое s_ref); {nn}")
                    for v in NEW:
                        add(t_, z, sub + "total_" + v, np.mean(rel[v]), "rel", f"среднее rel_err {v}; {nn}")
                        add(t_, z, sub + "median_" + v, np.median(rel[v]), "rel", f"медиана rel_err {v}; {nn}")
                        add(t_, z, sub + "delta_" + v, np.mean((S[v][msk] - S["potential_jh"][msk]) / sref[msk]), "rel",
                            f"вклад правила {v}: mean((s_{v} − s_potential_jh)/s_ref); {nn}")
                    if not sub:
                        add(t_, z, "cover", np.mean(zone[msk]), "rel", f"доля точек над мёртвой зоной SWG-7; {nn}")
                        continue
                    cc = col[msk]
                    q = {k: P[k][msk] for k in P}
                    su_jh = 1 + q["A"] * q["dS"]
                    su_req = sref[msk] / S["potential_jh"][msk] * su_jh
                    add(t_, z, "out_su_jh", np.median(su_jh), "rel", f"медиана 1 + A·ΔS (множитель JH); {nn}")
                    add(t_, z, "out_su_req", np.median(su_req), "rel",
                        f"медиана нужного множителя (s_ref/s_jh)·(1 + A·ΔS) — при котором JH совпал бы с Пикаром; {nn}")
                    add(t_, z, "out_dS_l", np.median(q["dS"]), "rel", f"медиана ΔS однородного потенциала на max(z, l); {nn}")
                    add(t_, z, "out_dSdx_L", np.median(C1["dSdx"][cc] * C1["L"][cc]), "rel",
                        f"медиана L·∂ΔS/∂s на высоте l (градиент давления: < 0 — неблагоприятный); {nn}")
                    add(t_, z, "out_l_over_z", np.median(C1["l"][cc] / z), "rel", f"медиана l / z (l — JH); {nn}")
                    add(t_, z, "out_hm_over_z", np.median(C1["hm"][cc] / z), "rel", f"медиана h_m / z; {nn}")
                    add(t_, z, "out_dist_crest_L", np.nanmedian(geo["dist_crest"][cc] / C1["L"][cc]), "rel",
                        f"медиана расстояния от ближайшего гребня вдоль ветра / L (> 0 — за гребнем); {nn}")
                    add(t_, z, "out_far", np.mean(geo["dist_crest"][cc] > 2 * C1["L"][cc]), "rel",
                        f"доля точек дальше 2L за гребнем (дальний след, не склон); {nn}")
                    add(t_, z, "out_past_xr", np.mean(np.isfinite(geo["past_xr"][cc])), "rel",
                        f"доля точек за точкой присоединения x_r зоны SWG-4 на своём профиле; {nn}")
                    add(t_, z, "out_slope", np.median(geo["slope"][cc]), "rel", f"медиана уклона земли вдоль ветра; {nn}")
                    add(t_, z, "out_apg", np.mean(C1["dSdx"][cc] < 0), "rel",
                        f"доля точек с неблагоприятным градиентом (∂ΔS/∂s < 0 на l); {nn}")
                    add(t_, z, "out_picard_rev10", np.mean(rev10[cc]), "rel", f"доля колонок с u∥ < 0 у Пикара на 10 м; {nn}")
                    # профиль: дефицит Пикара относительно potential_jh по слоям
                    rat = 1.0 - ppro[cc] / prof_jh[cc]
                    l_, hm_ = C1["l"][cc][:, None], C1["hm"][cc][:, None]
                    zq = zp[None, :]
                    lv = zq >= 10.0                   # ниже 10 м: Пикар — значение первой клетки, у Perdigão z ≈ z0
                    for nm_, band in (("below_l", lv & (zq < l_)), ("l_hm", lv & (zq >= l_) & (zq < hm_)),
                                      ("above_hm", lv & (zq >= hm_))):
                        v = np.where(band, rat, np.nan)
                        add(t_, z, f"out_def_{nm_}", np.nanmean(v), "rel",
                            f"средний дефицит Пикара 1 − s_ref(z)/s_jh(z) по уровням SWD1 ≥ 10 м в слое {nm_} (l, h_m — "
                            f"JH колонки); {nn}")
                    # гипотеза «в»
                    su_lag = 1 + q["A"] * (dS_lag[cc] + (q["dS"] - dS_loc[cc]))
                    add(t_, z, "out_su_lag", np.median(su_lag), "rel",
                        f"медиана 1 + A·ΔS_lag (ΔS на l с экспоненциальной памятью против ветра, λ = l·ln(l/z0)/κ²); {nn}")
                    ok = np.isfinite(su_req) & np.isfinite(su_lag)
                    if ok.sum() > 5:
                        add(t_, z, "out_corr_local", np.corrcoef(su_req[ok], su_jh[ok])[0, 1], "rel",
                            f"корреляция нужного множителя с 1 + A·ΔS (локально); {nn}")
                        add(t_, z, "out_corr_lag", np.corrcoef(su_req[ok], su_lag[ok])[0, 1], "rel",
                            f"корреляция нужного множителя с 1 + A·ΔS_lag; {nn}")
                    ri = RI["attached_jh"]
                    ins = ri["inside"][msk]
                    add(t_, z, "out_inside_l", np.mean(ins), "rel", f"доля точек ниже l (правило APG действует); {nn}")
                    if ins.any():
                        add(t_, z, "out_Gl", np.median(ri["gl"][msk][ins]), "rel",
                            f"медиана G·l/u*_l² — параметр градиента давления Таунсенда (> 0 — неблагоприятный); {nn}")
                        add(t_, z, "out_tauw", np.median(ri["a"][msk][ins]), "rel",
                            f"медиана τ_w/τ_l = u*_w²/u*_l² (сшивка правила); < 0 — предотрывное; {nn}")
                        add(t_, z, "out_tauw_neg", np.mean(ri["a"][msk][ins] < 0), "rel", f"доля τ_w < 0; {nn}")
                        add(t_, z, "out_fac_att", np.median(ri["fac"][msk][ins]), "rel",
                            f"медиана множителя правила u_att/u_JH ниже l; {nn}")
                    # сырьё для diag.json (размерные медианы)
                    if t_ in ("lee", "valley"):
                        dg[f"{t_}_{z:g}"] = dict(
                            n=int(base.sum()), n_out=int(msk.sum()),
                            l_m=float(np.median(C1["l"][cc])), hm_m=float(np.median(C1["hm"][cc])),
                            L_m=float(np.median(C1["L"][cc])),
                            dist_crest_m=[float(np.nanpercentile(geo["dist_crest"][cc], p)) for p in (10, 50, 90)],
                            drop_m=float(np.nanmedian(geo["drop"][cc])),
                            past_xr_m=float(np.nanmedian(geo["past_xr"][cc])) if np.isfinite(geo["past_xr"][cc]).any() else None,
                            dSdx_per_km=float(np.median(C1["dSdx"][cc]) * 1e3),
                            picard_profile_med=[float(v) for v in np.nanmedian(ppro[cc], 0)],
                            jh_profile_med=[float(v) for v in np.nanmedian(prof_jh[cc], 0)], ZP=list(map(float, zp)))
        # по расстоянию от гребня (лее 10 м, вне зоны) — где завышение
        m = (kind == "picard_nom") & (typ == "lee") & (zagl == 10.0) & ~zone
        cc = col[m]
        bins = []
        dl = geo["dist_crest"][cc] / C1["L"][cc]
        for lo, hi in ((-1e9, 0), (0, 1), (1, 2), (2, 4), (4, 1e9)):
            b = (dl >= lo) & (dl < hi)
            if b.any():
                rr = (S["potential_jh"][m][b] - sref[m][b]) / sref[m][b]
                ra = (S["attached_jh"][m][b] - sref[m][b]) / sref[m][b]
                bins.append(dict(dist_over_L=[lo, hi], n=int(b.sum()), mean_rel_jh=float(rr.mean()),
                                 median_rel_jh=float(np.median(rr)), mean_rel_att=float(ra.mean()),
                                 slope_med=float(np.median(geo["slope"][cc][b])), s_ref=float(sref[m][b].mean()),
                                 s_jh=float(S["potential_jh"][m][b].mean()),
                                 dSdx_per_km=float(np.median(C1["dSdx"][cc][b]) * 1e3)))
        dg["lee10_out_by_dist"] = bins
        # мачты: Пикар против измерения (гипотеза «г»), в / вне зоны
        mm = kind == "mast"
        if mm.any():
            xs = np.array([p["x"] for p in pl])[mm]
            ys = np.array([p["y"] for p in pl])[mm]
            sp = pic.s(xs, ys, zagl[mm])
            for t_ in sorted(set(typ[mm])):
                b = typ[mm] == t_
                for sub, sel in (("", b), ("out_", b & ~zone[mm])):
                    if not sel.any():
                        continue
                    zz = float(np.mean(zagl[mm][sel]))
                    nn = f"мачты n={int(sel.sum())}, средняя высота {zz:.0f} м" + ("; вне зоны" if sub else "")
                    add(t_, zz, sub + "mast_picard_rel", np.mean((sp[sel] - sref[mm][sel]) / sref[mm][sel]), "rel",
                        f"гипотеза «г»: среднее rel Пикара nom к измерению мачты; {nn}")
                    for v in ("potential_jh",) + NEW:
                        add(t_, zz, sub + f"mast_{v}_rel", np.mean((S[v][mm][sel] - sref[mm][sel]) / sref[mm][sel]), "rel",
                            f"среднее rel {v} к измерению мачты; {nn}")
            dg["masts"] = [dict(id=pl[i]["id"], type=pl[i]["type"], z_agl=pl[i]["z_agl"], zone=bool(zone[i]),
                                s_meas=float(sref[i]), s_picard=float(sp[k]),
                                **{v: float(S[v][i]) for v in ("potential_jh",) + NEW})
                           for k, i in enumerate(np.nonzero(mm)[0])]
        for rule in NEW:
            add("crest" if case != "ASK_TU03B" else "upstream", refs["norm"][case]["z_agl"], f"norm_{rule}",
                norm_info[case][rule]["mean"], "rel",
                f"отношение скорости {rule} / potential_jh в опорной точке (среднее по группам; s делится на него)")
    summary = T.summarize(rows)
    masts = T.mast_stats(rows)
    doc = dict(format="swg-ground", version=1, git=K.git_short(), created=K.now_iso(), task="swg-9",
               variants=VARIANTS, rows=rows, summary=summary, masts=masts, decomp=decomp, scan=[],
               base_check=dict(max_abs_ds_vs_swg1=base_check,
                               note="max |s_potential_jh (здесь) − s_potential_jh (out/swg-1)| по точкам"),
               norm=norm_info)
    K.dump_json(OUT / "ground.json", doc)
    K.dump_json(OUT / "diag.json", dict(format="swg9-diag", version=1, git=K.git_short(), created=K.now_iso(),
                                        cases=diag))
    (OUT / "tables.md").write_text(tables(doc, diag))
    print("ground.json:", len(rows), "строк; base_check", base_check)


def tables(doc, diag):
    S = {(s["case"], s["variant"], s["type"], s["z_agl"]): s for s in doc["summary"] if s["ref_kind"] == "picard_nom"}
    vs = ("potential_jh",) + NEW
    out = ["# SWG-9: таблицы (вывод `py -m attached.run assemble`)", "",
           "## До/после против Пикара nom: n / доля в ±15 % / среднее rel / медиана rel", ""]
    out.append("| тип | z, м | случай | " + " | ".join(vs) + " |")
    out.append("|---|---|---|" + "---|" * len(vs))
    for t in K.TYPES:
        for z in ZS:
            for c in K.CASES:
                cells = []
                for v in vs:
                    s = S.get((c, v, t, z))
                    cells.append("–" if s is None else
                                 f"{s['n']} / {s['frac_tol']:.2f} / {s['mean_rel']:+.2f} / {s['median_rel']:+.2f}")
                out.append(f"| {t} | {z:g} | {CS[c]} | " + " | ".join(cells) + " |")
    D = {(d["case"], d["type"], d["z_agl"], d["term"]): d["value"] for d in doc["decomp"]}
    out += ["", "## Вне зоны (zone_h SWG-7 = 0): среднее / медиана rel", ""]
    out.append("| тип | z | случай | n вне | доля вне | potential_jh | attached_jh | attached_jh_nl | Δs_jh |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for t in ("lee", "valley", "crest", "windward"):
        for z in ZS:
            for c in K.CASES:
                if (c, t, z, "out_total_jh") not in D:
                    continue
                g = lambda k: D.get((c, t, z, k), float("nan"))
                nout = round(S[(c, "potential_jh", t, z)]["n"] * (1 - g("cover")))
                cells = [f"{g('out_total_' + v if v != 'potential_jh' else 'out_total_jh'):+.2f} / "
                         f"{g('out_median_' + v if v != 'potential_jh' else 'out_median_jh'):+.2f}" for v in vs]
                out.append(f"| {t} | {z:g} | {CS[c]} | {nout} | {1 - g('cover'):.2f} | " + " | ".join(cells) +
                           f" | {g('out_ds_jh'):+.3f} |")
    terms = ("out_su_jh", "out_su_req", "out_su_lag", "out_corr_local", "out_corr_lag", "out_dS_l", "out_dSdx_L",
             "out_apg", "out_l_over_z", "out_hm_over_z", "out_dist_crest_L", "out_far", "out_past_xr", "out_slope",
             "out_picard_rev10", "out_def_below_l", "out_def_l_hm", "out_def_above_hm", "out_inside_l", "out_Gl",
             "out_tauw", "out_tauw_neg", "out_fac_att")
    out += ["", "## Разбор вне зоны (медианы/доли; слагаемые decomp)", ""]
    out.append("| случай | тип | z | " + " | ".join(t[4:] for t in terms) + " |")
    out.append("|---|---|---|" + "---|" * len(terms))
    for c in K.CASES:
        for t in K.TYPES:
            for z in ZS:
                if (c, t, z, "out_su_jh") not in D:
                    continue
                out.append(f"| {CS[c]} | {t} | {z:g} | " + " | ".join(
                    f"{D[(c, t, z, k)]:+.2f}" if (c, t, z, k) in D else "–" for k in terms) + " |")
    out += ["", "## Лее 10 м вне зоны по расстоянию от гребня (в долях L)", ""]
    out.append("| случай | dist/L | n | mean rel jh | median rel jh | mean rel attached | уклон | s_ref | s_jh | ∂ΔS/∂s, 1/км |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for c in K.CASES:
        for b in diag[c]["lee10_out_by_dist"]:
            lo, hi = b["dist_over_L"]
            out.append(f"| {CS[c]} | [{lo if lo > -1e8 else '−∞'}, {hi if hi < 1e8 else '∞'}) | {b['n']} | "
                       f"{b['mean_rel_jh']:+.2f} | {b['median_rel_jh']:+.2f} | {b['mean_rel_att']:+.2f} | "
                       f"{b['slope_med']:+.3f} | {b['s_ref']:.2f} | {b['s_jh']:.2f} | {b['dSdx_per_km']:+.2f} |")
    out += ["", "## Профили (медианы по колонкам лее вне зоны, 10 м): s Пикара / s potential_jh по уровням SWD1", ""]
    for c in K.CASES:
        q = diag[c].get("lee_10")
        if not q:
            continue
        out.append(f"- {CS[c]} (l {q['l_m']:.0f} м, h_m {q['hm_m']:.0f} м, L {q['L_m']:.0f} м): " + ", ".join(
            f"{z:g} м {a:.2f}/{b:.2f}" for z, a, b in zip(q["ZP"], q["picard_profile_med"], q["jh_profile_med"])))
    M_ = {(m["case"], m["variant"], m["type"]): m for m in doc["masts"]}
    out += ["", "## Мачты: RMSE s / доля в ±15 % (по типам)", ""]
    out.append("| случай | тип | n | " + " | ".join(vs) + " |")
    out.append("|---|---|---|" + "---|" * len(vs))
    for c in K.CASES:
        for t in ("all",) + K.TYPES:
            if (c, "potential_jh", t) not in M_:
                continue
            cells = [f"{M_[(c, v, t)]['rmse_s']:.3f} / {M_[(c, v, t)]['frac_tol']:.2f}" if (c, v, t) in M_ else "–"
                     for v in vs]
            out.append(f"| {CS[c]} | {t} | {M_[(c, 'potential_jh', t)]['n']} | " + " | ".join(cells) + " |")
    out += ["", "## Мачты лее: Пикар и варианты против измерения (гипотеза «г»)", ""]
    out.append("| случай | мачта | z | в зоне | s изм. | Пикар | potential_jh | attached_jh | attached_jh_nl |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for c in K.CASES:
        for m in diag[c].get("masts", []):
            if m["type"] != "lee":
                continue
            out.append(f"| {CS[c]} | {m['id']} | {m['z_agl']:g} | {'да' if m['zone'] else 'нет'} | {m['s_meas']:.2f} | "
                       f"{m['s_picard']:.2f} | {m['potential_jh']:.2f} | {m['attached_jh']:.2f} | {m['attached_jh_nl']:.2f} |")
    out += ["", f"Проверка базы: max |Δs| potential_jh против out/swg-1 = {doc['base_check']['max_abs_ds_vs_swg1']}",
            f"Опорная точка (правило / база): {json.dumps(doc['norm'], ensure_ascii=False)}"]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
