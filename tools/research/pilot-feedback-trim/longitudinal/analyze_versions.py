"""Таблица по тегам: паспорт, solve_trim, нейтраль (мышь 0), руки отпущены, +2 см; запуск, X из «на себя» 0,3."""
import json, gzip, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from analyze_x import analyze
D = os.path.join(os.path.dirname(__file__), "out", "versions")
tags = ["v1.5.15", "v1.5.20", "v1.5.21", "v1.6.0", "v1.7.0"]
wings = ["sport", "moyes_litespeed_rx", "ww_t2c", "apogee", "training"]
def load(p):
    try:
        return json.load(gzip.open(p + ".gz", "rt"))["wings"]
    except Exception:
        return {}
print("A. Установившийся режим при вводе 0, плотность постоянная: V км/ч (θ°) ; масса пилота игры / эталонная")
print(f"{'wing':20s}{'tag':9s}{'pass':>6s}{'solve_g':>8s}{'neut_g':>8s}{'th_g':>6s}{'relax_g':>8s}{'sh+2_g':>8s}{'solve_r':>8s}{'neut_r':>8s}{'th_r':>6s}{'k/cm':>6s}")
for w in wings:
    for t in tags:
        g = load(f"{D}/{t}_steady_game.json").get(w); r = load(f"{D}/{t}_steady_ref.json").get(w)
        if not g or not r:
            print(f"{w:20s}{t:9s}  нет данных"); continue
        print(f"{w:20s}{t:9s}{g['trim_kmh']:6.1f}{g['solve_trim_kmh']:8.1f}{g['neutral']['V']:8.1f}{g['neutral']['theta']:6.1f}{g['relaxed']['V']:8.1f}{g['shift']['2']['V']:8.1f}{r['solve_trim_kmh']:8.1f}{r['neutral']['V']:8.1f}{r['neutral']['theta']:6.1f}{g['kmh_per_cm']:6.2f}")
print("\nB. После разбега (склон 12°/17°), pitch 0: Vmin, Vmax, θmax за 1–21 с; полуразмах V 1–11 с и 30–40 с")
print(f"{'wing':20s}{'tag':9s}{'slope':>6s}{'Vmin':>6s}{'Vmax':>6s}{'thmax':>6s}{'A1':>6s}{'A30':>6s}")
for w in wings:
    for t in tags:
        l = load(f"{D}/{t}_launch.json").get(w)
        if not l:
            print(f"{w:20s}{t:9s}  нет данных"); continue
        for s, rr in l.items():
            a = np.array(rr["series"]); tt = a[:, 0]; V = a[:, 1]
            print(f"{w:20s}{t:9s}{s:>6s}{rr['v_min_1_21']:6.1f}{rr['v_max_1_21']:6.1f}{rr['th_max_1_21']:6.1f}{np.ptp(V[(tt>1)&(tt<11)])/2:6.2f}{np.ptp(V[tt>30])/2:6.2f}")
print("\nC. X («на себя» 0,3 и вираж 30°): T, δ, ζ по V; размах V за 10 с; остаточный размах за последние 30 с")
print(f"{'wing':20s}{'tag':9s}{'case':14s}{'T':>5s}{'delta':>7s}{'zeta':>7s}{'p2p10':>7s}{'p2p_l30':>8s}")
for w in wings:
    for t in tags:
        x = load(f"{D}/{t}_x.json").get(w)
        if not x:
            print(f"{w:20s}{t:9s}  нет данных"); continue
        for c in ("q-0.3_X", "q0.3_X", "bank30_X"):
            if c not in x: continue
            v = analyze(x[c]["series"], x[c]["t_release"], 1)
            f = lambda k, n=2: "-" if v.get(k) is None else f"{v[k]:.{n}f}"
            print(f"{w:20s}{t:9s}{c:14s}{f('T_all',1):>5s}{f('delta_all'):>7s}{f('zeta',3):>7s}{v['p2p_first10s']:7.2f}{v['p2p_last30s']:8.2f}")
