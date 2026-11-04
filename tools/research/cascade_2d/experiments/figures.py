"""CSD-4: картинки для README -> out/fig/: поля V3 и B400 против P25 (C1, C2, C3), E_u по уровням, Парето «время - E_u»,
C1 V0/V1/V2/V3 (разность u, w с эталоном), профиль C0 у земли."""
import json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); CD = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(CD, "metrics")); sys.path.insert(0, os.path.join(CD, "contract"))
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import metrics as M, cascade2d_io as io, plots as P
DATA = os.environ.get("CASCADE2D_DATA", os.path.expanduser("~/data/cascade_2d")) + "/fields/"
FIG = f"{CD}/out/fig"; os.makedirs(FIG, exist_ok=True)
V = json.load(open(f"{CD}/out/verdict.json")); LV = json.load(open(f"{CD}/out/levels.json"))
CASES = ["C0", "C1", "C2", "C3", "C4"]
cols = {"V0": "#999999", "V1": "#1f77b4", "V2": "#ff7f0e", "V3": "#d62728", "B": "#2ca02c"}

# 1. поля: V3 и B400 против P25 (C1, C2, C3)
for C in ("C1", "C2", "C3"):
    rm, ra = io.read_f1(DATA + f"{C}/picard_none_d25.json"); xc, L = M.case_xc_L(C)
    bm, ba = io.read_f1(DATA + f"{C}/picard_none_d400.json"); b = M.make_baseline(bm, ba, rm, ra)
    P.fields_figure(b[0], b[1], rm, ra, xc, L, f"{C}: B400 (P400 линейно на 25 м) против P25", f"{FIG}/{C}/B400_fields.png")

# 2. E_u по уровням: каскад V0-V3 (старт 400) против P_k своего уровня; B_k против P25
fig, ax = plt.subplots(1, 5, figsize=(16, 3.4), sharey=False)
for a, C in zip(ax, CASES):
    for var in ("V0", "V1", "V2", "V3"):
        lev = LV[C][f"{var}_from400"]; a.plot([200, 100, 50, 25], [lev[str(k)]["E_u"] for k in (200, 100, 50, 25)], "o-", color=cols[var], label=var, ms=3)
    bl = {r["variant"]: r["E_u"] for r in json.load(open(f"{CD}/out/metrics/{C}.json"))["rows"] if r["source"] == "baseline"}
    a.plot([400, 200, 100, 50], [bl[f"B{k}"] for k in (400, 200, 100, 50)], "s--", color=cols["B"], label="B_k (против P25)", ms=3)
    a.set_xscale("log", base=2); a.invert_xaxis(); a.set_title(C, fontsize=9); a.set_xlabel("dx, м"); a.grid(alpha=.3)
ax[0].set_ylabel("E_u / U_ref"); ax[0].legend(fontsize=7)
fig.suptitle("E_u: каскад (старт 400 м) против P_k своего уровня; B_k против P25", fontsize=10); fig.tight_layout(); P.save_small(fig, f"{FIG}/E_u_levels.png"); plt.close(fig)

# 3. Парето: время на ряд - E_u
fig, ax = plt.subplots(1, 5, figsize=(16, 3.4))
for a, C in zip(ax, CASES):
    d = V["cases"][C]
    a.plot([c["T_row"] for c in d["K4"]["candidates"]], [c["E_u"] for c in d["K4"]["candidates"]], "s--", color=cols["B"], label="B_k (P_k)")
    for c in d["K4"]["candidates"]:
        a.annotate(f"B{c['k']}", (c["T_row"], c["E_u"]), fontsize=6, xytext=(2, 2), textcoords="offset points")
    T400 = d["K4"]["candidates"][0]["T_row"]
    a.plot([T400 + d["K3"]["T_desc"]], [d["V3_400"]["E_u"]], "o", color=cols["V3"], label="V3 от P400 (P400 + спуск)")
    T200 = d["K4"]["candidates"][1]["T_row"]
    a.plot([T200 + d["K3"]["T_desc"]], [d["V3_200"]["E_u"]], "^", color=cols["V1"], label="V3 от P200")
    a.set_xscale("log"); a.set_title(C, fontsize=9); a.set_xlabel("время на ряд, с"); a.grid(alpha=.3)
ax[0].set_ylabel("E_u / U_ref"); ax[0].legend(fontsize=7)
fig.suptitle("Парето: цена и ошибка (меньше и левее - лучше); точки каскада включают решение родителя", fontsize=10); fig.tight_layout(); P.save_small(fig, f"{FIG}/pareto.png"); plt.close(fig)

# 4. C1 V0/V1/V2/V3: разность с эталоном (|u|, w)
C = "C1"; rm, ra = io.read_f1(DATA + f"{C}/picard_none_d25.json"); xc, L = M.case_xc_L(C)
air = ra["cell"] > 0.5; ur, wr = M.cell_vel(ra); x, z = P._grid(rm, ra)
fig, ax = plt.subplots(2, 4, figsize=(16, 6), sharex=True, sharey=True)
for j, var in enumerate(("V0", "V1", "V2", "V3")):
    m, a = M.to_ref_grid(*io.read_f1(DATA + f"{C}/cascade_{var}_d25_from400.json"), rm, ra); u, w = M.cell_vel(a)
    for r, (f, g, lim) in enumerate(((np.hypot(u, w), np.hypot(ur, wr), 4.0), (w, wr, 2.0))):
        pc = ax[r, j].pcolormesh(x, z, np.ma.array(f - g, mask=~air), cmap="RdBu_r", vmin=-lim, vmax=lim, shading="flat")
        ax[r, j].set_xlim(xc - 3 * L, xc + 6 * L); ax[r, j].set_ylim(-rm["dz"], 900)
        ax[r, j].set_title(f"{var}: " + ("|u| - эталон" if r == 0 else "w - эталон"), fontsize=9)
fig.colorbar(pc, ax=ax, fraction=0.02); fig.suptitle("C1: разность с P25 по вариантам (старт 400 м), м/с", fontsize=10)
P.save_small(fig, f"{FIG}/C1_variants.png"); plt.close(fig)

# 5. C0: профиль у земли
pr = json.load(open(f"{CD}/out/diag_C0_profile.json"))
fig, a = plt.subplots(figsize=(5, 4))
for k, lab in (("P25", "эталон P25"), ("B400", "B400"), ("V1", "каскад V1")):
    a.plot([p[k] for p in pr], [p["z"] for p in pr], label=lab)
a.set_xlabel("u, м/с"); a.set_ylabel("z_agl, м"); a.legend(); a.grid(alpha=.3); a.set_title("C0: профиль u в колонне x = 0", fontsize=9)
fig.tight_layout(); P.save_small(fig, f"{FIG}/C0_profile.png"); plt.close(fig)
for f in sorted(os.listdir(FIG)): pass
print(*[f"{r}/{f}: {os.path.getsize(os.path.join(r, f))//1024} KB" for r, _, fs in os.walk(FIG) for f in fs], sep="\n")
