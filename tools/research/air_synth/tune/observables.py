"""Наблюдаемые рельефа для настройки (SY-5): вектор чисел по квадрату 384x384, шаг 100 м (38.4 x 38.4 км).
Общие для реальных квадратов и для generate(...)[1]. Статистики — terrain_stats/stats.py (импорт, не правится).
Счётчики вершин — ln(1+N) (ближе к гауссову шуму, полином лучше), рельеф — ln(м)."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "terrain_stats"))
import stats  # noqa: E402

N = 384
AREA_KM2 = (N * 0.1) ** 2


def coarsen(h, k):
    n = h.shape[0] // k * k
    return h[:n, :n].reshape(n // k, k, n // k, k).mean(axis=(1, 3))


def observables(z100):
    """z100: (384, 384) м. Возвращает dict name -> float (nan, если не определено)."""
    h = np.asarray(z100, float)
    o = {}
    P = stats.peaks(h, 100.0)
    for t in (30, 100, 300):
        o[f"lnN{t}"] = float(np.log1p((P["prom"] >= t).sum()))
    m = P["prom"] >= 30
    o["saddle_km"] = float(np.median(P["d_saddle"][m]) / 1000) if m.sum() >= 3 else float("nan")
    h4 = coarsen(h, 4)
    P4 = stats.peaks(h4, 400.0)
    for t in (100, 300):
        o[f"lnN{t}_c400"] = float(np.log1p((P4["prom"] >= t).sum()))
    o["ln_relief"] = float(np.log(h.max() - h.min() + 1.0))
    o["ln_lrelief2500"] = float(np.log(stats.local_relief(h, 100.0) + 1.0))
    s = stats.slope_stats(h, 100.0)
    o["slope_p50"], o["slope_p90"] = s["median"], s["p90"]
    s4 = stats.slope_stats(h4, 400.0)
    o["slope_p50_c400"], o["slope_p90_c400"] = s4["median"], s4["p90"]
    k, Pk, _, _ = stats.profile_psd(h, 100.0)
    b = stats.beta_bands(k, Pk, [(3000, 12000), (1000, 3000), (400, 1000)])
    o["beta_L"], o["beta_M"], o["beta_S"] = b["3000-12000"], b["1000-3000"], b["400-1000"]
    d = stats.drainage(h, 100.0, (1.0,))
    o["Dd_1km2"] = d["1.0"]["Dd_km_per_km2"]
    o["anisotropy"] = stats.orientation(h, 100.0)["anisotropy"]
    return o


NAMES = list(observables(np.random.default_rng(0).normal(size=(N, N)).cumsum(0).cumsum(1) * 0.01).keys())


def vec(o):
    return np.array([o[n] for n in NAMES], float)
