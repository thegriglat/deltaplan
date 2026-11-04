"""CSD-4, K5: E_u каскада (V0..V3h, старт 400 и 200) против P_k своего уровня, k = 200,100,50,25.
Запускает metrics.py с --ref picard_d<k> и полями каскада этого уровня; сводка -> out/levels.json."""
import glob, json, os, subprocess, sys, tempfile
R = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
CD = os.path.join(R, "tools/research/cascade_2d")
DATA = os.environ.get("CASCADE2D_DATA", os.path.expanduser("~/data/cascade_2d"))
res = {}
for C in ["C0", "C1", "C2", "C3", "C4"]:
    for dx in (200, 100, 50, 25):
        ref = f"{DATA}/fields/{C}/picard_none_d{dx}.json"
        fl = sorted(f for f in glob.glob(f"{DATA}/fields/{C}/cascade_V*_d{dx}_from*.json") if "run" not in f)
        if dx == 200:
            fl = [f for f in fl if "from400" in f]
        if not fl:
            continue
        with tempfile.TemporaryDirectory() as td:
            subprocess.run([os.path.join(CD, "py"), os.path.join(CD, "metrics/metrics.py"), "--case", C, "--ref", ref,
                            "--fields", *fl, "--baselines", "", "--out", td], check=True, capture_output=True)
            m = json.load(open(f"{td}/{C}.json"))
        for r in m["rows"]:
            if r["source"] == "cascade":
                res.setdefault(C, {}).setdefault(f"{r['variant']}_from{r['parent_dx']}", {})[str(dx)] = dict(
                    E_u=r["E_u"], E_w=r["E_w"], max_rel_div=r["max_rel_div"], max_speed=r["max_speed"])
json.dump(res, open(os.path.join(CD, "out/levels.json"), "w"), indent=1)
for C, d in res.items():
    for k, v in d.items():
        print(C, k, {dx: round(x["E_u"], 4) for dx, x in v.items()})
