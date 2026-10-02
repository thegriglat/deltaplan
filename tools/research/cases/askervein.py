"""Случай калибровки Askervein (C10 v2, docs/contracts/air-model.md): одиночный холм, нейтраль, TU-03B.

Адаптер к форме C10 поверх прежних скриптов: рельеф — air3d/askervein.py (изолинии WAsP, Zenodo 4095052), наблюдаемые
разгонов — tune/askervein_runs.py (39 точек AM-09: FSR на 10 м по линиям A, AA, B и профиль на HT; σ данных — из
tune/out/fit_s1.json), профиль опорной мачты RS — recal/config.json (S(z)/S(24 м), чашки и змей). Сетка, область,
губки и профиль притока — по общим правилам rules.py (как у Perdigão), схема — scheme.py. Решатель не меняется.
Сеточные поправки и σ сетки — пересчитаны на общей схеме (b1/grid.py → b1/out/grid.json), старые AM-09 не берутся.

  observations() -> list[dict]      run_one(over, subcase="tu03b", dx=20.0, ctl=None) -> dict
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
sys.path.insert(0, str(HERE))
sys.path.append(str(HERE.parent / "air3d"))
sys.path.append(str(HERE.parent / "morris"))

import rules as RU        # noqa: E402
import scheme as SC       # noqa: E402

NAME = "ask"
SUBCASES = ["tu03b"]
DATA = ROOT / "tools/research/data/askervein/askervein_validation1.txt"
FIT_S1 = HERE.parent / "tune/out/fit_s1.json"
RECAL = HERE.parent / "recal/config.json"

RS = (74300.0, 20980.0)
HT = (75387.0, 23735.0)
F_COR = 2 * 7.2921159e-5 * math.sin(math.radians(57.186))     # 1,225e-4 1/с (Askervein 57°11' с. ш.)
WDIR = 210.0
U10_IN = 8.8                     # U10 фона: правило «модель на опорной точке = данные»: S(RS, 10 м) модели = 8,895 (Gill UVW) на номинале (b1/out/probe_runs.jsonl: 8,9 → 9,00; ×8,895/9,00)
NOM = dict(lam_frac=0.031, lam=40.0, alpha=0.235, z0=0.03)    # z0 — Taylor & Teunissen 1987; α, λ/h — перекалибровка
SIG_FLOOR = 0.03                 # общий с Perdigão абсолютный член σ (калибровка/перебег чашек, положение точки)
REF_H = 24.0                     # профиль RS: S(z)/S(24 м)


def _rows():
    return list(csv.DictReader(open(DATA)))


def _h_relief():
    """H = вершина HT над опорной RS (высоты станций в данных: 124,61 и 4,75 м) — перепад рельефа в области наблюдений."""
    z = {r["Name"]: float(r["Z(m)"]) for r in _rows() if r["Name"] in ("HT", "RS")}
    return z["HT"] - z["RS"]


H_M = _h_relief()                                        # 119,9 м (по карте рельефа 124 − 8 = 116 м)
DX_NOM = round(H_M / RU.H_PER_DX / 5.0) * 5.0             # 20 м
MIN_AGL = RU.MIN_AGL_PER_DZ * DX_NOM / 2                  # 10 м: наблюдаемые на 10 м и выше


@lru_cache(maxsize=None)
def _ak():
    """air3d/askervein.py (рельеф по изолиниям WAsP) — под другим именем: этот модуль тоже зовётся askervein."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("askervein_air3d", HERE.parent / "air3d/askervein.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@lru_cache(maxsize=None)
def terrain(dx, L=4000.0):
    return _ak().terrain(dx, L)


@lru_cache(maxsize=None)
def hmax(L=4000.0):
    return float(terrain(10.0, L)[3].max())


def geometry(dx=None, dom_mul=1.0, top_mul=1.0):
    return RU.geometry(H_M, hmax(RU.N_DOM * DX_NOM * dom_mul), DX_NOM, dx, dom_mul, top_mul)


def base_params(over=None):
    geo = geometry()
    kw = dict(f_cor=F_COR, sponge_side_m=geo["sponge_side"], sponge_top_m=geo["sponge_top"], **NOM)
    kw.update(over or {})
    if "max_profile" not in (over or {}):
        kw["max_profile"] = RU.max_profile(kw["alpha"], U10_IN, kw["z0"], kw["f_cor"])
    return kw


def _setup():
    geo = geometry()
    return dict(
        H_m=round(H_M, 1), dx_m=DX_NOM, dz_m=geo["dz"], L_dom_m=geo["L"], top_m=round(geo["top"], 1),
        sponge_side_m=geo["sponge_side"], sponge_top_m=round(geo["sponge_top"], 1), f_cor=F_COR, wdir_deg=WDIR,
        u_ref=f"S(RS, 10 м) = 8,895 м/с (данные); U10 фона {U10_IN} м/с — модель на опорной точке = данные",
        alpha=NOM["alpha"], z0_m=NOM["z0"],
        z_sat_rule=f"z_sat = {RU.Z_SAT_FRAC}·0,3u*/f, u* = κU10/ln(10/z0): {RU.z_sat(U10_IN, NOM['z0'], F_COR):.0f} м на номинале",
        max_profile=round(RU.max_profile(NOM["alpha"], U10_IN, NOM["z0"], F_COR), 3),
        canopy="леса нет (вереск, трава): d = 0",
        stability="TU-03B: нейтраль (сильный ветер, пасмурно; Taylor & Teunissen 1987); модель — нейтраль (γ = 0, без нагрева)",
    )


SETUP = {"tu03b": _setup()}


def grid_and_case(dx, over=None, ctl=None):
    import air as A
    import synth as SY
    ctl = dict(ctl or {})
    dom_mul, top_mul = ctl.pop("dom_mul", 1.0), ctl.pop("top_mul", 1.0)
    heat, gam = ctl.pop("heat_wm2", 0.0), ctl.pop("gam", 0.0)
    geo = geometry(dx, dom_mul, top_mul)
    x0, y0, n, hc = terrain(dx, geo["L"])
    g = A.Grid(dx, n, n, geo["dz"], -geo["dz"], geo["nz"], x0, y0)
    kw = base_params(over)
    kw["sponge_top_m"] = geo["sponge_top"]
    kw = SC.apply(kw, ctl=bool(ctl) or dom_mul != 1.0 or top_mul != 1.0 or heat != 0.0 or gam != 0.0)
    kw.update(ctl)
    prm = A.Params(**kw)
    case = A.Case(U10=U10_IN, wdir=WDIR, gam=SY.const_gam(gam), H=None if heat == 0.0 else np.full(hc.shape, float(heat)))
    return g, hc, case, prm, geo


# ---------------------------------------------------------------------------------------- наблюдаемые
GRID_FILE = HERE / "b1/out/grid.json"
GRP = {"наветренная сторона": "ask_upwind", "вершина/гребень": "ask_top", "подветренная сторона": "ask_lee",
       "линия B (вдоль гребня)": "ask_lineB"}


def _grid():
    return json.loads(GRID_FILE.read_text()) if GRID_FILE.exists() else {}


def rs_data():
    rows = [r for r in _rows() if r["Name"] == "RS"]
    cup = {float(r["H(m)"]): float(r["S(m/s)"]) for r in rows if r["Sensor"] == "AES cup"}
    kite = {float(r["H(m)"]): float(r["S(m/s)"]) for r in rows if "kite" in r["Sensor"]}
    cfg = json.loads(RECAL.read_text())["rs_profile"]
    out = {}
    for name, sig in cfg["use"].items():
        src, h = (cup, float(name[3:])) if name.startswith("cup") else (kite, float(name[4:]))
        out[f"RS_{name}"] = dict(h=h, data=src[h] / cup[REF_H], sig=sig)
    return out


@lru_cache(maxsize=None)
def _observations():
    gr = _grid()
    fit = json.loads(FIT_S1.read_text())
    out = []
    for o in fit["obs"]:
        name = f"ask_{o['name']}"
        g = gr.get(name, {})
        out.append(dict(name=name, grp=GRP[o["grp"]], data=round(o["data"], 4),
                        sig=round(math.hypot(o["sig_data"], SIG_FLOOR), 4),
                        sig_grid=round(float(g.get("sig_grid", 0.0)), 4), grid_corr=round(float(g.get("grid_corr", 0.0)), 4),
                        unit="ΔS = S/S(RS, z) − 1", subcase="tu03b",
                        src=f"Taylor & Teunissen 1987, Zenodo 4095052 (askervein_validation1.txt); AM-09 tune/out/fit_s1.json: "
                            f"σ_данных {o['sig_data']:.3f} (FSRmin/FSRmax) ⊕ 0,03"))
    for name, r in rs_data().items():
        nm = f"ask_{name}"
        g = gr.get(nm, {})
        out.append(dict(name=nm, grp="ask_rs", data=round(r["data"], 4), sig=r["sig"],
                        sig_grid=round(float(g.get("sig_grid", 0.0)), 4), grid_corr=round(float(g.get("grid_corr", 0.0)), 4),
                        unit="S(RS, z)/S(RS, 24 м)", subcase="tu03b",
                        src=f"RS {'чашки AES' if 'cup' in name else 'змей BRE'} {r['h']:g} м к чашкам 24 м; σ — recal/config.json"))
    return out


def observations():
    return [dict(o) for o in _observations()]


# ---------------------------------------------------------------------------------------- прогон
PROFILE_H = (15.0, 24.0, 34.0)   # профиль HT к RS на той же высоте (AM-09; 3–8 м ниже 1,5 dz — не берутся)


@lru_cache(maxsize=None)
def obs_points():
    """Точки 10 м (как tune/askervein_runs.obs_points: без RS, повторы в одной точке — среднее положение)."""
    pts = {}
    for r in _rows():
        try:
            fsr, h = float(r["FSR"]), float(r["H(m)"])
        except ValueError:
            continue
        if fsr <= -900 or h != 10.0 or r["Name"].startswith("RS"):
            continue
        name = r["Name"].split()[0] if r["Name"].startswith(("HT", "CP")) else r["Name"]
        key = (round(float(r["X(m)"]) / 20), round(float(r["Y(m)"]) / 20)) if name not in ("HT", "CP") else name
        pts.setdefault(key, []).append(dict(name=name, x=float(r["X(m)"]), y=float(r["Y(m)"])))
    return [dict(name=lst[0]["name"], x=float(np.mean([p["x"] for p in lst])), y=float(np.mean([p["y"] for p in lst])))
            for lst in pts.values()]


def model_obs(S, g):
    """Разгон ΔS = S(точка, z)/S(RS, z) − 1 на той же высоте над землёй (Taylor & Teunissen), профиль RS — S(z)/S(24 м);
    выборка — synth.agl (линейно по z над рельефом клетки) + билинейно по столбцам, как в AM-09/recal."""
    import synth as SY
    from real import bil
    u, v, w, th = S.centers()
    sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
    names = {o["name"] for o in observations()}
    s10 = SY.agl(S, sp, 10.0)
    r10 = bil(g, s10, *RS)
    obs = {}
    for p in obs_points():
        obs[f"ask_{p['name']}"] = bil(g, s10, p["x"], p["y"]) / r10 - 1
    for h in PROFILE_H:
        sh = SY.agl(S, sp, h)
        obs[f"ask_HT_prof{h:g}"] = bil(g, sh, *HT) / bil(g, sh, *RS) - 1
    ref = bil(g, SY.agl(S, sp, REF_H), *RS)
    for name, r in rs_data().items():
        obs[f"ask_{name}"] = bil(g, SY.agl(S, sp, r["h"]), *RS) / ref
    return {k: float(v) for k, v in obs.items() if k in names}, dict(rs10=float(r10))


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


def run_one(over: dict, subcase: str = "tu03b", dx: float = DX_NOM, ctl: dict | None = None, keep: bool = False) -> dict:
    """Один прогон air.py (C10 v2). over — переопределения air.Params; общая схема — поверх; ctl — контроль
    (scheme_ctl = True; поля схемы и/или "dom_mul", "top_mul", "heat_wm2", "gam")."""
    import model as M
    assert subcase in SUBCASES
    g, hc, case, prm, geo = grid_and_case(dx, over, ctl)
    row = dict(case=NAME, subcase=subcase, dx=float(dx), params=_clean(dataclasses.asdict(prm)))
    if ctl:
        row.update(scheme_ctl=True, ctl=_clean(dict(ctl)))
    try:
        with M.GpuLock() as lk:
            S = M.SY.run(g, hc, case, prm, max_outer=SC.MAX_OUTER)
        meta = M.meta(S)
        obs, extra = model_obs(S, g)
        row.update(status=meta["status"], iters=meta["iters"], t=float(meta["t"]), obs=_clean(obs),
                   t_lock_wait=round(lk.wait, 2), inputs=dict(wdir=WDIR, u10_in=U10_IN, rs10_model=extra["rs10"], rs10_obs=8.895),
                   geo=_clean(dict(geo, n_cells=int(g.nx * g.ny * g.nz))), h_bl=float(np.mean(S.h_bl)),
                   lam_eff=float(np.mean(S.lam_np)))
        if keep:
            row["_S"] = S
        else:
            M.free(S)
    except Exception as e:                                                       # noqa: BLE001
        row.update(status="error", iters=0, t=0.0, obs={}, err=repr(e))
    return row


if __name__ == "__main__":
    obs = observations()
    print(len(obs), "наблюдаемых; H", round(H_M, 1), "dx", DX_NOM)
    print(json.dumps(SETUP, ensure_ascii=False, indent=1))
