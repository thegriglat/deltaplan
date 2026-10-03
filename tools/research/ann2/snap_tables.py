"""AN-1, шаг 5: сводка out/snap_cases.json → out/snap_tables.md / .json"""
import json
import numpy as np
from common import OUT
D = json.load(open(OUT / "snap_cases.json"))
m = lambda cs, k: float(np.median([c[k] for c in cs if c.get(k) is not None])) if cs else float("nan")
def grp(c):
    if c["nc"]: return "не сошлось за 1000 (нс)"
    return "сошлось, it_сх ≥ 300" if c["conv_it"] >= 300 else "сошлось, it_сх < 300"
G = {}
for c in D: G.setdefault((grp(c)), []).append(c)
L = ["| группа | n | U10 мед | ошибка сети P2 мед. (клетки → мед. по случаям) | p90 клеток | разброс σ (11 снимков) p90 клеток | σ мед. клеток | шум цели: 11 снимков против 51, мед. клеток | p90 | ошибка к среднему 500…1000 | отход цели от среднего 500…1000, мед. клеток | то же p90 | отход от состояния через +100 it |", "|" + "---|" * 13]
f = lambda x: "—" if x is None or np.isnan(x) else f"{x:.3f}"
tab = {}
for k, cs in sorted(G.items(), key=lambda kv: kv[0]):
    r = dict(n=len(cs), U10=m(cs, "U10"), err_med=m(cs, "err_med"), err_p90=m(cs, "err_p90"), sig_p90=m(cs, "sigma11_p90"), sig_med=m(cs, "sigma11_med"),
             half=m(cs, "tgt11_vs_all_med"), half90=m(cs, "tgt11_vs_all_p90"), err_lr=m(cs, "err_to_longrun_med"), dr_med=m(cs, "drift_conv_to_longrun_med"), dr_p90=m(cs, "drift_conv_to_longrun_p90"), dr100=m(cs, "drift_conv_plus100_med"))
    tab[k] = r
    L.append(f"| {k} | {r['n']} | {r['U10']:.2f} | {f(r['err_med'])} | {f(r['err_p90'])} | {f(r['sig_p90'])} | {f(r['sig_med'])} | {f(r['half'])} | {f(r['half90'])} | {f(r['err_lr'])} | {f(r['dr_med'])} | {f(r['dr_p90'])} | {f(r['dr100'])} |")
# U10-корзины: ошибка против шума
L += ["", "Ошибка и шум цели по корзинам U10 (все случаи выборки)", "", "| U10 | n (нс / сошедшихся) | ошибка мед. | σ(11) мед. клеток, нс | отход цели от среднего, сошедшиеся | ошибка / |V| (мед.) |", "|---|---|---|---|---|---|"]
for a, b in ((0, 2), (2, 4), (4, 6), (6, 99)):
    cs = [c for c in D if a <= c["U10"] < b]
    if not cs: continue
    nc = [c for c in cs if c["nc"]]; cv = [c for c in cs if not c["nc"]]
    rel = float(np.median([c["err_med"] / c["vt_med"] for c in cs]))
    L.append(f"| {a}–{b} | {len(nc)} / {len(cv)} | {f(m(cs, 'err_med'))} | {f(m(nc, 'sigma11_med'))} | {f(m(cv, 'drift_conv_to_longrun_med'))} | {rel:.3f} |")
# отношение по случаям
rt = np.array([c["err_med"] / c["sigma11_med"] for c in D if c["nc"] and c["sigma11_med"] > 0.02])
rh = np.array([c["err_med"] / c["tgt11_vs_all_med"] for c in D if c["nc"] and c["tgt11_vs_all_med"] > 0.002])
rc = np.array([c["err_med"] / c["drift_conv_to_longrun_med"] for c in D if not c["nc"] and c["drift_conv_to_longrun_med"] > 0.005])
S = dict(ratio_err_over_sigma_nc=dict(n=len(rt), q=np.percentile(rt, [10, 50, 90]).tolist()), ratio_err_over_halfnoise_nc=dict(n=len(rh), q=np.percentile(rh, [10, 50, 90]).tolist()),
         ratio_err_over_drift_conv=dict(n=len(rc), q=np.percentile(rc, [10, 50, 90]).tolist()))
# сошедшиеся: доля шума в квадрате
cv = [c for c in D if not c["nc"]]
S["conv_n"] = len(cv); S["conv_repro_max"] = max(c["repro_max_abs"] for c in D)
S["conv_err_sq_noise_share_med"] = float(np.median([c["drift_conv_to_longrun_med"] ** 2 / c["err_med"] ** 2 for c in cv]))
nc = [c for c in D if c["nc"]]
S["nc_err_sq_noise_share_med"] = float(np.median([c["sigma11_med"] ** 2 / c["err_med"] ** 2 for c in nc])); S["nc_tgtnoise_share_med"] = float(np.median([c["tgt11_vs_all_med"] ** 2 / c["err_med"] ** 2 for c in nc]))
tr = [c for c in D if c["set"] == "train"]; ho = [c for c in D if c["set"] == "holdout_sys"]
S["train_vs_holdout_err"] = dict(train=m(tr, "err_med"), n_train=len(tr), hold=m(ho, "err_med"), n_hold=len(ho))
L += ["", "```", json.dumps(S, ensure_ascii=False, indent=1), "```"]
open(OUT / "snap_tables.md", "w").write("\n".join(L)); json.dump(dict(groups=tab, summary=S), open(OUT / "snap_tables.json", "w"), ensure_ascii=False, indent=1)
print("\n".join(L))
