#!/usr/bin/env python3
"""TK-18: числа модели trike.glb и trike_params.json для сверки со схемой пилота v2 (sketch_check.md).

Запуск: python3 tools/research/trike-model/sketch_check.py  (чистый Python, без Blender: glb разбирается напрямую).
Оси вывода — Blender/params: x вправо, y вперёд, z вверх, начало — HangPoint. glTF (x, y, z) -> (x, -z, y).
Модель — trike.glb из ветки (собрана до TK-11: трубы 60 мм, панели InstrumentPanel в glb нет).
"""
import json, math, struct, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[3]
P = json.load(open(ROOT / "tools/blender/trike_params.json"))
D = {k: v["value"] for k, v in P["dims"].items()}
GZ = P["ground_z"]
KZ = -2.12                       # ось киля (build_trike.py)
out = {}

# ---------- glb ----------
raw = (ROOT / "assets/models/trike/trike.glb").read_bytes()
jl = struct.unpack("<I", raw[12:16])[0]
J = json.loads(raw[20:20 + jl])
BIN = raw[20 + jl + 8:]
nodes = {n["name"]: n for n in J["nodes"]}


def verts(mesh_idx):
    pts = []
    for pr in J["meshes"][mesh_idx]["primitives"]:
        a = J["accessors"][pr["attributes"]["POSITION"]]
        bv = J["bufferViews"][a["bufferView"]]
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        st = bv.get("byteStride", 12)
        for i in range(a["count"]):
            x, y, z = struct.unpack_from("<fff", BIN, off + i * st)
            pts.append((x, -z, y))
    return pts


def bl(n):
    t = n.get("translation", [0, 0, 0])
    return (t[0], -t[2], t[1])


lod0 = verts(nodes["Trike_LOD0"]["mesh"])
wf, wl, wr = bl(nodes["WheelFront"]), bl(nodes["WheelRearL"]), bl(nodes["WheelRearR"])
out["model_wheelbase"] = round(wf[1] - wl[1], 3)
out["model_axle_front_y"], out["model_axle_rear_y"] = round(wf[1], 3), round(wl[1], 3)
out["model_wheel_front_d"] = round(2 * (wf[2] - min(p[2] for p in lod0 if abs(p[0]) < 0.07 and abs(p[1] - wf[1]) < 0.25)), 3)
out["model_wheel_rear_d"] = round(2 * (wl[2] - min(p[2] for p in lod0 if abs(p[0] - wl[0]) < 0.07 and abs(p[1] - wl[1]) < 0.25)), 3)
keel = [p for p in lod0 if abs(p[0]) < 0.035 and -0.1 < p[1] < 0.5 and -2.2 < p[2] < -2.0]
out["model_keel_bottom_z"] = round(min(p[2] for p in keel), 3)
out["model_keel_clearance"] = round(min(p[2] for p in keel) - GZ, 3)
low = [p for p in lod0 if p[2] < -2.2 and abs(p[1] - wf[1]) > 0.3 and abs(p[1] - wl[1]) > 0.3]
out["model_below_keel_verts"] = {"count": len(low), "min_z": round(min(p[2] for p in low), 3), "y_range": [round(min(p[1] for p in low), 2), round(max(p[1] for p in low), 2)], "x_abs_max": round(max(abs(p[0]) for p in low), 2)}
pz = bl(nodes["Propeller"])
out["model_prop_axis"] = [round(c, 3) for c in pz]
out["model_prop_axis_above_ground"] = round(pz[2] - GZ, 3)
out["model_prop_axis_above_keel_bottom"] = round(pz[2] - out["model_keel_bottom_z"], 3)
out["model_prop_tip_clearance"] = round(pz[2] - D["prop_d"] / 2 - GZ, 3)
out["model_engine_frame_above_keel_bottom"] = round((pz[2] - 0.23) - out["model_keel_bottom_z"], 3)
out["model_markers"] = sorted(n for n in nodes if not n.startswith(("Trike", "Prop_", "Engine")))
mast_base_y = -math.tan(math.radians(D["mast_tilt_deg"])) * (-KZ)
out["model_mast_base_y"] = round(mast_base_y, 3)
out["model_mast_base_behind_rear_axle"] = round(out["model_axle_rear_y"] - mast_base_y, 3)

# ---------- схема: масштаб по пикселям (papa_sketch_v2.jpeg 720x1280) ----------
# ручная разметка: ось заднего колеса x=205, переднего 548 (база ~1800 мм), подвес (325, 490),
# низ мачты (212, 757), верх мачты (322, 505), нос подкоса (575, 725), штанга (407, 675), приборы (500, 700)
mm_px = 1800 / (548 - 205)
sk = {
    "mm_per_px": round(mm_px, 3),
    "hang_y_from_rear_axle_m": round((325 - 205) * mm_px / 1000, 3),
    "mast_tilt_deg": round(math.degrees(math.atan2(322 - 212, 757 - 505)), 1),
    "nose_ahead_of_front_axle_m": round((575 - 548) * mm_px / 1000, 3),
    "instr_y_from_hang_m": round((500 - 325) * mm_px / 1000, 3),
    "bar_y_from_hang_m": round((407 - 325) * mm_px / 1000, 3),
    "wheel_d_px_mm": round(55 * mm_px),
    "keel_gap_px_mm": round((843 - 790) * mm_px),
    "hang_above_ground_scale_m": round((843 - 490) * mm_px / 1000, 2),
    "engine_frame_above_keel_scale_m": round((790 - 675) * mm_px / 1000, 2),
    "engine_axis_above_keel_scale_m": round((790 - 650) * mm_px / 1000, 2),
}
out["sketch"] = sk
out["sketch"]["vertical_scale_factor_vs_model"] = round(-GZ / sk["hang_above_ground_scale_m"], 2)

# ---------- штанга, подкос, приборы (плоскость y-z) ----------
H = lambda y, z: math.hypot(y, z)
bar = P["bar"]
R = H(bar["trim"][1], bar["trim"][2])
ang = lambda p: math.degrees(math.atan2(p[1], -p[2]))            # от вертикали вниз, вперёд +
a_pull, a_trim, a_push = (ang(bar[k]) for k in ("full_pull", "trim", "full_push"))
rb = bar["d"] / 2


def bar_at(a):
    r = math.radians(a)
    return (R * math.sin(r), -R * math.cos(r))


def dseg(p, a, b):
    ab = (b[0] - a[0], b[1] - a[1]); ap = (p[0] - a[0], p[1] - a[1])
    t = max(0, min(1, (ap[0] * ab[0] + ap[1] * ab[1]) / (ab[0] ** 2 + ab[1] ** 2)))
    return math.hypot(p[0] - a[0] - t * ab[0], p[1] - a[1] - t * ab[1])


def poly_d(p, pl):
    return min(dseg(p, pl[i], pl[i + 1]) for i in range(len(pl) - 1))


strut_model = [(0.0, -0.03), (0.88, -1.55), (1.0, -2.0)]       # build_trike.py, без скругления 0.35 м
strut_sketch = [(0.0, -0.03), (1.30 - 0.0, -2.0)]               # прямой, нос над осью переднего + 0.13
eye = tuple(P["seat"]["eye"][1:])
panel_model = tuple(P["panel"]["center"][1:])
# приборы по схеме: на 70% длины подкоса (x 500 из 325..575)
f = 0.70
instr = (f * strut_sketch[1][0], f * strut_sketch[1][1] - 0.03)
# вариант предложения: панель той же высоты z модели, на подкосе нос 1.30 (y по линии подкоса)
zp = panel_model[1]
prop_panel = (strut_sketch[1][0] * zp / strut_sketch[1][1] - 0.05, zp)   # на 5 см позади оси подкоса
res = {"bar_R": round(R, 3), "ang_pull_trim_push": [round(a_pull, 1), round(a_trim, 1), round(a_push, 1)]}
res["bar_trim_to_model_strut_gap_m"] = round(poly_d(bar_at(a_trim), strut_model) - rb - D["tube_strut_d"] / 2, 3)
cross_model = [a for a in [a_pull + i * 0.25 for i in range(int((a_push + 3 - a_pull) / 0.25))]
               if poly_d(bar_at(a), strut_model) - rb - D["tube_strut_d"] / 2 < 0]
res["bar_hits_model_strut_deg"] = [round(cross_model[0], 1), round(cross_model[-1], 1)] if cross_model else None
cross_sk = [a for a in [a_pull + i * 0.25 for i in range(int((a_push + 3 - a_pull) / 0.25))]
            if poly_d(bar_at(a), strut_sketch) - rb - 0.02 < 0]
res["bar_hits_sketch_strut_deg"] = [round(cross_sk[0], 1), round(cross_sk[-1], 1)] if cross_sk else None


def occl(target):
    """диапазон угла штанги, при котором ось штанги ближе rb+0.01 к лучу глаз -> центр цели"""
    bad = [a for a in [a_pull - 3 + i * 0.25 for i in range(int((a_push + 6 - a_pull) / 0.25))]
           if dseg(bar_at(a), eye, target) < rb + 0.01]
    return [round(bad[0], 1), round(bad[-1], 1)] if bad else None


for name, t in (("panel_model", panel_model), ("instr_sketch", instr), ("panel_on_strut", prop_panel)):
    res[name] = {"yz": [round(t[0], 3), round(t[1], 3)], "R_from_hang": round(H(*t), 3),
                 "dist_from_eye": round(math.hypot(t[0] - eye[0], t[1] - eye[1]), 3),
                 "look_down_deg": round(math.degrees(math.atan2(eye[1] - t[1], t[0] - eye[0])), 1),
                 "bar_occludes_deg": occl(t)}
res["panel_on_strut"]["dist_to_strut_axis"] = round(poly_d(prop_panel, strut_sketch), 3)
res["panel_model"]["dist_to_model_strut_axis"] = round(poly_d(panel_model, strut_model), 3)
out["bar_strut_instruments"] = res

# ---------- ЦТ по массам (оценка, массы — допущения) ----------
pil, eng, fuel, frame = 80.0, 50.0, 0.72 * D["tank_volume_l"], 60.0
hipf, hipr = P["seat"]["hip"][1], P["seat_rear"]["seat_pan"][1] - 0.1
yf, yr = hipf + 0.10, hipr + 0.10             # ЦТ тела — на 0.10 м впереди бедра (ноги вперёд)
y_eng = -0.92 - D["engine_l"] / 2 - 0.05 + 0.34
y_tank = P["tank"]["center"][1]
for label, pilots in (("two", [(pil, yf), (pil, yr)]), ("front_only", [(pil, yf)]), ("rear_only", [(pil, yr)])):
    for fuel_k, fk in (("full", 1.0), ("empty", 0.0)):
        parts = pilots + [(eng, y_eng), (fuel * fk, y_tank), (frame, 0.0)]
        m = sum(a for a, _ in parts)
        out.setdefault("cg_y_from_hang_m", {})[f"{label}_{fuel_k}"] = round(sum(a * y for a, y in parts) / m, 3)
out["cg_assumptions"] = {"pilot_kg": pil, "engine_prop_exhaust_kg": eng, "fuel_kg": round(fuel, 1), "frame_wheels_kg": frame,
                         "engine_y": round(y_eng, 3), "tank_y": y_tank, "pilot_front_y": round(yf, 3), "pilot_rear_y": round(yr, 3)}
out["params_tubes"] = {k: D[k] for k in ("tube_keel_d", "tube_mast_d", "tube_strut_d", "tube_frame_d")}
out["params_version"] = P["version"]

print(json.dumps(out, ensure_ascii=False, indent=1))
