"""Затухание фугоиды «Маятника» при удержании хода (out/long_*.json): огибающая γ − γ̄ по экстремумам.
Запуск: python phugoid_long.py → out/phugoid_long.json, таблица в stdout."""
import json, pathlib, sys
import numpy as np
HERE = pathlib.Path(__file__).resolve().parent

def env(ser, t0=6.0):
    a = np.array(ser)
    a = a[a[:, 0] > t0]
    t, g = a[:, 0], a[:, 2]
    tail = a[a[:, 0] > t[-1] - 60]
    geq = tail[:, 2].mean()
    x = g - geq
    ext = [i for i in range(1, len(x) - 1) if (x[i] - x[i - 1]) * (x[i + 1] - x[i]) < 0 and abs(x[i]) > 0.05]
    # чередование знаков: из подряд одного знака берём больший
    ee = []
    for i in ext:
        if ee and np.sign(x[i]) == np.sign(x[ee[-1]]):
            if abs(x[i]) > abs(x[ee[-1]]):
                ee[-1] = i
        else:
            ee.append(i)
    amp = [abs(x[i]) for i in ee]
    T = 2 * float(np.mean(np.diff(t[ee]))) if len(ee) > 2 else None
    r = [amp[i + 2] / amp[i] for i in range(len(amp) - 2)]
    def amp_at(tt):
        w = (t > tt - 10) & (t < tt + 10)
        return float((x[w].max() - x[w].min()) / 2) if w.any() else None
    return {"gamma_eq": float(geq), "T_s": T, "ratio_per_period_first4": [round(v, 3) for v in r[:4]],
            "ratio_median": float(np.median(r)) if r else None,
            "amp_deg_at": {str(tt): amp_at(tt) for tt in (20, 60, 120, 200, 290)},
            "alpha_range_tail": [float(tail[:, 3].min()), float(tail[:, 3].max())],
            "bar_max_tail": float(tail[:, 5].max()), "n_range_tail": [float(tail[:, 6].min()), float(tail[:, 6].max())]}

res = {}
for f in sorted((HERE / "out").glob("long_*.json")):
    d = json.loads(f.read_text())
    res[f.stem] = {w: {p: env(v["series"]) for p, v in ps.items()} for w, ps in d["wings"].items()}
(HERE / "out" / "phugoid_long.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
print("| вариант | крыло | ход | γ̄, ° | T, с | ×за период (медиана) | амплитуда γ на 20/60/120/290 с, ° | α хвост, ° | штанга max, Н | n хвост |")
print("|---|---|---|---|---|---|---|---|---|---|")
for k, ws in res.items():
    for w, ps in ws.items():
        for p, e in ps.items():
            a = e["amp_deg_at"]
            print(f"| {k[5:]} | {w} | {p} | {e['gamma_eq']:.1f} | {e['T_s'] or 0:.2f} | {e['ratio_median'] or 0:.2f} | "
                  f"{a['20']:.1f} / {a['60']:.1f} / {a['120']:.1f} / {a['290']:.2f} | {e['alpha_range_tail'][0]:.1f}…{e['alpha_range_tail'][1]:.1f} | "
                  f"{e['bar_max_tail']:.0f} | {e['n_range_tail'][0]:.2f}…{e['n_range_tail'][1]:.2f} |")
