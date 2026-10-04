#!/usr/bin/env python3
"""Набор условий hgw24 (S2 v4, решение пользователя 05.10): 24 разнообразных условия на место дельтаплана + возмущения погоды.

  make_hgw24.py --relief-corpus ~/air_synth_data/real/hg_v1   --sites ../hg_sites/sites.json --out ~/air_synth_data/conditions/hg_v1_hgw24
  make_hgw24.py --relief-corpus ~/air_synth_data/real/game_hg --out ~/air_synth_data/conditions/game_hgw24      (места игры — ориентации нет)

Исходные условия (на место, ГСЧ SeedSequence([cond_seed, relief_id])): месяц — апрель…сентябрь (каждый ровно 4 раза из 24; юг — +6 месяцев,
таблицы погоды сдвинуты на 6 — см. s5_io.weather_cfg), час — утро 7–10 / день 11–16 / вечер 17–20 (в каждом месяце по одному из трёх + один
случайный класс), U10 — лог-равномерно 2–12 м/с (90 %) или 0,5–2 м/с (10 %), направление «откуда» — 60 % из ориентации старта (центр
сектора ± 45°), 40 % равномерно (нет ориентации — 100 %), t_max = климат(месяц, широта) + dt_surface (замена шума ±4 К S2 v3 возмущением v4).
Возмущения (S2 v4): dt_surface_k N(0; 3,5) ±8, dt_upper_k N(0; 3) ±7, lapse_k_per_km треугольное 3–9 (мода 6,5), inv_depth_m и inv_range_k —
множители lognormal σ 0,35 (в столбцах именно множители), cloud_cover 0,8·Beta(1,5; 2,5) (среднее 0,3). Производные — тем же кодом, что строит
случай решателя (conditions.derive под подменённым конфигом Day; контекст места — как у решателя, model_place.context по рельефу)."""
import argparse
import json
import math
import os
import re
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import s5_io as S5   # noqa: E402
import solve_corpus as SC   # noqa: E402

cio = S5.cio
sys.path.insert(0, str(HERE.parent / "corpus"))
import conditions as C   # noqa: E402
import model_place as M  # noqa: E402

SEED = 20261005
K = 24
MONTHS = (4, 5, 6, 7, 8, 9)
HOUR_CLASSES = ((7.0, 10.0), (11.0, 16.0), (17.0, 20.0))     # утро, день, вечер
CLASS_NAMES = ("morning", "day", "evening")
SKY_CAT = (("clear", 0.0), ("partly", 0.3), ("overcast", 0.85))   # cover категорий configs/weather_model.json
T_JULY, T_AMP, T_LAT_SLOPE = 26.0, 8.0, -0.5                  # S2 v3: норма июля, косинус по месяцам (амплитуда 8), −0,5 °C/° от 50°
T_RANGE = (0.0, 40.0)                                         # configs/weather_model.json: ui.temperature_c

HG_DTYPE = np.dtype(cio.CONDITIONS_DTYPE.descr + [(n, "<f8") for n in S5.HG_COLUMNS] + [("dtheta_dz_k_per_km", "<f8")])
COMPASS = {"N": 0, "NNE": 22.5, "NE": 45, "ENE": 67.5, "E": 90, "ESE": 112.5, "SE": 135, "SSE": 157.5, "S": 180, "SSW": 202.5, "SW": 225,
           "WSW": 247.5, "W": 270, "WNW": 292.5, "NW": 315, "NNW": 337.5}


def _pt(tok):
    """Румб -> градусы (немецкое O = восток), число -> градусы, иначе None."""
    t = tok.strip().upper().replace("O", "E").replace("NNE", "NNE")
    t = t.replace("SWW", "WSW").replace("NWW", "WNW")
    if t in COMPASS:
        return float(COMPASS[t])
    try:
        v = float(t)
        return v % 360.0 if 0 <= v <= 360 else None
    except ValueError:
        return None


def orientation_centers(text):
    """site_orientation S6 -> список центров секторов (° откуда). Токены через ; , / пробел; «A-B» — центр дуги по часовой от A до B."""
    if not text:
        return []
    out = []
    for tok in re.split(r"[;,/\s]+", str(text)):
        if not tok:
            continue
        if "-" in tok and not tok.lstrip("-").replace(".", "").isdigit():
            a, _, b = tok.partition("-")
            pa, pb = _pt(a), _pt(b)
            if pa is not None and pb is not None:
                out.append((pa + ((pb - pa) % 360.0) / 2.0) % 360.0)
            continue
        p = _pt(tok)
        if p is not None:
            out.append(p)
    return out


def t_clim(month_season, lat):
    """Климат t_max, °C: норма июля 26 − 8·(1 − cos(2π(m−7)/12)) − 0,5·(|lat| − 50) (S2 v3); ограничено 0…36."""
    t = T_JULY - T_AMP * (1 - math.cos(2 * math.pi * (month_season - 7) / 12.0)) + T_LAT_SLOPE * (abs(lat) - 50.0)
    return float(min(max(t, 0.0), 36.0))


def draw(rng):
    """Все случайные поля одного условия (порядок розыгрыша фиксирован)."""
    return dict(
        u_strong=bool(rng.random() < 0.9),
        u=float(rng.random()),
        from_site=bool(rng.random() < 0.6),
        pick=float(rng.random()),
        off=float(rng.uniform(-45, 45)),
        wdir_u=float(rng.uniform(0, 360)),
        h=float(rng.random()),
        dt_surface=float(np.clip(rng.normal(0, 3.5), -8, 8)),
        dt_upper=float(np.clip(rng.normal(0, 3.0), -7, 7)),
        lapse=float(rng.triangular(3.0, 6.5, 9.0)),
        inv_depth_f=float(math.exp(rng.normal(0, 0.35))),
        inv_range_f=float(math.exp(rng.normal(0, 0.35))),
        cover=float(0.8 * rng.beta(1.5, 2.5)))


def rows_for(seed, rid, name, lat, lon, g100, relief_summary, orientation, k=K):
    rng = np.random.Generator(np.random.PCG64(np.random.SeedSequence([int(seed), int(rid)])))
    centers = orientation_centers(orientation)
    utc = float(round(lon / 15.0))
    # месяцы: каждый 4 раза; классы часа: на месяц — все три + один случайный; порядок условий перемешан
    months = [m for m in MONTHS for _ in range(k // len(MONTHS))]
    classes = []
    for _ in MONTHS:
        classes += [0, 1, 2, int(rng.integers(3))]
    perm = rng.permutation(k)
    pairs = [(months[i], classes[i]) for i in perm]
    south = lat < 0
    # контекст места — как у решателя (model_place.context: ground_context по g100)
    M.register(f"hg_{rid:06d}", np.asarray(g100, np.float64), 0.0)
    base_ctx = dict(M.context(f"hg_{rid:06d}"))
    hc = cio.block_mean(np.asarray(g100, np.float64), 4)
    W = S5._air3d_weather()
    rows = np.zeros(k, HG_DTYPE)
    for c in range(k):
        m_season, cls = pairs[c]
        d = draw(rng)
        month = ((m_season - 1 + 6) % 12) + 1 if south else m_season
        lo, hi = HOUR_CLASSES[cls]
        hour = float(np.round(lo + d["h"] * (hi - lo), 2))
        u10 = float(np.round(math.exp(math.log(2.0) + d["u"] * (math.log(12.0) - math.log(2.0))), 2)) if d["u_strong"] else float(np.round(0.5 + 1.5 * d["u"], 2))
        if d["from_site"] and centers:
            ctr = centers[int(d["pick"] * len(centers)) % len(centers)]
            wdir = float(np.round((ctr + d["off"]) % 360.0, 1))
        else:
            wdir = float(np.round(d["wdir_u"], 1))
        t_max = float(np.round(min(max(t_clim(m_season, lat) + d["dt_surface"], T_RANGE[0]), T_RANGE[1]), 1))
        dts = t_max - t_clim(m_season, lat)           # фактический сдвиг (после обрезки по диапазону меню)
        cover = float(np.round(d["cover"], 3))
        cfg = S5.weather_cfg(W.CFG, lat, d["dt_upper"], d["lapse"], d["inv_depth_f"], d["inv_range_f"], cover)
        ctx = dict(base_ctx, month=month, day=15, lat=lat, lon=lon, utc_offset_h=utc)
        with S5.weather_override(cfg):
            raw = dict(hour=hour, sky=S5.HG_SKY, U10=u10, wdir=wdir, t_max=t_max)
            der = C.derive(raw, ctx, hc, relief_summary["relief_m"])
            D = W.Day(hour, t_max, S5.HG_SKY, ctx)
            zz = D.z_i + np.linspace(0.0, 1000.0, 101)
            dth = float(np.mean(np.asarray(D.gamma(zz), float)) * 1000.0)
        r = rows[c]
        r["relief_id"], r["cond_id"] = int(rid), c
        r["u10_m_s"], r["wind_from_deg"], r["hour_local"], r["t_max_c"] = u10, wdir, hour, t_max
        r["lat_deg"], r["lon_deg"], r["utc_offset_h"] = lat, lon, utc
        r["sky"] = min(range(3), key=lambda i: abs(SKY_CAT[i][1] - cover))
        r["month"], r["day"] = month, 15
        for f in cio.CONDITIONS_DTYPE.names:
            if f in der:
                r[f] = der[f]
        r["strat_override"], r["n_bv_override_s"], r["z_i_override_agl_m"] = False, np.nan, np.nan
        r["dt_surface_k"], r["dt_upper_k"], r["lapse_k_per_km"] = dts, d["dt_upper"], d["lapse"]
        r["inv_depth_m"], r["inv_range_k"], r["cloud_cover"] = d["inv_depth_f"], d["inv_range_f"], cover
        r["dtheta_dz_k_per_km"] = dth
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--relief-corpus", required=True)
    ap.add_argument("--sites", default=str(HERE.parent / "hg_sites/sites.json"), help="sites.json S6 (site_orientation по place.name = site_id)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--k-cond", type=int, default=K)
    ap.add_argument("--seed", type=int, default=SEED)
    a = ap.parse_args(argv)
    cor = cio.Corpus(a.relief_corpus)
    ori = {s["site_id"][:16]: s.get("site_orientation") for s in json.load(open(a.sites))}
    S = 100
    os.makedirs(a.out, exist_ok=True)
    cio.clean_tmp(a.out)
    ids = cor.ids()
    base = dict(relief_corpus=str(Path(a.relief_corpus).resolve()), cond_seed=np.uint64(a.seed), k_per_relief=a.k_cond, mechanical_only=False,
                shard_size=S, generator_version="hgw24", git_commit=SC.git_commit(), command=" ".join(sys.argv), reject_fraction=0.0,
                contract="S2 v4")
    cio.write_manifest(a.out, dict(base, kind="conditions", cond_seed=int(a.seed), n_total=len(ids) * a.k_cond,
                                   note="hgw24 (S2 v4): 24 условия на место + возмущения погоды; inv_depth_m / inv_range_k — множители"))
    for part in sorted({i // S for i in ids}):
        tabs = []
        for rid in [i for i in ids if i // S == part]:
            pl = cor.place(rid)
            tabs.append(rows_for(a.seed, rid, pl["name"], float(pl["lat_deg"]), float(pl["lon_deg"]), cor.h100(rid, np.float64),
                                 cor.summary(rid), ori.get(pl["name"]), a.k_cond))
        cio.write_conditions_part(a.out, part, np.concatenate(tabs), base)
    cor.close()
    info = cio.build_view(a.out, "conditions")
    m = cio.read_manifest(a.out); m.update(info); cio.write_manifest(a.out, m)
    print(info)


if __name__ == "__main__":
    main()
