"""Набор метрик для сравнения рельефа с реальным (те же величины, что в run_stats.py)."""
import numpy as np
import stats

TH = (30, 100, 300)


def metrics(z100, z400):
    """z100: 384x384 (шаг 100 м), z400: 96x96 (шаг 400 м). Площадь 38,4 км -> пересчёт на 40x40 км умножением на (40/38.4)^2."""
    f = (40.0 / 38.4) ** 2
    out = {}
    P1 = stats.peaks(z100, 100.0); P4 = stats.peaks(z400, 400.0)
    out["peaks100"] = {t: round(float((P1["prom"] >= t).sum() * f), 1) for t in TH}
    out["peaks400"] = {t: round(float((P4["prom"] >= t).sum() * f), 1) for t in TH}
    out["b30_300_400"] = stats.ccdf_exponent(P4["prom"], 30, 300)
    out["slope100"] = stats.slope_stats(z100, 100.0); out["slope400"] = stats.slope_stats(z400, 400.0)
    out["hyps"] = stats.hypsometric(z100); out["lrelief"] = stats.local_relief(z100, 100.0)
    out["orient"] = stats.orientation(z100, 100.0)
    k, P, _, _ = stats.profile_psd(z100, 100.0)
    out["beta"] = stats.beta_bands(k, P, [(10000, 38400), (3000, 10000), (1000, 3000), (400, 1000)])
    out["drain"] = stats.drainage(z100, 100.0)
    out["crit400"] = stats.critical_counts(z400)
    return out


def row(m):
    return [m["hyps"]["relief"], m["hyps"]["std"], m["hyps"]["HI"], m["lrelief"], m["slope100"]["mean"], m["slope100"]["p99"],
            m["slope400"]["mean"], m["peaks100"][30], m["peaks100"][100], m["peaks400"][30], m["peaks400"][100], m["peaks400"][300],
            m["drain"]["1.0"]["Dd_km_per_km2"], m["beta"]["3000-10000"], m["beta"]["1000-3000"], m["orient"]["anisotropy"]]


HEAD = ["relief", "std", "HI", "lrel5km", "slope100", "p99_100", "slope400", "pk100>=30", "pk100>=100", "pk400>=30", "pk400>=100",
        "pk400>=300", "Dd1", "β3-10km", "β1-3km", "aniso"]
