"""Тележка трайка: assets/models/trike/trike.glb (+ assets/source/trike/trike.blend). Контракт TK-K2
(docs/contracts/trike-model.md).

    blender --background --python tools/blender/build_trike.py
    godot --headless --path . --import

Размеры — tools/blender/trike_params.json (TK-K1). Оси Blender: +X вправо, +Y вперёд, +Z вверх; начало —
точка подвески крыла HangPoint (вершина мачты); земля z = ground_z. В Godot (x, z, −y).

Узлы: Trike_LOD0/1/2 (всё, кроме винта; в LOD0 и кроме двигателя — он отдельным мешем Engine_LOD0 с UV0, в LOD1/2
двигатель упрощён и входит в меш), Propeller (Empty на ступице; в Godot локальная +Z — ось двигателя,
направлена назад, к наблюдателю за трайком (в Blender это локальная −Y объекта: экспортёр сопрягает оси
(x, z, −y)); наклон носом вверх prop_tilt_deg), его дети Prop_LOD0/1,
маркеры HangPoint, WheelFront, WheelRearL, WheelRearR. Анимация prop_spin: один оборот вокруг локальной Z
за 1 с (кадры 0–24, 24 к/с); положительный угол вокруг +Z (взгляд сзади) = против часовой, т. е.
prop_cw_from_behind = false.
Цвета — вершинные (COLOR_0), материалы Metal/Soft/Composite белые; шина — материал Wheel с общей текстурой
wheel_tire (wheel_parts.tire_texture()). Колёса LOD0 — свои (шина с UV под текстуру wheel_tire, диск, ступица), размеры по dims.
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
SR = P["seat_rear"]
TK = P["tank"]
GZ = P["ground_z"]

# логическое имя → (физический материал, цвет sRGB)
COLORS = {
    "Tube": ("Metal", (0.72, 0.73, 0.75)),        # алюминиевая труба
    "Fitting": ("Metal", (0.2, 0.21, 0.22)),
    "Steel": ("Metal", (0.55, 0.56, 0.58)),
    "WheelRim": ("Metal", (0.2, 0.21, 0.22)),
    "Seat": ("Soft", (0.07, 0.07, 0.08)),          # тёмная ткань
    "Tank": ("Composite", (0.8, 0.8, 0.77)),       # пластиковая канистра
    "Fairing": ("Composite", (0.93, 0.93, 0.9)),   # обтекатель приборов, брызговик
    "Lamp": ("Composite", (0.98, 0.95, 0.8)),
    "Spring": ("Metal", (0.78, 0.62, 0.12)),       # пружина амортизатора (жёлтый цинк)
    "Pedal": ("Soft", (0.1, 0.1, 0.1)),
    "EngBlack": ("Metal", (0.1, 0.1, 0.11)),       # картер Rotax
    "EngSilver": ("Metal", (0.6, 0.61, 0.63)),     # головки цилиндров, редуктор
    "Muffler": ("Metal", (0.4, 0.38, 0.35)),
    "Blade": ("Composite", (0.66, 0.46, 0.27)),    # дерево под стеклотканью на эпоксидке; тон — вершинными цветами
    "Hub": ("Metal", (0.08, 0.08, 0.09)),
    "Wheel": ("Wheel", (1.0, 1.0, 1.0)),
}


def phys_mats() -> dict:
    tire = W.tire_texture()
    tire.filepath_raw = ""          # экспортёр иначе назовёт картинку по файлу ("tire"), а не wheel_tire
    return {
        "Metal": U.material("Metal", (1, 1, 1), rough=0.42, metal=0.55, double=True),
        "Soft": U.material("Soft", (1, 1, 1), rough=0.9, double=True),
        "Composite": U.material("Composite", (1, 1, 1), rough=0.45, double=True),
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
    tint = getattr(mb, "tint", {})          # вершинный множитель тона (дерево винта)
    for f, ln in zip(me.polygons, face_logical):
        c = U.srgb(COLORS[ln][1])
        for k in range(f.loop_total):
            t = tint.get(me.loops[f.loop_start + k].vertex_index, (1.0, 1.0, 1.0))
            cols.extend((min(c[0] * t[0], 1.0), min(c[1] * t[1], 1.0), min(c[2] * t[2], 1.0), 1.0))
    ca.data.foreach_set("color", cols)
    me.color_attributes.active_color = ca
    me.color_attributes.render_color_index = 0
    return ob


V = Vector
RK, RM, RS, RF = (D[k] / 2 for k in ("tube_keel_d", "tube_mast_d", "tube_strut_d", "tube_frame_d"))
KZ = -2.12                                                       # ось трубы киля
MAST_BASE = V((0, -math.tan(math.radians(D["mast_tilt_deg"])) * (-KZ), KZ))   # низ мачты (вершина — HangPoint)
Y_R = D["axle_rear_y"]                                           # ось задних колёс
HUB_Y = -0.92 - D["engine_l"] / 2 - 0.05                         # ступица винта (фланец редуктора)
EZ = GZ + D["prop_axis_height"]                                  # высота оси винта
ALPHA = math.radians(D["prop_tilt_deg"])                         # ось винта носом вверх


def panel_back() -> Vector:
    """Центр тыла панели — точка на оси переднего подкоса (крепление)."""
    pn = P["panel"]
    return V(pn["center"]) - V(pn["normal"]).normalized() * 0.015


PB = panel_back()
_dir = (PB - V((0, 0, -0.03))).normalized()
STRUT_CORNER = PB + _dir * 0.35                                  # fillet(d = 0.35) начинается ровно в тыле панели
RZ = KZ - RK + 0.60                                              # подмоторная рама — на 0.60 м над низом киля


def mast_y(z: float) -> float:
    """y оси мачты на высоте z."""
    return MAST_BASE.y * z / KZ


def spow(x: float, e: float) -> float:
    return math.copysign(abs(x) ** e, x) if x else 0.0


def sstep(a: float, b: float, x: float) -> float:
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def pillow(mb, c, half, mat, rot=None, e=0.4, seg=12, rings=6, warp=None) -> None:
    """Мягкая «подушка» — суперэллипсоид с полуразмерами half, плоскими верхом и низом (колпаки-многоугольники);
    warp(p) — местная деформация (вмятина сиденья, боковые валики)."""
    rot = rot or Matrix.Identity(3)
    c = V(c)
    zs = 1.0 / spow(math.cos(math.pi / rings), e)            # верхний пояс — ровно на высоте half[2]
    grid = []
    for i in range(1, rings):
        th = math.pi * i / rings
        zc, rr = spow(math.cos(th), e) * zs, spow(math.sin(th), e)
        row = []
        for j in range(seg):
            ph = 2 * math.pi * j / seg
            p = V((half[0] * rr * spow(math.cos(ph), e), half[1] * rr * spow(math.sin(ph), e), half[2] * zc))
            row.append(c + rot @ (warp(p) if warp else p))
        grid.append(row)
    mb.add_grid(grid, mat, wrap=True)
    mb.add_face([mb.add_vert(p) for p in grid[0]], mat, smooth=False)
    mb.add_face([mb.add_vert(p) for p in reversed(grid[-1])], mat, smooth=False)


def fillet(pts, d: float, n: int = 3) -> list:
    """Ломаная со скруглёнными углами (квадратичная Безье на углу, отступ d)."""
    out = [V(pts[0])]
    for i in range(1, len(pts) - 1):
        p, a, b = V(pts[i]), V(pts[i - 1]), V(pts[i + 1])
        p0 = p + (a - p).normalized() * min(d, (a - p).length * 0.45)
        p1 = p + (b - p).normalized() * min(d, (b - p).length * 0.45)
        for k in range(n + 1):
            t = k / n
            out.append(p0.lerp(p, t).lerp(p.lerp(p1, t), t))
    out.append(V(pts[-1]))
    return out


def spring(mb, p0, p1, rc: float, rw: float, turns: int, per: int, mat: str, sides: int) -> None:
    """Витая пружина: спираль радиуса rc из проволоки rw вдоль p0→p1."""
    p0, p1 = V(p0), V(p1)
    d = (p1 - p0).normalized()
    u = d.cross(V((1, 0, 0)) if abs(d.x) < 0.9 else V((0, 1, 0))).normalized()
    w = d.cross(u)
    n = turns * per
    pts = []
    for i in range(n + 1):
        a = 2 * math.pi * i / per
        pts.append(p0.lerp(p1, i / n) + u * (rc * math.cos(a)) + w * (rc * math.sin(a)))
    mb.add_tube(pts, rw, mat, sides=sides, cap=True)


def box(mb, center, size, mat, rot=None) -> None:
    mb.add_box(center, size, mat, rot=rot)


# ---------- сиденье ----------

def seat(mb, spec: dict, lod: int, rear: bool) -> None:
    """Формованное кресло: подушка с вмятиной и боковыми валиками, спинка с «крыльями»; рейки под подушкой и трубы
    крепления: переднее — к килю, заднее — к килю и к мачте."""
    pan = V(spec["seat_pan"])
    pw, pd = spec["seat_pan_size"]
    bw, bh = spec["backrest_size"]
    br = Matrix.Rotation(math.radians(spec["backrest_angle_deg"]), 3, "X")
    bb = V(spec["backrest_base"])
    hz = 0.045
    if lod == 2:
        box(mb, pan + V((0, 0, -hz)), (pw, pd, 2 * hz), "Seat")
        box(mb, bb + br @ V((0, -0.05, bh / 2)), (bw, 0.1, bh), "Seat", rot=br)
        return
    seg, rings = (12, 6) if lod == 0 else (8, 4)

    def dish(p):                                    # центр подушки ниже, к бокам валики
        if p.z > 0:
            p.z += 0.03 * sstep(0.5, 1.0, abs(p.x) / (pw / 2))
        return p

    def wing(p):                                    # спинка: боковые «крылья» вперёд
        if p.y > 0:
            p.y += 0.07 * sstep(0.45, 1.0, abs(p.x) / (bw / 2))
        return p

    pillow(mb, pan + V((0, 0, -hz)), (pw / 2, pd / 2, hz), "Seat", e=0.35, seg=seg, rings=rings, warp=dish)
    pillow(mb, bb + br @ V((0, -0.05, bh / 2)), (bw / 2, 0.05, bh / 2), "Seat", rot=br, e=0.4, seg=seg,
           rings=rings, warp=wing)
    sdt = 6 if lod == 0 else 4
    rz = pan.z - 2 * hz - RF                        # рейки под подушкой
    y0, y1 = pan.y - pd / 2 + 0.04, pan.y + pd / 2 - 0.04
    for s in (-1, 1):
        x = s * 0.17
        mb.add_tube([V((x, y0, rz)), V((x, y1, rz))], RF, "Tube", sides=sdt)
        top = bb + br @ V((x, -0.11, bh * 0.85))
        base = bb + br @ V((x, -0.11, 0.05))
        mb.add_tube([V((x, y0, rz)), base, top] if lod == 0 else [V((x, y0, rz)), top], RF, "Tube", sides=sdt)
        # к килю: передняя нога и (у переднего сиденья) задняя
        mb.add_tube([V((x, y1, rz)), V((0, y1 + 0.04, KZ))], RF, "Tube", sides=sdt)
        if rear:
            # заднее — к мачте: нога назад-вверх и скоба от спинки
            mz = -1.5
            mb.add_tube([V((x, y0, rz)), V((0, mast_y(mz), mz))], RF, "Tube", sides=sdt)
            if lod == 0:
                q = bb + br @ V((x, -0.11, bh * 0.7))
                mb.add_tube([q, V((0, mast_y(q.z), q.z))], RF, "Tube", sides=sdt)
        else:
            mb.add_tube([V((x, y0, rz)), V((0, y0 - 0.05, KZ))], RF, "Tube", sides=sdt)
        if lod == 0 and not rear:
            q = bb + br @ V((x, -0.11, bh * 0.45))
            mb.add_tube([q, V((0, q.y - 0.02, KZ))], RF, "Tube", sides=sdt)


def rear_footrests(mb, lod: int) -> None:
    """Подножки заднего сиденья (seat_rear.foot_*): площадки на трубах к килю."""
    sdt = (6, 4, 3)[lod]
    for key in ("foot_l", "foot_r"):
        p = V(SR[key])
        box(mb, p + V((0, 0, -0.0075)), (0.1, 0.18, 0.015), "Fitting")
        mb.add_tube([V((p.x, p.y - 0.05, p.z - 0.015)), V((p.x * 0.2, p.y - 0.12, KZ))], RF * 0.8, "Tube", sides=sdt)
        mb.add_tube([V((p.x, p.y + 0.05, p.z - 0.015)), V((p.x * 0.2, p.y + 0.0, KZ))], RF * 0.8, "Tube", sides=sdt)


def tank(mb, lod: int) -> None:
    """Бак-канистра (tank): скруглённые рёбра, вертикальная горловина с крышкой на верху в точке filler."""
    c = V(TK["center"])
    sx, sy, sz = TK["size"]
    if lod == 2:
        box(mb, c, (sx, sy, sz), "Tank")
        return
    seg, rings = (12, 6) if lod == 0 else (8, 4)
    pillow(mb, c, (sx / 2, sy / 2, sz / 2), "Tank", e=0.25, seg=seg, rings=rings)
    if lod == 0:
        f = V(TK["filler"])
        mb.add_tube([V((f.x, f.y, f.z - 0.02)), V((f.x, f.y, f.z + 0.012))], 0.03, "Tank", sides=10)
        mb.add_tube([V((f.x, f.y, f.z + 0.012)), V((f.x, f.y, f.z + 0.022))], 0.036, "Fitting", sides=10)


def wheel(mb, c: Vector, sign: int, d: float, w: float, lod: int) -> None:
    """Колесо: LOD0 — шина с протектором-текстурой (UV как у wheel_parts), штампованный диск с выпуклой ступицей;
    LOD1/2 — цилиндр."""
    if lod > 0:
        sides = 12 if lod == 1 else 8   # вершина строго внизу: 270° кратно шагу
        mb.add_tube([c - Vector((w / 2, 0, 0)), c + Vector((w / 2, 0, 0))], d / 2, "Wheel", sides=sides)
        return
    R, hw = d / 2, w / 2
    hr = 0.31 * R * 0.5 + 0.012               # высота боковины ≈ 15 % радиуса + запас
    rc = R - hr
    nseg, nprof = 14, 8

    def at(dx, r, ang):
        return c + Vector((dx, r * math.sin(ang), r * math.cos(ang)))

    prof = []
    for k in range(nprof):
        a = 2 * math.pi * k / nprof
        ca, sa = math.cos(a), math.sin(a)
        prof.append((hw * math.copysign(abs(ca) ** 0.55, ca), rc + hr * math.copysign(abs(sa) ** 0.55, sa)))
    rings, uv = [], []
    for j in range(nseg + 1):
        ang = 2 * math.pi * j / nseg
        rings.append([at(dx, r, ang) for dx, r in prof] + [at(*prof[0], ang)])
        uv.append([(4 * j / nseg, k / nprof) for k in range(nprof + 1)])
    mb.add_grid(rings, "Wheel", uv, flip=(sign < 0))
    rim = rc - hr * 0.35
    for sx in (-1, 1):                         # диск обода с двух сторон, у борта и выпуклая ступица
        mb.add_face([mb.add_vert(at(sx * hw * 0.5, rim, 2 * math.pi * j / nseg)) for j in range(nseg)][::sx], "WheelRim", smooth=False)
    mb.add_tube([c + Vector((-hw * 0.8, 0, 0)), c + Vector((hw * 0.8, 0, 0))], [0.045, 0.045], "WheelRim", sides=8)
    mb.add_tube([c + Vector((sign * hw * 0.8, 0, 0)), c + Vector((sign * hw * 0.95, 0, 0)),
                 c + Vector((sign * hw * 1.1, 0, 0))], [0.04, 0.035, 0.02], "WheelRim", sides=8)
    # ось: от узла рамы сквозь ступицу, гайка снаружи
    mb.add_tube([c + Vector((-sign * hw * 0.8, 0, 0)), c + Vector((sign * hw * 1.15, 0, 0))], 0.0085, "Steel", sides=6)
    mb.add_tube([c + Vector((sign * hw * 1.1, 0, 0)), c + Vector((sign * hw * 1.4, 0, 0))], 0.0115, "Steel", sides=6)


def main_gear(mb, lod: int) -> None:
    """Основное шасси: на каждой стороне треугольник труб от киля (передний и задний рычаги к узлу колеса) и
    подкос-амортизатор от мачты с витой пружиной."""
    sdt = (6, 4, 3)[lod]
    zc = GZ + D["wheel_rear_d"] / 2
    for s in (-1, 1):
        h = V((s * (D["track"] / 2 - D["tire_rear_w"] / 2 - 0.02), Y_R, zc))       # узел оси у внутренней стороны шины
        k1, k2 = V((0, -0.38, KZ)), V((0, -0.85, KZ))
        m = V((0, mast_y(-1.62), -1.62))
        if lod == 2:
            mb.add_tube([k1, h, k2], RF, "Tube", sides=sdt)
            continue
        mb.add_tube([k1, h], RF, "Tube", sides=sdt)
        mb.add_tube([k2, h], RF, "Tube", sides=sdt)
        mb.add_tube([h, h + V((s * 0.06, 0, 0))], RF * 1.2, "Steel", sides=sdt)
        a, b = m, h + V((0, 0, 0.03))
        if lod == 0:                                  # амортизатор: корпус сверху, шток снизу, пружина между
            p = lambda t: a.lerp(b, t)
            mb.add_tube([a, p(0.38)], RF * 0.85, "Tube", sides=sdt)
            mb.add_tube([p(0.38), b], 0.009, "Steel", sides=6)
            spring(mb, p(0.4), p(0.9), 0.034, 0.008, 6, 8, "Spring", 3)
            mb.add_tube([p(0.9) - (b - a).normalized() * 0.01, p(0.9) + (b - a).normalized() * 0.01], 0.04, "Fitting", sides=8)
        else:
            mb.add_tube([a, b], RF * 0.8, "Tube", sides=sdt)


def front_gear(mb, lod: int, nose, y_f: float, zc_f: float) -> None:
    sdt = (6, 4, 3)[lod]
    head = V((0, 1.1, -2.0))
    if lod == 2:
        mb.add_tube([nose, V((0, y_f, zc_f))], RF, "Tube", sides=sdt)
        return
    mb.add_tube([nose, head], RF, "Tube", sides=sdt)
    for s in (-1, 1):
        mb.add_tube([head + V((s * 0.075, 0, 0.0)), V((s * 0.075, y_f, zc_f))], RF * 0.85, "Tube", sides=sdt)
    mb.add_tube([head + V((-0.075, 0, 0)), head + V((0.075, 0, 0))], RF * 0.85, "Tube", sides=sdt)
    # брызговик над колесом — дуга по радиусу колеса + 3 см
    rf = D["wheel_front_d"] / 2 + 0.03
    wf = D["tire_front_w"] / 2 + 0.015
    n = 8 if lod == 0 else 4
    rows = []
    for i in range(n + 1):
        a = math.radians(-45 + 165 * i / n)             # 0 — вверх; + вперёд
        rows.append([V((x, y_f + rf * math.sin(a), zc_f + rf * math.cos(a))) for x in (-wf, -wf * 0.35, wf * 0.35, wf)])
    mb.add_grid(rows, "Fairing", smooth=True)
    if lod == 0:
        for s in (-1, 1):
            mb.add_tube([V((s * wf * 0.7, y_f + rf * math.sin(math.radians(-5)), zc_f + rf * math.cos(math.radians(-5)))),
                         head + V((s * 0.075, 0.0, -0.12))], 0.008, "Steel", sides=5)
    # подножки руления и педаль газа: плоские площадки pedal_size под pedal_angle_deg (передний край выше),
    # плоскость через seat.foot_l/foot_r/throttle_pedal (опора всей стопой)
    pw, pl = S["pedal_size"]
    pr = Matrix.Rotation(math.radians(S["pedal_angle_deg"]), 3, "X")     # z → нормаль (0, −sin a, cos a)
    pn, pu = pr @ V((0, 0, 1)), pr @ V((0, 1, 0))                         # нормаль к пилоту, вдоль площадки вперёд-вверх
    for p in (V(S["foot_l"]), V(S["foot_r"])):
        box(mb, p - pn * 0.0075, (pw, pl, 0.015), "Fitting", rot=pr)
        rear = p - pu * (pl * 0.5 - 0.03) - pn * 0.015
        mb.add_tube([rear, head + V((p.x * 0.5, 0.0, -0.05))], RF * 0.75, "Tube", sides=sdt)
        if lod == 0:
            mb.add_tube([p - pn * 0.015, V((p.x * 0.3, 1.1, -2.25))], RF * 0.6, "Tube", sides=sdt)
    tp = V(S["throttle_pedal"])
    box(mb, tp + pn * 0.004, (pw * 0.8, pl * 0.8, 0.008), "Pedal", rot=pr)     # накладка педали газа на подножке
    mb.add_tube([V((-0.15, 1.1, -2.25)), V((0.15, 1.1, -2.25))], RF * 0.7, "Tube", sides=sdt)
    # приборный обтекатель над носом на стойках от головы вилки и фара
    tilt = Matrix.Rotation(math.radians(-14), 3, "X")
    if lod == 0:
        for s in (-1, 1):
            mb.add_tube([head + V((s * 0.05, 0, 0)), V((s * 0.06, 1.08, -1.78))], 0.012, "Tube", sides=6)
        pillow(mb, V((0, 1.1, -1.72)), (0.15, 0.1, 0.07), "Fairing", rot=tilt, e=0.45, seg=10, rings=6)
        mb.add_tube([head + V((0, 0.0, 0.0)), V((0, 1.2, -1.93))], 0.01, "Tube", sides=5)
        mb.add_tube([V((0, 1.2, -1.93)), V((0, 1.27, -1.93))], 0.05, "Lamp", sides=10)
    else:
        pillow(mb, V((0, 1.1, -1.72)), (0.15, 0.1, 0.07), "Fairing", rot=tilt, e=0.45, seg=8, rings=4)


def panel_rot() -> Matrix:
    """Оси панели: X вправо, Y = −нормаль (в толщину, от пилота), Z — вверх в плоскости панели."""
    n = V(P["panel"]["normal"]).normalized()
    x = V((1, 0, 0))
    return Matrix((x, -n, n.cross(x))).transposed()


def panel(mb, lod: int) -> None:
    """Приборная панель (panel): плита между пилотом и штангой на кронштейнах от переднего подкоса; приборы — круглые
    циферблаты на лицевой стороне (к пилоту)."""
    pn = P["panel"]
    c, n = V(pn["center"]), V(pn["normal"]).normalized()
    w, h = pn["size"]
    if lod == 2:
        return
    rot = panel_rot()
    box(mb, c, (w, 0.03, h), "Fairing", rot=rot)
    if lod > 0:
        return
    box(mb, c + n * 0.0155, (w - 0.02, 0.002, h - 0.02), "Pedal", rot=rot)
    for k, dx in enumerate((-w / 3, 0.0, w / 3)):
        r = 0.045 if k != 1 else 0.038
        q = c + n * 0.017 + rot @ V((dx, 0, 0))
        mb.add_tube([q, q + n * 0.006], r, "Lamp" if k == 1 else "Fitting", sides=8)
    for sx in (-1, 1):                                         # кронштейны от тыла панели к оси подкоса
        mb.add_tube([c - n * 0.015 + rot @ V((sx * w * 0.3, 0, 0)), PB], 0.008, "Steel", sides=5)


def engine_simple(mb, lod: int) -> None:
    """Упрощённый двигатель внутри Trike_LOD1/2 (в LOD0 двигатель — отдельный меш Engine_LOD0)."""
    hub = V((0, HUB_Y, EZ))
    rt = Matrix.Rotation(ALPHA, 3, "X")
    E = lambda x, a, z: hub + rt @ V((x, a, z))
    box(mb, E(0, 0.34, -0.03), (0.28, 0.3, 0.22), "EngBlack", rot=rt)
    if lod == 1:
        mb.add_tube([E(0, 0.03, 0), E(0, 0.19, 0)], 0.095, "EngSilver", sides=6)
        for a in (0.275, 0.405):
            mb.add_tube([E(0, a, 0.08), E(0, a, 0.25)], 0.06, "EngSilver", sides=5)
        mb.add_tube([E(-0.15, 0.5, -0.13), E(-0.15, 0.12, -0.13)], 0.05, "Muffler", sides=5)
    # рама под двигателем: полозья на мачту и киль
    rz = RZ
    sdt = (6, 4, 3)[lod]
    for s in (-1, 1):
        x = s * 0.14
        mb.add_tube([V((x, HUB_Y + 0.12, rz)), V((0, -0.98, KZ))], RF, "Tube", sides=sdt)
        if lod == 1:
            mb.add_tube([V((x, HUB_Y + 0.56, rz)), V((0, mast_y(-1.48), -1.48))], RF, "Tube", sides=sdt)
            mb.add_tube([V((x, HUB_Y + 0.12, rz)), V((x, HUB_Y + 0.56, rz))], RF, "Tube", sides=sdt)


def trike(lod: int, M: dict):
    mb = U.MeshBuilder()
    sd = (12, 6, 3)[lod]          # сторон у трубы
    sdt = (6, 4, 3)[lod]
    wb = D["wheelbase"]
    d_f, d_r = D["wheel_front_d"], D["wheel_rear_d"]
    w_f, w_r = D["tire_front_w"], D["tire_rear_w"]
    y_f = Y_R + wb
    zc_f, zc_r = GZ + d_f / 2, GZ + d_r / 2
    # ---- рама ----
    nose = V((0, y_f + 0.14, -2.0))                                  # нос киля/подкоса: над передней осью, на 0.14 м вперёд
    keel = [V((0, -0.98, KZ)), V((0, MAST_BASE.y, KZ)), V((0, 0.7, KZ)), nose]
    mb.add_tube(keel, RK, "Tube", sides=sd)
    mb.add_tube([V((0, 0, 0)), MAST_BASE], RM, "Tube", sides=sd)                              # мачта — одна труба
    strut = [V((0, 0, -0.03)), STRUT_CORNER, nose]                                             # передний подкос с изгибом внизу; начало изгиба — в тыле панели
    mb.add_tube(fillet(strut, 0.35, 4 if lod == 0 else 2) if lod < 2 else strut[:1] + strut[2:], RS, "Tube", sides=sd,
                up=(1, 0, 0))
    main_gear(mb, lod)
    front_gear(mb, lod, nose, y_f, zc_f)
    # ---- сиденья, бак ----
    seat(mb, S, lod, rear=False)
    panel(mb, lod)
    if P["prototype"]["seats"] == 2:
        seat(mb, SR, lod, rear=True)
        if lod == 0:
            rear_footrests(mb, lod)
    tank(mb, lod)
    # ---- колёса ----
    wheel(mb, V((0, y_f, zc_f)), 1, d_f, w_f, lod)
    wheel(mb, V((-D["track"] / 2, Y_R, zc_r)), -1, d_r, w_r, lod)
    wheel(mb, V((D["track"] / 2, Y_R, zc_r)), 1, d_r, w_r, lod)
    # ---- упрощённый двигатель (LOD1/2) и подмоторная рама (всех LOD) ----
    engine_simple(mb, lod) if lod > 0 else engine_frame(mb)
    # ---- точка подвески: пластина и болт на вершине мачты ----
    if lod == 0:
        pts = F.rounded_outline([(-0.05, -0.05), (0.05, -0.05), (0.05, 0.05), (-0.05, 0.05)], 0.015, 2)
        for dx in (-1, 1):
            F.add_prism(mb, pts, V((dx * 0.04, 0, -0.01)), V((0, 1, 0)), V((0, 0, 1)), 0.006, "Fitting")
        F.add_bolt(mb, V((0, 0, 0)), (1, 0, 0), 0.13, 0.009, "Steel")
    return mb


def engine_frame(mb) -> None:
    """Подмоторная рама Trike_LOD0 (полозья, ноги к килю и мачте); сам двигатель — меш Engine_LOD0."""
    rz = RZ
    rt = Matrix.Rotation(ALPHA, 3, "X")
    for s in (-1, 1):
        x = s * 0.14
        for a in (0.25, 0.43):                                          # стойки от полозьев к лапам двигателя
            lug = V((0, HUB_Y, EZ)) + rt @ V((s * 0.12, a, -0.205))
            mb.add_tube([V((x, lug.y, rz)), lug], RF, "Tube", sides=6)
        mb.add_tube([V((x, HUB_Y + 0.12, rz)), V((x, HUB_Y + 0.56, rz))], RF, "Tube", sides=6)
        mb.add_tube([V((x, HUB_Y + 0.12, rz)), V((0, -0.98, KZ))], RF, "Tube", sides=6)
        mb.add_tube([V((x, HUB_Y + 0.56, rz)), V((0, mast_y(-1.48), -1.48))], RF, "Tube", sides=6)
        mb.add_tube([V((x, HUB_Y + 0.56, rz)), V((0, -0.82, KZ))], RF, "Tube", sides=6)
    mb.add_tube([V((-0.14, HUB_Y + 0.12, rz)), V((0.14, HUB_Y + 0.12, rz))], RF, "Tube", sides=6)
    mb.add_tube([V((-0.14, HUB_Y + 0.56, rz)), V((0.14, HUB_Y + 0.56, rz))], RF, "Tube", sides=6)


# ---------- двигатель (Engine_LOD0) ----------

def engine() -> "U.MeshBuilder":
    """Rotax 582-типа: рядный двухцилиндровый двухтактный, цилиндры вверх с рёбрами и головками, карбюраторы с
    воздушным коробом сбоку, резонансная труба под двигателем, редуктор C к винту. Локальные оси: a — вперёд от
    фланца винта, x — вправо, z — вверх от оси винта; всё повёрнуто на prop_tilt_deg вокруг ступицы."""
    mb = U.MeshBuilder()
    hub = V((0, HUB_Y, EZ))
    rt = Matrix.Rotation(ALPHA, 3, "X")
    E = lambda x, a, z: hub + rt @ V((x, a, z))
    ncyl = int(D["engine_cyl_count"])
    rc = D["engine_cyl_d"] / 2
    pitch = D["engine_cyl_d"] * 1.05
    a_mid = 0.34
    cyls = [a_mid + (i - (ncyl - 1) / 2) * pitch for i in range(ncyl)]

    def tube(pts, r, mat, sides, up=(0, 0, 1)):
        mb.add_tube([E(*p) for p in pts], r, mat, sides=sides, up=up)

    tube([(0, 0.035, 0), (0, 0.06, 0), (0, 0.08, 0), (0, 0.12, 0), (0, 0.19, 0)], [0.06, 0.06, 0.095, 0.1, 0.1], "EngSilver", 12)
    pillow(mb, E(0, a_mid, -0.03), (0.14, 0.15, 0.11), "EngBlack", rot=rt, e=0.35, seg=12, rings=6)
    tube([(0, 0.49, -0.03), (0, 0.52, -0.03)], 0.085, "EngSilver", 10)                    # передняя крышка
    for s in (-1, 1):                                                                    # лапы крепления к раме
        for a in (a_mid - 0.09, a_mid + 0.09):
            mb.add_box(E(s * 0.12, a, -0.17), (0.05, 0.05, 0.07), "Fitting", rot=rt)
    fin_z = [0.07, 0.085, 0.10, 0.115, 0.13, 0.145, 0.16, 0.175, 0.19]
    fin_r = [rc * k for k in (0.8, 1.0, 1.0, 0.8, 0.8, 1.0, 1.0, 0.8, 0.8)]
    for a in cyls:
        tube([(0, a, z) for z in fin_z], fin_r, "EngSilver", 10)
        tube([(0, a, 0.19), (0, a, 0.225), (0, a, 0.25), (0, a, 0.262)], [rc * 0.8, rc * 0.75, rc * 0.55, rc * 0.2], "EngBlack", 10)
        tube([(0, a, 0.26), (0, a, 0.3)], 0.009, "Steel", 5)                              # свеча
        # карбюратор сбоку: впускной патрубок, корпус, колпак дросселя
        tube([(0.12, a, 0.0), (0.18, a, 0.0)], 0.032, "Pedal", 8)
        tube([(0.18, a, 0.0), (0.27, a, 0.0)], 0.04, "EngBlack", 8)
        tube([(0.24, a, 0.0), (0.24, a, 0.07)], 0.028, "Steel", 6)
        tube([(0.27, a, 0.0), (0.31, a, 0.0)], 0.035, "Pedal", 8)
        # выхлопная труба от головки вниз в резонатор
        tube(fillet([(-0.055, a, 0.14), (-0.15, a, 0.14), (-0.15, a, -0.13)], 0.06, 3), 0.022, "Muffler", 6, up=(0, 1, 0))
    tube([(0.31, cyls[0] - 0.07, 0.0), (0.31, cyls[-1] + 0.07, 0.0)], 0.05, "EngSilver", 8)   # воздушный короб
    # резонансная труба под двигателем (engine_exhaust_d, длина engine_exhaust_l: хвост сзади, к редуктору) и
    # глушитель (muffler_d, muffler_l) ниже неё, вдоль двигателя; выхлоп глушителя — вперёд
    re_, rl = D["engine_exhaust_d"] / 2, D["engine_exhaust_l"]
    a_b = 0.08                                                        # хвостовой конец камеры
    pa = lambda t: a_b + rl * t
    tube([(-0.15, pa(1.0), -0.13), (-0.15, pa(0.93), -0.13), (-0.15, pa(0.82), -0.13), (-0.15, pa(0.55), -0.13),
          (-0.15, pa(0.3), -0.13), (-0.15, pa(0.06), -0.13), (-0.15, a_b, -0.13)],
         [0.03, re_ * 0.9, re_, re_, re_ * 0.7, re_ * 0.4, re_ * 0.3], "Muffler", 8)
    rm, ml = D["muffler_d"] / 2, D["muffler_l"]
    zm = -0.13 - re_ - rm - 0.03                                      # глушитель под камерой
    tube(fillet([(-0.15, a_b, -0.13), (-0.15, a_b, zm), (-0.26, a_b + 0.07, zm)], 0.05, 2), 0.022, "Steel", 6)
    tube([(-0.26, a_b, zm), (-0.26, a_b + 0.03, zm), (-0.26, a_b + 0.07, zm), (-0.26, a_b + ml - 0.04, zm),
          (-0.26, a_b + ml, zm)], [rm * 0.5, rm * 0.9, rm, rm, rm * 0.5], "Muffler", 9)
    tube([(-0.26, a_b + ml, zm), (-0.26, a_b + ml + 0.07, zm)], 0.022, "Steel", 6)
    return mb


# ---------- винт ----------

def propeller(lod: int, M: dict) -> "U.MeshBuilder":
    """Винт в локальных осях узла Propeller: диск в плоскости XY, ось +Z (назад), ступица в начале. Деревянные
    узкие лопасти почти постоянной хорды (prop_chord_max → prop_chord_tip), закруглённый конец, крутка по режиму
    крейсера: угол установки = угол потока atan(V/ωr) + угол атаки."""
    mb = U.MeshBuilder()
    R = D["prop_d"] / 2
    nb = int(D["prop_blades"])
    r0 = 0.06
    hr = D["prop_hub_d"] / 2
    c_max, c_tip = D["prop_chord_max"], D["prop_chord_tip"]
    omega = D["prop_rpm"] * 2 * math.pi / 60
    # станции: радиус, хорда; на 0,7 R — ровно c_max
    r_tip = R - 0.05                                                  # начало закругления
    stations = [(r0, c_max * 0.72), (0.15, c_max * 0.85), (0.27, c_max * 0.96), (0.42, c_max), (0.7 * R, c_max),
                (0.78, c_max * 0.97), (r_tip, c_tip)]
    for ang in (0.6, 1.1, 1.4, 1.5707):
        stations.append((r_tip + 0.05 * math.sin(ang), c_tip * max(math.cos(ang), 0.06)))
    if lod > 0:
        stations = [stations[0], stations[3], stations[6], stations[-1]]
    # лопасти и ступица
    hs = 12 if lod == 0 else 5
    if lod == 0:                                                      # кок: цилиндр ступицы и ожива назад
        mb.add_tube([V((0, 0, -0.05)), V((0, 0, 0.04)), V((0, 0, 0.1)), V((0, 0, 0.16)), V((0, 0, 0.2))],
                    [hr * 0.9, hr, hr * 0.92, hr * 0.55, 0.012], "Hub", sides=hs)
    else:
        mb.add_tube([V((0, 0, -0.04)), V((0, 0, 0.06)), V((0, 0, 0.17))], [hr, hr, 0.012], "Hub", sides=hs)
    sec = [(0.5, 0.0), (0.3, 0.5), (0.0, 0.6), (-0.3, 0.35), (-0.5, 0.0), (-0.3, -0.15), (0.0, -0.2), (0.3, -0.12)]
    mb.tint = {}
    for b in range(nb):
        a = 2 * math.pi * b / nb + math.pi / 2
        rad = V((math.cos(a), math.sin(a), 0))
        tan = V((-math.sin(a), math.cos(a), 0))
        zax = V((0, 0, 1))
        rows, tints = [], []
        for r, chord in stations:
            beta = math.atan2(25.0, omega * r) + math.radians(4.0)         # поток 25 м/с + угол атаки 4°
            ch = tan * math.cos(beta) - zax * math.sin(beta)               # от задней кромки к передней
            nrm = -(tan * math.sin(beta) + zax * math.cos(beta))           # сторона разрежения — вперёд
            thick = chord * (0.13 if r < 0.3 else 0.1)
            c = rad * r
            if lod == 0:
                rows.append([c + ch * (sa * chord) + nrm * (sb * thick) for sa, sb in sec])
            else:
                rows.append([c + ch * (chord / 2), c - ch * (chord / 2)])
            t = (r - r0) / (R - r0)
            k = 1.0 + 0.09 * math.sin(7.0 * t + 1.7 * b) - 0.1 * (1 - t) ** 2
            tints.append((k * 1.04, k, k * 0.94))
        base = len(mb.verts)
        mb.add_grid(rows, "Blade", wrap=(lod == 0))
        ncol = len(rows[0])
        for i, tt in enumerate(tints):
            for j in range(ncol):
                mb.tint[base + i * ncol + j] = tt
        if lod == 0:                                                      # торец закруглённого конца — колпак
            mb.add_face([base + (len(rows) - 1) * ncol + j for j in range(ncol)][::-1], "Blade", smooth=False)
    # оси узла: ось двигателя (назад) = локальная −Y объекта Blender, плоскость диска XZ, «верх» Godot = +Z
    # объекта: старая локальная (x, y, z) → (x, −z, y), поворот вокруг X на +90°
    mb.verts = [(x, -z, y) for x, y, z in mb.verts]
    return mb


def unwrap(ob) -> None:
    """Развёртка UV0 без наложений в [0, 1] (smart project с упаковкой островов)."""
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(45), island_margin=0.004, scale_to_bounds=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    ob.select_set(False)


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
    eng = build_mesh(engine(), "Engine_LOD0", M)
    unwrap(eng)
    print(f"ENGINE LOD0: {U.tri_count([eng.name])} tris")

    # узел винта: локальная Z — ось двигателя (назад), наклон носом вверх
    tilt = D["prop_tilt_deg"]
    hub = Vector((0, HUB_Y, EZ))
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
    pm = panel_rot()
    U.empty("InstrumentPanel", P["panel"]["center"], matrix=Matrix.Translation(V(P["panel"]["center"])) @ pm.to_4x4(), size=0.1)
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
