#!/usr/bin/env python3
"""MLK-3: «до» (data/before_*.json — MLK-1, dh v1) против «после» (data/after_*.json — dh К2 v2) → compare_tables.md
и числа приёмки (stdout, JSON последней строкой). Швы и dh меша «до» — быстрый прогон зонда v2 с --dh=v1 --quick=1
(data/before_mesh_*.json), «после» — раздел mesh в after_*.json.
«После» для меша — data/after_mesh_*.json (быстрый прогон v2), если есть, иначе раздел mesh в after_*.json.
Запуск: python3 -I tools/research/mountain_look/compare.py"""
import csv, glob, json, os

here = os.path.dirname(os.path.abspath(__file__))
data = os.path.join(here, "data")


def load(prefix):
    out = {}
    for f in sorted(glob.glob(os.path.join(data, prefix + "_*.json"))):
        tag = os.path.basename(f)[len(prefix) + 1:-5]
        if prefix in ("before", "after") and tag.startswith("mesh_"):
            continue
        out[tag] = json.load(open(f))
    return out


B, A, BM, AM = load("before"), load("after"), load("before_mesh"), load("after_mesh")
EV = ["Everest", "Lhotse", "Nuptse", "AmaDablam", "Makalu"]
HIGH = ["everest_namche", "everest_gokyo", "everest_menu", "elbrus_cheget", "elbrus_menu", "montblanc_chamonix", "dombay"]
lines = []
P = lines.append
res = {}

P("## Названные вершины: недобор (сырой − отрисовка), м — до / после (из него шаг LOD: игра − отрисовка)\n")
P("| место | вершина | d, км | слой | шаг вершин, м | недобор до | после | LOD до | LOD после |")
P("|---|---|---|---|---|---|---|---|---|")
ev_b = ev_a = lod_b = lod_a = 0.0
for tag in sorted(set(B) & set(A)):
    pa = {p["name"]: p for p in A[tag]["peaks"] if not p["name"].startswith("sil_")}
    for p in B[tag]["peaks"]:
        if p["name"].startswith("sil_") or p["name"] not in pa:
            continue
        q = pa[p["name"]]
        db, da = p["h_raw"] - p["h_render"], q["h_raw"] - q["h_render"]
        lb, la = p["h_game"] - p["h_render"], q["h_game"] - q["h_render"]
        P("| %s | %s | %.1f | %s | %.0f | %.1f | %.1f | %.1f | %.1f |" % (tag, p["name"], p["dist_km"], p["layer"], p["vertex_step_m"], db, da, lb, la))
        if tag.startswith("everest") and p["name"] in EV:
            ev_b += db; ev_a += da; lod_b += lb; lod_a += la
res["peak_deficit_m_before_after"] = {"everest_group_sum_before": round(ev_b, 1), "everest_group_sum_after": round(ev_a, 1),
    "ratio": round(ev_a / ev_b, 3) if ev_b else None, "lod_part_sum_before": round(lod_b, 1), "lod_part_sum_after": round(lod_a, 1)}

P("\n## Горизонт: шероховатость отрисовки / сырой (rough_ratio), недобор p50 / max, °\n")
P("| место | ratio до | после | rough рендер до | после | недобор p50 до | после | max до | после |")
P("|---|---|---|---|---|---|---|---|---|")
rr = {}
for tag in sorted(set(B) & set(A)):
    hb, ha = B[tag]["horizon"], A[tag]["horizon"]
    P("| %s | %.3f | %.3f | %.4f | %.4f | %.3f | %.3f | %.3f | %.3f |" % (tag, hb["rough_ratio"], ha["rough_ratio"], hb["rough_render_deg"], ha["rough_render_deg"],
      hb["deficit_deg_p50"], ha["deficit_deg_p50"], hb["deficit_deg_max"], ha["deficit_deg_max"]))
    rr[tag] = [round(hb["rough_ratio"], 3), round(ha["rough_ratio"], 3)]
res["rough_ratio_before_after"] = rr


def profile(prefix, tag):
    f = os.path.join(data, "%s_%s_profile.csv" % (prefix, tag))
    if not os.path.exists(f):
        return None
    return [float(r["render_deg"]) for r in csv.DictReader(open(f))], [float(r["raw30_deg"]) for r in csv.DictReader(open(f))]


if "ongudai" in A and "ongudai" in B:
    hb, ha = B["ongudai"]["horizon"], A["ongudai"]["horizon"]
    ch = {"rough_render_change": round(ha["rough_render_deg"] / hb["rough_render_deg"] - 1.0, 4)}
    pb, pa = profile("before", "ongudai"), profile("after", "ongudai")
    if pb and pa:
        d = [abs(x - y) for x, y in zip(pa[0], pb[0])]
        ch["mean_abs_change_deg"] = round(sum(d) / len(d), 4)
        ch["max_abs_change_deg"] = round(max(d), 4)
        # относительно недобора «до» (сырой − отрисовка) по азимутам: какая доля прежнего расхождения изменилась
        defb = [abs(r - x) for x, r in zip(pb[0], pb[1])]
        ch["change_vs_deficit_before"] = round(sum(d) / max(sum(defb), 1e-9), 4)
    res["ongudai_horizon_change"] = ch

P("\n## Меш: dh вершин, «надувание» долин (вогнутые места дальше 3 км), швы LOD и слоёв — до (v1) / после (v2)\n")
P("| место | слой | dh p90 до/после, м | dh max | средний dh дальше 3 км | долины: средний dh до / после | щели LOD p99, м | щели не закрыты юбкой, шт | край слоя: скачок p90 / max, м; щелей |")
P("|---|---|---|---|---|---|---|---|---|")
vmax = None
seams = {}
for tag in sorted(A):
    ma = AM.get(tag, {}).get("mesh") or A[tag].get("mesh")
    mb = BM.get(tag, {}).get("mesh")
    if not ma:
        continue
    lb = {l["id"]: l for l in (mb or {}).get("layers", [])}
    for l in ma["layers"]:
        b = lb.get(l["id"], {})
        g = lambda d, k: ("%.1f" % d[k]) if d.get(k) is not None else "–"
        sa, sb = ma.get("layer_seam", {}), (mb or {}).get("layer_seam", {})
        seam = ("%s / %s; %s → %s / %s; %s" % (g(sb, "jump_abs_m_p90"), g(sb, "jump_abs_m_max"), sb.get("open_over_skirt", "–"),
            g(sa, "jump_abs_m_p90"), g(sa, "jump_abs_m_max"), sa.get("open_over_skirt", "–"))) if l["id"] == "detail" and sa else ""
        P("| %s | %s | %s / %s | %s / %s | %s / %s | %s / %s | %s / %s | %s / %s | %s |" % (tag, l["id"], g(b, "dh_m_p90"), g(l, "dh_m_p90"), g(b, "dh_m_max"), g(l, "dh_m_max"),
          g(b, "dh_far_mean_m"), g(l, "dh_far_mean_m"), g(b, "valley_dh_mean_m"), g(l, "valley_dh_mean_m"), g(b, "lod_gap_m_p99"), g(l, "lod_gap_m_p99"),
          b.get("lod_gap_over_skirt", "–"), l["lod_gap_over_skirt"], seam))
        if l.get("valley_dh_mean_m") is not None:
            vmax = l["valley_dh_mean_m"] if vmax is None else max(vmax, l["valley_dh_mean_m"])
        seams.setdefault(tag, {})[l["id"]] = {"lod_gap_p99": [b.get("lod_gap_m_p99"), l["lod_gap_m_p99"]],
            "over_skirt": [b.get("lod_gap_over_skirt"), l["lod_gap_over_skirt"]]}
    if ma.get("layer_seam"):
        seams[tag]["layer_jump_p90_max"] = [[(mb or {}).get("layer_seam", {}).get("jump_abs_m_p90"), (mb or {}).get("layer_seam", {}).get("jump_abs_m_max")],
            [ma["layer_seam"].get("jump_abs_m_p90"), ma["layer_seam"].get("jump_abs_m_max")]]
        seams[tag]["layer_open_cracks"] = [(mb or {}).get("layer_seam", {}).get("open_over_skirt"), ma["layer_seam"].get("open_over_skirt")]
res["valley_inflation_m"] = vmax
res["seams"] = seams

open(os.path.join(here, "compare_tables.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
print(json.dumps(res, ensure_ascii=False))
