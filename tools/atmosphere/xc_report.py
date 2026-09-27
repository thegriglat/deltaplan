#!/usr/bin/env python3
"""Свод матрицы xc_matrix.sh (карточка 02): медиана/квартили по сидам, доля успешных, коридор
по эталонам из docs/research/xc_reference.md.

    tools/atmosphere/xc_report.py [каталог_результатов=tmp_xc_matrix]

Эталоны (только средний/сильный день — см. xc_reference.md; weak без эталона):
"""
import glob
import json
import os
import re
import statistics
import sys
from collections import defaultdict

RESULT_DIR = sys.argv[1] if len(sys.argv) > 1 else "tmp_xc_matrix"

# метрика -> (weather -> (lo, hi)); None = эталона нет (только weak).
CORRIDORS = {
    "avg_climb_ms": {"medium": (1.0, 2.0), "strong": (2.0, 3.5)},
    "circling_fraction": {"medium": (0.40, 0.55), "strong": (0.30, 0.45)},
    "avg_speed_kmh": {"medium": (20.0, 30.0), "strong": (30.0, 45.0)},
    "thermals_per_10km": {"medium": (2.0, 4.0), "strong": (1.5, 3.0)},
    "frac_vario_ge_7": {"medium": (0.0, 0.01), "strong": (0.0, 0.02)},
}
METRICS = list(CORRIDORS.keys()) + ["glide_ratio_eff"]
METRIC_LABEL = {
    "avg_climb_ms": "набор в термике, м/с",
    "circling_fraction": "доля времени в кружении",
    "avg_speed_kmh": "маршрутная скорость, км/ч",
    "thermals_per_10km": "термиков/10 км",
    "frac_vario_ge_7": "доля времени вариометр ≥7 м/с",
    "glide_ratio_eff": "эффективное качество (справочно, эталона нет)",
}

FNAME_RE = re.compile(
    r"^(?P<loc>[a-z]+)_(?P<weather>weak|medium|strong)_wind(?P<wind>\d+)_seed(?P<seed>\d+)_(?P<clouds>clouds|noclouds)\.json$"
)


def load_runs(result_dir):
    runs = []
    for path in sorted(glob.glob(os.path.join(result_dir, "*.json"))):
        m = FNAME_RE.match(os.path.basename(path))
        if not m:
            continue
        with open(path) as f:
            try:
                d = json.load(f)
            except json.JSONDecodeError:
                print(f"! пропуск (битый json): {path}", file=sys.stderr)
                continue
        d.update(m.groupdict())
        d["clouds"] = d["clouds"] == "clouds"
        end_reason = d.get("end_reason")
        d["bad"] = end_reason in (None, "timeout", "error")  # прогон не долетел и не сел — исключаем из метрик
        dist = float(d.get("distance_km", 0.0))
        t = max(float(d.get("time_s", 0.0)), 1.0)
        d["success"] = (not d["bad"]) and dist >= 40.0
        d["thermals_per_10km"] = (d.get("thermals", 0) / dist * 10.0) if dist > 0 else 0.0
        d["frac_vario_ge_7"] = float(d.get("time_vario_ge_7_s", 0.0)) / t
        runs.append(d)
    return runs


def quartiles(values):
    if not values:
        return (float("nan"),) * 3
    vs = sorted(values)
    med = statistics.median(vs)
    if len(vs) >= 4:
        q1 = statistics.median(vs[: len(vs) // 2])
        q3 = statistics.median(vs[(len(vs) + 1) // 2 :])
    else:
        q1 = q3 = med
    return q1, med, q3


def corridor_mark(metric, weather, med):
    rng = CORRIDORS.get(metric, {}).get(weather)
    if rng is None:
        return "—" if weather == "weak" else "?"
    lo, hi = rng
    if med < lo:
        return "ниже"
    if med > hi:
        return "выше"
    return "в коридоре"


def fmt(x):
    return f"{x:.3f}" if abs(x) < 10 else f"{x:.1f}"


def main():
    runs = load_runs(RESULT_DIR)
    if not runs:
        print(f"Нет прогонов в {RESULT_DIR} (ожидались файлы вида loc_weather_windN_seedN_clouds.json)")
        return
    print(f"# Свод xc_matrix ({len(runs)} прогонов из {RESULT_DIR})\n")

    n_bad_total = sum(1 for r in runs if r["bad"])
    if n_bad_total:
        print(f"**{n_bad_total} прогон(а/ов) — timeout/error (не долетели и не сели), исключены из метрик ниже:**\n")
        for r in runs:
            if r["bad"]:
                print(f"- {r['loc']}_{r['weather']}_wind{r['wind']}_seed{r['seed']}"
                      f"_{'clouds' if r['clouds'] else 'noclouds'}: {r.get('end_reason')}")
        print()

    by_lw = defaultdict(list)
    for r in runs:
        if not r["bad"]:
            by_lw[(r["loc"], r["weather"])].append(r)

    weather_order = {"weak": 0, "medium": 1, "strong": 2}
    for (loc, weather) in sorted(by_lw, key=lambda k: (k[0], weather_order[k[1]])):
        group = by_lw[(loc, weather)]
        n = len(group)
        n_ok = sum(1 for r in group if r["success"])
        print(f"## {loc} × {weather}  (n={n}, успешных ≥40 км: {n_ok}/{n} = {n_ok/n:.0%})\n")
        print("| метрика | Q1 | медиана | Q3 | коридор |")
        print("|---|---|---|---|---|")
        for metric in METRICS:
            vals = [r[metric] for r in group]
            q1, med, q3 = quartiles(vals)
            mark = corridor_mark(metric, weather, med)
            print(f"| {METRIC_LABEL[metric]} | {fmt(q1)} | {fmt(med)} | {fmt(q3)} | {mark} |")
        print()

    # Диагностика: --clouds против без --clouds (итог 01: без --clouds бот находит термики хуже).
    print("## Диагностика: доля успешных, с `--clouds` и без\n")
    print("| локация | пресет | без clouds | с clouds |")
    print("|---|---|---|---|")
    by_lwc = defaultdict(list)
    for r in runs:
        if not r["bad"]:
            by_lwc[(r["loc"], r["weather"], r["clouds"])].append(r)
    for (loc, weather) in sorted({(r["loc"], r["weather"]) for r in runs}, key=lambda k: (k[0], weather_order[k[1]])):
        no_c = by_lwc.get((loc, weather, False), [])
        c = by_lwc.get((loc, weather, True), [])
        rate_no = sum(1 for r in no_c if r["success"]) / len(no_c) if no_c else float("nan")
        rate_c = sum(1 for r in c if r["success"]) / len(c) if c else float("nan")
        print(f"| {loc} | {weather} | {rate_no:.0%} | {rate_c:.0%} |")
    print()

    print("Список «что выбивается» (коридор 'ниже'/'выше') — см. итоговую таблицу выше; вход для 03.")


if __name__ == "__main__":
    main()
