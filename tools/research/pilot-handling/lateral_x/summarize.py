"""PHD-2: сводка по game_metrics.json → out/summary_modes.json и печать (моды, спираль, доля голландского шага после X)."""
import json, math
from pathlib import Path
import numpy as np
OUT = Path(__file__).resolve().parent / "out"
M = {o["key"]: o for o in json.load(open(OUT / "game_metrics.json"))}
COLS = ["t", "phi", "beta", "p", "r", "psidot", "relx", "rely", "relz", "shx", "u_roll", "u_pitch", "V", "theta"]
W = ["training", "laminar", "sport", "icaro_mastr"]
raw = {}
for w in W:
    raw.update({k: v for k, v in json.load(open(OUT / f"game_{w}.json"))["runs"].items()})


def ser(k):
    a = np.array(raw[k]["series"]); return {c: a[:, i] for i, c in enumerate(COLS)}


def top(o, sig, lo=0.0, hi=99):
    p = [q for q in o["fast"][sig]["poles"] if lo <= q["omega"] <= hi]
    return p[0] if p else None


modes = []
rows = []
for w in W:
    # спираль: A из T30 — наклон ln|φ| на 1–8 с
    d = ser(f"{w}|T30|A"); m = (d["t"] >= 1) & (d["t"] <= 8)
    lam = float(np.polyfit(d["t"][m], np.log(np.abs(d["phi"][m])), 1)[0])
    # фугоида: V в A
    o = M[f"{w}|T30|A"]; pv = top(o, "V", 0.5, 2.0)
    # голландский шаг: D (толчок по рысканию), по r
    od = M[f"{w}|S0|KR"]; pd_ = top(od, "r", 1.5, 3.2)
    # качание пилота: C из T30 (руки отпущены) по стропе
    oc = M[f"{w}|T30|C"]; ps = top(oc, "strap", 3.0, 9.0)
    oa = M[f"{w}|T30|A"]
    # доля голландского шага в A: полюс r в 1.7–2.6, амплитуда / амплитуда фугоидного полюса r
    pr = [q for q in oa["fast"]["r"]["poles"]]
    rows.append((w, lam, pv, pd_, ps))
    print(f"{w}: спираль после X из 30° λ={lam:+.3f} 1/с; фугоида(V) {pv and (round(pv['omega'],2), round(pv['zeta'],2))}; "
          f"ГШ(D) {pd_ and (round(pd_['omega'],2), round(pd_['zeta'],2))}; качание пилота (C) {ps and (round(ps['omega'],2), round(ps['zeta'],2))}; "
          f"A: r-полюса {[(round(q['omega'],2), round(q['zeta'],2), round(q['amp'],2)) for q in pr]}")
    for case, nm, pole in (("D: толчок по рысканию 0,15 рад/с, штанга в нейтрали, из прямого полёта", "dutch_roll", pd_),
                           ("A: X из виража 30° (r, 8–20 с, полином 3-й ст. вычтен)", "phugoid", pv),
                           ("C: руки отпущены в вираже 30° (угол стропы)", "pilot_swing", ps)):
        if pole:
            modes.append({"wing": w, "case": case, "mode": nm, "omega_rad_s": round(pole["omega"], 3), "zeta": round(pole["zeta"], 3), "source": "game"})
    modes.append({"wing": w, "case": "A: X из виража 30°, ln|φ| на 1–8 с (λ, 1/с; ζ не определена → 0)", "mode": "spiral",
                  "omega_rad_s": 0.0, "zeta": 0.0, "source": "game", "lambda_1_s": round(lam, 4)})
(OUT / "summary_modes_game.json").write_text(json.dumps(modes, indent=1, ensure_ascii=False))
# сравнение A и B/C/H: φ_кон, β быстрая, строп. быстрая — медианы по крыльям
print()
for st in ("T30", "T45", "S1", "T30P"):
    for sc in ("A", "A2", "B05", "B1", "B2", "C"):
        vals = [M[f"{w}|{st}|{sc}"] for w in W]
        f = lambda g: " ".join(f"{g(o):6.2f}" for o in vals)
        print(f"{st:5s}{sc:4s} φ_кон: {f(lambda o: o['phi_end'])} | β быстр.: {f(lambda o: o['fast']['beta']['peak_after2'])} | строп. быстр.: {f(lambda o: o['fast']['strap']['peak_after2'])} | p быстр.: {f(lambda o: o['fast']['p']['peak_after2'])}")
