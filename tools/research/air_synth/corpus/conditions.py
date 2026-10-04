#!/usr/bin/env python3
"""SY-3: условия для сети (контракт S2 v1, docs/contracts/air-synth.md).

Распределения исходных условий — как у случаев P2 (air_nn_pilot/airlite_gen.plan_rows + places.context):
час 9/12/15/20, облачность clear/partly/overcast, U10 0,5–8 м/с (штиль не берём), откуда дует 0–360°, t_max 18–34 °C,
дата — reference_context (15 июля), lat/lon — условная точка из распределения мест P2 (PLACE_BOXES), пояс round(lon/15).
Производные — кодом решателя (air3d: weather.Day, wind_prof.for_hour, air.solar_flux) + N, Fr, w*/U по AN-4
(tools/research/ann2/regime.py). Для H1 берутся только механические условия (w*/U < WSU_THR): перевыбор с тем же ГСЧ.

  conditions.py make --corpus <каталог S1> --out <каталог S2> --k 2 --seed S [--name ...]
  conditions.py dist --n 10000 --seed S --out out_conditions/dist_v1.json     # распределения на поддельных рельефах

sample(cond_seed, relief_id, relief_summary, k, hc400=None) -> list[Conditions] — детерминированно (SeedSequence
([cond_seed, relief_id])). hc400 — рельеф g400 (float, (96, 96), [j — север, i — восток]); без него — грубая модель
(плоский склон, долина и среднее по сводке), только для проверок: производные отличаются, см. README/summary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
import time
import types
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
AIR3D = HERE.parents[1] / "air3d"
sys.path.insert(0, str(AIR3D))

import corpus_io as cio  # noqa: E402  (SY-1: HDF5, S2 v2)
import air as A          # noqa: E402  (код решателя, только импорт; cupy не нужен)
import weather as W      # noqa: E402
import wind_prof as WP   # noqa: E402

CONTRACT = "S2 v2"
SKY_CODE = {"clear": 0, "partly": 1, "overcast": 2}
HOURS = (9.0, 12.0, 15.0, 20.0)            # airlite_gen.HOURS
SKIES = ("clear", "partly", "overcast")    # airlite_gen.SKIES
U10_RANGE = (0.5, 8.0)                     # plan_rows (без штиля: каждый 12-й случай P2 — штиль, в H1 не входит)
TMAX_RANGE = (18.0, 34.0)
WSU_THR = 0.5                              # ann2/regime.py: WSU_THR — механический режим при w*/U < 0,5
G, TH0, RHO_CP = 9.81, 300.0, 1.2 * 1005.0 # ann2/regime.py (Дирдорф), TH0 как в решателе
G_OVER_TH0 = 9.81 / 300.0                  # film_bg.py
N_LAYER_M = 1500.0                         # film_bg.py: N над слоем перемешивания — z_i … z_i + 1500 м
MAX_TRIES = 2000                           # предел перевыбора на одно условие

# Горные системы терраса P2 (air_nn_pilot/configs/terrain.yaml → systems): [lat_min, lat_max, lon_min, lon_max]
PLACE_BOXES = {
    "southern_alps_nz": [[-46.0, -42.4, 166.6, 172.8]], "caucasus": [[40.0, 44.6, 37.0, 49.8]],
    "pyrenees": [[41.9, 43.5, -2.2, 3.4]], "appalachians": [[33.5, 42.0, -85.8, -74.5], [42.0, 48.5, -78.0, -63.5]],
    "alps": [[43.6, 48.4, 5.0, 16.8]], "carpathians": [[44.2, 50.2, 18.0, 27.5]], "balkans": [[39.0, 46.0, 13.5, 28.5]],
    "apennines": [[37.5, 44.6, 7.5, 18.6]], "iberia": [[36.0, 43.9, -9.6, 3.4]],
    "scandinavia": [[57.5, 70.0, 4.5, 31.0]], "britain": [[49.8, 59.0, -8.5, 2.0]], "ural": [[50.0, 70.0, 55.0, 66.5]],
    "anatolia": [[35.8, 42.2, 26.0, 45.0]], "iran": [[25.0, 40.0, 44.0, 62.0]],
    "hindukush_pamir": [[33.0, 40.5, 62.0, 75.5]], "tianshan": [[39.5, 45.5, 68.0, 95.5]],
    "altai_sayan": [[45.0, 56.5, 82.0, 100.0]], "mongolia_baikal": [[45.0, 58.0, 100.0, 120.0]],
    "himalaya_tibet": [[26.0, 39.5, 72.0, 104.0]], "china_east": [[18.0, 45.0, 104.0, 123.0]],
    "indochina": [[5.0, 26.0, 92.0, 110.0]], "japan_korea": [[30.0, 46.0, 124.0, 146.0]],
    "siberia_east": [[50.0, 70.0, 120.0, 180.0]], "taiwan_philippines": [[4.5, 25.5, 117.0, 127.0]],
    "insulindia": [[-11.0, 7.5, 94.0, 141.0]], "newguinea": [[-11.0, -0.5, 141.0, 156.0]],
    "australia": [[-44.0, -10.0, 112.0, 154.0]], "new_zealand": [[-47.5, -34.0, 166.0, 179.0]],
    "india": [[6.0, 26.0, 68.0, 92.0]], "arabia": [[12.0, 32.0, 34.0, 60.0]], "east_africa": [[-15.0, 16.0, 28.0, 52.0]],
    "south_africa": [[-35.0, -15.0, 12.0, 41.0]], "atlas": [[27.0, 37.5, -12.0, 12.0]],
    "africa_other": [[-15.0, 27.0, -18.0, 28.0]], "coast_mountains": [[48.0, 60.0, -137.0, -125.0]],
    "alaska_yukon": [[58.0, 70.0, -170.0, -125.0]], "rockies_cordillera": [[31.0, 58.0, -125.0, -102.0]],
    "mexico_central_america": [[7.0, 31.0, -118.0, -77.0]], "andes_north": [[-15.0, 12.5, -82.0, -60.0]],
    "andes_central": [[-35.0, -15.0, -76.0, -60.0]], "patagonia": [[-56.0, -35.0, -76.0, -63.0]],
    "brazil_highlands": [[-35.0, 5.0, -60.0, -34.0]],
}
SYSTEM_CAP = 0.12     # terrain.yaml: select.system_cap — доля пула на одну систему


def _box_weights():
    """Вес бокса ∝ площади (cos φ·Δφ·Δλ), доля системы ≤ SYSTEM_CAP (избыток — остальным пропорционально)."""
    boxes, sysid, w = [], [], []
    for s, bs in PLACE_BOXES.items():
        for b in bs:
            la0, la1, lo0, lo1 = b
            boxes.append(b)
            sysid.append(s)
            w.append((math.sin(math.radians(la1)) - math.sin(math.radians(la0))) * math.radians(lo1 - lo0))
    w = np.array(w)
    names = sorted(set(sysid))
    share = {s: sum(w[i] for i in range(len(w)) if sysid[i] == s) for s in names}
    tot = sum(share.values())
    share = {s: v / tot for s, v in share.items()}
    capped = {}
    for _ in range(50):            # водолив: превышение кэпа раздаётся тем, кто ниже кэпа
        over = {s for s, v in share.items() if v > SYSTEM_CAP}
        if not over:
            break
        free = [s for s in share if s not in over]
        excess = sum(share[s] - SYSTEM_CAP for s in over)
        base = sum(share[s] for s in free)
        for s in over:
            share[s] = SYSTEM_CAP
        for s in free:
            share[s] += excess * share[s] / base
    ww = np.array([share[sysid[i]] * w[i] / sum(w[j] for j in range(len(w)) if sysid[j] == sysid[i]) for i in range(len(w))])
    return boxes, sysid, ww / ww.sum()


BOXES, BOX_SYS, BOX_P = _box_weights()


# ----------------------------------------------------------------- исходные условия
def draw_place(rng):
    """Условная точка (lat, lon, utc_offset_h): бокс по весам, широта — равномерно по площади, долгота — равномерно."""
    la0, la1, lo0, lo1 = BOXES[int(rng.choice(len(BOXES), p=BOX_P))]
    s = rng.uniform(math.sin(math.radians(la0)), math.sin(math.radians(la1)))
    lat = float(np.round(abs(math.degrees(math.asin(s))), 3))   # только северное полушарие: южные боксы — зеркально
    lon = float(np.round(rng.uniform(lo0, lo1), 3))
    return lat, lon, float(round(lon / 15.0))


def draw_raw(rng):
    """Одно условие как plan_rows (час и облачность — равномерно из 4 × 3; в P2 — по кругу, то же маргинально);
    U10 — 0,5–8 м/с (штиль не берём), округление как в P2 (0,01 м/с; 0,1°; 0,1 °C)."""
    return dict(hour=float(HOURS[int(rng.integers(4))]), sky=SKIES[int(rng.integers(3))],
                U10=float(np.round(rng.uniform(*U10_RANGE), 2)), wdir=float(np.round(rng.uniform(0, 360), 1)),
                t_max=float(np.round(rng.uniform(*TMAX_RANGE), 1)))


# ----------------------------------------------------------------- рельеф для производных
def coarse_hc(summary, n=96):
    """Грубая модель рельефа по сводке (без g400): горизонтальная поверхность на средней высоте (h_min + h_max)/2 —
    для проверок, когда поля нет. Долина — нижние 10 % по сводке (h_min + 0,1·relief)."""
    return np.full((n, n), 0.5 * (summary.h_min_m + summary.h_max_m)), summary.h_min_m + 0.1 * summary.relief_m


def ground_ctx(hc, dx=400.0, x0=-19200.0, radius=10000.0, samples=15, low_pct=0.1):
    """weather.ground_context по сетке: билинейно (как places.height_at) в круге radius, 15 × 15 точек."""
    hc = np.asarray(hc, float)
    n = hc.shape[0]

    def h_fn(x, y):
        fi = np.clip((x - x0) / dx - 0.5, 0, n - 1.000001)
        fj = np.clip((y - x0) / dx - 0.5, 0, n - 1.000001)
        i0, j0 = int(fi), int(fj)
        a, b = fi - i0, fj - j0
        return float((1 - b) * ((1 - a) * hc[j0, i0] + a * hc[j0, i0 + 1]) + b * ((1 - a) * hc[j0 + 1, i0] + a * hc[j0 + 1, i0 + 1]))

    return W.ground_context(h_fn, radius, samples, low_pct)


def heat_mean(hc, D, ctx, lat, lon, utc, dx=400.0):
    """Hs — среднее по области max(H, 0), Вт/м²: H = air.solar_flux (с запаздыванием прогрева «none»), у края области
    гасится как в решателе Air.__init__ (heat_taper_m); AN-4 брал это же из d400_H решения с нагревом."""
    doy = W.day_of_year(ctx["month"], ctx["day"])
    H, sun = A.solar_flux(hc, dx, D, lat, lon, utc, doy, water=None, lag_h=W.CFG["heating"]["lag_h"]["none"])
    ny, nx = hc.shape
    if np.any(H != 0):
        tp = A.Params().heat_taper_m
        xe, ye = (np.arange(nx) + 0.5) * dx, (np.arange(ny) + 0.5) * dx
        Lx, Ly = nx * dx, ny * dx
        exx = np.clip(np.minimum(xe, Lx - xe) / tp, 0, 1)
        eyy = np.clip(np.minimum(ye, Ly - ye) / tp, 0, 1)
        H = H * (np.sin(0.5 * np.pi * eyy)[:, None] * np.sin(0.5 * np.pi * exx)[None, :]) ** 2
    return float(np.maximum(H, 0).mean()), sun


def wstar(Hs, zi_agl):
    """Дирдорф: w* = (g/θ0 · Hs/(ρ·cp) · z_i)^(1/3), м/с; Hs ≤ 0 или z_i ≤ 0 → 0 (ann2/regime.py)."""
    return (G / TH0 * max(Hs, 0.0) / RHO_CP * max(zi_agl, 0.0)) ** (1 / 3)


def derive(raw, ctx, hc, relief_m):
    """Производные случая (словарь полей Derived) тем же кодом, что строит случай P2: weather.Day, wind_prof.for_hour,
    air.solar_flux; N и Fr — film_bg.bg_raw (без обрезки Fr); w*/U — ann2/regime.py."""
    hour, U10 = raw["hour"], raw["U10"]
    D = W.Day(hour, raw["t_max"], raw["sky"], ctx)
    P0 = A.Params()
    alpha, mp, cls, sun_el = WP.for_hour(ctx, hour, raw["sky"], U10, P0.z0, P0.f_cor)
    Hs, sun = heat_mean(hc, D, ctx, ctx["lat"], ctx["lon"], ctx["utc_offset_h"])
    hm = float(np.mean(hc))
    zi_agl = float(D.z_i - hm)
    ws = wstar(Hs, zi_agl)
    U = U10 * mp                                                  # скорость притока выше z_sat (профиль насыщается)
    wsu = ws / max(U, 0.1)
    z = D.z_i + np.linspace(0.0, N_LAYER_M, 301)
    N = float(np.mean(np.sqrt(G_OVER_TH0 * np.maximum(np.asarray(D.gamma(z), float), 0.0))))
    fr = U / (N * max(relief_m, 1.0)) if N > 0 else 1e3
    cap = D.st["cap_agl_m"]
    return dict(alpha=float(alpha), max_profile=float(mp), z_i_m=float(D.z_i), z_lcl_m=float(D.z_lcl), heat=float(D.heat),
                brk=float(D.st["brk"]), stability_class=WP.CLASSES.index(cls), has_cap=bool(math.isfinite(cap)),
                cap_agl_m=float(cap) if math.isfinite(cap) else 0.0, sun_el_deg=float(sun_el), sun_az_deg=float(sun[0]),
                t_c=float(D.t), n_bv_s=N, froude=float(fr), w_star_m_s=float(ws), w_star_over_u=float(wsu),
                mechanical=bool(wsu < WSU_THR), hs_w_m2=Hs, u_sat_m_s=U, z_i_agl_m=zi_agl)


def _ctx(lat, lon, utc, hc_or_none, summary, month_day=None):
    rc = W.CFG["reference_context"]
    md = month_day or (rc["month"], rc["day"])
    ctx = dict(month=md[0], day=md[1], lat=lat, lon=lon, utc_offset_h=utc)
    if hc_or_none is None:
        hc, valley = coarse_hc(types.SimpleNamespace(**summary) if isinstance(summary, dict) else summary)
        ctx.update(valley_msl_m=float(valley), mean_msl_m=float(hc.mean()))
    else:
        hc = np.asarray(hc_or_none, float)
        ctx.update(ground_ctx(hc))
    return ctx, hc


def _g(o, k):
    return o[k] if isinstance(o, dict) else getattr(o, k)


def draw_p2(rng, n):
    """Условие из распределения P2 без отбора (plan_rows): час и облачность по кругу от глобального номера n = relief_id·k + cond_id,
    каждый 12-й (n % 12 == 5) — штиль (U10 = 0); направление, t_max и U10 — как в P2."""
    u = float(np.round(rng.uniform(*U10_RANGE), 2))
    return dict(hour=float(HOURS[n % 4]), sky=SKIES[(n // 4) % 3], U10=0.0 if n % 12 == 5 else u,
                wdir=float(np.round(rng.uniform(0, 360), 1)), t_max=float(np.round(rng.uniform(*TMAX_RANGE), 1)))


def sample_ex(cond_seed, relief_id, relief_summary, k, hc400=None, extras=None, place=None, mechanical_only=False):
    """→ (rows, tries): rows — структурный массив cio.CONDITIONS_DTYPE (k строк, S2 v2), по умолчанию из распределения P2 без отбора (draw_p2, mechanical_only=False; признак mechanical — для оценки),
    mechanical_only=True — перевыбор только механических без штиля (вариант набора); tries — сколько кандидатов просмотрено на каждое (для доли отказов); extras — список, куда кладутся словари с
    сырыми полями и полным derive() (Hs, U, z_i AGL). relief_summary — dict или объект с h_min_m, h_max_m, relief_m;
    place — dict/объект с name, lat_deg, lon_deg (реальное место S1). Детерминированно: ГСЧ — SeedSequence
    ([cond_seed, relief_id]); место (lat, lon, пояс) — одно на рельеф, как место P2 с n_cond условиями."""
    summ = types.SimpleNamespace(**relief_summary) if isinstance(relief_summary, dict) else relief_summary
    rng = np.random.Generator(np.random.PCG64(np.random.SeedSequence([int(cond_seed), int(relief_id)])))
    lat, lon, utc = draw_place(rng)
    md = None
    if place is not None and _g(place, "name"):      # реальное место — его координаты; юг — 15 января (лето)
        lat, lon = float(_g(place, "lat_deg")), float(_g(place, "lon_deg"))
        utc = float(round(lon / 15.0))
        md = (1, 15) if lat < 0 else None
    ctx, hc = _ctx(lat, lon, utc, hc400, summ, md)
    rows = np.zeros(k, cio.CONDITIONS_DTYPE)
    tries = []
    for c in range(k):
        for t in range(1, MAX_TRIES + 1):
            raw = draw_raw(rng) if mechanical_only else draw_p2(rng, int(relief_id) * k + c)
            d = derive(raw, ctx, hc, summ.relief_m)
            if d["mechanical"] or not mechanical_only:
                break
        else:
            raise RuntimeError(f"рельеф {relief_id}: нет механического условия за {MAX_TRIES} попыток")
        if extras is not None:
            extras.append(dict(d, u10=raw["U10"], wdir=raw["wdir"], hour=raw["hour"], sky=raw["sky"], tmax=raw["t_max"], lat=lat))
        r = rows[c]
        r["relief_id"], r["cond_id"] = int(relief_id), c
        r["u10_m_s"], r["wind_from_deg"], r["hour_local"], r["t_max_c"] = raw["U10"], raw["wdir"], raw["hour"], raw["t_max"]
        r["lat_deg"], r["lon_deg"], r["utc_offset_h"] = lat, lon, utc
        r["sky"], r["month"], r["day"] = SKY_CODE[raw["sky"]], ctx["month"], ctx["day"]
        for f in rows.dtype.names:
            if f in d:
                r[f] = d[f]
        r["strat_override"], r["n_bv_override_s"], r["z_i_override_agl_m"] = False, np.nan, np.nan
        tries.append(t)
    return rows, tries


def sample(cond_seed, relief_id, relief_summary, k, hc400=None, place=None, mechanical_only=False):
    """Контракт S2 v2: k строк (cond_id 0 … k−1), по умолчанию P2 без отбора, детерминированно."""
    return sample_ex(cond_seed, relief_id, relief_summary, k, hc400, place=place, mechanical_only=mechanical_only)[0]


# ----------------------------------------------------------------- CLI make
def generator_version():
    return "cond1-" + hashlib.sha1(Path(__file__).read_bytes()).hexdigest()[:7]


def _git_commit():
    try:
        return subprocess.check_output(["git", "-C", str(HERE), "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        return ""


def summary_of(rel):
    return rel.summary


def make(corpus_dir, out_dir, k, seed, name=None, command="", mechanical_only=False):
    """Набор условий S2 v2 по корпусу S1: части part-NNNNN.h5 (рельефы id [n·S, (n+1)·S) корпуса), вид conditions.h5,
    manifest.json. Готовые части пропускаются (продолжение той же командой)."""
    cor = cio.Corpus(corpus_dir)
    S = int(cor.attrs.get("shard_size", 100)) or 100
    os.makedirs(out_dir, exist_ok=True)
    cio.clean_tmp(out_dir)
    ids_all = cor.ids()
    n_parts = (max(ids_all) // S + 1) if ids_all else 0
    base = dict(relief_corpus=str(Path(corpus_dir).resolve()), cond_seed=np.uint64(seed), k_per_relief=k, mechanical_only=bool(mechanical_only),
                shard_size=S, generator_version=generator_version(), git_commit=_git_commit(), command=command,
                wsu_threshold=WSU_THR)
    man = dict(base, contract=CONTRACT, kind="conditions", name=name or Path(out_dir).name, cond_seed=int(seed),
               n_total=len(ids_all) * k, place_distribution="PLACE_BOXES (terrain.yaml), north only, area-weighted, cap 0.12",
               date="15 July (model reliefs); real places south: 15 January", strat_override="not filled (H5 later)")
    cio.write_manifest(out_dir, man)
    done = set(cio.list_parts(out_dir))
    for part in range(n_parts):
        ids = [i for i in ids_all if i // S == part]
        if part in done or not ids:
            continue
        tabs, tr = [], []
        for rid in ids:
            sm = cor.summary(rid)
            pl = cor.place(rid) if cor._has("place") else None
            rows, tries = sample_ex(seed, rid, sm, k, cor.h400(rid, np.float64), place=pl, mechanical_only=mechanical_only)
            tabs.append(rows)
            tr += tries
        rej = 1 - len(tr) / sum(tr)
        cio.write_conditions_part(out_dir, part, np.concatenate(tabs), dict(base, reject_fraction=rej, sum_tries=int(sum(tr))))
    cor.close()
    info = cio.build_view(out_dir, "conditions")
    # общая доля отказов набора = 1 − Σ(условий) / Σ(просмотренных кандидатов) по всем частям -> корень вида и manifest
    import h5py
    n_ok = n_tries = 0
    for p in cio.list_parts(out_dir):
        with h5py.File(cio.part_path(out_dir, p), "r") as f:
            n_ok += int(f.attrs["n_records"])
            n_tries += int(f.attrs["sum_tries"])
    rej = 1 - n_ok / n_tries
    with h5py.File(os.path.join(out_dir, cio.VIEW_NAME["conditions"]), "a") as f:
        f.attrs["reject_fraction"] = rej
    man.update(info, reject_fraction=rej, reject_fraction_note="1 − Σ условий / Σ кандидатов по всем частям; по частям — атрибут reject_fraction")
    cio.write_manifest(out_dir, man)
    return info


# ----------------------------------------------------------------- распределения (dist_v1.json)
def fake_relief(rng, n=96):
    """Поддельный рельеф g400 для распределений: поле со степенным спектром (β = 2,7 — спектр 1–10 км из
    terrain_statistics.md), перепад — логравномерно 300–3000 м (размах мест П6: 200–3000 м), дно — 200–2500 м."""
    kx = np.fft.fftfreq(n)[None, :]
    ky = np.fft.fftfreq(n)[:, None]
    k = np.sqrt(kx ** 2 + ky ** 2)
    k[0, 0] = 1.0
    f = np.fft.ifft2((rng.standard_normal((n, n)) + 1j * rng.standard_normal((n, n))) * k ** (-(2.7 + 1.0) / 2)).real
    f = (f - f.min()) / (f.max() - f.min())
    relief = float(np.exp(rng.uniform(math.log(300.0), math.log(3000.0))))
    base = float(rng.uniform(200.0, 2500.0))
    hc = base + relief * f
    s = dict(h_min_m=float(hc.min()), h_max_m=float(hc.max()), relief_m=float(hc.max() - hc.min()))
    return hc, s


def _q(a, qs=(0, 1, 5, 25, 50, 75, 95, 99, 100)):
    a = np.asarray(a, float)
    return {f"p{q}": float(np.percentile(a, q)) for q in qs}


def _h(a, lo, hi, n=20):
    c, e = np.histogram(np.asarray(a, float), bins=n, range=(lo, hi))
    return dict(edges=[float(x) for x in e], counts=[int(x) for x in c])


def summary_cond(cond_dir, out):
    """Сводка набора S2 -> JSON: доли механических и штилей, распределения (квантили) по полям, разбивка по часу/облачности."""
    T = cio.Conditions(cond_dir).table
    f = lambda n: T[n].astype(float)
    mech = T["mechanical"].astype(bool)
    res = dict(cond_dir=str(cond_dir), n=len(T), n_reliefs=int(len(np.unique(T["relief_id"]))), attrs={k: (v.item() if hasattr(v, "item") else v) for k, v in
               cio.Conditions(cond_dir).attrs.items() if k not in ("command",)},
               mechanical_fraction=float(mech.mean()), calm_fraction=float((T["u10_m_s"] == 0).mean()),
               weak_wind_fraction_u10_lt2=float((T["u10_m_s"] < 2).mean()),
               mechanical_by_hour={str(h): float(mech[T["hour_local"] == h].mean()) for h in HOURS},
               mechanical_by_sky={s_: float(mech[T["sky"] == c].mean()) for s_, c in SKY_CODE.items()},
               hour_counts={str(h): int((T["hour_local"] == h).sum()) for h in HOURS},
               sky_counts={s_: int((T["sky"] == c).sum()) for s_, c in SKY_CODE.items()},
               stability_class_counts={str(c): int((T["stability_class"] == c).sum()) for c in range(6)},
               has_cap_fraction=float(T["has_cap"].mean()))
    for n in ("u10_m_s", "wind_from_deg", "t_max_c", "lat_deg", "w_star_over_u", "w_star_m_s", "froude", "n_bv_s", "hs_w_m2", "alpha", "max_profile"):
        res[n] = _q(f(n))
        if n in ("w_star_over_u", "froude"):
            res[n + "_mechanical"] = _q(f(n)[mech]) if mech.any() else None
            res[n + "_non_mechanical"] = _q(f(n)[~mech]) if (~mech).any() else None
    res["froude_lt_1_fraction"] = float((f("froude") < 1).mean())
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    json.dump(res, open(out, "w"), indent=1, ensure_ascii=False)
    return res


def dist(n, seed, out):
    rng = np.random.default_rng(seed)
    recs, tries, firstdraw = [], [], []
    t0 = time.time()
    for rid in range(n):
        hc, s = fake_relief(rng)
        ex = []
        conds, tr = sample_ex(seed, rid, s, 1, hc, ex, mechanical_only=True)
        recs.append(dict(ex[0], relief=s['relief_m'], hmin=s['h_min_m'], hmean=float(hc.mean())))
        tries.append(tr[0])
        # безусловное распределение: первый кандидат того же ГСЧ (до перевыбора) — для доли отказов по режимам
        r2 = np.random.Generator(np.random.PCG64(np.random.SeedSequence([int(seed), int(rid)])))
        lat, lon, utc = draw_place(r2)
        ctx, h2 = _ctx(lat, lon, utc, hc, s)
        raw = draw_raw(r2)
        d = derive(raw, ctx, h2, s['relief_m'])
        firstdraw.append(dict(hour=raw["hour"], sky=raw["sky"], u10=raw["U10"], wsu=d["w_star_over_u"], mech=d["mechanical"],
                              froude=d["froude"]))
    col = lambda k_: np.array([r[k_] for r in recs])
    f = lambda k_: np.array([r[k_] for r in firstdraw])
    fr = col("froude")
    out_d = dict(
        contract=CONTRACT, generator_version=generator_version(), n_reliefs=n, seed=seed, fake_reliefs="fake_relief(): степенной спектр, перепад логравномерно 300–3000 м, дно 200–2500 м",
        wsu_threshold=WSU_THR, seconds=round(time.time() - t0, 1),
        mechanical_reject_fraction=float(1 - len(tries) / np.sum(tries)),
        candidates_per_condition=float(np.mean(tries)),
        reject_first_draw=dict(overall=float(1 - np.mean(f("mech"))),
                               by_hour={str(h): float(1 - np.mean(f("mech")[f("hour") == h])) for h in HOURS},
                               by_sky={s_: float(1 - np.mean(f("mech")[np.array([x == s_ for x in [r["sky"] for r in firstdraw]])])) for s_ in SKIES},
                               by_u10={f"{lo}-{hi}": float(1 - np.mean(f("mech")[(f("u10") >= lo) & (f("u10") < hi)]))
                                       for lo, hi in ((0.5, 1.5), (1.5, 2.5), (2.5, 4), (4, 6), (6, 8.01))}),
        w_star_over_u_first_draw=_q(f("wsu")),
        # принятые (механические) условия — набор H1
        accepted=dict(
            u10_m_s=dict(q=_q(col("u10")), hist=_h(col("u10"), 0.5, 8.0)),
            wind_from_deg=dict(q=_q(col("wdir")), hist=_h(col("wdir"), 0, 360, 12)),
            hour_local={str(h): int(np.sum(col("hour") == h)) for h in HOURS},
            sky={s_: int(sum(1 for r in recs if r["sky"] == s_)) for s_ in SKIES},
            t_max_c=dict(q=_q(col("tmax")), hist=_h(col("tmax"), 18, 34, 16)),
            lat_deg=dict(q=_q(col("lat")), hist=_h(col("lat"), 0, 70, 14)),
            relief_m=dict(q=_q(col("relief"))),
            alpha=dict(q=_q(col("alpha"))), max_profile=dict(q=_q(col("max_profile"))),
            z_i_m=dict(q=_q(col("z_i_m"))), z_i_agl_m=dict(q=_q(col("z_i_agl_m"))),
            z_lcl_m=dict(q=_q(col("z_lcl_m"))), heat=dict(q=_q(col("heat"))), brk=dict(q=_q(col("brk"))),
            stability_class={ch: int(np.sum(col("stability_class") == i)) for i, ch in enumerate(WP.CLASSES)},
            has_cap=float(np.mean(col("has_cap"))), cap_agl_m=dict(q=_q(col("cap_agl_m")[col("has_cap") > 0]) if np.any(col("has_cap") > 0) else {}),
            sun_el_deg=dict(q=_q(col("sun_el_deg"))), t_c=dict(q=_q(col("t_c"))),
            n_bv_s=dict(q=_q(col("n_bv_s"))), hs_w_m2=dict(q=_q(col("hs_w_m2"))),
            u_sat_m_s=dict(q=_q(col("u_sat_m_s"))),
            froude=dict(q=_q(fr), log10_hist=_h(np.log10(fr), -2.5, 1.5, 16)),
            w_star_m_s=dict(q=_q(col("w_star_m_s"))),
            w_star_over_u=dict(q=_q(col("w_star_over_u")), hist=_h(col("w_star_over_u"), 0, 0.5, 10)),
        ),
        froude_range=dict(min=float(fr.min()), p5=float(np.percentile(fr, 5)), median=float(np.median(fr)),
                          p95=float(np.percentile(fr, 95)), max=float(fr.max()),
                          share_gt_1=float(np.mean(fr > 1)), share_lt_0_1=float(np.mean(fr < 0.1))),
        froude_first_draw=_q(f("froude")),
    )
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(json.dumps(out_d, ensure_ascii=False, indent=1))
    return out_d


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("make", help="набор условий S2 по корпусу S1")
    m.add_argument("--corpus", required=True)
    m.add_argument("--out", required=True)
    m.add_argument("--k", type=int, default=2)
    m.add_argument("--seed", type=int, required=True)
    m.add_argument("--name")
    m.add_argument("--mechanical-only", action="store_true", help="только механические (перевыбор, без штиля); по умолчанию — P2 без отбора")
    d = sub.add_parser("dist", help="распределения на n поддельных рельефах")
    d.add_argument("--n", type=int, default=10000)
    d.add_argument("--seed", type=int, default=1)
    d.add_argument("--out", default=str(HERE / "out_conditions" / "dist_v1.json"))
    sm = sub.add_parser("summary", help="сводка набора S2 -> JSON")
    sm.add_argument("--conditions", required=True)
    sm.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "summary":
        r = summary_cond(a.conditions, a.out)
        print(f"{a.out}: n={r['n']} mechanical={r['mechanical_fraction']:.3f} calm={r['calm_fraction']:.3f}")
    elif a.cmd == "make":
        man = make(a.corpus, a.out, a.k, a.seed, a.name, mechanical_only=a.mechanical_only, command="conditions.py " + " ".join(sys.argv[1:]))
        print(f"{a.out}: {man}")
    else:
        r = dist(a.n, a.seed, a.out)
        print(f"{a.out}: reject={r['mechanical_reject_fraction']:.3f} Fr median={r['froude_range']['median']:.3f}")


if __name__ == "__main__":
    main()
