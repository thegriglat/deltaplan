#!/usr/bin/env python3
"""Вид из кабины без Godot и без пересборки .glb (PV-1, модуль pilot-view).

Из тех же данных, что и игра (tools/blender/glider_params.json + tools/blender/aframe_geom.py,
tools/blender/aframe_trim.json, configs/pilot.json, configs/camera.json), считает для крыла:
положение глаз и камеры, середины базовой штанги и носовых тросов (от углов штанги к носу)
относительно камеры, углы от оси взгляда вперёд и минимальный вертикальный FOV при заданном
аспекте, при котором видны центр штанги и носовые тросы.

Модель (как в игре, scripts/game/camera_rig.gd): камера = маркер глаз PilotHead (в позе prone это
pilot_eye из glider_params.json, оси крыла) + cockpit.offset_m в осях крыла (Godot x вправо,
y вверх, z назад); ориентация головы по тангажу — горизонт мира (_level_head убирает тангаж и
оставляет крен), взгляд вверх на -look_down_deg. Крыло наклонено на тангаж киля на триме
(aframe_trim.json). Трапеция в нейтрали, пилот не сдвинут (pilot_shift = 0).

Оси: крыло (Blender) x вправо, y вперёд, z вверх, начало HangPoint; мир — то же, но киль
повёрнут на theta (нос вверх) вокруг x. Камера: yc вверх, zc вперёд по оси взгляда.

Сценарные параметры (по умолчанию — текущая игра):
  --gap M          зазор низ тела — верх штанги, м: пилот сдвигается по вертикали под это значение
                   (иначе — как сейчас: -hang_length_m относительно оси штанги крыла)
  --bar-fwd M      вынос штанги вперёд от плечевых суставов (горизонт. в осях крыла), м: пилот
                   сдвигается по y (иначе — как сейчас, плечи из aframe_trim.json)
  --cam X Y Z      смещение камеры в осях cockpit.offset_m (x вправо, y вверх, z назад)
  --look-down DEG  наклон взгляда относительно горизонта, + вниз (как cockpit.look_down_deg)
  --aspect A       аспект кадра (16/9)
  --solve          подобрать наклон взгляда (0…--max-look-down), при котором min_vfov минимален
  --max-look-down  предел подбора, ° вниз (25)
Запуск: python3 tools/research/pilot_view/cockpit_view.py --wing apogee [--json] | --all [--json]
"""
import argparse
import json
import math
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "blender"))
import aframe_geom as G  # noqa: E402

PARAMS = os.path.join(ROOT, "tools", "blender", "glider_params.json")
TRIM = os.path.join(ROOT, "tools", "blender", "aframe_trim.json")
PILOT = os.path.join(ROOT, "configs", "pilot.json")
CAMERA = os.path.join(ROOT, "configs", "camera.json")
NOSE_TIP_BACK = 0.05  # трос крепится к носу на 0,05 м позади носового узла (build_gliders.py)
BIG = 180.0


def load():
    cfg = {}
    for k, path in (("params", PARAMS), ("trim", TRIM), ("pilot", PILOT), ("camera", CAMERA)):
        with open(path, encoding="utf-8") as f:
            cfg[k] = json.load(f)
    return cfg


def rot_x(pt, theta_deg):
    """Крыло -> мир: поворот вокруг x, нос вверх на theta."""
    t = math.radians(theta_deg)
    x, y, z = pt
    return (x, y * math.cos(t) - z * math.sin(t), y * math.sin(t) + z * math.cos(t))


def cam_coords(pt_world, cam_world, gaze_up_deg):
    """Точка мира -> (xc вправо, yc вверх, zc вперёд по оси) камеры, взгляд вверх на gaze_up."""
    g = math.radians(gaze_up_deg)
    d = [pt_world[i] - cam_world[i] for i in range(3)]
    zc = d[1] * math.cos(g) + d[2] * math.sin(g)
    yc = -d[1] * math.sin(g) + d[2] * math.cos(g)
    return d[0], yc, zc


def axis_angle(c):
    n = math.sqrt(c[0] ** 2 + c[1] ** 2 + c[2] ** 2)
    return math.degrees(math.acos(max(-1.0, min(1.0, c[2] / n))))


def half_tan_needed(c, aspect):
    """tan(половина вертикального FOV), при которой точка на краю кадра; inf - за плоскостью глаз."""
    if c[2] <= 1e-6:
        return math.inf
    return max(abs(c[1]) / c[2], abs(c[0]) / (c[2] * aspect))


def vfov_from_tan(t):
    return BIG if math.isinf(t) else min(BIG, 2 * math.degrees(math.atan(t)))


def scene(cfg, wid, gap=None, bar_fwd=None, cam_off=None, look_down=None, aspect=16 / 9):
    cf = cfg["params"]["control_frame"]
    p = cfg["params"]["wings"][wid]
    pil = cfg["pilot"]["visual"]
    cam_cfg = cfg["camera"]["cockpit"]
    theta = cfg["trim"]["trim_pitch_deg"][wid]
    sh = cfg["trim"]["shoulder_mid"]  # [x, y вверх, z вперёд] в осях Godot->крыло: см. aframe_cg.balance
    shoulder_y, shoulder_z = sh[2], sh[1]  # вперёд, вверх
    eye = list(cfg["params"]["pilot_eye"])  # x, y вперёд, z вверх (оси крыла)
    off = cam_off if cam_off is not None else cam_cfg["offset_m"]
    ld = cam_cfg["look_down_deg"] if look_down is None else look_down

    fp = G.frame_points(p, cf)
    faired = p["faired_uprights"]
    dip = cf["speedbar_dip_m"] if faired else 0.0
    r_bar = cf["basebar_r_m"]
    z_axis = fp["z_bb"] - dip  # ось штанги в середине
    w = fp["w"]
    y_bb = fp["y_bb"]

    body_bottom = -pil["hang_length_m"]  # низ тела под карабином (HangPoint)
    gap_now = body_bottom - (z_axis + r_bar)
    dz = 0.0 if gap is None else (z_axis + r_bar + gap) - body_bottom
    dy = 0.0 if bar_fwd is None else (y_bb - bar_fwd) - shoulder_y
    shoulder_y_orig = shoulder_y
    eye[1] += dy
    eye[2] += dz
    shoulder = (shoulder_y + dy, shoulder_z + dz)

    cam = (off[0], eye[1] - off[2], eye[2] + off[1])  # Godot z назад -> Blender y вперёд -минус
    cam_w = rot_x(cam, theta)
    gaze_up = -ld
    kz = cf["keel_z_m"]
    nose = (0.0, p["nose_forward_m"] - NOSE_TIP_BACK, kz)

    def to_cam(pt):
        return cam_coords(rot_x(pt, theta), cam_w, gaze_up)

    flat = cf["speedbar_flat_half_m"]

    def z_bar_at(x):
        a = abs(x)
        if a <= flat or not faired:
            return z_axis if a <= flat else fp["z_bb"]
        k = min(1.0, (a - flat) / (w - flat))
        return fp["z_bb"] - dip * (1 - (3 * k * k - 2 * k ** 3))

    bar_c = to_cam((0.0, y_bb, z_axis))
    chord_min = min(axis_angle(to_cam((w * (2 * i / 100 - 1), y_bb, z_bar_at(w * (2 * i / 100 - 1))))) for i in range(101))
    wire_pts = []
    n = 200
    for i in range(n + 1):
        t = i / n
        wire_pts.append(to_cam((w * (1 - t), y_bb + (nose[1] - y_bb) * t, z_axis + (nose[2] - z_axis) * t)))
    # левый и правый тросы симметричны; берём правый (знак x не важен для углов/FOV)
    corner_c = wire_pts[0]
    nose_c = wire_pts[-1]
    bar_tan = half_tan_needed(bar_c, aspect)
    wire_tan = min(half_tan_needed(c, aspect) for c in wire_pts)
    wire_best = min(wire_pts, key=lambda c: half_tan_needed(c, aspect))
    bar_vfov = vfov_from_tan(bar_tan)
    wire_vfov = vfov_from_tan(wire_tan)
    min_vfov = max(bar_vfov, wire_vfov)
    elev = math.degrees(math.atan2(bar_c[1], math.hypot(bar_c[0], bar_c[2])))
    # наклон стоек, при котором штанга оказалась бы на bar_fwd впереди плеч БЕЗ сдвига пилота (A1)
    tilt_needed = None
    if bar_fwd is not None:
        sin_t = (shoulder_y_orig + bar_fwd - fp["apex_y"]) / fp["s"]
        tilt_needed = round(math.degrees(math.asin(sin_t)), 1) if abs(sin_t) <= 1 else None
    return {
        "wing": wid,
        "upright_tilt_now_deg": p.get("upright_tilt_deg", cf["upright_tilt_deg"]),
        "upright_tilt_needed_deg": tilt_needed,
        "trim_pitch_deg": round(theta, 2),
        "look_down_deg": ld,
        "eye_wing_m": [round(v, 3) for v in eye],
        "camera_wing_m": [round(v, 3) for v in cam],
        "shoulder_fwd_up_m": [round(v, 3) for v in shoulder],
        "basebar_center_wing_m": [0.0, round(y_bb, 3), round(z_axis, 3)],
        "gap_body_bar_top_now_m": round(gap_now, 3),
        "pilot_shift_down_m": round(-dz, 3),
        "pilot_shift_fwd_m": round(dy, 3),
        "bar_fwd_of_shoulder_m": round(y_bb - shoulder[0], 3),
        "bar_below_eye_m": round(eye[2] - z_axis, 3),
        "basebar_center_deg": round(axis_angle(bar_c), 1),
        "basebar_chord_min_deg": round(chord_min, 1),
        "basebar_center_below_axis_deg": round(-elev, 1),
        "basebar_center_cam_m": [round(v, 3) for v in bar_c],
        "nosewire_corner_deg": round(axis_angle(corner_c), 1),
        "nosewire_nose_deg": round(axis_angle(nose_c), 1),
        "nosewire_closest_deg": round(axis_angle(wire_best), 1),
        "bar_vfov_deg": round(bar_vfov, 1),
        "wire_vfov_deg": round(wire_vfov, 1),
        "min_vfov_deg": round(min_vfov, 1),
        "visible_at_any_fov": bool(not math.isinf(bar_tan)),
        "aspect": round(aspect, 4),
    }


def solve_look(cfg, wid, max_ld=25.0, **kw):
    best = None
    for i in range(0, int(max_ld * 10) + 1):
        ld = i / 10
        kw2 = dict(kw)
        kw2["look_down"] = ld
        r = scene(cfg, wid, **kw2)
        if best is None or r["min_vfov_deg"] < best["min_vfov_deg"] - 1e-9:
            best = r
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wing")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--gap", type=float)
    ap.add_argument("--bar-fwd", type=float)
    ap.add_argument("--cam", type=float, nargs=3, metavar=("X", "Y", "Z"))
    ap.add_argument("--look-down", type=float)
    ap.add_argument("--aspect", type=float, default=16 / 9)
    ap.add_argument("--solve", action="store_true")
    ap.add_argument("--max-look-down", type=float, default=25.0)
    a = ap.parse_args()
    cfg = load()
    ids = list(cfg["params"]["wings"]) if a.all else [a.wing or "apogee"]
    kw = dict(gap=a.gap, bar_fwd=a.bar_fwd, cam_off=a.cam, aspect=a.aspect)
    rows = []
    for wid in ids:
        if a.solve:
            rows.append(solve_look(cfg, wid, max_ld=a.max_look_down, **kw))
        else:
            rows.append(scene(cfg, wid, look_down=a.look_down, **kw))
    if a.json:
        print(json.dumps(rows if a.all else rows[0], ensure_ascii=False, indent=1))
        return
    hdr = ("wing", "pitch", "gap_now", "bar_fwd_sh", "bar_deg", "below_axis", "wire_corner", "wire_nose",
           "bar_vfov", "wire_vfov", "min_vfov")
    print(" ".join("%-14s" % h if i == 0 else "%10s" % h for i, h in enumerate(hdr)))
    for r in rows:
        v = (r["wing"], r["trim_pitch_deg"], r["gap_body_bar_top_now_m"], r["bar_fwd_of_shoulder_m"],
             r["basebar_center_deg"], r["basebar_center_below_axis_deg"], r["nosewire_corner_deg"],
             r["nosewire_nose_deg"], r["bar_vfov_deg"], r["wire_vfov_deg"], r["min_vfov_deg"])
        print("%-14s" % v[0] + " ".join("%10.2f" % x if isinstance(x, float) else "%10s" % x for x in v[1:]))


if __name__ == "__main__":
    main()
