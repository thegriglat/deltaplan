"""AN-1, шаг 7: сводка perturb: изменение цели (60 м, область без 5 клеток) при U10 × 1,02 и +1° направления против ошибки сети P2."""
import json
import numpy as np
from common import OUT, RUN
import common
from pilotnn import evaluate as E
cfg = json.loads((RUN / "config.json").read_text()); ec = cfg["eval"]
agl = [10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 200, 300, 400]
lw = None
S = {c["case"]: c for c in json.load(open(OUT / "snap_cases.json"))}
e = 5; rows = []
for f in sorted((OUT / "perturb").glob("*.npz")):
    z = np.load(f); cid = f.stem
    from pilotnn.evaluate import level_weights, at_level
    if lw is None:
        info = json.loads((RUN / "run_info.json").read_text()); from pilotnn.data import Datasets
        lw = level_weights(Datasets([(d["name"], d["root"]) for d in info["datasets"]]).agl, ec["agl_key_m"])
    g = lambda k: at_level(z[k], lw)[:2][:, e:-e, e:-e]
    d = {}
    for k in ("u10", "wdir"):
        dd = np.hypot(*(g(k) - g("base")))
        d[k] = (float(np.median(dd)), float(np.percentile(dd, 90)))
    vt = float(np.median(np.hypot(*g("base"))))
    rows.append(dict(case=cid, nc=S[cid]["nc"], U10=S[cid]["U10"], vt=vt, err=S[cid]["err_med"], d_u10=d["u10"][0], d_u10_p90=d["u10"][1], d_wdir=d["wdir"][0], d_wdir_p90=d["wdir"][1],
                     status={k: str(z[k + "_status"]) for k in ("base", "u10", "wdir")}))
json.dump(rows, open(OUT / "perturb_cases.json", "w"), ensure_ascii=False, indent=1)
L = ["| случай | класс | U10 | |V| мед. | ошибка P2 мед. | сдвиг цели при U10×1,02: мед. / p90 | при +1°: мед. / p90 | статусы |", "|---|---|---|---|---|---|---|---|"]
for r in rows:
    L.append(f"| {r['case']} | {'нс' if r['nc'] else 'сошёлся'} | {r['U10']:.2f} | {r['vt']:.2f} | {r['err']:.3f} | {r['d_u10']:.3f} / {r['d_u10_p90']:.3f} | {r['d_wdir']:.3f} / {r['d_wdir_p90']:.3f} | {','.join(r['status'].values())} |")
for k, nm in (("nc", "нс"), ("conv", "сошедшиеся")):
    cs = [r for r in rows if r["nc"] == (k == "nc")]
    if cs:
        L.append(f"| **медиана, {nm} (n={len(cs)})** | | | | {np.median([r['err'] for r in cs]):.3f} | {np.median([r['d_u10'] for r in cs]):.3f} / {np.median([r['d_u10_p90'] for r in cs]):.3f} | {np.median([r['d_wdir'] for r in cs]):.3f} / {np.median([r['d_wdir_p90'] for r in cs]):.3f} | |")
open(OUT / "perturb_tables.md", "w").write("\n".join(L)); print("\n".join(L))
