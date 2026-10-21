"""Тележка трайка: assets/models/trike/trike.glb (+ assets/source/trike/trike.blend). Контракт TK-K2
(docs/contracts/trike-model.md).

    blender --background --python tools/blender/build_trike.py
    godot --headless --path . --import

Размеры — tools/blender/trike_params.json (TK-K1). Оси Blender: +X вправо, +Y вперёд, +Z вверх; начало —
точка подвески крыла HangPoint (вершина мачты); земля z = ground_z. В Godot (x, z, −y).

Узлы: Trike_LOD0/1/2 (всё, кроме винта), Propeller (Empty на ступице; в Godot локальная +Z — ось двигателя,
направлена назад, к наблюдателю за трайком (в Blender это локальная −Y объекта: экспортёр сопрягает оси
(x, z, −y)); наклон носом вверх prop_tilt_deg), его дети Prop_LOD0/1,
маркеры HangPoint, WheelFront, WheelRearL, WheelRearR. Анимация prop_spin: один оборот вокруг локальной Z
за 1 с (кадры 0–24, 24 к/с); положительный угол вокруг +Z (взгляд сзади) = против часовой, т. е.
prop_cw_from_behind = false.
Цвета — вершинные (COLOR_0), материалы Metal/Soft/Composite белые; шина — материал Wheel с общей текстурой
wheel_tire (wheel_parts.tire_texture()). Колёса — wheel_parts.add_wheel, масштабированное под размеры.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import frame_parts as F  # noqa: E402
import wheel_parts as W  # noqa: E402

OUT = os.path.join(U.MODELS, "trike")
SRC = os.path.join(U.SOURCE, "trike")
P = U.load_json("tools/blender/trike_params.json")
D = {k: v["value"] for k, v in P["dims"].items()}
S = P["seat"]
GZ = P["ground_z"]

# логическое имя → (физический материал, цвет sRGB)
COLORS = {
    "Tube": ("Metal", (0.72, 0.73, 0.75)),        # алюминиевая труба
    "Fitting": ("Metal", (0.2, 0.21, 0.22)),
    "Steel": ("Metal", (0.55, 0.56, 0.58)),
    "WheelRim": ("Metal", (0.2, 0.21, 0.22)),
    "Seat": ("Soft", (0.07, 0.07, 0.08)),          # тёмная ткань
    "Tank": ("Soft", (0.78, 0.78, 0.75)),
    "Pedal": ("Soft", (0.1, 0.1, 0.1)),
    "EngBlack": ("Metal", (0.1, 0.1, 0.11)),       # картер Rotax
    "EngSilver": ("Metal", (0.6, 0.61, 0.63)),     # головки цилиндров, редуктор
    "Muffler": ("Metal", (0.4, 0.38, 0.35)),
    "Blade": ("Composite", (0.2, 0.13, 0.08)),     # композит под дерево
    "Hub": ("Metal", (0.08, 0.08, 0.09)),
    "Wheel": ("Wheel", (1.0, 1.0, 1.0)),
}


def phys_mats() -> dict:
    tire = W.tire_texture()
    tire.filepath_raw = ""          # экспортёр иначе назовёт картинку по файлу ("tire"), а не wheel_tire
    return {
        "Metal": U.material("Metal", (1, 1, 1), rough=0.42, metal=0.55, double=True),
        "Soft": U.material("Soft", (1, 1, 1), rough=0.9, double=True),
        "Composite": U.material("Composite", (1, 1, 1), rough=0.5, double=True),
        "Wheel": U.material("Wheel", (1, 1, 1), rough=0.88, image=tire),
    }


def build_mesh(mb, name: str, M: dict, parent=None):
    logical = list(mb.mat_names)
    face_logical = [logical[m] for m in mb.mats]
    phys = []
    for ln in logical:
        if COLORS[ln][0] not in phys:
            phys.append(COLORS[ln][0])
    mb.mats = [phys.index(COLORS[n][0]) for n in face_logical]
    mb.mat_names = phys
    ob = mb.build(name, M, parent)
    me = ob.data
    ca = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    cols = []
    for f, ln in zip(me.polygons, face_logical):
        c = U.srgb(COLORS[ln][1])
        for _ in range(f.loop_total):
            cols.extend((c[0], c[1], c[2], 1.0))
    ca.data.foreach_set("color", cols)
    me.color_attributes.active_color = ca
    me.color_attributes.render_color_index = 0
    return ob


def merge(mb, sub, sx: float, syz: float, offset: Vector) -> None:
    """Добавить сетку sub (колесо в начале координат) с масштабом (sx вдоль оси X, syz радиально)."""
    base = len(mb.verts)
    for v in sub.verts:
        mb.verts.append(tuple(Vector((v[0] * sx, v[1] * syz, v[2] * syz)) + offset))
    for f, uv, m, sm in zip(sub.faces, sub.uvs, sub.mats, sub.smooth):
        mb.add_face([base + i for i in f], sub.mat_names[m], uv, sm)


def wheel(mb, c: Vector, sign: int, d: float, w: float, lod: int) -> None:
    if lod == 0:
        sub = U.MeshBuilder()
        W.add_wheel(sub, Vector((0, 0, 0)), sign, 0.0)
        merge(mb, sub, w / (2 * W.HALF_W), d / (2 * W.R_OUT), c)
    else:
        sides = 12 if lod == 1 else 8   # вершина строго внизу: 270° кратно шагу
        mb.add_tube([c - Vector((w / 2, 0, 0)), c + Vector((w / 2, 0, 0))], d / 2, "Wheel", sides=sides)


def box_rot(mb, center, size, mat, rot=None):
    mb.add_box(center, size, mat, rot=rot)


def trike(lod: int, M: dict):
    mb = U.MeshBuilder()
    sd = (12, 6, 3)[lod]          # сторон у трубы
    sdt = (8, 4, 3)[lod]          # у тонких труб
    V = Vector
    wb, tr = D["wheelbase"], D["track"]
    d_f, d_r = D["wheel_front_d"], D["wheel_rear_d"]
    w_f, w_r = D["tire_front_w"], D["tire_rear_w"]
    y_r, y_f = D.get("axle_rear_y", -0.55), D.get("axle_rear_y", -0.55) + wb
    zc_f, zc_r = GZ + d_f / 2, GZ + d_r / 2

    # ---- рама ----
    keel_z = -2.12
    nose = V((0, 1.0, -2.0))
    mast_base = V((0, math.tan(math.radians(D["mast_tilt_deg"])) * (-keel_z), keel_z))
    mast_base.y = -mast_base.y                                   # мачта наклонена вперёд к вершине
    keel = [V((0, -0.98, keel_z)), V((0, mast_base.y, keel_z)), V((0, 0.7, keel_z)), nose]
    mb.add_tube(keel, 0.03, "Tube", sides=sd)
    mb.add_tube([V((0, 0, 0)), mast_base], 0.028, "Tube", sides=sd)                  # мачта
    mb.add_tube([V((0, 0, -0.03)), nose], 0.022, "Tube", sides=sd)                   # передний подкос
    # задние подкосы к колёсам: рессора-дуга и косая стойка от мачты
    for s in (-1, 1):
        ax = V((s * tr / 2, y_r, zc_r))
        spring = [V((0, y_r, keel_z + 0.02)), V((s * 0.3, y_r, keel_z - 0.07)),
                  V((s * 0.6, y_r, zc_r + 0.02)), ax + V((-s * 0.06, 0, 0))]
        mb.add_tube(spring, 0.022, "Tube", sides=sdt)
        mid = V((0, -0.40, -1.20))
        if lod < 2:
            mb.add_tube([mid, ax + V((-s * 0.1, 0.0, 0.02))], 0.015, "Tube", sides=sdt)
    # передняя вилка и колесо
    head = V((0, 1.1, -2.0))
    if lod == 2:
        mb.add_tube([nose, V((0, y_f, zc_f))], 0.02, "Tube", sides=sdt)
    else:
        mb.add_tube([nose, head], 0.022, "Tube", sides=sdt)
        for s in (-1, 1):
            mb.add_tube([head + V((s * 0.075, 0, 0.0)), V((s * 0.075, y_f, zc_f))], 0.016, "Tube", sides=sdt)
        mb.add_tube([head + V((-0.075, 0, 0)), head + V((0.075, 0, 0))], 0.016, "Tube", sides=sdt)
        # подножки руления и педаль газа (точки опоры — seat.foot_*, seat.throttle_pedal)
        fl, fr = V(S["foot_l"]), V(S["foot_r"])
        for p in (fl, fr):
            box_rot(mb, p + V((0, 0, -0.0075)), (0.1, 0.2, 0.015), "Fitting")
            mb.add_tube([V((p.x, p.y - 0.1, p.z - 0.0075)), head + V((p.x * 0.5, 0.0, -0.05))], 0.014, "Tube",
                        sides=sdt)
        tp = V(S["throttle_pedal"])
        pivot = V((tp.x, tp.y - 0.07, tp.z - 0.02))
        pa = Matrix.Rotation(math.radians(12), 3, "X")
        box_rot(mb, tp + V((0, 0, -0.008)), (0.08, 0.14, 0.016), "Pedal", rot=pa)
        if lod == 0:
            mb.add_tube([pivot, tp + V((0, -0.03, -0.015))], 0.008, "Steel", sides=6)
        mb.add_tube([V((-0.15, 1.1, -2.25)), V((0.15, 1.1, -2.25))], 0.014, "Tube", sides=sdt)
    # ---- сиденья ----
    pan = V(S["seat_pan"])
    pw, pd = S["seat_pan_size"]
    box_rot(mb, pan + V((0, 0, -0.035)), (pw, pd, 0.07), "Seat")
    ba, bw, bh = S["backrest_angle_deg"], S["backrest_size"][0], S["backrest_size"][1]
    br = Matrix.Rotation(math.radians(ba), 3, "X")
    bb = V(S["backrest_base"])
    box_rot(mb, bb + br @ V((0, -0.03, bh / 2)), (bw, 0.06, bh), "Seat", rot=br)
    if P["prototype"]["seats"] == 2 and lod < 2:
        pan2 = V((0, pan.y - 0.58, pan.z + 0.0))
        box_rot(mb, pan2 + V((0, 0, -0.035)), (pw, 0.30, 0.07), "Seat")
        br2 = Matrix.Rotation(math.radians(10), 3, "X")
        bb2 = V((0, pan2.y - 0.19, pan2.z + 0.02))
        box_rot(mb, bb2 + br2 @ V((0, -0.03, 0.225)), (bw, 0.06, 0.45), "Seat", rot=br2)
        mb.add_tube([V((-0.2, pan2.y, pan2.z - 0.07)), V((-0.2, pan2.y, keel_z))], 0.012, "Tube", sides=sdt)
        mb.add_tube([V((0.2, pan2.y, pan2.z - 0.07)), V((0.2, pan2.y, keel_z))], 0.012, "Tube", sides=sdt)
    # бак под передним сиденьем
    if lod < 2:
        mb.add_ellipsoid((0, pan.y - 0.02, pan.z - 0.1), (0.19, 0.3, 0.05), "Tank",
                         seg=(14, 8)[lod], rings=(7, 4)[lod])
        for s in (-1, 1):  # стойки сиденья
            mb.add_tube([V((s * 0.2, pan.y + 0.1, pan.z - 0.07)), V((s * 0.2, pan.y + 0.1, keel_z))], 0.012,
                        "Tube", sides=sdt)
    # ---- колёса ----
    wheel(mb, V((0, y_f, zc_f)), 1, d_f, w_f, lod)
    wheel(mb, V((-tr / 2, y_r, zc_r)), -1, d_r, w_r, lod)
    wheel(mb, V((tr / 2, y_r, zc_r)), 1, d_r, w_r, lod)
    # ---- двигатель (Rotax 912: оппозитный, редуктор сзади) ----
    ez = GZ + D["prop_axis_height"]
    ey = -0.92
    el, ew, eh = D["engine_l"], D["engine_w"], D["engine_h"]
    hub_y = ey - el / 2 - 0.05                       # фланец винта
    box_rot(mb, V((0, ey + 0.05, ez)), (0.30, 0.30, eh * 0.88), "EngBlack")             # картер
    box_rot(mb, V((0, ey - el / 2 + 0.08, ez)), (0.22, 0.17, 0.22), "EngSilver")        # редуктор
    if lod < 2:
        for yy in (ey + 0.05 + 0.08, ey + 0.05 - 0.08):
            for s in (-1, 1):
                mb.add_tube([V((s * 0.15, yy, ez)), V((s * (ew / 2 - 0.04), yy, ez))], 0.055, "EngBlack",
                            sides=sdt + 4)
                mb.add_tube([V((s * (ew / 2 - 0.09), yy, ez)), V((s * ew / 2, yy, ez))], 0.07, "EngSilver",
                            sides=sdt + 4)
        mb.add_tube([V((0.1, ey + 0.05, ez - 0.18)), V((0.1, ey - 0.25, ez - 0.2))], 0.05, "Muffler", sides=sdt + 2)
    mb.add_tube([V((0, ey - el / 2 + 0.0, ez)), V((0, hub_y + 0.0, ez))], 0.03, "Steel", sides=sdt)
    # подмоторная рама
    for s in ((-1, 1) if lod < 2 else ()):
        mb.add_tube([V((s * 0.12, ey + 0.1, ez - eh * 0.4)), V((0, keel[0].y, keel_z))], 0.015, "Tube",
                    sides=sdt)
        mb.add_tube([V((s * 0.12, ey + 0.1, ez - eh * 0.4)), V((0, -0.55, -1.5))], 0.015, "Tube", sides=sdt)
    # ---- точка подвески: пластина и болт на вершине мачты ----
    if lod == 0:
        pts = F.rounded_outline([(-0.05, -0.05), (0.05, -0.05), (0.05, 0.05), (-0.05, 0.05)], 0.015, 2)
        for dx in (-1, 1):
            F.add_prism(mb, pts, V((dx * 0.04, 0, -0.01)), V((0, 1, 0)), V((0, 0, 1)), 0.006, "Fitting")
        F.add_bolt(mb, V((0, 0, 0)), (1, 0, 0), 0.13, 0.009, "Steel")
    return mb


# ---------- винт ----------

def propeller(lod: int, M: dict) -> "U.MeshBuilder":
    """Винт в локальных осях узла Propeller: диск в плоскости XY, ось +Z (назад), ступица в начале."""
    mb = U.MeshBuilder()
    R = D["prop_d"] / 2
    nb = int(D["prop_blades"])
    r0 = 0.07
    # ступица со спинером (конус назад)
    hs = 8 if lod == 0 else 5
    mb.add_tube([Vector((0, 0, -0.03)), Vector((0, 0, 0.06)), Vector((0, 0, 0.16))], [0.085, 0.085, 0.012],
                "Hub", sides=hs)
    ns = 5 if lod == 0 else 2          # станции вдоль лопасти
    for b in range(nb):
        a = 2 * math.pi * b / nb + math.pi / 2
        rad = Vector((math.cos(a), math.sin(a), 0))
        tan = Vector((-math.sin(a), math.cos(a), 0))
        rows = []
        for i in range(ns + 1):
            t = i / ns
            r = r0 + (R - r0) * t
            chord = 0.15 * (1 - 0.7 * t ** 2) if i < ns else 0.02          # сужение к концу
            beta = math.radians(55 - 40 * t)                                # крутка: больше у ступицы
            ch = tan * math.cos(beta) + Vector((0, 0, 1)) * math.sin(beta)  # направление хорды
            nrm = -tan * math.sin(beta) + Vector((0, 0, 1)) * math.cos(beta)
            c = rad * r
            th = chord * 0.12
            if lod == 0:
                rows.append([c + ch * (chord / 2), c + nrm * th, c - ch * (chord / 2), c - nrm * th])
            else:
                rows.append([c + ch * (chord / 2), c - ch * (chord / 2)])
        if lod == 0:
            mb.add_grid(rows, "Blade", wrap=True)
        else:
            mb.add_grid(rows, "Blade")
    # оси узла: ось двигателя (назад) = локальная −Y объекта Blender, плоскость диска XZ, «верх» Godot = +Z
    # объекта: старая локальная (x, y, z) → (x, −z, y), поворот вокруг X на +90°
    mb.verts = [(x, -z, y) for x, y, z in mb.verts]
    return mb


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    M = phys_mats()
    sc = bpy.context.scene
    sc.render.fps = 24
    sc.frame_start, sc.frame_end = 0, 24

    for lod in range(3):
        mb = trike(lod, M)
        ob = build_mesh(mb, f"Trike_LOD{lod}", M)
        lo = min(v.co.z for v in ob.data.vertices)
        print(f"TRIKE LOD{lod}: {U.tri_count([ob.name])} tris, низ z {lo:.4f} (земля {GZ})")

    # узел винта: локальная Z — ось двигателя (назад), наклон носом вверх
    tilt = D["prop_tilt_deg"]
    hub = Vector((0, -0.92 - D["engine_l"] / 2 - 0.05, GZ + D["prop_axis_height"]))
    prop = U.empty("Propeller", hub, size=0.2)
    prop.rotation_mode = "ZYX"                       # R = Rx(a)·Ry(φ): спин вокруг локальной Y объекта
    alpha = math.radians(tilt)                       # носом вверх: локальная +Y = (0, cos, sin)
    # положительный поворот вокруг +Z Godot (назад, к наблюдателю) = против часовой при взгляде сзади;
    # +Z Godot = −Y Blender, поэтому угол вокруг Y Blender = −θ
    sign = 1.0 if D["prop_cw_from_behind"] else -1.0
    prop.rotation_euler = (alpha, 0.0, 0.0)
    for lod in range(2):
        pm = propeller(lod, M)
        ob = build_mesh(pm, f"Prop_LOD{lod}", M, parent=prop)
        print(f"PROP LOD{lod}: {U.tri_count([ob.name])} tris")
    # анимация
    prop.animation_data_create()
    act = bpy.data.actions.new("prop_spin")
    prop.animation_data.action = act
    for k in range(5):
        prop.rotation_euler = (alpha, sign * math.radians(90 * k), 0.0)
        prop.keyframe_insert("rotation_euler", frame=6 * k)
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    prop.rotation_euler = (alpha, 0.0, 0.0)
    act.use_fake_user = True
    # маркеры
    U.empty("HangPoint", (0, 0, 0))
    y_r = D.get("axle_rear_y", -0.55)
    U.empty("WheelFront", (0, y_r + D["wheelbase"], GZ + D["wheel_front_d"] / 2))
    U.empty("WheelRearL", (-D["track"] / 2, y_r, GZ + D["wheel_rear_d"] / 2))
    U.empty("WheelRearR", (D["track"] / 2, y_r, GZ + D["wheel_rear_d"] / 2))

    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "trike.blend"), check_existing=False, compress=True)
    glb = os.path.join(OUT, "trike.glb")
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", export_yup=True, use_selection=False,
                              export_apply=True, export_extras=False, export_vertex_color="ACTIVE",
                              export_animations=True, export_animation_mode="ACTIONS",
                              export_force_sampling=True, export_cameras=False, export_lights=False)
    U.externalize_shared(glb)
    print("EXPORTED trike: %d tris" % U.tri_count())


main()
