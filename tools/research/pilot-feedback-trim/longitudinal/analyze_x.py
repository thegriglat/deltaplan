"""Период, логарифмический декремент и размах колебаний V(t), θ(t) после X / отдачи штанги (trim_batch.gd --mode=xtest)."""
import json, math, sys
import numpy as np


def peaks(t, y, y_inf):
    """Экстремумы y - y_inf: (время, амплитуда со знаком)."""
    d = y - y_inf
    out = []
    for i in range(1, len(d) - 1):
        if (d[i] > d[i-1] and d[i] >= d[i+1]) or (d[i] < d[i-1] and d[i] <= d[i+1]):
            out.append((t[i], d[i]))
    # убрать мелкую рябь
    return [p for p in out if abs(p[1]) > 0.05 * max(abs(q[1]) for q in out)] if out else []


def analyze(series, t_r, col=1):
    s = np.array(series)
    t, y = s[:, 0], s[:, col]
    post = t >= t_r
    tp, yp = t[post] - t_r, y[post]
    y_inf = yp[tp > tp[-1] - 15].mean()  # среднее за последние 15 с
    y0 = y[(t > t_r - 1) & (t <= t_r)].mean()
    pk = peaks(tp, yp, y_inf)
    res = {"y_pre": float(y0), "y_inf": float(y_inf), "first_dev": float(np.max(np.abs(yp - y_inf))),
           "p2p_first10s": float(np.ptp(yp[tp < 10])), "p2p_last30s": float(np.ptp(yp[tp > tp[-1] - 30]))}
    # декремент по пикам одного знака
    for sign, name in ((1, "pos"), (-1, "neg")):
        q = [(a, b) for a, b in pk if b * sign > 0]
        if len(q) >= 3:
            T = np.mean(np.diff([a for a, _ in q]))
            amp = [abs(b) for _, b in q]
            dec = [math.log(amp[i] / amp[i+1]) for i in range(len(amp) - 1) if amp[i+1] > 0.02 * amp[0]]
            res[name] = {"T": float(T), "delta": float(np.mean(dec)) if dec else None, "n": len(q), "amp0": amp[0]}
    # период по всем экстремумам (T = 2·шаг) и δ по соседним полупериодам
    if len(pk) >= 4:
        res["T_all"] = float(2 * np.mean(np.diff([a for a, _ in pk])))
        amp = [abs(b) for _, b in pk]
        d2 = [math.log(amp[i] / amp[i+2]) for i in range(len(amp) - 2) if amp[i+2] > 0.02 * amp[0]]
        res["delta_all"] = float(np.mean(d2)) if d2 else None
        res["zeta"] = (res["delta_all"] / math.sqrt(4 * math.pi ** 2 + res["delta_all"] ** 2)) if d2 else None
    return res


if __name__ == "__main__":
    import gzip
    d = json.load(gzip.open(sys.argv[1], "rt") if sys.argv[1].endswith(".gz") else open(sys.argv[1]))
    out = {}
    for w, cases in d["wings"].items():
        out[w] = {}
        for c, v in cases.items():
            out[w][c] = {"V": analyze(v["series"], v["t_release"], 1), "theta": analyze(v["series"], v["t_release"], 2)}
    json.dump(out, open(sys.argv[2], "w"), indent=1)
    print(f"{'wing':20s}{'case':16s}{'Vpre':>6s}{'Vinf':>6s}{'dev1':>6s}{'p2p10':>6s}{'p2p_l30':>8s}{'T':>6s}{'delta':>7s}{'zeta':>6s}{'thpre':>6s}{'thinf':>6s}{'thp2p10':>8s}")
    for w, cs in out.items():
        for c, r in cs.items():
            v, th = r["V"], r["theta"]
            f = lambda x, n=2: "-" if x is None else f"{x:.{n}f}"
            print(f"{w:20s}{c:16s}{v['y_pre']:6.1f}{v['y_inf']:6.1f}{v['first_dev']:6.2f}{v['p2p_first10s']:6.2f}{v['p2p_last30s']:8.2f}{f(v.get('T_all'),1):>6s}{f(v.get('delta_all')):>7s}{f(v.get('zeta'),3):>6s}{th['y_pre']:6.1f}{th['y_inf']:6.1f}{th['p2p_first10s']:8.2f}")
