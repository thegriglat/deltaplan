#!/usr/bin/env python3
"""Сводка data/before_*.json → summary_tables.md (таблицы для README)."""
import json, glob, math, csv, statistics as st, os
here = os.path.dirname(os.path.abspath(__file__))
out = []
P = out.append
files = sorted(glob.glob(here + "/data/before_*.json"))
D = {os.path.basename(f)[7:-5]: json.load(open(f)) for f in files}
P("## Горизонт (+300 м над землёй, до %s км)\n" % list(D.values())[0]["range_km"])
P("| место | rough raw° | rough игра° | rough рендер° | ratio | недобор p50° | p90° | max° | из них сетка 100 м p50° | источник p50° | LOD p50° | доля фона |")
P("|---|---|---|---|---|---|---|---|---|---|---|---|")
for k, d in D.items():
    h = d["horizon"]
    P("| %s | %.3f | %.3f | %.3f | %.2f | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f | %.2f |" % (k, h["rough_raw_deg"], h["rough_game_deg"], h["rough_render_deg"], h["rough_ratio"],
      h["deficit_deg_p50"], h["deficit_deg_p90"], h["deficit_deg_max"], h["deficit_grid100_deg_p50"], h["deficit_source_deg_p50"], h["deficit_lod_deg_p50"], h["far_layer_share"]))
P("\n## Названные вершины (высота в диске вокруг пика, м)\n")
P("| место | вершина | d, км | слой | raw | сетка 100 м | игра | рендер | недобор, м | град. | потери: сетка / источник / LOD, м | шаг вершин, м |")
P("|---|---|---|---|---|---|---|---|---|---|---|---|")
for k, d in D.items():
    for p in d["peaks"]:
        if p["name"].startswith("sil_"): continue
        P("| %s | %s | %.1f | %s | %.0f | %.0f | %.0f | %.0f | %.1f | %.2f | %.1f / %.1f / %.1f | %.0f |" % (k, p["name"], p["dist_km"], p["layer"], p["h_raw"], p["h_raw100"], p["h_game"], p["h_render"],
          p["h_raw"]-p["h_render"], p["deficit_deg"], p["loss_grid_m"], p["loss_source_m"], p["loss_lod_m"], p["vertex_step_m"]))
P("\n## Вершины силуэта (медиана по месту, по слою)\n")
P("| место | слой | n | d медиана, км | недобор p50, м | град. p50 | сетка | источник | LOD |")
P("|---|---|---|---|---|---|---|---|---|")
for k, d in D.items():
    for ly in ("detail", "far"):
        ps = [p for p in d["peaks"] if p["name"].startswith("sil_") and p["layer"] == ly]
        if not ps: continue
        m = lambda key: st.median(p[key] for p in ps)
        P("| %s | %s | %d | %.1f | %.1f | %.3f | %.1f | %.1f | %.1f |" % (k, ly, len(ps), m("dist_km"), st.median(p["h_raw"]-p["h_render"] for p in ps), m("deficit_deg"), m("loss_grid_m"), m("loss_source_m"), m("loss_lod_m")))
P("\n## Гребни: кривизна игра/сырое (curv_ratio) и просадка p50 / p90, м\n")
P("| место | слой | полоса, км | выше леса: n / curv / drop p50 / p90 / drop рендера p50 | лес: n / curv / drop p50 / p90 / drop рендера p50 |")
P("|---|---|---|---|---|")
f = lambda c: "%d / %s / %s / %s / %s" % (c["n"], *[("%.2f" % c[x]) if c[x] is not None else "–" for x in ("curv_ratio", "drop_m_p50", "drop_m_p90", "drop_render_m_p50")])
for k, d in D.items():
    by = {}
    for c in d["crests"]:
        by.setdefault((c["layer"], tuple(c["band_km"])), {})[c["zone"]] = c
    for (ly, b), z in by.items():
        P("| %s | %s | %g–%g | %s | %s |" % (k, ly, b[0], b[1], f(z["above_forest"]), f(z["forest"])))
P("\n## Память (VRAM, МБ)\n")
m = list(D.values())[0]["memory"]
P("| детальный слой | высоты RF+мипы | классы R8 | маска 10 м RG8 | детальный итого | + фон (%.1f) |" % m["far_layer_mb"])
P("|---|---|---|---|---|---|")
for r in m["rows"]:
    P("| %g км | %.1f | %.1f | %.1f | %.1f | %.1f |" % (r["detail_km"], r["heights_rf_mips_mb"], r["classes_r8_mb"], r["mask10_rg8_mb"], r["detail_total_mb"], r["detail_total_mb"] + m["far_layer_mb"]))
open(here + "/summary_tables.md", "w").write("\n".join(out) + "\n")
print("\n".join(out))

# ---- дополнение: горизонт по профилю CSV, раздельно детальный/фон; Эверест на силуэте
def prof(tag):
    rows = list(csv.DictReader(open(here + "/data/before_%s_profile.csv" % tag)))
    return [{k: float(v) for k, v in r.items()} for r in rows]
def pct(a, p):
    a = sorted(a); return a[min(int(p * len(a)), len(a) - 1)] if a else float("nan")
out2 = ["\n## Горизонт по слою точки силуэта в отрисовке (граница 20 км от старта)\n",
        "| место | группа | доля азимутов | недобор p50° | p90° | сетка p50° | источник p50° | LOD p50° |", "|---|---|---|---|---|---|---|---|"]
for k, d in D.items():
    pr = prof(k)
    for name, sel in (("до 20 км (детальный)", lambda r: r["dist_render_km"] <= 20), ("дальше 20 км (фон)", lambda r: r["dist_render_km"] > 20)):
        g = [r for r in pr if sel(r)]
        if not g: continue
        out2.append("| %s | %s | %.2f | %.3f | %.3f | %.3f | %.3f | %.3f |" % (k, name, len(g) / len(pr), pct([r["raw30_deg"] - r["render_deg"] for r in g], .5), pct([r["raw30_deg"] - r["render_deg"] for r in g], .9),
            pct([r["raw30_deg"] - r["raw100_deg"] for r in g], .5), pct([r["raw100_deg"] - r["game_deg"] for r in g], .5), pct([r["game_deg"] - r["render_deg"] for r in g], .5)))
out2 += ["\n## Эверест на силуэте (азимут на пик ±0,5°)\n", "| место | азимут° | d до пика, км | угол сырой° | угол рендера° | недобор° | расстояние точки горизонта (сырой) км | (рендер) км | Эверест на горизонте |", "|---|---|---|---|---|---|---|---|---|"]
for k, d in D.items():
    ev = [p for p in d["peaks"] if p["name"] == "Everest"]
    if not ev: continue
    p = ev[0]
    dx = (p["lon"] - d["lon"]) * 111.195 * math.cos(math.radians(d["lat"])); dy = (p["lat"] - d["lat"]) * 111.195
    az = math.degrees(math.atan2(dx, dy)) % 360
    pr = prof(k)
    g = [r for r in pr if abs(((r["az_deg"] - az + 180) % 360) - 180) <= 0.5]
    best = max(g, key=lambda r: r["raw30_deg"])
    on = abs(best["dist_raw_km"] - p["dist_km"]) < 1.5
    out2.append("| %s | %.1f | %.1f | %.3f | %.3f | %.3f | %.1f | %.1f | %s |" % (k, az, p["dist_km"], best["raw30_deg"], best["render_deg"], best["raw30_deg"] - best["render_deg"], best["dist_raw_km"], best["dist_render_km"], "да" if on else "нет (закрыт)"))
open(here + "/summary_tables.md", "a").write("\n".join(out2) + "\n")
print("\n".join(out2))
