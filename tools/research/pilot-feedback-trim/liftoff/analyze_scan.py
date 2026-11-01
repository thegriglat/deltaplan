"""PFT-4: сетка alpha_neutral / bar_after + оценка Ланчестера амплитуды V по состоянию на передаче рук. python3 analyze_scan.py out"""
import json, gzip, sys, os, glob, re
import numpy as np
D = sys.argv[1] if len(sys.argv) > 1 else "out"
st = json.load(gzip.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../longitudinal/out/steady_game.json.gz")))["wings"]
def ld(p): return json.load(gzip.open(p) if p.endswith(".gz") else open(p))
def metr(r, w):
    c = {k: i for i, k in enumerate(r["cols"])}; a = np.array(r["series"]); t = a[:, 0]; tb = r["t_bar_after"]
    th = a[:, c["theta"]]; V = a[:, c["V_kmh"]]; g = a[:, c["gamma"]]
    m = (t >= tb) & (t <= tb + 20); ib = int(np.argmin(abs(t - tb))); tr = st[w]["neutral"]
    dV = V[ib] - tr["V"]; dg = np.radians(g[ib] - tr["gamma"]) * -1 * -1  # g — угол спуска (+вниз); трим тоже
    # у PFT-1 gamma трима = -5,2 (знак «вверх +»), у меня + вниз: приводим
    g_tr = -tr["gamma"]
    dg = np.radians(g[ib] - g_tr)
    lanch = float(np.hypot(dV, tr["V"] * dg / np.sqrt(2)))
    return dict(t_bar=tb, th_bar=th[ib], V_bar=V[ib], dV=dV, dgam=np.degrees(dg), V_amp=(V[m].max() - V[m].min()) / 2, th_amp=(th[m].max() - th[m].min()) / 2, lanch_V_amp=lanch)
res = {}
for f in sorted(glob.glob(os.path.join(D, "*.json*"))):
    n = os.path.basename(f).split(".json")[0]
    if n.startswith("air_") or n == "t0" or n == "summary" or n.startswith("scan_summary"): continue
    d = ld(f)
    for w, sl in d["wings"].items():
        for s, r in sl.items():
            res.setdefault(n, {})[f"{w}/{s}"] = metr(r, w) | {"alpha_neutral": r["alpha_neutral_deg"]}
json.dump(res, open(os.path.join(D, "scan_summary.json"), "w"), indent=1)
def key(n): 
    m = re.match(r"([a-z_]+?)([0-9.]*)$", n); return (m.group(1), float(m.group(2) or 0))
for n in sorted(res, key=key):
    for k, v in res[n].items():
        if k.split("/")[0] in ("sport", "ww_t2c"):
            print(f"{n:14s}{k:12s} aN={v['alpha_neutral']:5.1f} tB={v['t_bar']:5.2f} thB={v['th_bar']:5.1f} dV={v['dV']:+5.1f} dg={v['dgam']:+5.1f} | Vamp={v['V_amp']:5.2f} Lanch={v['lanch_V_amp']:5.2f} thAmp={v['th_amp']:5.2f}")
