#!/usr/bin/env python3
"""SPF-1 п.2: сдвиг элементов крыла в кабинном кадре при тангаже киля theta(V).
Берёт геометрию и камеру из tools/research/pilot_view/cockpit_view.py (stdlib), подставляя
theta из замера jitter_theta.gd (out/jitter.json, раздел calm). Камера = _level_head: тангаж
крыла отброшен, взгляд вниз cockpit.look_down_deg. Запуск: python3 theta_view.py [--json out]"""
import json, math, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "pilot_view"))
import cockpit_view as cv  # noqa: E402

cfg = cv.load()
calm = json.load(open(os.path.join(HERE, "out", "jitter.json")))["calm"]
FOV_V = cfg["camera"]["fov_deg"]
ASPECT = 16 / 9
rows = []
for c in calm:
    w = c["wing"]
    if abs(c["v_kmh"] - c["v_target_kmh"]) > 3:  # sport 30 км/ч недостижим (пикирование)
        continue
    cfg["trim"]["trim_pitch_deg"][w] = c["theta_deg"]
    r = cv.scene(cfg, w, aspect=ASPECT)
    bc = r["basebar_center_cam_m"]
    # возвышение над осью камеры, ° (+ вверх) для центра штанги, и ближайшей точки троса
    elev_bar = math.degrees(math.atan2(bc[1], bc[2])) if bc[2] > 0 else None
    rows.append({
        "wing": w, "v_kmh": round(c["v_kmh"], 1), "theta_deg": round(c["theta_deg"], 2),
        "gamma_deg": round(c["gamma_deg"], 2), "alpha_deg": round(c["alpha_deg"], 2),
        "sink_ms": round(c["sink_ms"], 2),
        "keel_above_horizon_deg": round(c["theta_deg"], 2),
        "bar_center_from_axis_deg": r["basebar_center_deg"],
        "wire_corner_from_axis_deg": r["nosewire_corner_deg"],
        "wire_nose_from_axis_deg": r["nosewire_nose_deg"],
        "wire_closest_from_axis_deg": r["nosewire_closest_deg"],
        "wire_min_vfov_deg": r["wire_vfov_deg"], "bar_min_vfov_deg": r["bar_vfov_deg"],
        "bar_in_frame_fov90": r["bar_vfov_deg"] <= FOV_V,
        "wire_in_frame_fov90": r["wire_vfov_deg"] <= FOV_V,
        "bar_center_cam_m": r["basebar_center_cam_m"],
    })
print(json.dumps(rows, ensure_ascii=False, indent=1))
if "--json" in sys.argv:
    json.dump(rows, open(sys.argv[sys.argv.index("--json") + 1], "w"), ensure_ascii=False, indent=1)
