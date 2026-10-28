#!/usr/bin/env python3
"""Сведение опыта RW-6z: сырьё $RW6Z_RAW/<variant>/<loc>__<site>/meta.json + diffs.jsonl -> results.json.

Запуск: RW6Z_RAW=~/data/rw6z python3 summarize.py diffs.jsonl results.json
"""
import json, os, sys

raw = os.path.expanduser(os.environ.get("RW6Z_RAW", "~/data/rw6z"))
diffs_path, out_path = sys.argv[1], sys.argv[2]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
VARIANTS = ["base", "chunk1000", "pert_u10", "pert_t"]
FIELDS = [
    ("training_island", "ridge_west"), ("training_island", "thermal_plain"),
    ("volcano_island", "plateau_landing"), ("volcano_island", "thermal_slope"),
    ("training_island", "lee_bowl"), ("training_island", "landing_hill"),
]
PHASES = ["A", "B", "C", "D", "F", "G", "H"]
CHS = ["u", "v", "w_mech", "w_conv", "theta"]

runs, metas = [], {}
for loc, site in FIELDS:
    for v in VARIANTS:
        p = os.path.join(raw, v, f"{loc}__{site}", "meta.json")
        if not os.path.exists(p):
            continue
        m = json.load(open(p))
        metas[(loc, site, v)] = m
        runs.append({"loc": loc, "site": site, "variant": v, "k": m["k"], "wall_s": m["wall_s"],
                     "passes": [{"level": q["level"], "pass": q["pass"], "status": q["status"],
                                 "status_mech": q["status_mech"], "status_heat": q["status_heat"],
                                 "iters_mech": q["iters_mech"], "iters_heat": q["iters_heat"],
                                 "div_rms": q["div_rms"], "div_rms_mech": q["div_rms_mech"],
                                 "div_rms_heat": q["div_rms_heat"]} for q in m["passes"]]})

diffs = [json.loads(l) for l in open(diffs_path)]
for d in diffs:
    d["loc"], d["site"]  # ключи как в карточке
D = {}
for d in diffs:
    D[(d["loc"], d["site"], d["level"], d["cmp"], d["cells"])] = d


def xmax(d):
    return max(d["ch"][c]["x_tol"] for c in CHS)


fields = []
for loc, site in FIELDS:
    bm = metas.get((loc, site, "base"))
    if not bm:
        continue
    levels = [l["name"] for l in bm["levels"]]
    num = {}  # (cmp) -> max x_tol по уровням/каналам на picard
    for cmp_ in ("chunk1000_vs_base", "pert_u10_vs_base", "pert_t_vs_base"):
        vals = [xmax(D[(loc, site, lv, cmp_, "picard")]) for lv in levels if (loc, site, lv, cmp_, "picard") in D]
        num[cmp_] = max(vals) if vals else None
    den = max(xmax(D[(loc, site, lv, "base_vs_gpu", "picard")]) for lv in levels)
    shift = max(num[c] for c in ("chunk1000_vs_base", "pert_u10_vs_base") if num[c] is not None)
    R = shift / den if den > 0 else None
    mech_gpu = max(xmax(D[(loc, site, lv, "base_vs_gpu", "mech")]) for lv in levels
                   if D[(loc, site, lv, "base_vs_gpu", "mech")]["ch"]["u"]["n"] > 0) if any(
        D[(loc, site, lv, "base_vs_gpu", "mech")]["ch"]["u"]["n"] > 0 for lv in levels) else 0.0
    mech_err = mech_gpu > 1.0
    if R is None:
        # picard-клеток нет (область заморожена целиком): сдвиг нечем мерить, судим по механизмам
        verdict = "port_error" if mech_err else "mixed"
    elif R >= 0.1:
        verdict = "instability"
    elif R < 0.01:
        verdict = "port_error"
    else:
        verdict = "mixed"
    if mech_err and verdict == "instability":
        verdict = "mixed"
    st = {}
    for q in bm["passes"]:
        st.setdefault(q["level"], []).append(
            f'{q["status"]} м{q["iters_mech"]}/т{q["iters_heat"]} div{q["div_rms"]:.1e}')
    s = bm["stats"]
    po = {}
    for lv in levels:
        d = D.get((loc, site, lv, "base_vs_gpu", "all"))
        po[lv] = d.get("phase_over_tol") if d else None
    fields.append({
        "loc": loc, "site": site, "u10": s["u10"], "u10_file": json.load(open(
            os.path.join(root, "data/locations", loc, "air", f"{site}.json")))["levels"][-1]["meta"].get("u10"),
        "fr": s["fr"], "n_bv": s["n_bv"],
        "k_crate": bm["k"], "k_file": bm["k_file"],
        "status_crate": st, "status_gpu": "нет данных",
        "phase_counts_over_tol": po, "phase_frac": dict(zip(PHASES, s["phase_frac"])),
        "frozen_frac": s["frozen_frac"], "frozen_frac_mech": s["frozen_frac_mech"],
        "shift_x_tol": num, "gpu_picard_x_tol": den, "gpu_mech_x_tol": mech_gpu,
        "R": R, "verdict": verdict,
        "amp_u10": (max(D[(loc, site, lv, "pert_u10_vs_base", "all")]["hspeed"]["max"] for lv in levels)
                    / (1e-6 * s["u10"]) if (loc, site, levels[0], "pert_u10_vs_base", "all") in D else None),
        "gpu_hspeed_max": max(D[(loc, site, lv, "base_vs_gpu", "all")]["hspeed"]["max"] for lv in levels),
        "u0": D[(loc, site, levels[-1], "base_vs_gpu", "all")]["u0"],
        "nonconv_cells_crate": sum(D[(loc, site, lv, "base_vs_gpu", "nonconv")]["hspeed"]["n"] for lv in levels),
        "note": ("ошибка переноса механизмов: base_vs_gpu на mech-клетках > 1x допуска; " if mech_err else "")
                + ("контроль" if site == "lee_bowl" else ""),
    })

res = {"version": 1, "runs": runs, "diffs": diffs, "fields": fields}
tmp = out_path + ".tmp"
json.dump(res, open(tmp, "w"), ensure_ascii=False)
os.replace(tmp, out_path)
print("fields", len(fields), "diffs", len(diffs), "runs", len(runs))
