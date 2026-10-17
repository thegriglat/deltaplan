"""Фугоида после ступеньки хода: игра (out/longstep_*.json) против точечной массы с постоянным CL,
равным установившемуся CL игры на этом ходу (тот же старт — трим). Огибающая |γ − γ̄| по полупериодам.
Запуск: python phugoid_step.py → out/phugoid_step.json + таблица."""
import json, math, pathlib
import numpy as np
from analyze import Polar, simulate, wing_cfg, RHO, G
HERE = pathlib.Path(__file__).resolve().parent

def half_amps(t, g, geq, t0=0.0):
    x = g - geq
    m = t > t0
    t, x = t[m], x[m]
    ee = []
    for i in range(1, len(x) - 1):
        if (x[i] - x[i - 1]) * (x[i + 1] - x[i]) < 0:
            if ee and np.sign(x[i]) == np.sign(x[ee[-1]]):
                if abs(x[i]) > abs(x[ee[-1]]): ee[-1] = i
            else:
                ee.append(i)
    ee = [i for i in ee if abs(x[i]) > 0.3]
    return [(round(float(t[i]), 2), round(float(x[i]), 2)) for i in ee]

out = {}
rows = []
for f in sorted((HERE / "out").glob("longstep_*.json")):
    d = json.loads(f.read_text())
    var = f.stem[9:]
    for w, ps in d["wings"].items():
        pol = Polar(wing_cfg(w))
        for p, v in ps.items():
            a = np.array(v["series"])
            t, g, al, V = a[:, 0], a[:, 2], a[:, 3], a[:, 4] / 3.6
            tail = a[t > t[-1] - 30]
            geq = tail[:, 2].mean()
            Ve = tail[:, 4].mean() / 3.6
            cl_e = 2 * pol.m * G * math.cos(math.radians(geq)) / (RHO * pol.S * Ve * Ve)
            pm = simulate(pol, lambda _t: cl_e, V[0], math.radians(g[0]), T=t[-1], dt=0.01)
            _, g_pm_eq = pol.steady(cl_e)
            hg = half_amps(t, g, geq)
            hp = half_amps(pm[:, 0], np.degrees(pm[:, 2]), math.degrees(g_pm_eq))
            def per_period(h):
                return [round(abs(h[i + 2][1] / h[i][1]), 3) for i in range(min(len(h) - 2, 6))]
            out.setdefault(var, {}).setdefault(w, {})[p] = {
                "game_half": hg[:10], "pm_half": hp[:10], "game_ratio": per_period(hg), "pm_ratio": per_period(hp),
                "CL_eq": cl_e, "alpha_range": [float(al.min()), float(al.max())],
                "bar_max": float(a[:, 5].max()), "n_range": [float(a[:, 6].min()), float(a[:, 6].max())]}
            o = out[var][w][p]
            rows.append(f"| {var} | {w} | {p} | {', '.join(f'{x[1]:+.1f}' for x in hg[:5])} | "
                        f"{', '.join(f'{x[1]:+.1f}' for x in hp[:5])} | {', '.join(map(str, o['game_ratio'][:3]))} | "
                        f"{', '.join(map(str, o['pm_ratio'][:3]))} | {o['alpha_range'][0]:.1f}…{o['alpha_range'][1]:.1f} | {o['bar_max']:.0f} |")
(HERE / "out" / "phugoid_step.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
print("| руки | крыло | ход | γ − γ̄ игры по полупериодам, ° | точечная масса, ° | игра ×за период | т. масса ×за период | α игры, ° | штанга max, Н |")
print("|---|---|---|---|---|---|---|---|---|")
print("\n".join(rows))
