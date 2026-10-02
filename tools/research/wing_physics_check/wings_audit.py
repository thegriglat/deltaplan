#!/usr/bin/env python3
"""WPC-1: паспорт против модели. Читает замеры модели (out/model_runs.jsonl от wings_audit_run.gd),
конфиги крыльев и паспорта (tools/research/data/wing_passports/), пишет:
  out/wings_audit.csv   — контракт К4 v2 (docs/contracts/wing-physics-check.md)
  out/summary.json      — сводка: группы, расхождения > 10 %, путевая против 6 м/с, отрыв
  out/penetration_est.csv, out/takeoff.csv — подробные таблицы
  out/fig_*.png         — картинки (если есть matplotlib)
Запуск: python3 tools/research/wing_physics_check/wings_audit.py (из корня репозитория).

Приведение паспортных скоростей к массе случая: V ∝ √M (тот же угол атаки, ρ = 1,225):
  DHV Vmin/Vmax (VG 0)  — при середине «Startgewicht» карточки;
  точки поляр Wills Wing — при 1,3·(мин. масса пилота) + масса крыла (правило страницы WW);
  прочие скорости/снижения производителя — при середине hook-in + масса крыла (масса не указана);
  «при максимальной загрузке» — при макс. hook-in + масса крыла. Верхние границы («or less», «<») не берём.
Качество от массы не зависит.
"""
import csv
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
PASS = ROOT / "tools/research/data/wing_passports"
G = 9.80665
WIND_MS = 6.0
TAKEOFF_WINDS = [0, 3, 6, 10]
QUANT = ["stall", "trim", "full_pull", "min_sink", "min_sink_speed", "best_glide",
         "best_glide_speed", "sink_at_80"]
UNIT = {"min_sink": "m/s", "sink_at_80": "m/s", "best_glide": "1"}
HEADER = ("wing,group,mass_case,pilot_mass_kg,total_mass_kg,src_key,quantity,unit,model,config,"
          "passport,passport_src,diff_pct").split(",")

# Крылья без ключа паспорта в _doc: числа — из источников, названных в _doc их конфигов.
# m_kg — полная масса, к которой относится число (None — середина hook-in + крыло).
MANUAL = {
    "sport": {"src": "Moyes Litespeed RS 4 (moyes.com.au, по _doc конфига)", "hook": (74, 104), "wing": 34.5,
              "trim": (36.0, None), "min_sink": (0.9, None), "min_sink_speed": (40.0, None),
              "best_glide": (15.0, None)},
    "training": {"src": "Wills Wing Falcon (willswing.com polar data; Falcon 4 170)", "hook": (63.5, 99.8),
                 "wing": 22.2, "min_sink": (1.092, 1.3 * 63.5 + 22.2),
                 "min_sink_speed": (30.58, 1.3 * 63.5 + 22.2), "ww_v2": (54.72, 2.692, 1.3 * 63.5 + 22.2)},
    "atlas": {"src": "«Крылья Родины» (Кареткин, Рябцев, Бабкин): срыв 29–30 при пилоте ≤ 70 кг, "
                     "макс. 72, снижение 1 м/с", "hook": (65, 95), "wing": 25.0,
              "stall": (29.5, 70 + 25.0), "full_pull": (72.0, None), "min_sink": (1.0, None)},
    "slavutich_ut": {"src": "Славутич-УТ (delta-nsk.ucoz.ru, ru.wikipedia): качество 6", "hook": (60, 90),
                     "wing": 25.0, "best_glide": (6.0, None)},
    "combat": {"src": "Aeros Combat GT 13.2 (aeros.com.ua/combat_gt): Vmin 29–31 при рекоменд. массе",
               "hook": (70, 110), "wing": 35.0, "stall": (30.0, None)},
    "target": {"src": "Aeros Target 16 (en.wikipedia Aeros_Target, delta-nsk.ucoz.ru): качество 7",
               "hook": (60, 100), "wing": 24.75, "best_glide": (7.0, None)},
    "apogee": {"src": "Апогей (со слов пилота 28.09.2026): качество 6–7", "hook": (50, 100), "wing": 25.0,
               "best_glide": (6.5, None)},
}
# Точки поляр Wills Wing по семействам (polars_points.json) для крыльев с ключом WW.
WW_POLAR_FAMILY = {"ww_eagle": "Eagle", "ww_ultra_sport": "Ultra Sport", "ww_super_sport": "Super Sport",
                   "ww_u2": "U2", "ww_fusion": "Fusion", "ww_talon": "Talon"}


def load_jsonl(p):
    out = {}
    for line in p.read_text().splitlines():
        if line.strip():
            r = json.loads(line)
            out[r["key"]] = r
    return out


def polar_interp(pts, v):
    for i in range(1, len(pts)):
        if v <= pts[i][0]:
            t = (v - pts[i - 1][0]) / (pts[i][0] - pts[i - 1][0])
            return pts[i - 1][1] + t * (pts[i][1] - pts[i - 1][1])
    return None


def sweep_interp(sweep, v, field="sink_ms"):
    s = sorted([x for x in sweep if not x["stalled"]], key=lambda x: x["v_kmh"])
    for i in range(1, len(s)):
        if s[i - 1]["v_kmh"] <= v <= s[i]["v_kmh"]:
            t = (v - s[i - 1]["v_kmh"]) / (s[i]["v_kmh"] - s[i - 1]["v_kmh"])
            return s[i - 1][field] + t * (s[i][field] - s[i - 1][field])
    return None


def passport_for(wid, cfg, merged, polars):
    """{quantity: (value, M_kg or None, src_text)} + src_key."""
    res = {}
    keys = re.findall(r"«([^»]*\|[^»]*)»", cfg["_doc"])
    if wid in MANUAL:
        man = MANUAL[wid]
        mid = 0.5 * (man["hook"][0] + man["hook"][1]) + man["wing"]
        for q in QUANT + ["ww_v2"]:
            if q in man:
                val = man[q]
                if q == "ww_v2":
                    res[q] = (val[0], val[1], val[2], man["src"])
                else:
                    res[q] = (val[0], val[1] if val[1] else mid, man["src"])
        return res, ""
    if not keys:
        return res, ""
    prim = keys[0]
    fam = "|".join(prim.split("|")[:3])
    recs = [merged[k] for k in keys if k in merged and "|".join(k.split("|")[:3]) == fam]
    if prim in merged:
        recs = [merged[prim]] + [r for r in recs if r["key"] != prim]
    if not recs:
        return res, prim
    p0 = recs[0]["fields"]

    def fv(f, k):
        return f[k]["value"] if k in f else None

    def hook_mid(f):
        lo, hi = fv(f, "pilot_mass_min_kg"), fv(f, "pilot_mass_max_kg")
        wm = fv(f, "wing_mass_kg") or cfg["wing_mass_kg"]
        if lo is None or hi is None:
            lo, hi = cfg["pilot_mass_min_kg"], cfg["pilot_mass_max_kg"]
        return 0.5 * (lo + hi) + wm, hi + wm

    def take(q, field, rule):
        for r in recs:
            f = r["fields"]
            if field not in f:
                continue
            srcs = f[field]["sources"]
            quotes = " / ".join(s["quote"] for s in srcs)
            ql = quotes.lower()
            if "or less" in ql or "<" in quotes:
                continue  # верхняя граница, не измерение
            if field == "vms_kmh" and all("placard" in s["file"] for s in srcs):
                continue  # плакаты WW: Vms разобран неоднозначно (25/40)
            if field == "trim_speed_kmh" and "maximum" in ql:
                continue  # Sting 3: «maximum or steady state speed» — не трим
            if field == "best_glide" and "v best glide" in ql:
                continue  # Bautek: это скорость, а не качество
            val = abs(f[field]["value"])
            mid, mmax = hook_mid(f)
            if rule == "dhv":
                tlo, thi = fv(f, "takeoff_mass_min_kg"), fv(f, "takeoff_mass_max_kg")
                m = 0.5 * (tlo + thi) if tlo and thi else mid
                note = f"DHV {field} {val:g} при {m:.0f} кг"
            elif rule == "none":
                m = None
                note = f"{field} {val:g}"
            else:
                m = mmax if "maximum" in ql else mid
                note = f"{field} {val:g} при {m:.0f} кг"
            other = "" if r["key"] == prim else f" (размер {r['key'].split('|')[3]})"
            res[q] = (val, m, f"{r['key']}{other}: {note}; «{quotes[:90]}»")
            return True
        return False

    take("stall", "vmin_vg0_kmh", "dhv") or take("stall", "stall_speed_kmh", "maker")
    take("trim", "trim_speed_kmh", "maker")
    take("full_pull", "vmax_vg0_kmh", "dhv") or take("full_pull", "vmax_vg100_kmh", "dhv")
    take("min_sink", "min_sink_ms", "maker")
    take("min_sink_speed", "vms_kmh", "maker")
    take("best_glide", "best_glide", "none")
    take("best_glide_speed", "best_glide_speed_kmh", "maker")
    # особые разборы цитат
    for r in recs:
        f = r["fields"]
        if "min_sink_ms" in f and "@" in f["min_sink_ms"]["sources"][0]["quote"] and "min_sink_speed" not in res:
            mm = re.search(r"@\s*([\d.]+)\s*km/h", f["min_sink_ms"]["sources"][0]["quote"])
            if mm:
                res["min_sink_speed"] = (float(mm.group(1)), hook_mid(f)[0], f"{r['key']}: «{f['min_sink_ms']['sources'][0]['quote']}»")
        if "best_glide" in f and "v best glide" in f["best_glide"]["sources"][0]["quote"].lower() \
                and "best_glide_speed" not in res:
            v = f["best_glide"]["value"] * 1.609344
            res["best_glide_speed"] = (v, hook_mid(f)[0], f"{r['key']}: «{f['best_glide']['sources'][0]['quote']}» (mph)")
    if wid in WW_POLAR_FAMILY:
        famname = WW_POLAR_FAMILY[wid]
        pts = [p for p in polars["polar_points"] if p["family"] == famname]
        pmin = fv(p0, "pilot_mass_min_kg") or cfg["pilot_mass_min_kg"]
        m = 1.3 * pmin + (fv(p0, "wing_mass_kg") or cfg["wing_mass_kg"])
        src = f"Wills Wing polar data {famname}: {pts[0]['quote']} при 1,3·{pmin:.0f}+крыло = {m:.0f} кг"
        res["min_sink"] = (pts[0]["sink_ms"], m, src)
        res.setdefault("min_sink_speed", (pts[0]["speed_kmh"], m, src))
        res["ww_v2"] = (pts[1]["speed_kmh"], pts[1]["sink_ms"], m, f"WW polar {famname}: {pts[1]['quote']}")
    return res, prim


def scaled(val, m_src, m_case, q):
    if m_src is None or q == "best_glide":
        return val
    return val * math.sqrt(m_case / m_src)


def fmt(x, nd=3):
    return "" if x is None else f"{x:.{nd}f}"


def main():
    runs = load_jsonl(OUT / "model_runs.jsonl")
    merged = {r["key"]: r for r in json.loads((PASS / "wings_merged.json").read_text())}
    polars = json.loads((PASS / "polars_points.json").read_text())
    sites = json.loads((OUT / "start_sites.json").read_text())
    top_site = max(sites, key=lambda s: s["msl_m"])
    flight = json.loads((ROOT / "configs/flight.json").read_text())
    ad = flight["air_density"]
    pilot = json.loads((ROOT / "configs/pilot.json").read_text())
    rows, summ, pen_rows, to_rows, v2_rows = [], [], [], [], []
    wings = sorted({k.split("|")[0] for k in runs})
    for wid in wings:
        cfg = json.loads((ROOT / f"configs/wings/{wid}.json").read_text())
        pp, src_key = passport_for(wid, cfg, merged, polars)
        for mc in ("ref", "pilot85"):
            r = runs.get(f"{wid}|{mc}")
            if r is None:
                continue
            M, Mref = r["total_mass_kg"], r["mass_ref_kg"]
            s = math.sqrt(M / Mref)
            pts = cfg["polar"]["points_kmh_ms"]
            ref = cfg["reference"]
            s80 = polar_interp(pts, 80.0 / s)
            model = {
                "stall": r["stall_kmh"], "trim": r["trim"]["v_kmh"], "full_pull": r["full_pull"]["v_kmh"],
                "min_sink": r["min_sink"]["sink_ms"], "min_sink_speed": r["min_sink"]["v_kmh"],
                "best_glide": r["best_glide"]["ld"], "best_glide_speed": r["best_glide"]["v_kmh"],
                "sink_at_80": r["at_80"].get("sink_ms"),
            }
            conf = {
                "stall": pts[0][0] * s, "trim": cfg["trim_speed_kmh"] * s,
                "full_pull": cfg["full_pull_speed_kmh"] * s, "min_sink": ref["min_sink_ms"] * s,
                "min_sink_speed": ref["min_sink_speed_kmh"] * s, "best_glide": ref["best_glide"],
                "best_glide_speed": ref["best_glide_speed_kmh"] * s,
                "sink_at_80": (s80 * s) if s80 is not None else None,
            }
            # высота старта (самый высокий старт — худший случай для отрыва)
            rho_top = ad["sea_level_kgm3"] * math.exp(-top_site["msl_m"] / ad["scale_height_m"])
            k_alt = math.sqrt(ad["polar_ref_kgm3"] / rho_top)
            model["stall_start_alt"] = r["stall_kmh"] * k_alt
            conf["stall_start_alt"] = conf["stall"] * k_alt
            for w in TAKEOFF_WINDS:
                model[f"takeoff_gs_w{w}"] = model["stall_start_alt"] - 3.6 * w
                conf[f"takeoff_gs_w{w}"] = conf["stall_start_alt"] - 3.6 * w
            pas = {}
            for q in QUANT:
                if q in pp:
                    val, msrc, txt = pp[q]
                    pas[q] = (scaled(val, msrc, M, q), txt)
            if "stall" in pas:
                pas["stall_start_alt"] = (pas["stall"][0] * k_alt, pas["stall"][1])
                for w in TAKEOFF_WINDS:
                    pas[f"takeoff_gs_w{w}"] = (pas["stall_start_alt"][0] - 3.6 * w, pas["stall"][1])
            alt_note = f"ρ на {top_site['location']}/{top_site['start']} {top_site['msl_m']:.0f} м = {rho_top:.3f}"
            for q in QUANT + ["stall_start_alt"] + [f"takeoff_gs_w{w}" for w in TAKEOFF_WINDS]:
                mv, cv = model.get(q), conf.get(q)
                pv, ptxt = pas.get(q, (None, ""))
                if q.startswith("takeoff") or q == "stall_start_alt":
                    ptxt = alt_note + ("; " + ptxt if ptxt else "")
                diff = None
                floor = 0.05 if q in ("min_sink", "sink_at_80", "best_glide") else 1.0
                if pv is not None and mv is not None and abs(pv) >= floor:
                    diff = (mv - pv) / pv * 100.0
                rows.append({
                    "wing": wid, "group": cfg["group"], "mass_case": mc, "pilot_mass_kg": fmt(r["pilot_mass_kg"], 1),
                    "total_mass_kg": fmt(M, 1), "src_key": src_key, "quantity": q,
                    "unit": UNIT.get(q, "km/h"), "model": fmt(mv), "config": fmt(cv), "passport": fmt(pv),
                    "passport_src": ptxt, "diff_pct": fmt(diff, 1),
                })
            # путевая против 6 м/с: на уровне моря и на высотах 1000/1500/2000 (замер модели)
            def gs(meas):
                v = meas["v_kmh"] / 3.6
                cosg = math.sqrt(max(1 - (meas["sink_ms"] / v) ** 2, 0))
                return v * cosg - WIND_MS
            pen = {"wing": wid, "group": cfg["group"], "mass_case": mc, "total_mass_kg": round(M, 1),
                   "trim_kmh": round(model["trim"], 1), "full_pull_kmh": round(model["full_pull"], 1),
                   "gs_trim_0m": round(gs(r["trim"]), 2), "gs_pull_0m": round(gs(r["full_pull"]), 2)}
            for a in r["altitude"]:
                if "trim" in a:
                    h = int(a["alt_m"])
                    pen[f"gs_trim_{h}m"] = round(gs(a["trim"]), 2)
                    pen[f"gs_pull_{h}m"] = round(gs(a["full_pull"]), 2)
                    pen[f"trim_{h}m_kmh"] = round(a["trim"]["v_kmh"], 2)
                    pen[f"trim_{h}m_expected_kmh"] = round(model["trim"] * math.sqrt(1.225 / a["rho"]), 2)
            # «на себя» по паспорту DHV (если есть)
            if "full_pull" in pas:
                pen["passport_full_pull_kmh"] = round(pas["full_pull"][0], 1)
            pen_rows.append(pen)
            # отрыв: на каждом старте
            if mc == "pilot85":
                rc = pilot["run"]
                for st in [{"location": "-", "start": "sea_level", "msl_m": 0.0}] + sites:
                    rho = ad["sea_level_kgm3"] * math.exp(-st["msl_m"] / ad["scale_height_m"])
                    vs = r["stall_kmh"] * math.sqrt(1.225 / rho)
                    row = {"wing": wid, "group": cfg["group"], "location": st["location"], "start": st["start"],
                           "msl_m": st["msl_m"], "rho": round(rho, 4), "pilot_mass_kg": r["pilot_mass_kg"],
                           "vmin_model_kmh": round(vs, 1),
                           "vmin_passport_kmh": round(pas["stall"][0] * math.sqrt(1.225 / rho), 1) if "stall" in pas else "",
                           "run_cap_noload_kmh": round(rc["speed_max_ms"] * 3.6, 1),
                           "run_cap_full_unload_kmh": round(rc["speed_max_ms"] * (1 + rc["unload_speed_bonus"]) * 3.6, 1)}
                    for w in TAKEOFF_WINDS:
                        row[f"gs_need_w{w}_kmh"] = round(vs - 3.6 * w, 1)
                        # предел бега в модели (ground_run.gd:239–242): v ≤ v0·(1 + b·разгрузка),
                        # разгрузка ≈ ((v + ветер)/Vmin)² при CL = CL_max; склон предел не поднимает
                        v0, b, vsm = rc["speed_max_ms"], rc["unload_speed_bonus"], vs / 3.6
                        v = v0
                        for _ in range(200):
                            v = v0 * (1 + b * min(1.0, ((v + w) / vsm) ** 2))
                        row[f"run_reach_w{w}_kmh"] = round(v * 3.6, 1)
                        row[f"liftoff_w{w}"] = int(v + w >= vsm - 1e-6)
                    to_rows.append(row)
            if "ww_v2" in pp:
                v2, sink2, m2, txt = pp["ww_v2"]
                v2s = v2 * math.sqrt(M / m2)
                sk = sink2 * math.sqrt(M / m2)
                msk = sweep_interp(r["sweep"], v2s)
                v2_rows.append({"wing": wid, "mass_case": mc, "v_kmh": round(v2s, 1), "passport_sink_ms": round(sk, 3),
                                "model_sink_ms": round(msk, 3) if msk else "", "src": txt})
            summ.append((wid, cfg["group"], mc, model, conf, pas))
    OUT.mkdir(exist_ok=True)
    with open(OUT / "wings_audit.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=HEADER, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    for name, data in (("penetration_est.csv", pen_rows), ("takeoff.csv", to_rows), ("ww_v2_check.csv", v2_rows)):
        if data:
            keys = list(dict.fromkeys(k for d in data for k in d))
            with open(OUT / name, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=keys, lineterminator="\n")
                w.writeheader()
                w.writerows(data)
    # сводка
    big = []
    for wid, grp, mc, model, conf, pas in summ:
        if mc != "ref":
            continue
        for q in ("stall", "trim", "full_pull", "min_sink", "best_glide", "min_sink_speed", "best_glide_speed"):
            if q in pas and model.get(q) is not None:
                d = (model[q] - pas[q][0]) / pas[q][0] * 100
                cd = (conf[q] - pas[q][0]) / pas[q][0] * 100 if conf.get(q) else None
                if abs(d) > 10:
                    big.append({"wing": wid, "group": grp, "quantity": q, "model": round(model[q], 2),
                                "config": round(conf[q], 2), "passport": round(pas[q][0], 2),
                                "diff_pct": round(d, 1), "config_diff_pct": round(cd, 1) if cd is not None else None,
                                "passport_src": pas[q][1]})
    groups = {}
    for wid, grp, mc, model, conf, pas in summ:
        if mc != "ref":
            continue
        g = groups.setdefault(grp, {"n": 0})
        g["n"] += 1
        for q in ("stall", "trim", "full_pull", "min_sink", "best_glide"):
            g.setdefault(q + "_model", []).append(model[q])
            if q in pas:
                g.setdefault(q + "_passport", []).append(pas[q][0])
                g.setdefault(q + "_diff", []).append((model[q] - pas[q][0]) / pas[q][0] * 100)
    for g in groups.values():
        for k in list(g):
            if isinstance(g[k], list):
                g[k] = [round(min(g[k]), 2), round(max(g[k]), 2), len(g[k])]
    p85 = [p for p in pen_rows if p["mass_case"] == "pilot85"]
    pen_sum = {
        "wind_ms": WIND_MS,
        "gs_trim_0m_range": [min(p["gs_trim_0m"] for p in p85), max(p["gs_trim_0m"] for p in p85)],
        "gs_pull_0m_range": [min(p["gs_pull_0m"] for p in p85), max(p["gs_pull_0m"] for p in p85)],
        "gs_trim_1500m_range": [min(p.get("gs_trim_1500m", 99) for p in p85), max(p.get("gs_trim_1500m", -99) for p in p85)],
        "gs_pull_1500m_range": [min(p.get("gs_pull_1500m", 99) for p in p85), max(p.get("gs_pull_1500m", -99) for p in p85)],
        "worst_trim_0m": min(p85, key=lambda p: p["gs_trim_0m"]),
        "max_density_trim_mismatch_pct": max(abs(p[f"trim_{h}m_kmh"] / p[f"trim_{h}m_expected_kmh"] - 1) * 100
                                             for p in p85 for h in (1000, 1500, 2000) if f"trim_{h}m_kmh" in p),
    }
    trim_cfg = []
    for wid, grp, mc, model, conf, pas in summ:
        trim_cfg.append({"wing": wid, "mass_case": mc,
                         "trim_model_vs_config_pct": round((model["trim"] / conf["trim"] - 1) * 100, 2),
                         "pull_model_vs_config_pct": round((model["full_pull"] / conf["full_pull"] - 1) * 100, 2)})
    summary = {"top_start": top_site, "groups": groups, "big_diffs_ref": big, "penetration_6ms": pen_sum,
               "trim_pull_vs_config_max_abs_pct": [max(abs(t["trim_model_vs_config_pct"]) for t in trim_cfg),
                                                   max(abs(t["pull_model_vs_config_pct"]) for t in trim_cfg)],
               "n_wings": len(wings), "n_rows": len(rows)}
    (OUT / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    print(f"крыльев {len(wings)}, строк К4 {len(rows)}, расхождений > 10 % (ref): {len(big)}")
    try:
        plots(summ, pen_rows, to_rows)
    except ImportError:
        print("нет matplotlib — картинки пропущены")


def plots(summ, pen_rows, to_rows):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    C = {"soviet": "#eb6834", "trainer": "#1baf7a", "kingpost": "#2a78d6", "topless": "#4a3aa7"}
    plt.rcParams.update({"font.size": 9, "axes.spines.top": False, "axes.spines.right": False})
    # 1. модель против паспорта, % по величинам
    qs = ["stall", "trim", "full_pull", "min_sink", "min_sink_speed", "best_glide", "best_glide_speed"]
    fig, ax = plt.subplots(figsize=(9, 4.5))
    for i, q in enumerate(qs):
        for wid, grp, mc, model, conf, pas in summ:
            if mc == "ref" and q in pas:
                d = (model[q] - pas[q][0]) / pas[q][0] * 100
                ax.scatter(i + (hash(wid) % 100 - 50) / 250, d, s=22, color=C[grp], edgecolor="white", linewidth=0.6)
                if abs(d) > 10:
                    ax.annotate(wid, (i, d), fontsize=6, xytext=(4, 0), textcoords="offset points", color="#52514e")
    ax.axhspan(-10, 10, color="#e9e8e4", zorder=0)
    ax.axhline(0, color="#52514e", lw=0.8)
    ax.set_xticks(range(len(qs)), qs)
    ax.set_ylabel("(модель − паспорт) / паспорт, %")
    ax.set_title("Модель против паспорта, эталонная масса, ρ = 1,225 (полоса ±10 %)")
    for g, c in C.items():
        ax.scatter([], [], color=c, label=g)
    ax.legend(frameon=False, ncol=4, loc="upper left")
    fig.tight_layout()
    fig.savefig(OUT / "fig_diff_pct.png", dpi=150)
    plt.close(fig)
    # 2. путевая против 6 м/с, 85 кг
    p85 = sorted([p for p in pen_rows if p["mass_case"] == "pilot85"], key=lambda p: (p["group"], p["gs_trim_0m"]))
    fig, ax = plt.subplots(figsize=(9, 8))
    y = range(len(p85))
    ax.barh([i + 0.2 for i in y], [p["gs_trim_1500m"] for p in p85], height=0.38, color="#9ec1ec", label="трим, 1500 м")
    ax.barh([i - 0.2 for i in y], [p["gs_pull_1500m"] for p in p85], height=0.38,
            color=[C[p["group"]] for p in p85], label="полностью на себя, 1500 м")
    ax.set_yticks(list(y), [f"{p['wing']} ({p['group']})" for p in p85], fontsize=6.5)
    ax.axvline(0, color="#52514e", lw=0.8)
    ax.set_xlabel("путевая скорость против ветра 6 м/с, м/с (V·cosγ − 6), пилот 85 кг")
    ax.set_title("Против 6 м/с: модель, установившийся полёт, штиль-поляра")
    ax.legend(frameon=False, loc="lower right")
    fig.tight_layout()
    fig.savefig(OUT / "fig_penetration_6ms.png", dpi=150)
    plt.close(fig)
    # 3. отрыв: нужная путевая на самом высоком старте
    top = max((r["msl_m"] for r in to_rows))
    tr = sorted([r for r in to_rows if r["msl_m"] == top], key=lambda r: r["vmin_model_kmh"])
    fig, ax = plt.subplots(figsize=(9, 8))
    for k, w in enumerate(TAKEOFF_WINDS):
        ax.scatter([r[f"gs_need_w{w}_kmh"] for r in tr], range(len(tr)), s=14,
                   color=["#2a78d6", "#1baf7a", "#eda100", "#e87ba4"][k], label=f"ветер {w} м/с")
    vp = [(i, r["vmin_passport_kmh"]) for i, r in enumerate(tr) if r["vmin_passport_kmh"] != ""]
    ax.scatter([v for _, v in vp], [i for i, _ in vp], marker="|", s=60, color="#0b0b0b", label="паспорт Vmin, штиль")
    ax.axvspan(4 * 3.6, 6 * 3.6, color="#e9e8e4", zorder=0, label="бег с крылом 4–6 м/с")
    ax.axvline(tr[0]["run_cap_noload_kmh"], color="#52514e", ls="--", lw=0.8, label="предел бега в модели (без разгрузки)")
    ax.axvline(tr[0]["run_cap_full_unload_kmh"], color="#52514e", ls=":", lw=0.8, label="предел бега (полная разгрузка)")
    ax.set_yticks(range(len(tr)), [f"{r['wing']} ({r['group']})" for r in tr], fontsize=6.5)
    ax.set_xlabel(f"нужная путевая скорость отрыва ≈ Vmin − ветер, км/ч (старт {top:.0f} м, пилот 85 кг)")
    ax.legend(frameon=False, fontsize=7, loc="lower right")
    fig.tight_layout()
    fig.savefig(OUT / "fig_takeoff.png", dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    sys.exit(main())
