#!/usr/bin/env python3
"""TB-13: радиус пузырей 2000 м — дальнее поле шаблона, потребители, цена; сборка out/round3_radius.json.

Запуск (после Rust-теста, его вывод — в лог):
  cargo test --manifest-path rust/Cargo.toml -p dp-air --release --test thermal_bubble_radius -- --nocapture > /tmp/radius.log
  tools/research/thermal_bubble/py tools/research/thermal_bubble/round3/radius.py /tmp/radius.log
Лог даёт строки `RADJSON {...}` (шов, цена); Python добавляет дальнее поле шаблона (bubble.py, только чтение),
время сближения, потребителей и рекомендацию. Рисунки — round3/radius_*.png.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
sys.path.insert(0, str(PKG))
import bubble as bb  # noqa: E402  (только чтение)

OUT = PKG / "out" / "round3_radius.json"
WSTAR, ZL = 2.56, 1400.0          # медианы docs/research/calibration_data/thermals.md
W0 = 1.2436 * WSTAR               # сила термика игры (K_ALLEN w*)
TAU = 690.0                       # время работы источника (допущение шаблона)
ENV = bb.Env(wind=(0.0, 0.0), zi=ZL)
N_A = 8.5 / ZL**2                 # плотность ядер Аллена, 1/м²


def far_field():
    """Максимум по жизни |u_ρ| и |w| на высотах потребителей как функция ρ (термик без ветра, ось вертикальна)."""
    src = bb.from_strength(0.0, 0.0, 0.0, W0, ZL, TAU, ENV)
    ts = np.arange(30.0, 3000.0, 30.0)
    states = [(t, bb.state(src, ENV, t)) for t in ts]
    states = [(t, s) for t, s in states if s is not None]
    rho = np.unique(np.concatenate([np.linspace(0, 300, 61), np.linspace(300, 3000, 109)]))
    heights = {"ground_12m": 12.0, "hub_80m": 80.0, "mid_300m": 300.0}
    res = {}
    per_t = {}
    for name, z in heights.items():
        ur_max = np.zeros_like(rho)
        w_max = np.zeros_like(rho)
        rows = []
        for t, s in states:
            P = np.zeros((rho.size, 3))
            P[:, 0] = s.xc + rho
            P[:, 1] = s.yc
            P[:, 2] = z
            v = bb.velocity(P, [s], ENV)
            ur_max = np.maximum(ur_max, np.abs(v[:, 0]))
            w_max = np.maximum(w_max, np.abs(v[:, 2]))
            rows.append(np.abs(v[:, 0]))
        res[name] = (ur_max, w_max)
        per_t[name] = np.array(rows)
    return src, ts[: len(states)], rho, res, per_t


def rho_at(rho, arr, thr):
    """Наибольшее ρ, где arr ≥ thr (0, если нигде)."""
    idx = np.nonzero(arr >= thr)[0]
    return float(rho[idx[-1]]) if idx.size else 0.0


def main():
    log = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    rows = []
    if log and log.exists():
        for line in log.read_text().splitlines():
            if line.startswith("RADJSON "):
                rows.append(json.loads(line[8:]))
    seam_cases = [r for r in rows if r["kind"] == "seam"]
    seam_all = next((r for r in rows if r["kind"] == "seam_all"), None)
    foci = [r for r in rows if r["kind"] == "foci"]
    costs = sorted((r for r in rows if r["kind"] == "cost"), key=lambda r: r["radius_m"])

    src, ts, rho, res, per_t = far_field()
    thr = [0.1, 0.3, 0.5, 1.0]
    far = {}
    for name, (ur, w) in res.items():
        far[name] = {
            "u_rho_peak_ms": float(ur.max()),
            "w_peak_ms": float(w.max()),
            "rho_u_ge_m": {str(t): rho_at(rho, ur, t) for t in thr},
            "rho_w_ge_m": {str(t): rho_at(rho, w, t) for t in thr},
        }
    # доля площади, где |u_ρ| на 12 м ≥ порога, в мгновенной картине: n_A π ρ_thr(t)² усреднено по стадиям жизни
    area = {}
    for t_thr in (0.3, 1.0):
        rho_t = np.array([rho_at(rho, row, t_thr) for row in per_t["ground_12m"]])
        area[str(t_thr)] = float(min(1.0, N_A * math.pi * np.mean(rho_t**2)))
    # дальний край поля u_ρ (0,1 м/с): как далеко от оси шаблон даёт горизонталь
    reach_u = far["ground_12m"]["rho_u_ge_m"]["0.1"]
    reach_w = max(far[h]["rho_w_ge_m"]["0.1"] for h in far)

    # сближение: расстояние от границы вклада до пилота в момент смены режима
    d_seam = seam_all["dist_to_difference_min_m"] if seam_all else float("nan")
    closing = {f"{v:.0f}_ms": d_seam / v for v in (15.0, 25.0, 40.0)}

    # потребители воздуха дальше bubble_radius_m от любого фокуса (configs/*, scripts/*; см. radius.md §3)
    h = far
    far_consumers = [
        {"name": "windsock (мачта посадки, ветроуказатель)", "range_m": 3000, "queries": "mean_wind_at на высоте ~10 м",
         "wants": "горизонталь", "bubble_effect_ms": h["ground_12m"]["u_rho_peak_ms"],
         "note": "рукав поднимается с 4 км/ч (1,1 м/с); приток ≥ 1 м/с только на ρ ≤ %.0f м от оси" % h["ground_12m"]["rho_u_ge_m"]["1.0"],
         "verdict": "не видно: профиль не даёт u_h, шаблон даёт ≤ порога на доле площади %.1f %%" % (100 * area["1.0"])},
        {"name": "ветряки OSM", "range_m": 8000, "queries": "air_fn на высоте ступицы 80 м, ≤ 24 опросов за 0,5 с",
         "wants": "горизонталь (скорость, курс)", "bubble_effect_ms": h["hub_80m"]["u_rho_peak_ms"],
         "note": "cut-in 3 м/с, номинал 12 м/с; приток на 80 м ≥ 0,3 м/с на ρ ≤ %.0f м" % h["hub_80m"]["rho_u_ge_m"]["0.3"],
         "verdict": "поправка к скорости ≤ %.2f м/с на доле площади — ниже порога видимости ротора" % h["hub_80m"]["u_rho_peak_ms"]},
        {"name": "дым труб OSM / костры", "range_m": 5000, "queries": "air_fn у устья (0…12 м), кластер 250 м",
         "wants": "горизонталь (снос шлейфа, wind_damp 0,05…0,1)", "bubble_effect_ms": h["ground_12m"]["u_rho_peak_ms"],
         "note": "wind_damp гасит ×0,05…0,1 порыв; приток вблизи термика ≤ %.2f м/с" % h["ground_12m"]["u_rho_peak_ms"],
         "verdict": "не видно"},
        {"name": "трава, деревья, снежный шлейф у камеры", "range_m": 0, "queries": "mean_wind_at/air_fn у камеры пилота",
         "wants": "горизонталь", "bubble_effect_ms": h["ground_12m"]["u_rho_peak_ms"],
         "note": "у камеры; камера = фокус (режим осмотра двигает фокус вместе с камерой)",
         "verdict": "внутри 2000 м, шов не виден"},
        {"name": "признаки термиков (ласточки, пух)", "range_m": 400, "queries": "ядра cores() и sample_many над источником ядра",
         "wants": "w у источника для пуха (дальность 0,12 м / 0,3 мрад = 400 м)", "bubble_effect_ms": 0.0,
         "note": "ласточки 1133 м; радиус ядер 3000×1,2 = 3600 м только для списка ядер (не w); пух ≤ 400 м",
         "verdict": "внутри 2000 м; ядра идут от cores(), шаблон их не трогает"},
        {"name": "облака (cloud_density, suction)", "range_m": 20000, "queries": "снимки термиков snapshot_thermals (параметры, не w)",
         "wants": "положение, сила, стадия", "bubble_effect_ms": 0.0,
         "note": "формула облаков не вызывает ThermalField.sample; подсос под основанием (suck) — в профиле, не в шаблоне",
         "verdict": "радиус пузырей не влияет"},
        {"name": "боты и пилоты сети", "range_m": 0, "queries": "air_fn у себя; сами фокусы (вес 0,3/0,5, ≤ 16)",
         "wants": "полный воздух", "bubble_effect_ms": 0.0,
         "note": "каждый — свой фокус: радиус 2000 м у каждого; цена растёт с числом несвязных фокусов",
         "verdict": "внутри своего радиуса"},
    ]

    # цена
    cost = []
    for c in costs:
        cost.append({k: c[k] for k in ("radius_m", "thermals_active", "bubbles_alive", "warm_ms", "build_ms_per_s",
                                       "state_build_ms_per_s", "cache_tables", "cache_mb", "query_ns_per_point")})
    base = next((c for c in costs if c["radius_m"] == 0.0), None)
    c2 = next((c for c in costs if c["radius_m"] == 2000.0), None)
    c6 = next((c for c in costs if c["radius_m"] == 6000.0), None)

    recommendation = ""
    f4 = next((f for f in foci if f["radius_m"] == 2000.0 and f["foci"] == 4), None)
    if c2 and c6 and seam_all and f4:
        recommendation = (
            "Радиус 2000 м достаточен: шов пилоту не виден. Режим термика меняется, когда его вклад (w или uh) на "
            "расстоянии не менее %.0f м от фокуса (радиус вклада пузыря <= %.0f м), т.е. за %.0f с до границы вклада "
            "на 15 м/с и за %.0f с на 40 м/с; сам фокус в момент смены не чувствует разрыва (0,000 м/с). Увеличивать "
            "не нужно: 6000 м = %.0f мс/с, %.0f МБ, прогрев %.0f с против %.0f мс/с, %.0f МБ, %.0f с на 2000 м. Цену "
            "задаёт число несвязных фокусов (боты и пилоты сети): 4 фокуса на 2000 м = %.0f мс/с, %.0f МБ; при "
            "необходимости радиус можно снизить до 1000-1500 м (оценка зазора 1000 м: ~%.0f м до различия). "
            "Старый профиль целиком убрать нельзя: его формула нужна для маски фона (background_sink*(1-mask)), "
            "sigma края, облачного подсоса, статичных термиков и столбов ниже 100 м (там шаблона нет), а w профиля "
            "за 2000 м нужна дальнему дыму труб (2-5 км, подъём <= 2 м/с). Убрать можно флаг и w профиля динамических "
            "термиков внутри радиуса (уже так при флаге); профиль оставить лёгким слоем: маска, sigma, подсос, "
            "w вне радиуса."
            % (d_seam, seam_all["table_radius_max_m"], closing["15_ms"], closing["40_ms"],
               c6["build_ms_per_s"], c6["cache_mb"], c6["warm_ms"] / 1000,
               c2["build_ms_per_s"], c2["cache_mb"], c2["warm_ms"] / 1000,
               f4["build_ms_per_s"], f4["cache_mb"], d_seam - 1000.0)
        )

    out = {
        "schema": "tb13/1",
        "task": "TB-13",
        "case": {"w_star": WSTAR, "z_l": ZL, "w0": W0, "tau": TAU, "n_A_per_m2": N_A},
        "seam": {"cases": seam_cases, "all": seam_all, "closing_time_s": closing, "dist_to_difference_min_m": d_seam,
                 "table_reach_w_0p1_m": reach_w, "table_reach_u_0p1_ground_m": reach_u},
        "far_field": far,
        "area_fraction_u_ge": area,
        "far_consumers": far_consumers,
        "cost": cost,
        "foci": foci,
        "recommendation": recommendation,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    tmp.rename(OUT)
    print("wrote", OUT)

    # рисунки
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(1, 2, figsize=(10, 4))
    for name, (ur, w) in res.items():
        ax[0].semilogx(np.maximum(rho, 1), ur, label=name)
        ax[1].semilogx(np.maximum(rho, 1), w, label=name)
    for a, t in zip(ax, ("max |u_ρ| по жизни, м/с", "max |w| по жизни, м/с")):
        a.set_xlabel("ρ от оси, м"); a.set_ylabel(t); a.axhline(0.1, color="gray", lw=0.6); a.legend()
    fig.tight_layout(); fig.savefig(HERE / "radius_farfield.png", dpi=110); plt.close(fig)

    if costs:
        fig, ax = plt.subplots(1, 3, figsize=(12, 3.6))
        R = [c["radius_m"] for c in costs]
        ax[0].plot(R, [c["build_ms_per_s"] for c in costs], "o-"); ax[0].set_title("сборка, мс на 1 с игры")
        ax[1].plot(R, [c["cache_mb"] for c in costs], "o-"); ax[1].set_title("кеш таблиц, МБ")
        ax[2].plot(R, [c["bubbles_alive"] for c in costs], "o-"); ax[2].set_title("живых пузырей")
        for a in ax:
            a.set_xlabel("bubble_radius_m, м")
        fig.tight_layout(); fig.savefig(HERE / "radius_cost.png", dpi=110); plt.close(fig)


if __name__ == "__main__":
    main()
