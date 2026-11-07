"""Печатает markdown-таблицы для stage1-regimes.md из out/regimes."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyse import *
import theory as th
Fs = [0.2, 0.3, 0.5, 0.7, 0.85, 1.2, 1.5, 2, 3]; Ms = [0.05, 0.1, 0.2, 0.3, 0.4, 0.6, 0.8, 1.0, 1.2]
def find(sub, F, M, suf=""):
    n = f"A1_{sub}_F{F:.3f}_M{M:.3f}{suf}"
    return next((r for r in A1 if r["case"] == n), None)
def matrix(sub):
    print("| F0 \\ M | " + " | ".join(str(m) for m in Ms) + " |"); print("|---|" + "---|" * len(Ms))
    for F in Fs:
        cells = []
        for M in Ms:
            r = find(sub, F, M)
            if r is None: cells.append(""); continue
            s = r["regime_sw"].replace("unclassified", "?")
            th_ = r["regime_theory"].replace("|", "/")
            cells.append(s if r["match"] else f"**{s}**/{th_}")
        print(f"| {F} | " + " | ".join(cells) + " |")
def matrix_ctl(sub, FF):
    print("| F0 \\ M | " + " | ".join(str(m) for m in Ms) + " |"); print("|---|" + "---|" * len(Ms))
    for F in FF:
        cells = []
        for M in Ms:
            r = find(sub, F, M); s = r["regime_sw"].replace("unclassified", "?")
            cells.append(s if r["match"] else f"**{s}**/{r["regime_theory"].replace("|", "/")}")
        print(f"| {F} | " + " | ".join(cells) + " |")
print("### ridge a/h0=3"); matrix("r3")
print("### ridge a/h0=6"); matrix_ctl("r6", [0.5, 1.5, 2])
print("### step_up"); matrix_ctl("su3", [0.5, 1.5, 2])
print("### bore")
print("| F0 | M | M/M_c | h1/h0 SW | h1/h0 теор | s SW, м/с | s теор, м/с | q/(h0 U0) |"); print("|---|---|---|---|---|---|---|---|")
for r in A1:
    d = r["diag"]
    if "_r3_" in r["case"] and "_dx" not in r["case"] and d["h1_theory"] and r["bore_speed"] and r["regime_theory"] in ("R3", "R5") and (r["F0"], r["M"]) in [(0.5,0.3),(0.5,0.6),(0.5,0.8),(0.7,0.1),(0.7,0.4),(0.85,0.05),(0.85,0.4),(1.2,0.05),(1.2,0.4),(1.5,0.2),(1.5,0.6),(2.0,0.8),(0.2,0.6),(0.3,0.8)]:
        print(f"| {r['F0']} | {r['M']} | {r['M']/d['Mc']:.2f} | {r['h_up']:.3f} | {d['h1_theory']:.3f} | {r['bore_speed']:.2f} | {d['s_theory']:.2f} | {r['q_ratio']:.2f} |")
print("### hyst")
print("| случай | старт | regime_sw | Fr_crest | прыжок x/a (SW) | x/a теор | статус |"); print("|---|---|---|---|---|---|---|")
for r in A1:
    if "_jstart" in r["case"] or (r["regime_theory"] == "R2|R4j" and r["diag"].get("stand_jump") is not None):
        d = r["diag"]; a = d["a"]
        js = "_jstart" in r["case"]
        base = r["case"].replace("_jstart", "")
        if not js and not (base + "_jstart") in [x["case"] for x in A1]: continue
        xs = "—" if d["x_stand"] is None else f"{d['x_stand']/a:.2f}"
        xt = "—" if not js or d.get("x_j_theory") is None else f"{d['x_j_theory']/a:.2f}"
        print(f"| {base} | {'прыжок' if js else 'ровный'} | {r['regime_sw']} | {r['Fr_crest']:.2f} | {xs} | {xt} | {r['status']} |")
