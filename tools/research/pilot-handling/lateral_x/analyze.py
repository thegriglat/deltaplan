"""PHD-2: разбор game_*.json (lateral_batch.gd): метрики раскачки после X и моды (Прони) → out/game_metrics.json + таблица md.
  python3 analyze.py   (numpy)"""
import json, math, sys
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
COLS = ["t", "phi", "beta", "p", "r", "psidot", "relx", "rely", "relz", "shx", "u_roll", "u_pitch", "V", "theta"]


def prony(t, x, order=8, wmin=0.2, wmax=4.0):
    dt = t[1] - t[0]
    n = len(x)
    A = np.stack([x[order - k - 1:n - k - 1] for k in range(order)], 1)
    a, *_ = np.linalg.lstsq(A, x[order:], rcond=None)
    z = np.roots(np.concatenate([[1.0], -a]))
    lam = np.log(z.astype(complex)) / dt
    V = np.stack([z ** k for k in range(n)], 0)
    res, *_ = np.linalg.lstsq(V, x.astype(complex), rcond=None)
    out = []
    for l_, r_ in zip(lam, res):
        if l_.imag > 0 and wmin <= l_.imag <= wmax:
            wn = abs(l_)
            out.append({"omega": float(wn), "zeta": float(-l_.real / wn), "amp": float(2 * abs(r_))})
    return sorted(out, key=lambda q: -q["amp"])


def metrics(key, run):
    a = np.array(run["series"])
    d = {c: a[:, i] for i, c in enumerate(COLS)}
    t = d["t"]
    pre = t < 0
    m = t >= 0
    ref = {k: float(np.mean(d[k][pre & (t > -1.5)])) for k in ("phi", "beta", "relx", "r")}
    strap = np.degrees(np.arctan2(d["relx"], np.abs(d["rely"])))
    ref["strap"] = float(np.mean(strap[pre & (t > -1.5)]))
    phi, beta = d["phi"][m], d["beta"][m]
    tm = t[m]
    o = {"key": key, "phi0": ref["phi"], "beta0": ref["beta"], "strap0": ref["strap"], "u0": run["u0"], "nan": run["nan"]}
    # конечное положение (последние 5 с)
    fin = tm > tm[-1] - 5
    o["phi_end"] = float(phi[fin].mean()); o["phi_end_std"] = float(phi[fin].std())
    o["beta_end"] = float(beta[fin].mean())
    o["phi_max_abs"] = float(np.abs(phi).max()); o["beta_max_abs_post"] = float(np.abs(beta - ref["beta"]).max())
    o["r_max_abs"] = float(np.abs(d["r"][m]).max())
    # переброс φ через 0 относительно финала
    s0 = np.sign(ref["phi"]) or 1.0
    pk = float((-s0 * (phi - o["phi_end"])).max())  # наибольшее отклонение от финала в сторону, противоположную начальному
    o["phi_overshoot_deg"] = max(pk, 0.0) if abs(ref["phi"]) > 1 else float(np.abs(phi - o["phi_end"])[tm > 2].max() if (tm > 2).any() else 0)
    idx = np.where(np.abs(phi - o["phi_end"]) < 2.0)[0]
    # время до |φ − φ_конечное| < 2° навсегда
    bad = np.where(np.abs(phi - o["phi_end"]) >= 2.0)[0]
    o["t_settle_2deg"] = float(tm[bad[-1] + 1]) if len(bad) and bad[-1] + 1 < len(tm) else (0.0 if not len(bad) else float("nan"))
    # колебательность: число смен знака производной φ после 1 с с размахом > 0,5°
    # Прони по φ, β и стропе, окно 0,5–20 с
    w = (tm >= 0.5) & (tm <= 20.0)
    modes = {}
    for nm, x in (("phi", phi), ("beta", beta), ("strap", strap[m]), ("r", d["r"][m])):
        xx = x[w]
        xx = xx - np.mean(x[fin])
        modes[nm] = prony(tm[w], xx)[:3]
    o["prony"] = modes
    # быстрые моды отдельно от спирали: вычесть полином 3-й степени (0,5–20 с), потом Прони и размах
    fast = {}
    wd = (tm >= 0.5) & (tm <= 20.0)
    for nm, x, wmax in (("beta", beta, 4.0), ("r", d["r"][m], 4.0), ("phi", phi, 4.0), ("strap", strap[m], 9.0), ("p", d["p"][m], 9.0), ("V", d["V"][m], 4.0), ("theta", d["theta"][m], 4.0)):
        xx = x[wd]
        tt = tm[wd]
        c = np.polyfit(tt - tt.mean(), xx, 3)
        res = xx - np.polyval(c, tt - tt.mean())
        pr = prony(tt, res, order=10, wmin=0.3, wmax=wmax)
        q = [e for e in pr if e["amp"] > 0.05 * max(res.std() * 1.4, 1e-9)]
        fast[nm] = {"rms": float(res.std()), "pp_after2": float(np.ptp(res[tt > 2.0])) if (tt > 2.0).any() else 0.0,
                    "peak_after2": float(np.abs(res[tt > 2.0]).max()) if (tt > 2.0).any() else 0.0,
                    "poles": pr[:3]}
    o["fast"] = fast
    # размах качания стропы пилота после 1 с
    o["strap_swing_pp"] = float(np.ptp(strap[m][tm > 1.0]) if (tm > 1.0).any() else 0)
    o["strap_swing_max_dev"] = float(np.abs(strap[m][tm > 1.0] - np.mean(strap[m][fin])).max())
    # огибающая бета после 3 с и после 10 с
    for T in (3, 6, 10):
        mm = tm > T
        o[f"beta_dev_after{T}"] = float(np.abs(beta[mm] - np.mean(beta[fin])).max())
        o[f"r_after{T}"] = float(np.abs(d["r"][m][mm]).max())
    return o


def main():
    rows = []
    for f in sorted(OUT.glob("game_*.json")):
        if f.name == "game_metrics.json":
            continue
        for k, r in json.load(open(f))["runs"].items():
            rows.append(metrics(k, r))
    (OUT / "game_metrics.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False))
    if len(sys.argv) > 1 and sys.argv[1] == "fast":
        print("| крыло | сост. | сцен. | β быстрая: ампл.>2с ° | ГШ(r) ω/ζ (ампл.) | r быстр. ампл.>2с °/с | φ быстр. ампл. ° | строп. быстр. ампл. ° | КП(строп.) ω/ζ | p быстр. >2с °/с | фугоида V ω/ζ (ампл. м/с) | θ ω/ζ (ампл. °) |")
        print("|" + "---|" * 12)
        for o in rows:
            w, s_, sc = o["key"].split("|")
            F = o["fast"]
            g = lambda n: (f"{F[n]['poles'][0]['omega']:.2f}/{F[n]['poles'][0]['zeta']:.2f} ({F[n]['poles'][0]['amp']:.2f})" if F[n]["poles"] else "—")
            print(f"| {w} | {s_} | {sc} | {F['beta']['peak_after2']:.2f} | {g('r')} | {F['r']['peak_after2']:.2f} | {F['phi']['peak_after2']:.2f} | {F['strap']['peak_after2']:.2f} | {g('strap')} | {F['p']['peak_after2']:.2f} | {g('V')} | {g('theta')} |")
        return
    print("| крыло | сост. | сцен. | u0 | φ0 | φ_кон | переброс φ° | t_2° с | β0 | β макс откл | β>3с | r>3с °/с | строп. кач. | ГШ ω/ζ (β) | КП ω/ζ (строп.) |")
    print("|" + "---|" * 15)
    for o in rows:
        w, s, sc = o["key"].split("|")
        pb = o["prony"]["beta"]; ps = o["prony"]["strap"]
        f = lambda L_: f"{L_[0]['omega']:.2f}/{L_[0]['zeta']:.2f}" if L_ else "—"
        print(f"| {w} | {s} | {sc} | {o['u0']:+.2f} | {o['phi0']:.1f} | {o['phi_end']:.1f} | {o['phi_overshoot_deg']:.1f} | {o['t_settle_2deg']:.1f} | {o['beta0']:.1f} | {o['beta_max_abs_post']:.1f} | {o['beta_dev_after3']:.2f} | {o['r_after3']:.2f} | {o['strap_swing_max_dev']:.2f} | {f(pb)} | {f(ps)} |")


main()
