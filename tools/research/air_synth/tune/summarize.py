"""Сводка облака: квантили θ по группам, корреляции, таблица χ², ручные наборы -> out/cloud_report.md. Запуск: ../corpus/.venv/bin/python summarize.py"""
import json, os
import numpy as np
from scipy.stats import spearmanr
HERE = os.path.dirname(os.path.abspath(__file__)); OUT = os.path.join(HERE, "out")
C = json.load(open(f"{OUT}/theta_cloud.json")); M = json.load(open(f"{OUT}/theta_cloud_meta.json")); S = json.load(open(f"{OUT}/tune_summary.json"))
P = np.array(C["points"]); names = C["names"]
L = []
grp = {}
for i, (k, pl) in enumerate(zip(M["kind"], M["place"])):
    grp.setdefault("pool (все)" if k == "pool" else "game: " + pl, []).append(i)
    if k == "pool":
        grp.setdefault("pool: " + pl, []).append(i)
L.append("## Облако θ: медианы [p10–p90] по группам\n")
L.append("| группа | n | " + " | ".join(names) + " |"); L.append("|---|---|" + "---|" * len(names))
for g, ix in sorted(grp.items()):
    if len(ix) < 8 and not g.startswith("game"):
        continue
    q = np.percentile(P[ix], [10, 50, 90], axis=0)
    L.append(f"| {g} | {len(ix)} | " + " | ".join(f"{q[1,j]:.3g} [{q[0,j]:.2g}–{q[2,j]:.2g}]" for j in range(len(names))) + " |")
L.append("\n## Доля квадратов с параметром на границе TUNABLE\n")
L.append(", ".join(f"{n}: {v:.2f}" for n, v in S["frac_at_bound_per_param"].items()))
L.append("\n## Ранговые корреляции θ по облаку (Спирмен, T постоянно — исключено)\n")
ok = [j for j in range(len(names)) if np.ptp(P[:, j]) > 0]
R = spearmanr(P[:, ok]).statistic
L.append("| | " + " | ".join(names[j] for j in ok) + " |"); L.append("|---|" + "---|" * len(ok))
for a, ja in enumerate(ok):
    L.append(f"| {names[ja]} | " + " | ".join(f"{R[a,b]:+.2f}" for b in range(len(ok))) + " |")
L.append("\n## χ² по наблюдаемым (средний вклад на квадрат, ≈1 — в пределах σ; смещение — (генератор − эталон)/σ)\n")
L.append("| наблюдаемая | σ | σ_ген | σ_LOO | χ² | смещение | вне диапазона |"); L.append("|---|---|---|---|---|---|---|")
for n in S["names"]:
    L.append(f"| {n} | {S['sigma'][n]:.3g} | {S['sigma_gen'][n]:.3g} | {S['loo_rms'][n]:.3g} | {S['chi2_per_observable'][n]:.2f} | {S['mean_signed_residual'][n]:+.2f} | {S['frac_squares_out_of_range'][n]:.2f} |")
L.append(f"\nМедиана χ²/ndf по квадратам: {S['chi2_ndf_median']:.2f}; недостижимые: {', '.join(S['unreachable_observables'])}.")
L.append("\n## Eigentunes (σ параметров в u ∈ [-1,1] и главные направления), группа pool:ALL и game_far:ALL\n")
for g in ("pool:ALL", "game_far:ALL"):
    e = S["eigentunes"][g]
    L.append(f"**{g}**: χ²/ndf = {e['chi2']:.1f}/{e['ndf']}; σ_u = " + ", ".join(f"{n} {s:.2f}" for n, s in zip(S["tunable"], e["sigma_u"])) +
             "; λ = " + ", ".join(f"{x:.3g}" for x in e["eigenvalues"]) + "; главная ось: " + ", ".join(f"{n} {v:+.2f}" for n, v in zip(S["tunable"], e["eigenvectors"][0])))
if os.path.exists(f"{OUT}/manual_vs_tuned.json"):
    Mv = json.load(open(f"{OUT}/manual_vs_tuned.json"))
    L.append("\n## Ручные наборы и настроенные θ: средний χ² на наблюдаемую по квадратам места\n")
    L.append("| место / набор | χ² на наблюдаемую |"); L.append("|---|---|")
    for k, v in Mv.items():
        L.append(f"| {k} | {v['chi2_per_obs_mean']:.2f} |")
open(f"{OUT}/cloud_report.md", "w").write("\n".join(L) + "\n")
