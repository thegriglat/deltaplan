"""PT-11b (доп.): скорость в far-точках случая (свободный поток), до/после, t=0, без фокуса."""
import json, csv, io
import numpy as np
from pt11b import *
res = {}
for case, name in (("ongudai_strong", "ongudai_strong_massif0"), ("synth_strong", "synth_strong_massif0")):
    cf = ME / "cases" / f"{name.rsplit('_', 1)[0]}_massif0_nofocus.json"
    cf = ME / "cases" / f"{name}_nofocus.json"
    cj = json.load(open(cf)); tags = cj["point_tags"]
    far = [i for i, t in enumerate(tags) if t == "far"]
    for var in ("before", "after"):
        f = RAW / f"far_{case}_{var}.csv"
        if not f.exists():
            f.write_text(stand(var, "sample", cf, ["--mode", "mean", "--time", "0"], CASE[case]))
        rows = list(csv.DictReader(open(f)))
        U = [float(np.hypot(float(rows[i]["vx"]), float(rows[i]["vz"]))) for i in far]
        res.setdefault(case, {})[var] = dict(U_far=U, mean=float(np.mean(U)), y=[float(rows[i]["y"]) for i in far])
    res[case]["after_over_before_mean"] = res[case]["after"]["mean"] / res[case]["before"]["mean"]
json.dump(res, open(OUT / "far_U.json", "w"), indent=1)
print({c: (v["before"]["mean"], v["after"]["mean"], v["after_over_before_mean"]) for c, v in res.items()})
