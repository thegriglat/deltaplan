"""Случай калибровки Perdigão (C10 v2, docs/air_model_contracts.md): две параллельные гряды, зона рециркуляции.

Постановка — docs/plan/air_model_a4.md (А4) и docs/plan/air_model_b1.md (Б1: приведение к v2 — общая схема
scheme.py, сетка/область/профиль притока по общим правилам rules.py). Данные и скрипты — tools/research/cases/perdigao/.
Модуль собирает рельеф (DSM Copernicus GLO-30 конвейером игры + смещение под пологом), входы двух подслучаев
(NE 27.04.2017 17–19 UTC, SW 11.05.2017 10 UTC), наблюдаемые (профили мачт ISFS и зона рециркуляции Menke 2019)
и запускает air.py (решатель не меняется).

  observations() -> list[dict]      run_one(over, subcase, dx=30.0, ctl=None) -> dict      (контракт C10 v2)
"""
from __future__ import annotations

import csv
import dataclasses
import json
import math
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PD = HERE / "perdigao"
DATA = ROOT / "tools/research/data/perdigao"
sys.path.insert(0, str(HERE))
sys.path.append(str(HERE.parent / "air3d"))
sys.path.append(str(HERE.parent / "morris"))

import rules as RU        # noqa: E402
import scheme as SC       # noqa: E402

NAME = "pd"
SUBCASES = ["ne", "sw"]

# ---------------------------------------------------------------------------------------- постановка
BASE = 100.0                     # высота нуля сетки над морем, м (минимум DSM области 105 м)
F_COR = 2 * 7.2921159e-5 * math.sin(math.radians(39.711))      # 9,3e-5 1/с
# Лес: смещение d = 0,7 h_c под пологом (Raupach 1994; Palma 2020 WES 5 1469, Wagner 2019 ACP 19 1129 — эвкалипт 20–25 м,
# сосна до 15 м), h_c — средневзвешенная 18 м. DSM у мачт в лесу ≈ высота земли (Δ +1,3 м) — полог в нём не виден,
# смещение добавляет обёртка: поверхность = DSM + d·доля леса клетки. z0 — скаляр (подгоняется).
H_CANOPY = 18.0
D_DISP = 0.7 * H_CANOPY
Z0_FOREST = 0.1 * H_CANOPY       # 1,8 м
Z0_OPEN = 0.1                    # поле/кустарник (CORINE; README данных)
NOM = dict(lam_frac=0.031, lam=40.0, alpha=0.235)   # номинал перекалибровки Askervein (docs/air_model_tune.md)
MIN_Z_TOWER = 30.0               # уровни мачт ниже — в пологе и подслое шероховатости (2–3 h_c) — не берём
ZONE_U = 0.5                     # порог обратной скорости Menke, м/с
ZONE_LMIN = 50.0                 # мин. длина зоны Menke, м
BLIND = 15.0                     # слой у земли, отброшенный при поиске зоны, м
SECTION_OFFSETS = (-500.0, 0.0, 500.0)    # сдвиги разрезов вдоль гряды, м (Menke: разрезы 1, 2, 3 вдоль гряды)
# U10 фона: правило «модель на опорной точке = данные» на номинале общей схемы (b1/u10.py; S_ref модели = U100 наветренной
# мачты); дальше фиксирован — отношения S/S_ref от подгонки скорости не зависят (кроме h = 0,3 u*/f через u*).
U10_IN = dict(ne=3.27, sw=3.12)   # b1/out/probe_runs.jsonl: 3,15 → S_ref 8,457 (U100 8,791); 3,03 → 8,574 (8,824); U10 × U100/S_ref


def _csv(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def menke_geometry():
    """D (расстояние гребень–гребень) и H (гребень − дно) по разрезам 1 и 2 Menke 2019, табл. 2 (разрез 3 с холмом в долине
    исключён, как в menke2019/summary.md): H — среднее по обеим грядам обоих разрезов."""
    rows = [r for r in _csv(DATA / "menke2019/table2_transects.csv") if r["transect"] in ("1", "2")]
    D = float(np.mean([float(r["peak_to_peak_m"]) for r in rows]))
    H = float(np.mean([float(r[k]) - float(r["valley_min_m"]) for r in rows for k in ("peak_SW_m", "peak_NE_m")]))
    return D, H


D_MENKE, H_M = menke_geometry()  # 1407 м, 173,6 м
DX_NOM = round(H_M / RU.H_PER_DX / 10.0) * 10.0      # 30 м: H/5,8 к сетке данных 10 м
MIN_AGL = RU.MIN_AGL_PER_DZ * DX_NOM / 2              # 15 м

CASES = {
    # ref — наветренная мачта (tse13 гребень NE-гряды для NE, tse04 гребень SW-гряды для SW), 100 м
    "ne": dict(ref="tse13", file="ne_20170427", window=("17:00", "19:00")),
    "sw": dict(ref="tse04", file="sw_20170511", window=("10:00", "11:00")),
}
PROFILE_LEVELS = (30, 60, 100)                      # уровни мачт (м над землёй) — 3 на мачту, не дублировать
PROFILE_MASTS = dict(ne=["tse13", "tse04", "rsw03", "tse09", "tse11", "tse06", "tse10", "tse01", "tse02"],
                     sw=["tse04", "tse13", "tse09", "tse11", "tse06", "tse10", "tse12", "tse01", "tse02"])
SIG_REP = 0.10                   # представительность: DEM 30 м (σ высот мачт 2,9 м), лес, положение мачты (отн.)
SIG_FLOOR = 0.03                 # абсолютный член на S/S_ref (общий с Askervein: калибровка/перебег чашек, положение)


# ---------------------------------------------------------------------------------------- данные
@lru_cache(maxsize=None)
def masts():
    out = {}
    for r in _csv(PD / "out/masts.csv"):
        out[r["name"]] = dict(x=float(r["x"]), y=float(r["y"]), ground=float(r["ground_asl"]))
    return out


@lru_cache(maxsize=None)
def _terrain10(size=6000):
    f = PD / ("out/terrain10.npz" if size == 6000 else f"out/terrain10_{size // 1000}km.npz")
    z = np.load(f)
    return dict(dsm=z["dsm"].astype(np.float64), tree=z["tree"].astype(np.float64), x=z["x"], y=z["y"])


def forest_fraction():
    return float(_terrain10()["tree"].mean())


def z0_nominal():
    """z0 области: среднее по ln z0 (эффективная шероховатость, Mason 1988) по доле леса WorldCover."""
    f = forest_fraction()
    return math.exp(f * math.log(Z0_FOREST) + (1 - f) * math.log(Z0_OPEN))


def terrain(dx, L=6000.0):
    """hc (ny, nx), м над нулём сетки: DSM − BASE + d·доля леса клетки; y — на север, x — на восток. Область L — 6 км
    (terrain10.npz) или 9 км (terrain10_9km.npz, контроль области). dx кратен 5 м: 10-м выборка делится на 2×2 по 5 м
    (площадное среднее точно), затем блочное среднее до dx."""
    size = int(round(L))
    T = _terrain10(size)
    f = int(round(dx / 5.0))
    assert abs(f * 5.0 - dx) < 1e-9, "dx кратен 5 м"
    n = int(round(L / dx))
    dsm = np.repeat(np.repeat(T["dsm"], 2, 0), 2, 1)
    tree = np.repeat(np.repeat(T["tree"], 2, 0), 2, 1)
    assert n * f == dsm.shape[0], (n, f, dsm.shape)
    dsm = dsm.reshape(n, f, n, f).mean(axis=(1, 3))
    tree = tree.reshape(n, f, n, f).mean(axis=(1, 3))
    return -L / 2, -L / 2, n, dsm - BASE + D_DISP * tree


@lru_cache(maxsize=None)
def hmax(L=6000.0):
    return float(terrain(10.0, L)[3].max())


def case_inputs(sub):
    """Направление «откуда» и U100 на наветренной мачте — среднее окна (windowmean)."""
    c = CASES[sub]
    rows = [r for r in _csv(DATA / f"cases/{c['file']}_windowmean.csv") if r["site"] == c["ref"] and r["z_agl_m"] == "100"]
    r = rows[0]
    return dict(wdir=float(r["dir_deg"]), u100=float(r["spd"]), ref=c["ref"])


def geometry(dx=None, dom_mul=1.0, top_mul=1.0):
    return RU.geometry(H_M, hmax(6000.0 * dom_mul), DX_NOM, dx, dom_mul, top_mul)


def base_params(sub, over=None):
    """Параметры прогона без общей схемы: номинал + постоянные случая + over; max_profile — по правилу z_sat
    (rules.max_profile), если не задан в over явно."""
    geo = geometry()
    kw = dict(z0=round(z0_nominal(), 3), f_cor=F_COR, sponge_side_m=geo["sponge_side"], sponge_top_m=geo["sponge_top"], **NOM)
    kw.update(over or {})
    if "max_profile" not in (over or {}):
        kw["max_profile"] = RU.max_profile(kw["alpha"], U10_IN[sub], kw["z0"], kw["f_cor"])
    return kw


def _setup(sub):
    inp = case_inputs(sub)
    geo = geometry()
    z0 = round(z0_nominal(), 3)
    return dict(
        H_m=round(H_M, 1), dx_m=DX_NOM, dz_m=geo["dz"], L_dom_m=geo["L"], top_m=round(geo["top"], 1),
        sponge_side_m=geo["sponge_side"], sponge_top_m=round(geo["sponge_top"], 1), f_cor=F_COR,
        wdir_deg=round(inp["wdir"], 1),
        u_ref=f"U100 {inp['u100']:.2f} м/с на {inp['ref']} (гребень, 100 м); U10 фона {U10_IN[sub]} м/с — модель на опорной точке = данные на номинале",
        alpha=NOM["alpha"], z0_m=z0,
        z_sat_rule=f"z_sat = {RU.Z_SAT_FRAC}·0,3u*/f, u* = κU10/ln(10/z0): {RU.z_sat(U10_IN[sub], z0, F_COR):.0f} м на номинале",
        max_profile=round(RU.max_profile(NOM["alpha"], U10_IN[sub], z0, F_COR), 3),
        canopy=f"поверхность = DSM + d·доля леса WorldCover, d = 0,7·h_c = {D_DISP:.1f} м (h_c 18 м); z0 скаляр",
        stability=("NE: z/L −0,23…+0,05, Ri −0,16…−0,10 (гребень, 100 м); " if sub == "ne" else
                   "SW: z/L −0,14, Ri +0,075; ") + "модель — нейтраль (γ = 0, без нагрева); отклонение — контроль stab (b1)",
    )


SETUP = {s: _setup(s) for s in SUBCASES}


def grid_and_case(sub, dx, over=None, ctl=None):
    """Сетка, рельеф, Case, Params. ctl — контроль (не калибровка): {"adv2": False, …} поверх схемы, "dom_mul"/"top_mul" —
    область, "heat_wm2" — однородный поток тепла, "gam" — dθ̄/dz, К/м (контроль устойчивости)."""
    import air as A
    import synth as SY
    ctl = dict(ctl or {})
    dom_mul, top_mul = ctl.pop("dom_mul", 1.0), ctl.pop("top_mul", 1.0)
    heat, gam = ctl.pop("heat_wm2", 0.0), ctl.pop("gam", 0.0)
    geo = geometry(dx, dom_mul, top_mul)
    x0, y0, n, hc = terrain(dx, geo["L"])
    g = A.Grid(dx, n, n, geo["dz"], -geo["dz"], geo["nz"], x0, y0)
    kw = base_params(sub, over)
    kw["sponge_top_m"] = geo["sponge_top"]
    kw = SC.apply(kw, ctl=bool(ctl) or dom_mul != 1.0 or top_mul != 1.0 or heat != 0.0 or gam != 0.0)
    kw.update(ctl)
    prm = A.Params(**kw)
    inp = case_inputs(sub)
    case = A.Case(U10=U10_IN[sub], wdir=inp["wdir"], gam=SY.const_gam(gam),
                  H=None if heat == 0.0 else np.full(hc.shape, float(heat)))
    return g, hc, case, prm, inp, geo


# ---------------------------------------------------------------------------------------- выборка поля
def _col_interp(S, F, jj, ii, zt):
    """F (nz, ny, nx) в столбцах (jj, ii) на высоте zt (м над нулём сетки), линейно по z; ниже первой воздушной
    клетки — её значение (как synth.agl)."""
    g = S.g
    kf = (zt - (g.z_bot + 0.5 * g.dz)) / g.dz
    kf = np.maximum(kf, S.kb[jj, ii] - 1)            # kb — с ореолом (synth.agl: kb − 1)
    k0 = np.clip(np.floor(kf).astype(int), 0, g.nz - 2)
    a = np.clip(kf - k0, 0, 1)
    f0, f1 = F[k0, jj, ii], F[k0 + 1, jj, ii]
    f1 = np.where(np.isnan(f1), f0, f1)
    return (1 - a) * f0 + a * f1


def sample(S, F, x, y, z):
    """Поле F в точках (x, y, z — м над нулём сетки): билинейно по столбцам, линейно по z."""
    g = S.g
    x, y, z = np.broadcast_arrays(np.asarray(x, float), np.asarray(y, float), np.asarray(z, float))
    fi = np.clip((x - g.x0) / g.dx - 0.5, 0, g.nx - 1.000001)
    fj = np.clip((y - g.y0) / g.dx - 0.5, 0, g.ny - 1.000001)
    i0, j0 = np.floor(fi).astype(int), np.floor(fj).astype(int)
    a, b = fi - i0, fj - j0
    out = 0.0
    for dj, wj in ((0, 1 - b), (1, b)):
        for di, wi in ((0, 1 - a), (1, a)):
            out = out + wj * wi * _col_interp(S, F, j0 + dj, i0 + di, z)
    return out


def surface_at(S, x, y):
    g = S.g
    fi = np.clip((np.asarray(x, float) - g.x0) / g.dx - 0.5, 0, g.nx - 1.000001)
    fj = np.clip((np.asarray(y, float) - g.y0) / g.dx - 0.5, 0, g.ny - 1.000001)
    i0, j0 = np.floor(fi).astype(int), np.floor(fj).astype(int)
    a, b = fi - i0, fj - j0
    h = S.hc
    return (1 - b) * ((1 - a) * h[j0, i0] + a * h[j0, i0 + 1]) + b * ((1 - a) * h[j0 + 1, i0] + a * h[j0 + 1, i0 + 1])


def mast_speed(S, sp, name, z_tower):
    """Скорость модели на мачте name на высоте z_tower над землёй (по абсолютной высоте: земля + z_tower);
    NaN, если ниже MIN_AGL над поверхностью модели (полог и слепая зона)."""
    m = masts()[name]
    zs = m["ground"] - BASE + z_tower
    hs = float(surface_at(S, m["x"], m["y"]))
    if zs - hs < MIN_AGL:
        return float("nan")
    return float(sample(S, sp, m["x"], m["y"], zs))


# ---------------------------------------------------------------------------------------- зона рециркуляции
def zone_metrics(S, u, v, wdir, sref, offsets=SECTION_OFFSETS):
    """Зона за наветренной грядой по продольной компоненте вдоль ветра (определение Menke 2019, с. 2717):
    область с u_∥ < −0,5 м/с, выше BLIND над поверхностью, длиной > 50 м; берётся наибольшая связная область
    разреза. Разрезы — линии вдоль ветра через центр долины со сдвигами вдоль гряды. Возвращает средние по
    разрезам: L/D (D — расстояние гребень–гребень разреза), глубина/H (H — гребень−дно), max(−u_∥)/U100;
    плюс списки по разрезам (разрез без зоны: L = глубина = 0)."""
    from scipy import ndimage
    ang = math.radians(wdir)
    ex, ey = -math.sin(ang), -math.cos(ang)
    ax, ay = ey, -ex
    s = np.arange(-1500.0, 1500.0 + 1e-9, 10.0)
    per = []
    for t in offsets:
        px, py = t * ax + s * ex, t * ay + s * ey
        hs = surface_at(S, px, py)
        # дно долины — минимум сглаженной поверхности между ±700 м; гребни — максимумы по сторонам
        core = np.abs(s) <= 700
        hsm = ndimage.uniform_filter1d(hs, 9)
        iv = int(np.argmin(np.where(core, hsm, np.inf)))
        up = int(np.argmax(hs[:iv])) if iv > 2 else 0
        dn = iv + int(np.argmax(hs[iv:]))
        H = 0.5 * (hs[up] + hs[dn]) - hs[iv]
        Dd = s[dn] - s[up]
        zlev = np.arange(hs.min(), hs.max() + 700.0, 10.0)
        Z = np.broadcast_to(zlev[:, None], (len(zlev), len(s)))
        valid = Z >= hs[None, :] + BLIND
        upar = np.full(Z.shape, np.nan)
        for k in range(len(zlev)):
            ok = valid[k]
            if ok.any():
                uu = sample(S, u, px[ok], py[ok], zlev[k])
                vv = sample(S, v, px[ok], py[ok], zlev[k])
                upar[k, ok] = uu * ex + vv * ey
        inv = np.nan_to_num(upar, nan=0.0) < -ZONE_U
        lab, nlab = ndimage.label(inv)
        L = depth = 0.0
        if nlab:
            area = ndimage.sum(inv, lab, index=np.arange(1, nlab + 1))
            comp = lab == (1 + int(np.argmax(area)))
            cols = np.where(comp.any(axis=0))[0]
            L = (cols.max() - cols.min() + 1) * 10.0
            if L > ZONE_LMIN:
                depth = max(0.0, float(zlev[np.where(comp.any(axis=1))[0].max()] + 5.0 - hs[iv]))   # над дном долины
            else:
                L = depth = 0.0
        span = (s >= s[up]) & (s <= s[dn])
        rev = float(np.nanmax(np.where(span[None, :], -upar, np.nan)))
        per.append(dict(t=t, L=L, depth=depth, rev=rev, H=float(H), D=float(Dd), s_valley=float(s[iv])))
    mean = lambda key: float(np.mean([p[key] for p in per]))
    return dict(L_D=float(np.mean([p["L"] / p["D"] for p in per])),
                depth_H=float(np.mean([p["depth"] / p["H"] for p in per])),
                rev_U=float(np.mean([p["rev"] for p in per])) / sref, sections=per)


# ---------------------------------------------------------------------------------------- наблюдаемые
GRID_FILE = HERE / "b1/out/grid.json"     # sig_grid, grid_corr — общий способ Б1 (b1/grid.py), у обоих случаев одинаково


def _grid():
    return json.loads(GRID_FILE.read_text()) if GRID_FILE.exists() else {}


def _ratio_sigma(sub, site, z):
    """Разброс S(site, z)/S(ref, 100) по 5-мин окнам (время в окне случая), σ_t."""
    c = CASES[sub]
    t0, t1 = c["window"]
    rows = _csv(DATA / f"cases/{c['file']}_5min.csv")
    ser = {}
    for r in rows:
        hhmm = r["time_utc"][11:16]
        if not (t0 <= hhmm < t1) or r["spd"] == "":
            continue
        ser[(r["time_utc"], r["site"], int(float(r["z_agl_m"])))] = float(r["spd"])
    times = sorted({k[0] for k in ser})
    q = [ser[(t, site, z)] / ser[(t, c["ref"], 100)] for t in times if (t, site, z) in ser and (t, c["ref"], 100) in ser]
    return (float(np.std(q, ddof=1)) if len(q) > 3 else float("nan")), len(q)


@lru_cache(maxsize=None)
def _observations():
    gr = _grid()
    out = []
    for sub in SUBCASES:
        c = CASES[sub]
        wm = {(r["site"], int(r["z_agl_m"])): r for r in _csv(DATA / f"cases/{c['file']}_windowmean.csv") if r["spd"] != ""}
        ref = float(wm[(c["ref"], 100)]["spd"])
        for site in PROFILE_MASTS[sub]:
            for z in PROFILE_LEVELS:
                if (site, z) not in wm or (site == c["ref"] and z == 100) or z < MIN_Z_TOWER:
                    continue
                if int(wm[(site, z)]["n_5min"]) < 6:
                    continue
                r = float(wm[(site, z)]["spd"]) / ref
                st, nq = _ratio_sigma(sub, site, z)
                st = 0.0 if math.isnan(st) else st
                sig = math.sqrt(st ** 2 + (SIG_REP * r) ** 2 + SIG_FLOOR ** 2)
                name = f"pd_{sub}_{site}_{z}"
                g = gr.get(name, {})
                out.append(dict(name=name, grp=f"pd_{sub}_{site}", data=round(r, 4), sig=round(sig, 4),
                                sig_grid=round(float(g.get("sig_grid", 0.0)), 4), grid_corr=round(float(g.get("grid_corr", 0.0)), 4),
                                unit="S/S_ref", subcase=sub,
                                src=f"ISFS 5-мин NCAR/EOL, cases/{c['file']}_windowmean.csv: S({site},{z} м)/S({c['ref']},100 м); "
                                    f"σ = √(σ_5мин {st:.3f}² ⊕ (0,10·r)² ⊕ 0,03²), n = {nq}"))
        # ---- зона рециркуляции (Menke 2019, статистика по многим периодам → одна группа на оба подслучая)
        zones = [
            ("zoneL", 700.0 / D_MENKE, math.hypot(100.0, 100.0) / D_MENKE, "L/D",
             f"Menke 2019 ACP 19 2713: длина 697 ≈ 700 м, σ 100 м (разброс разрезов) ⊕ 100 м (среднее поле против периодов: Рис. 8 дал 420–680 м); D = {D_MENKE:.0f} м (табл. 2, разрезы 1–2)"),
            ("zoneDepth", 157.0 / H_M, math.hypot(30.0, 20.0) / H_M, "depth/H",
             f"Menke 2019: глубина 157 ± 30 м над дном ⊕ 20 м (слепая зона у земли, разброс разрезов); H = гребень − дно = {H_M:.0f} м (табл. 2, разрезы 1–2)"),
            ("zoneRev", 0.22, 0.10, "max(−u_∥)/U100",
             "Menke 2019 Рис. 10: макс. обратная скорость/U100 ≈ 0,22 (0,05–0,55); σ ⊕ осреднение лидара по лучу 30 м"),
        ]
        for key, data, sig, unit, src in zones:
            name = f"pd_{sub}_{key}"
            g = gr.get(name, {})
            out.append(dict(name=name, grp="pd_menke", data=round(data, 4), sig=round(sig, 4),
                            sig_grid=round(float(g.get("sig_grid", 0.0)), 4), grid_corr=round(float(g.get("grid_corr", 0.0)), 4),
                            unit=unit, subcase=sub,
                            src=src + "; menke2019/summary.md «Предлагаемые наблюдаемые» №" + {"zoneL": "1", "zoneDepth": "2", "zoneRev": "3"}[key]))
    return out


def observations():
    return [dict(o) for o in _observations()]


# ---------------------------------------------------------------------------------------- прогон
def model_obs(S, sub):
    """Модельные наблюдаемые тем же определением, что и данные; плюс (для разбора, в χ² не входит) на мачтах —
    компонента вдоль ветра притока u_∥ и направление «откуда»."""
    u, v, w, th = S.centers()
    sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
    inp = case_inputs(sub)
    sref = mast_speed(S, sp, inp["ref"], 100.0)
    ang = math.radians(inp["wdir"])
    ex, ey = -math.sin(ang), -math.cos(ang)
    obs, mast = {}, {}
    for o in observations():
        if o["subcase"] != sub:
            continue
        p = o["name"].split("_")
        if p[2].startswith("zone"):
            continue
        site, z = p[2], float(p[3])
        s = mast_speed(S, sp, site, z)
        obs[o["name"]] = s / sref
        uu, vv = mast_speed(S, u, site, z), mast_speed(S, v, site, z)
        mast[o["name"]] = dict(upar=(uu * ex + vv * ey) / sref, dir=math.degrees(math.atan2(-uu, -vv)) % 360.0)
    zm = zone_metrics(S, u, v, inp["wdir"], sref)
    obs[f"pd_{sub}_zoneL"] = zm["L_D"]
    obs[f"pd_{sub}_zoneDepth"] = zm["depth_H"]
    obs[f"pd_{sub}_zoneRev"] = zm["rev_U"]
    return obs, dict(sref=sref, zone=zm, mast=mast)


def _clean(x):
    if isinstance(x, (np.floating, float)):
        x = float(x)
        return None if not math.isfinite(x) else x
    if isinstance(x, (np.integer,)):
        return int(x)
    if isinstance(x, dict):
        return {k: _clean(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [_clean(v) for v in x]
    return x


def run_one(over: dict, subcase: str, dx: float = DX_NOM, ctl: dict | None = None, keep: bool = False) -> dict:
    """Один прогон air.py. over — переопределения полей air.Params (прочее: номинал + постоянные случая по правилам
    rules.py), общая схема scheme.py — поверх. ctl — контрольный прогон (строка scheme_ctl = True, в χ² не входит):
    поля Params схемы (например {"adv2": False}) и/или "dom_mul", "top_mul", "heat_wm2", "gam" (см. grid_and_case).
    Строка C10: {case, subcase, dx, params, status, iters, t, obs} + inputs, geo, h_bl, lam_eff, mast, zone_sections."""
    import model as M
    g, hc, case, prm, inp, geo = grid_and_case(subcase, dx, over, ctl)
    row = dict(case=NAME, subcase=subcase, dx=float(dx), params=_clean(dataclasses.asdict(prm)))
    if ctl:
        row.update(scheme_ctl=True, ctl=_clean(dict(ctl)))
    try:
        with M.GpuLock() as lk:
            S = M.SY.run(g, hc, case, prm, max_outer=SC.MAX_OUTER)
        meta = M.meta(S)
        obs, extra = model_obs(S, subcase)
        row.update(status=meta["status"], iters=meta["iters"], t=float(meta["t"]), obs=_clean(obs),
                   t_lock_wait=round(lk.wait, 2),
                   inputs=dict(wdir=inp["wdir"], u100_obs=inp["u100"], u10_in=case.U10, sref_model=extra["sref"]),
                   geo=_clean(dict(geo, n_cells=int(g.nx * g.ny * g.nz))), h_bl=float(np.mean(S.h_bl)),
                   lam_eff=float(np.mean(S.lam_np)), mast=_clean(extra["mast"]),
                   zone_sections=_clean(extra["zone"]["sections"]))
        if keep:
            row["_S"] = S
        else:
            M.free(S)
    except Exception as e:                                                       # noqa: BLE001
        row.update(status="error", iters=0, t=0.0, obs={}, err=repr(e))
    return row


if __name__ == "__main__":
    obs = observations()
    print(len(obs), "наблюдаемых;", "z0 номинал", round(z0_nominal(), 3), "доля леса", round(forest_fraction(), 3))
    for s in SUBCASES:
        print(s, json.dumps(SETUP[s], ensure_ascii=False, indent=1))
