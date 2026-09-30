"""Случай калибровки Perdigão (C10 v1, docs/air_model_contracts.md): две параллельные гряды, зона рециркуляции.

Постановка — docs/plan/air_model_a4.md, данные и скрипты — tools/research/cases/perdigao/ (README там).
Модуль собирает рельеф (DSM Copernicus GLO-30 конвейером игры + смещение под пологом), входы двух подслучаев
(NE 27.04.2017 17–19 UTC, SW 11.05.2017 10 UTC), наблюдаемые (профили мачт ISFS и зона рециркуляции Menke 2019)
и запускает air.py (решатель не меняется).

  observations() -> list[dict]          run_one(over, subcase, dx=30.0) -> dict      (контракт C10)
"""
from __future__ import annotations

import csv
import dataclasses
import json
import math
import sys
import time
from functools import lru_cache
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PD = HERE / "perdigao"
DATA = ROOT / "tools/research/data/perdigao"
sys.path.insert(0, str(HERE.parent / "air3d"))
sys.path.insert(0, str(HERE.parent / "morris"))

NAME = "pd"
SUBCASES = ["ne", "sw"]
DX_NOM = 30.0                    # номинальный шаг, м (= разрешение Copernicus GLO-30)

# ---------------------------------------------------------------------------------------- постановка
L_DOM = 6000.0                   # сторона области, м (x, y ∈ [−3000, 3000] от центра долины)
BASE = 100.0                     # высота нуля сетки над морем, м (минимум DSM области 105 м)
TOP = 1300.0                     # потолок над нулём сетки, м
SPONGE_SIDE = 1000.0             # боковая губка, м (как Askervein)
SPONGE_TOP = 700.0               # губка у потолка, м: начинается на 600 м над нулём = ≥ 200 м выше гребней
F_COR = 2 * 7.2921159e-5 * math.sin(math.radians(39.711))      # 9,3e-5 1/с
MAX_PROFILE = 2.5                # U(z)/U10 ≤ 2,5: степенной профиль до 494 м над поверхностью (α = 0,235); у Askervein 2,0 (холм 126 м)
# Лес: смещение d = 0,7 h_c под пологом и шероховатость z0 = 0,1 h_c (Raupach 1994; Palma 2020 WES 5 1469,
# Wagner 2019 ACP 19 1129 — эвкалипт 20–25 м, сосна до 15 м), h_c — средневзвешенная 18 м. Копернику не верим:
# DSM у мачт в лесу ≈ высота земли (Δ +1,3 м) — полог в нём не виден, смещение добавляет обёртка.
H_CANOPY = 18.0
D_DISP = 0.7 * H_CANOPY
Z0_FOREST = 0.1 * H_CANOPY       # 1,8 м
Z0_OPEN = 0.1                    # поле/кустарник (CORINE; README данных)
NOM = dict(lam_frac=0.031, alpha=0.235)       # номинал перекалибровки Askervein (docs/air_model_tune.md)
MIN_AGL = 10.0                   # ниже — в слепой зоне лидара / первая клетка решателя: не наблюдаем
MIN_Z_TOWER = 30.0               # уровни мачт ниже — в пологе и подслое шероховатости (2–3 h_c) — не берём
ZONE_U = 0.5                     # порог обратной скорости Menke, м/с
ZONE_LMIN = 50.0                 # мин. длина зоны Menke, м
BLIND = 15.0                     # слой у земли, отброшенный при поиске зоны, м
SECTION_OFFSETS = (-500.0, 0.0, 500.0)    # сдвиги разрезов вдоль гряды, м (Menke: разрезы 1, 2, 3 вдоль гряды)
U10_IN = dict(ne=3.15, sw=3.03)  # U10 фона, м/с (None — из U100 данных и степенного профиля): подобран так, что S_ref(модель)
                                 # на наветренной мачте = U100 данных (±3 %) на номинале; ниже — фиксирован, чтобы отношения S/S_ref
                                 # не зависели от подгонки скорости (разгон на гребне ≈ 1,5 — см. docs/plan/air_model_a4.md)


def menke_geometry():
    """D (расстояние гребень–гребень) и H (гребень − дно) по разрезам 1 и 2 Menke 2019, табл. 2 (разрез 3 с холмом в долине
    исключён, как в menke2019/summary.md): H — среднее по обеим грядам обоих разрезов."""
    rows = [r for r in _csv(DATA / "menke2019/table2_transects.csv") if r["transect"] in ("1", "2")]
    D = float(np.mean([float(r["peak_to_peak_m"]) for r in rows]))
    H = float(np.mean([float(r[k]) - float(r["valley_min_m"]) for r in rows for k in ("peak_SW_m", "peak_NE_m")]))
    return D, H

CASES = {
    # ref — наветренная мачта (tse13 гребень NE-гряды для NE, tse04 гребень SW-гряды для SW), 100 м
    "ne": dict(ref="tse13", file="ne_20170427", window=("17:00", "19:00")),
    "sw": dict(ref="tse04", file="sw_20170511", window=("10:00", "11:00")),
}
PROFILE_LEVELS = (30, 60, 100)                      # уровни мачт (м над землёй) — 3 на мачту, не дублировать
PROFILE_MASTS = dict(ne=["tse13", "tse04", "rsw03", "tse09", "tse11", "tse06", "tse10", "tse01", "tse02"],
                     sw=["tse04", "tse13", "tse09", "tse11", "tse06", "tse10", "tse12", "tse01", "tse02"])
SIG_REP = 0.10                   # представительность: DEM 30 м, лес, положение мачты, канал долины (отн.)
SIG_FLOOR = 0.03                 # абсолютный пол на S/S_ref


# ---------------------------------------------------------------------------------------- данные
def _csv(path):
    with open(path) as f:
        return list(csv.DictReader(f))


@lru_cache(maxsize=None)
def masts():
    out = {}
    for r in _csv(PD / "out/masts.csv"):
        out[r["name"]] = dict(x=float(r["x"]), y=float(r["y"]), ground=float(r["ground_asl"]))
    return out


@lru_cache(maxsize=None)
def _terrain10():
    z = np.load(PD / "out/terrain10.npz")
    return dict(dsm=z["dsm"].astype(np.float64), tree=z["tree"].astype(np.float64), x=z["x"], y=z["y"])


def forest_fraction():
    return float(_terrain10()["tree"].mean())


def z0_nominal():
    """z0 области: среднее по ln z0 (эффективная шероховатость, Mason 1988) по доле леса WorldCover."""
    f = forest_fraction()
    return math.exp(f * math.log(Z0_FOREST) + (1 - f) * math.log(Z0_OPEN))


def terrain(dx):
    """hc (ny, nx), м над нулём сетки: DSM − BASE + d·доля леса клетки; y — на север, x — на восток."""
    T = _terrain10()
    f = int(round(dx / 10.0))
    assert abs(f * 10.0 - dx) < 1e-9, "dx кратен 10 м"
    n = int(round(L_DOM / dx))
    nf = n * f
    assert nf == T["dsm"].shape[0], (nf, T["dsm"].shape)
    dsm = T["dsm"].reshape(n, f, n, f).mean(axis=(1, 3))
    tree = T["tree"].reshape(n, f, n, f).mean(axis=(1, 3))
    return -L_DOM / 2, -L_DOM / 2, n, dsm - BASE + D_DISP * tree


def case_inputs(sub):
    """Направление «откуда» и U100 на наветренной мачте — среднее окна (windowmean), U10 фона — из U100."""
    c = CASES[sub]
    rows = [r for r in _csv(DATA / f"cases/{c['file']}_windowmean.csv") if r["site"] == c["ref"] and r["z_agl_m"] == "100"]
    r = rows[0]
    return dict(wdir=float(r["dir_deg"]), u100=float(r["spd"]), ref=c["ref"])


def grid_and_case(sub, dx, over=None):
    import air as A
    import synth as SY
    x0, y0, n, hc = terrain(dx)
    dz = dx / 2
    nz = int(math.ceil(TOP / dz)) + 1
    nz += nz % 2
    g = A.Grid(dx, n, n, dz, -dz, nz, x0, y0)
    kw = dict(z0=round(z0_nominal(), 3), max_profile=MAX_PROFILE, f_cor=F_COR, sponge_side_m=SPONGE_SIDE,
              sponge_top_m=SPONGE_TOP, **NOM)
    kw.update(over or {})
    prm = A.Params(**kw)
    inp = case_inputs(sub)
    u10 = U10_IN[sub] or inp["u100"] / 10.0 ** prm.alpha / 1.47     # 1,47 — ориентир разгона на гребне (пробный прогон)
    case = A.Case(U10=u10, wdir=inp["wdir"], gam=SY.const_gam(0.0))
    return g, hc, case, prm, inp


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
def _grid_sigma():
    f = PD / "out/grid_sigma.json"
    return json.loads(f.read_text()) if f.exists() else {}


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
    gs = _grid_sigma()
    out = []
    # ---- профили мачт (S/S_ref), по подслучаям
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
                out.append(dict(name=name, grp=f"pd_{sub}_{site}", data=round(r, 4), sig=round(sig, 4),
                                sig_grid=round(float(gs.get(name, 0.0)), 4), grid_corr=0.0, unit="S/S_ref",
                                subcase=sub, src=f"ISFS 5-мин NCAR/EOL, cases/{c['file']}_windowmean.csv: S({site},{z} м)/S({c['ref']},100 м); "
                                                 f"σ = √(σ_5мин {st:.3f}² ⊕ (0,10·r)² ⊕ 0,03²), n = {nq}"))
        # ---- зона рециркуляции (Menke 2019, статистика по многим периодам → одна группа на оба подслучая)
        D_m, H_m = menke_geometry()
        zones = [
            ("zoneL", 700.0 / D_m, math.hypot(100.0, 100.0) / D_m, "L/D",
             f"Menke 2019 ACP 19 2713: длина 697 ≈ 700 м, σ 100 м (разброс разрезов) ⊕ 100 м (среднее поле против периодов: Рис. 8 дал 420–680 м); D = {D_m:.0f} м (табл. 2, разрезы 1–2)"),
            ("zoneDepth", 157.0 / H_m, math.hypot(30.0, 20.0) / H_m, "depth/H",
             f"Menke 2019: глубина 157 ± 30 м над дном ⊕ 20 м (слепая зона у земли, разброс разрезов); H = гребень − дно = {H_m:.0f} м (табл. 2, разрезы 1–2)"),
            ("zoneRev", 0.22, 0.10, "max(−u_∥)/U100",
             "Menke 2019 Рис. 10: макс. обратная скорость/U100 ≈ 0,22 (0,05–0,55); σ ⊕ осреднение лидара по лучу 30 м"),
        ]
        for key, data, sig, unit, src in zones:
            name = f"pd_{sub}_{key}"
            out.append(dict(name=name, grp="pd_menke", data=round(data, 4), sig=round(sig, 4),
                            sig_grid=round(float(gs.get(name, 0.0)), 4), grid_corr=0.0, unit=unit, subcase=sub,
                            src=src + "; menke2019/summary.md «Предлагаемые наблюдаемые» №" + {"zoneL": "1", "zoneDepth": "2", "zoneRev": "3"}[key]))
    return out


def observations():
    return [dict(o) for o in _observations()]


# ---------------------------------------------------------------------------------------- прогон
def model_obs(S, sub, dx):
    """Модельные наблюдаемые тем же определением, что и данные."""
    u, v, w, th = S.centers()
    sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
    inp = case_inputs(sub)
    sref = mast_speed(S, sp, inp["ref"], 100.0)
    obs = {}
    for o in observations():
        if o["subcase"] != sub:
            continue
        p = o["name"].split("_")
        if p[2].startswith(("zone",)):
            continue
        site, z = p[2], float(p[3])
        obs[o["name"]] = mast_speed(S, sp, site, z) / sref
    zm = zone_metrics(S, u, v, inp["wdir"], sref)
    obs[f"pd_{sub}_zoneL"] = zm["L_D"]
    obs[f"pd_{sub}_zoneDepth"] = zm["depth_H"]
    obs[f"pd_{sub}_zoneRev"] = zm["rev_U"]
    return obs, dict(sref=sref, zone=zm, u10_in=None)


def _clean(x):
    if isinstance(x, (np.floating, float)):
        x = float(x)
        return None if not math.isfinite(x) else x
    if isinstance(x, dict):
        return {k: _clean(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [_clean(v) for v in x]
    return x


def run_one(over: dict, subcase: str, dx: float = DX_NOM, keep: bool = False) -> dict:
    """Один прогон air.py. over — переопределения полей air.Params (прочее: номинал перекалибровки +
    постоянные случая). Строка C10: {case, subcase, dx, params, status, iters, t, obs}."""
    import model as M
    g, hc, case, prm, inp = grid_and_case(subcase, dx, over)
    row = dict(case=NAME, subcase=subcase, dx=float(dx), params=_clean(dataclasses.asdict(prm)))
    try:
        with M.GpuLock() as lk:
            S = M.SY.run(g, hc, case, prm, max_outer=4000)
        meta = M.meta(S)
        obs, extra = model_obs(S, subcase, dx)
        row.update(status=meta["status"], iters=meta["iters"], t=float(meta["t"]), obs=_clean(obs),
                   t_lock_wait=round(lk.wait, 2), inputs=dict(wdir=inp["wdir"], u100_obs=inp["u100"], u10_in=case.U10,
                                                               sref_model=extra["sref"]),
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
