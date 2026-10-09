#!/usr/bin/env python3
"""Замер surface-heat.
  compare.py <папка A> <папка B>   — таблица markdown «A → B» по месту×часу (ключевые числа SH5)
  compare.py --summary <папка>     — собрать summary.csv из <место>_h<час>.json
Метки — имена папок out/<метка>. Поля, которых нет в одной из сторон, печатаются как «—»."""
import csv
import json
import sys
from pathlib import Path


def load(p):
    out = {}
    for f in sorted(Path(p).glob("*_h*.json")):
        d = json.loads(f.read_text())
        out[(d["location"], d["hour"])] = d
    return out


def g(d, *path):
    for k in path:
        if d is None:
            return None
        if isinstance(d, list):
            return None
        d = d.get(k)
    return d


def flat(d):
    """Ключевые числа одной строкой (колонки summary.csv и таблицы)."""
    cls = d.get("h_by_class") or {}
    r = {
        "location": d["location"], "hour": d["hour"], "commit": d.get("commit"),
        "h_mean": g(d, "h_wm2", "mean"), "h_p10": g(d, "h_wm2", "p10"),
        "h_p50": g(d, "h_wm2", "p50"), "h_p90": g(d, "h_wm2", "p90"),
        "src_n": g(d, "sources", "n"), "src_density_km2": g(d, "sources", "density_km2"),
        "src_w0_mean": g(d, "sources", "strength_ms", "mean"),
        "src_w0_p10": g(d, "sources", "strength_ms", "p10"),
        "src_w0_p90": g(d, "sources", "strength_ms", "p90"),
        "ceil_p10": g(d, "ceiling_agl_m", "p10"), "ceil_p50": g(d, "ceiling_agl_m", "p50"),
        "ceil_p90": g(d, "ceiling_agl_m", "p90"),
        "water_frac": g(d, "water", "area_frac"), "water_h": g(d, "water", "h_mean_wm2"),
        "water_t": g(d, "water", "t_water_c"), "t_air": g(d, "water", "t_air_c"),
    }
    for c in ("forest", "grass", "crop", "shrub", "bare", "water", "built", "snow", "none"):
        r[f"h_{c}"] = g(cls, c, "mean")
        r[f"frac_{c}"] = g(cls, c, "area_frac")
    sl = [e["w_ms"] for e in d.get("slope_lift") or [] if e.get("windward") is not False and e.get("w_ms") is not None]
    r["slope_w_mean"] = round(sum(sl) / len(sl), 3) if sl else None
    r["slope_w_max"] = max(sl) if sl else None
    lee = [e for e in d.get("lee") or [] if "w_min_ms" in e]
    r["lee_w_min"] = min((e["w_min_ms"] for e in lee), default=None)
    r["lee_sigma_w"] = max((e["sigma_w_ms"] for e in lee), default=None)
    r["wall_s"] = d.get("wall_s")
    return r


def summary(p):
    rows = [flat(d) for _, d in sorted(load(p).items())]
    if not rows:
        print("нет данных в", p)
        return 1
    with (Path(p) / "summary.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"summary.csv: {len(rows)} строк")
    return 0


def fmt(x):
    if x is None:
        return "—"
    return f"{x:g}" if isinstance(x, (int, float)) else str(x)


def cell(a, b):
    if a == b:
        return fmt(a)
    return f"{fmt(a)} → {fmt(b)}"


KEYS = [
    ("h_mean", "H ср., Вт/м²"), ("h_p10", "H p10"), ("h_p90", "H p90"),
    ("h_forest", "H лес"), ("h_grass", "H луг"), ("h_bare", "H голое"),
    ("src_n", "источников"), ("src_density_km2", "плотн., /км²"), ("src_w0_mean", "w0 ср., м/с"),
    ("ceil_p50", "потолок p50, м"), ("slope_w_mean", "w склон, м/с"),
    ("lee_w_min", "w мин. подветр., м/с"), ("lee_sigma_w", "σ_w подветр., м/с"),
    ("water_frac", "вода, доля"), ("water_h", "H вода"),
]


def compare(a, b):
    A = {k: flat(d) for k, d in load(a).items()}
    B = {k: flat(d) for k, d in load(b).items()}
    print(f"Сравнение: {Path(a).name} → {Path(b).name}\n")
    print("| место | час | " + " | ".join(n for _, n in KEYS) + " |")
    print("|---|---|" + "---|" * len(KEYS))
    for key in sorted(set(A) | set(B)):
        ra, rb = A.get(key, {}), B.get(key, {})
        print(f"| {key[0]} | {fmt(key[1])} | " + " | ".join(cell(ra.get(k), rb.get(k)) for k, _ in KEYS) + " |")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--summary":
        sys.exit(summary(sys.argv[2]))
    if len(sys.argv) == 3:
        sys.exit(compare(*sys.argv[1:]))
    print(__doc__)
    sys.exit(2)
