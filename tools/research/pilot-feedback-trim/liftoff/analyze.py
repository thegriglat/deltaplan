"""PFT-4: разбор рядов liftoff_batch. python3 analyze.py out  -> out/summary.json и таблица в stdout."""
import json, gzip, sys, glob, os
import numpy as np
D = sys.argv[1] if len(sys.argv) > 1 else "out"
L = "../longitudinal/out/steady_game.json.gz"
st = json.load(gzip.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), L)))["wings"]
def ld(f):
    p = os.path.join(D, f)
    return json.load(gzip.open(p + ".gz")) if os.path.exists(p + ".gz") else json.load(open(p))
def arr(r): return np.array(r["series"]), {k: i for i, k in enumerate(r["cols"])}
def amp(x): return (x.max() - x.min()) / 2
out = {}
def lines(name):
    d = ld(name + ".json"); res = {}
    for w, sl in d["wings"].items():
        tr = st[w]["neutral"]
        for s, r in sl.items():
            a, c = arr(r); t = a[:, c["t"]]; th = a[:, c["theta"]]; V = a[:, c["V_kmh"]]
            th_tr = tr["theta"]; V_tr = tr["V"]; g_tr = tr["gamma"]
            tb = r["t_bar_after"]
            m = (t >= tb) & (t <= tb + 20.0)
            mm = (t >= tb + 1.0) & (t <= tb + 21.0)
            ib = int(np.argmin(abs(t - tb)))
            res[f"{w}/{s}"] = dict(
                t_lo=r["t_liftoff"], t_bar=tb, th_lo=a[0, c["theta"]], th_bar=th[ib], V_bar=V[ib], gam_bar=a[ib, c["gamma"]], q_bar=a[ib, c["q_dps"]],
                alpha_bar=a[ib, c["alpha"]], th_trim=th_tr, V_trim=V_tr, gam_trim=g_tr,
                th_max=th[m].max(), th_min=th[m].min(), th_amp=amp(th[m]), V_amp=amp(V[m]),
                V_min=V[mm].min(), V_max=V[mm].max(), V_amp_late=amp(V[(t >= tb + 15) & (t <= tb + 25)]),
                th_amp_late=amp(th[(t >= tb + 15) & (t <= tb + 25)]), stall=a[:, c["stall"]].max(),
                th_mean=th[m].mean(), V_mean=V[m].mean())
    return res
def air(v):
    d = ld(f"air_{v}.json"); res = {}
    for w, r in d["wings"].items():
        a, c = arr(r); t = a[:, c["t"]]; th = a[:, c["theta"]]; V = a[:, c["V_kmh"]]
        m = (t <= 20)
        res[w] = dict(v0=v, th_max=th[m].max(), th_min=th[m].min(), th_amp=amp(th[m]), V_amp=amp(V[m]), th_trim=th[0], V_trim=st[w]["neutral"]["V"], V_start=V[0])
    return res
names = ["base", "an_trim", "bar0", "bar05", "bar2", "bar3", "an_trim_bar0"]
for n in names:
    if os.path.exists(os.path.join(D, n + ".json")) or os.path.exists(os.path.join(D, n + ".json.gz")):
        out[n] = lines(n)
out["air"] = {str(v): air(v) for v in (33, 36, 38, 40, 42, 45) if os.path.exists(os.path.join(D, f"air_{v}.json")) or os.path.exists(os.path.join(D, f"air_{v}.json.gz"))}
json.dump(out, open(os.path.join(D, "summary.json"), "w"), indent=1)
for n in names:
    if n not in out: continue
    print("==", n)
    print(f"{'wing/slope':24s}{'t_lo':>6s}{'t_bar':>6s}{'thLO':>6s}{'thB':>6s}{'VB':>6s}{'gamB':>6s}{'qB':>6s}{'aB':>6s} | {'thmax':>6s}{'thmin':>6s}{'thAmp':>6s}{'VAmp':>6s}{'VAmpL':>6s}{'stall':>6s}")
    for k, v in out[n].items():
        print(f"{k:24s}{v['t_lo']:6.2f}{v['t_bar']:6.2f}{v['th_lo']:6.1f}{v['th_bar']:6.1f}{v['V_bar']:6.1f}{v['gam_bar']:6.1f}{v['q_bar']:6.1f}{v['alpha_bar']:6.1f} | {v['th_max']:6.1f}{v['th_min']:6.1f}{v['th_amp']:6.2f}{v['V_amp']:6.2f}{v['V_amp_late']:6.2f}{v['stall']:6.2f}")
print("== trim (steady) ", {w: (round(x['neutral']['V'],1), round(x['neutral']['theta'],1), round(x['neutral']['gamma'],1), round(x['neutral']['alpha'],1)) for w, x in st.items() if w in ('sport','ww_t2c','moyes_litespeed_rx','training')})
print("== air")
for v, d in out["air"].items():
    for w, x in d.items(): print(v, w, {k: round(val, 2) for k, val in x.items()})
