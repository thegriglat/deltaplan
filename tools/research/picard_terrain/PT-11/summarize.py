"""PT-11: итог -> out/PT-11/summary.json, presence.csv, thermals.csv (после agg_timing.py, presence.py analyze, run_post.sh)."""
import csv, json, math
from pathlib import Path
import numpy as np
OUT = Path(__file__).resolve().parents[1] / "out/PT-11"
tim = json.load(open(OUT / "timing.json"))
pres_files = {  # (набор, случай) -> файл; ongudai_storm информационно (ветер бури не однонаправленный)
    ("massif", "ongudai_strong"): "presence_ongudai_strong.json", ("massif", "synth_strong"): "presence_synth_strong.json",
    ("mod", "ongudai_strong"): "presence_ongudai_strong_mod.json", ("mod", "synth_strong"): "presence_synth_strong_mod.json",
    ("massif", "ongudai_storm"): "presence_ongudai_storm.json", ("mod", "ongudai_storm"): "presence_ongudai_storm_mod.json",
}
rows, nan = [], {"base": 0, "after": 0}
speed_ratios, lost, gained, kept = [], [], 0, 0
skipped = 0
for (setn, case), fn in pres_files.items():
    f = OUT / "presence" / fn
    if not f.exists():
        continue
    d = json.load(open(f))
    for v in nan:
        nan[v] += d["nan"][v]
    primary = case != "ongudai_storm"
    for ci, c in enumerate(d["crests"]):
        for t, m in c["moments"].items():
            b, a = m["base"], m["after"]
            for z in ("10", "30", "60", "100"):
                Sb, Sa = b["speed"][z]["S"], a["speed"][z]["S"]
                ratio = (Sa - 1) / (Sb - 1) if Sb > 1.05 else None
                rows.append(dict(set=setn, case=case, primary=primary, crest=ci, x=round(c["x"]), z=round(c["z"]), h=round(c["h"]), gain=round(c["gain"]),
                                 t=t, z_agl=z, S_before=Sb, S_after=Sa, ratio=ratio, wcrest_before=b["speed"][z]["crest"], wcrest_after=a["speed"][z]["crest"],
                                 wplain_before=b["speed"][z]["plain"], wplain_after=a["speed"][z]["plain"],
                                 slope_w_mean_before=b["slope_w_mean"], slope_w_mean_after=a["slope_w_mean"],
                                 slope_w_max_before=b["slope_w_max"], slope_w_max_after=a["slope_w_max"],
                                 rotor_frac_before=b["rotor"]["frac"], rotor_frac_after=a["rotor"]["frac"],
                                 rotor_minu_before=b["rotor"]["min_u"], rotor_minu_after=a["rotor"]["min_u"],
                                 rotor_h_before=b["rotor"]["height_m"], rotor_h_after=a["rotor"]["height_m"],
                                 rotor_len_before=b["rotor"]["length_m"], rotor_len_after=a["rotor"]["length_m"],
                                 rotor_before=b["rotor"]["present"], rotor_after=a["rotor"]["present"]))
            if primary:
                pass
prim = [r for r in rows if r["primary"]]
with open(OUT / "presence.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
vals = [r["ratio"] for r in prim if r["ratio"] is not None]
skipped = sum(1 for r in prim if r["ratio"] is None)
def sub(f):
    v = [r["ratio"] for r in prim if r["ratio"] is not None and f(r)]
    return min(v) if v else None
by_z = {z: sub(lambda r, z=z: r["z_agl"] == z) for z in ("10", "30", "60", "100")}
rot_pairs = {}
for r in prim:
    rot_pairs.setdefault((r["set"], r["case"], r["crest"], r["t"]), (r["rotor_before"], r["rotor_after"], r["rotor_frac_before"], r["rotor_frac_after"]))
rotor_before = sum(1 for v in rot_pairs.values() if v[0])
rotor_lost = sum(1 for v in rot_pairs.values() if v[0] and not v[1])
rotor_new = sum(1 for v in rot_pairs.values() if v[1] and not v[0])
wm = [(r["slope_w_mean_before"], r["slope_w_mean_after"]) for r in prim if r["z_agl"] == "10"]
# термики
th_rows = []
for day in (1, 2, 3):
    B = [json.loads(l) for l in open(OUT / f"thermals/base_ongudai_day_{day}.jsonl")]
    A = [json.loads(l) for l in open(OUT / f"thermals/after_ongudai_day_{day}.jsonl")]
    for b, a in zip(B, A):
        wb = np.array([k["w"] for k in b["cores"]]); wa = np.array([k["w"] for k in a["cores"]])
        th_rows.append(dict(day=day, t=b["t"], n_before=b["n"], n_after=a["n"], ratio=a["n"] / b["n"],
                            wmean_before=float(wb.mean()), wmean_after=float(wa.mean()), wmax_before=float(wb.max()), wmax_after=float(wa.max()),
                            nan_before=b["nan"], nan_after=a["nan"]))
        nan["base"] += b["nan"]; nan["after"] += a["nan"]
with open(OUT / "thermals.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(th_rows[0].keys())); w.writeheader(); w.writerows(th_rows)
for v, k in (("base", "base"), ("after", "after")):
    nan[v] += tim["nan_timing"][k]
heat = json.load(open(OUT / "heat_balance.json"))
nan["after"] += heat["nonfinite"]
summary = dict(
    load_ratio_max=tim["load_ratio_max"], load_ratio_by_place_t8=tim["load_ratio_by_place_t8"],
    nan_count=nan["after"], nan_count_before=nan["base"],
    crest_speedup_after_over_before_min=min(vals), crest_speedup_ratio_n=len(vals), crest_speedup_skipped_Sbefore_le_1_05=skipped,
    crest_speedup_ratio_min_by_z_agl=by_z,
    crest_speedup_ratio_median=float(np.median(vals)),
    rotor_lost=rotor_lost, rotor_cases_before=rotor_before, rotor_new_after=rotor_new, rotor_cases_total=len(rot_pairs),
    slope_w_mean_10m_before_after_median=[float(np.median([x for x, _ in wm])), float(np.median([y for _, y in wm]))],
    thermal_cores_after_over_before_min=min(r["ratio"] for r in th_rows),
    thermal_cores=th_rows,
    heat_balance=dict(ratio_total_vf=heat["ratio_total_vf"], ratio_total_plain=heat["ratio_total_plain"], quantiles=heat["ratio_vf_quantiles"], columns=heat["columns"], cut_heated_columns=heat["cut_heated_columns"]),
)
json.dump(summary, open(OUT / "summary.json", "w"), indent=1)
print(json.dumps({k: v for k, v in summary.items() if k != "thermal_cores"}, indent=1))
