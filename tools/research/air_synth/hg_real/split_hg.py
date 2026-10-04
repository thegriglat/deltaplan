#!/usr/bin/env python3
"""SY-10: деление мест каталога S6 на train / holdout (S1 v4, решение пользователя 05.10).

Правила (без рельефа — только координаты и страна, чистая функция, тестируется без сети):
 1. Место ближе NEAR_GAME_KM (20 км) к месту игры -> holdout, stratum = "near_game" (вне обучения).
 2. Остальные места связываются в компоненты односвязной кластеризацией с порогом SEP_KM (50 км) — по всем местам,
    включая near_game; компонента целиком либо train, либо holdout, поэтому каждое отложенное место >= 50 км от любого
    обучающего (проверяется отдельно в тесте и в split_summary.json).
 3. Кандидаты в отложенные — малые компоненты (<= MAX_COMP мест) без near_game; регион — REGION_OF (страна/горы);
    выбор по кругу по регионам (порядок регионов и место в регионе — по зерну), пока не набрано N_HOLDOUT.
 4. train — всё остальное; stratum train-мест — их регион.
"""
import math
import random

SEP_KM = 50.0
NEAR_GAME_KM = 20.0
MAX_COMP = 3
N_HOLDOUT = 20
SPLIT_SEED = 20261005
R_KM = 6371.0088

GAME = {"askarovo": (53.26, 58.54), "aushkul": (54.72, 59.69), "altai": (51.87, 85.87), "ongudai": (50.79, 86.13)}


def dist_km(la1, lo1, la2, lo2):
    p1, p2 = math.radians(la1), math.radians(la2)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lo2 - lo1) / 2) ** 2
    return 2 * R_KM * math.asin(min(1.0, math.sqrt(h)))


def region_of(site):
    """Макрорегион отбора: страна или горный район (для Франции, где 60 % мест, и больших стран — по координатам)."""
    c, la, lo = site["country"], site["lat"], site["lon"]
    if c == "FR":
        if la < 0:
            return "FR_overseas"
        if la < 43.0 and lo > 8.0:
            return "FR_corsica"
        if la < 43.6 and lo < 3.5:
            return "FR_pyrenees"
        if lo > 5.0 and la < 47.5:
            return "FR_alps_jura"
        if lo > 5.0:
            return "FR_east"
        return "FR_west_north"
    if c in ("AT", "CH", "SI") or (c == "IT" and la > 45.0):
        return "alps_AT_CH_SI_IT"
    if c in ("IT",):
        return "IT_south"
    if c in ("ES", "PT"):
        return "iberia"
    if c in ("NO", "SE", "DK"):
        return "scandinavia"
    if c in ("DE", "PL", "SK"):
        return "central_europe"
    if c in ("GB",):
        return "britain"
    if c in ("MK", "IL", "KZ", "RU", "KR", "IR"):
        return {"MK": "balkans", "IL": "levant", "KZ": "central_asia", "RU": "russia", "KR": "east_asia", "IR": "iran"}[c]
    if c in ("US", "CA"):
        return "north_america"
    if c == "BR":
        return "brazil"
    if c == "AU":
        return "australia"
    return c


def components(sites, sep_km=SEP_KM):
    n = len(sites)
    par = list(range(n))

    def find(x):
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x
    for i in range(n):
        for j in range(i):
            if dist_km(sites[i]["lat"], sites[i]["lon"], sites[j]["lat"], sites[j]["lon"]) < sep_km:
                par[find(i)] = find(j)
    comp = {}
    for i in range(n):
        comp.setdefault(find(i), []).append(i)
    return sorted(comp.values(), key=lambda c: c[0])


def split(sites, game=None, seed=SPLIT_SEED, n_holdout=N_HOLDOUT, max_comp=MAX_COMP):
    """sites — список dict (site_id, lat, lon, country). -> dict site_id -> (part, stratum)."""
    game = game or GAME
    near = {s["site_id"] for s in sites
            if any(dist_km(s["lat"], s["lon"], la, lo) < NEAR_GAME_KM for la, lo in game.values())}
    comps = components(sites)
    rng = random.Random(seed)
    by_region = {}
    for c in comps:
        if len(c) > max_comp or any(sites[i]["site_id"] in near for i in c):
            continue
        by_region.setdefault(region_of(sites[c[0]]), []).append(c)
    regions = sorted(by_region)
    rng.shuffle(regions)
    for r in regions:
        rng.shuffle(by_region[r])
    chosen, k = [], 0
    while len(chosen) < n_holdout and any(by_region.values()):
        r = regions[k % len(regions)]
        k += 1
        if by_region[r]:
            c = by_region[r].pop()
            if len(chosen) + len(c) > n_holdout and len(chosen) > 0 and len(c) > 1:
                continue
            chosen += c
    out = {}
    for i, s in enumerate(sites):
        out[s["site_id"]] = ("train", region_of(s))
    for i in chosen:
        out[sites[i]["site_id"]] = ("holdout", region_of(sites[i]))
    for sid in near:
        out[sid] = ("holdout", "near_game")
    return out
