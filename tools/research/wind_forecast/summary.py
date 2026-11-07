"""out/before.json → summary.json + таблицы Markdown (stdout). python3 -I summary.py"""
import json, os
H = os.path.dirname(os.path.abspath(__file__))
rows = json.load(open(os.path.join(H, "out", "before.json")))["rows"]
by = {}
for r in rows:
    by.setdefault(r["name"], {})[r["mode"]] = r
places, load = [], []
for n, m in by.items():
    s, i = m.get("start", {}), m.get("inflow", {})
    if "error" in s or "error" in i or not s or not i:
        continue
    places.append({"place": n, "start": f'{s["place"]}/{s["site"]}', "wind_from_deg": s["from"], "u10_menu": s["wind_ms"],
        "u_start10_start": round(s["u_start10"], 3), "k_start": round(s["k_final"], 4), "passes_start": s["passes_run"],
        "u_start10_inflow": round(i["u_start10"], 3), "umax_100m_start": round(s["umax_100"], 2), "umax_100m_inflow": round(i["umax_100"], 2),
        "k_log_start": s["k_log"], "start_msl": round(s["start"]["h_msl"], 1)})
    load.append({"place": n, "load_s_start": round(s["ready_s"], 1), "load_s_inflow": round(i["ready_s"], 1), "passes_start": s["passes_run"], "passes_inflow": i["passes_run"]})
json.dump({"places": places, "load": load, "note": "Rust dp-air (Formula, детерминированный режим), замок CPU = 1 ядро; U — mean на 10 м над землёй старта"}, open(os.path.join(H, "summary.json"), "w"), ensure_ascii=False, indent=1)
print("| место | меню м/с | U10 start | k | проходов | U10 inflow | inflow/start | max100 start | max100 inflow |\n|---|---|---|---|---|---|---|---|---|")
for p in places:
    print(f'| {p["place"]} | {p["u10_menu"]} | {p["u_start10_start"]} | {p["k_start"]} | {p["passes_start"]} | {p["u_start10_inflow"]} | {p["u_start10_inflow"]/max(p["u_start10_start"],1e-9):.2f} | {p["umax_100m_start"]} | {p["umax_100m_inflow"]} |')
print("\n| место | загрузка start, с | inflow, с | отношение |\n|---|---|---|---|")
for l in load:
    print(f'| {l["place"]} | {l["load_s_start"]} | {l["load_s_inflow"]} | {l["load_s_start"]/l["load_s_inflow"]:.2f} |')
