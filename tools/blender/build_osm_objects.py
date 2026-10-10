"""Опоры ЛЭП, столбы, мачты, телебашни и трубы OSM (osm-look OL-2, контракт L5):
assets/models/osm/{power_tower,power_pole,mast_lattice,tv_tower,chimney}.glb
(+ assets/source/osm/*.blend, текстуры assets/textures/osm/*.png).

    blender --background --python tools/blender/build_osm_objects.py

Лоупольно (≤ 600 треугольников на модель, ≤ 2 материала): решётка — не балки, а грани (усечённые
пирамиды, плоскости) с альфа-текстурой решётки (alpha scissor); ноги — тонкие трубки, чтобы вдали,
когда решётка в мипах «тает», оставался силуэт. Текстуры процедурные (numpy), CC0 не нужны.
Оси: метры, +Y вверх (Godot), начало — центр основания на земле; Blender Z = Godot Y, траверсы ЛЭП —
вдоль X (поперёк линии), линия — вдоль Blender Y (= −Z Godot). Размеры берутся из
configs/world_objects.json → osm_pilot (высоты, радиусы следа, точки подвеса power.*_arms_m).
Правило масштаба на экземпляре (OsmPilot): по Y = h / высота модели, по XZ = clamp((h / H)^0.75, 0.35, 1).
"""
import math
import os
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

OUT = os.path.join(U.MODELS, "osm")
SRC = os.path.join(U.SOURCE, "osm")
TEX = os.path.join(U.ROOT, "assets", "textures", "osm")
CFG = U.load_json("configs/world_objects.json")["osm_pilot"]
PW = CFG["power"]
VT = CFG["verticals"]
STEEL = (0.56, 0.58, 0.60)
RNG = np.random.default_rng(7)


# --- текстуры ---------------------------------------------------------------------------------


def _noise(h, w, k=1.0):
    n = RNG.normal(0.0, 1.0, (h, w))
    for _ in range(2):  # лёгкое размытие
        n = (n + np.roll(n, 1, 0) + np.roll(n, -1, 0) + np.roll(n, 1, 1) + np.roll(n, -1, 1)) / 5.0
    return n * k


def _seg_alpha(w, h, segs):
    """Альфа линий: segs = [(x0, y0, x1, y1, ширина)] в долях (x вправо, y вверх), сглаживание 1,2 px."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    xx = (xx + 0.5) / w
    yy = (yy + 0.5) / h
    a = np.zeros((h, w), np.float32)
    aa = 1.3 / w
    for x0, y0, x1, y1, wd in segs:
        d = np.full((h, w), 9.0, np.float32)
        for shift in (-1.0, 0.0, 1.0):  # шов по вертикали склеен (тайлится)
            ax, ay, bx, by = x0, y0 + shift, x1, y1 + shift
            vx, vy = bx - ax, by - ay
            t = np.clip(((xx - ax) * vx + (yy - ay) * vy) / (vx * vx + vy * vy + 1e-9), 0.0, 1.0)
            d = np.minimum(d, np.hypot(xx - (ax + t * vx), yy - (ay + t * vy)))
        a = np.maximum(a, np.clip((wd * 0.5 - d) / aa + 0.5, 0.0, 1.0))
    return a


def lattice_texture(name, bay_colors, size=256):
    """Решётчатая грань: две стойки по краям, X-раскосы, пояса. Пролётов по вертикали len(bay_colors);
    тайлится по V. Цвет вне линий = цвет линий (нет тёмной каймы в мипах)."""
    n = len(bay_colors)
    h = size * n
    rgb = np.zeros((h, size, 3), np.float32)
    alpha = np.zeros((h, size), np.float32)
    for i, col in enumerate(bay_colors):
        s = size
        segs = [(0.07, 0.0, 0.07, 1.0, 0.07), (0.93, 0.0, 0.93, 1.0, 0.07),
                (0.07, 0.0, 0.93, 1.0, 0.05), (0.93, 0.0, 0.07, 1.0, 0.05),
                (0.0, 0.015, 1.0, 0.015, 0.05)]
        a = _seg_alpha(s, s, segs)
        alpha[i * s:(i + 1) * s] = a
        base = np.array(col, np.float32)
        rgb[i * s:(i + 1) * s] = base + _noise(s, s, 0.03)[:, :, None]
    # шов пролёта: пояс на границе (ставит _seg_alpha с wrap), остальное — как есть
    return U.image_from_array(name, np.dstack([rgb, alpha]), os.path.join(TEX, name + ".png"))


def wood_texture(name):
    w, h = 64, 256
    g = _noise(h, w, 1.0)
    g = (g + np.roll(g, 7, 0)) * 0.5
    streak = _noise(1, w, 3.0)
    base = np.array([0.40, 0.30, 0.21], np.float32)
    rgb = base + (g * 0.05 + streak * 0.04)[:, :, None]
    return U.image_from_array(name, rgb.astype(np.float32), os.path.join(TEX, name + ".png"))


def chimney_texture(name):
    w, h = 64, 512
    rgb = np.array([0.62, 0.60, 0.57], np.float32) + (_noise(h, w, 0.05) + _noise(1, w, 0.04))[:, :, None]
    # у основания — копоть; верхние 40 % — красно-белые пояса авиационной маркировки
    v = (np.arange(h) + 0.5) / h
    rgb *= (0.78 + 0.22 * np.clip(v / 0.25, 0, 1))[:, None, None]
    band = [(0.60, 0.69, (0.78, 0.16, 0.12)), (0.69, 0.78, (0.93, 0.92, 0.9)),
            (0.78, 0.87, (0.78, 0.16, 0.12)), (0.87, 0.96, (0.93, 0.92, 0.9)),
            (0.96, 1.0, (0.78, 0.16, 0.12))]
    for lo, hi, col in band:
        m = (v >= lo) & (v < hi)
        rgb[m] = np.array(col, np.float32) + _noise(int(m.sum()), w, 0.03)[:, :, None]
    return U.image_from_array(name, rgb.astype(np.float32), os.path.join(TEX, name + ".png"))


def cabin_texture(name):
    w, h = 128, 128
    rgb = np.zeros((h, w, 3), np.float32)
    v = (np.arange(h) + 0.5) / h
    rgb[:] = np.array([0.80, 0.80, 0.78], np.float32)
    win = (v > 0.22) & (v < 0.58)
    rgb[win] = np.array([0.14, 0.20, 0.26], np.float32)
    mull = (np.arange(w) % 16) < 2  # переплёты (12 граней × 16 px = 192, берём 8 на оборот)
    rgb[np.ix_(win, mull)] = np.array([0.7, 0.7, 0.68], np.float32)
    rgb += _noise(h, w, 0.02)[:, :, None]
    return U.image_from_array(name, rgb.astype(np.float32), os.path.join(TEX, name + ".png"))


# --- помощники геометрии ----------------------------------------------------------------------


def frustum_faces(mb, mat, z0, z1, hw0, hw1, reps, v0=0.0):
    """4 грани усечённой пирамиды (полуширина hw0 внизу, hw1 вверху) с решёткой, V = reps пролётов."""
    for k in range(4):
        a = math.radians(90 * k)
        ca, sa = math.cos(a), math.sin(a)
        # грань с внешней нормалью (ca, sa): u идёт вдоль (−sa, ca)
        def pt(u, hw, z):
            return (ca * hw - sa * u * hw, sa * hw + ca * u * hw, z)
        idx = [mb.add_vert(pt(-1, hw0, z0)), mb.add_vert(pt(1, hw0, z0)),
               mb.add_vert(pt(1, hw1, z1)), mb.add_vert(pt(-1, hw1, z1))]
        mb.add_face(idx, mat, uv=[(0, v0), (1, v0), (1, v0 + reps), (0, v0 + reps)], smooth=False)


def legs(mb, mat, profile, radius):
    """Четыре угловые стойки по профилю [(полуширина, z), ...]; radius — число или список на точку."""
    for sx in (-1, 1):
        for sy in (-1, 1):
            pts = [(sx * hw, sy * hw, z) for hw, z in profile]
            mb.add_tube(pts, radius, mat, sides=4, cap=True, smooth=False)


def arm(mb, mat, x_tip, z_bot, thick_root, thick_tip, width_root, x_root, bays):
    """Траверса по +x (зеркально по −x): вертикальная ферма и горизонтальная — решётка повёрнута
    на 90° (стойки решётки = пояса фермы), V вдоль траверсы."""
    for sgn in (1, -1):
        xr, xt = sgn * x_root, sgn * x_tip
        top_r, top_t = z_bot + thick_root, z_bot + thick_tip
        idx = [mb.add_vert((xr, 0, top_r)), mb.add_vert((xr, 0, z_bot)),
               mb.add_vert((xt, 0, z_bot)), mb.add_vert((xt, 0, top_t))]
        mb.add_face(idx, mat, uv=[(0, 0), (1, 0), (1, bays), (0, bays)], smooth=False)
        w_r, w_t = width_root * 0.5, width_root * 0.2
        zc = z_bot + 0.5 * thick_root
        idx = [mb.add_vert((xr, -w_r, zc)), mb.add_vert((xr, w_r, zc)),
               mb.add_vert((xt, w_t, z_bot + 0.5 * thick_tip)), mb.add_vert((xt, -w_t, z_bot + 0.5 * thick_tip))]
        mb.add_face(idx, mat, uv=[(0, 0), (1, 0), (1, bays), (0, bays)], smooth=False)


def finish(stem, mb, mats, h_expect, max_tris=600):
    ob = mb.build(stem, mats)
    ob.select_set(True)
    zs = [v.co.z for v in ob.data.vertices]
    tris = U.tri_count()
    print("OSM %s: %d tris, top %.2f (ожидалось %.2f), %d материала" % (stem, tris, max(zs), h_expect, len(mats)))
    assert tris <= max_tris and len(mats) <= 2, stem
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, stem + ".blend"), check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, stem + ".glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)


# --- модели -----------------------------------------------------------------------------------


def build_power_tower():
    U.reset_scene()
    H = float(PW["tower_height_m"])
    arms = PW["tower_arms_m"]
    r_foot = float(PW["tower_radius_m"])
    hw_b = (r_foot - 0.15) / math.sqrt(2.0)
    levels = sorted({a[1] for a in arms})
    ext = {lv: max(abs(a[0]) for a in arms if a[1] == lv) for lv in levels}
    ins = 0.9  # гирлянда изоляторов под траверсой
    zw = levels[0] - 1.6  # талия — под нижней траверсой
    hw_w, hw_t = 0.8, 0.3
    img = lattice_texture("lattice_steel", [STEEL])
    mats = {"lat": U.material("tower_lattice", U.srgb(STEEL), 0.7, 0.3, True, img, True),
            "solid": U.material("tower_solid", U.srgb((0.5, 0.52, 0.55)), 0.6, 0.4)}
    mb = U.MeshBuilder()
    frustum_faces(mb, "lat", 0.0, zw, hw_b, hw_w, 5)
    frustum_faces(mb, "lat", zw, H, hw_w, hw_t, 3)
    legs(mb, "solid", [(hw_b, 0.0), (hw_w, zw), (hw_t, H)], [0.13, 0.09, 0.06])
    for lv in levels:
        e = ext[lv]
        arm(mb, "lat", e, lv + ins, 1.0, 0.35, 1.0, hw_w * 0.9, 3)
        for a in arms:
            if a[1] == lv:
                mb.add_tube([(a[0], 0, lv), (a[0], 0, lv + ins)], 0.06, "solid", sides=4, smooth=False)
    assert levels[-1] + ins + 1.0 <= H + 0.01, "верхняя траверса выше верха опоры"
    finish("power_tower", mb, mats, H)


def build_power_pole():
    U.reset_scene()
    H = float(PW["pole_height_m"])
    arms = PW["pole_arms_m"]
    r = float(PW["pole_radius_m"])
    img = wood_texture("wood_pole")
    mats = {"wood": U.material("pole_wood", U.srgb((0.4, 0.3, 0.21)), 0.9, 0.0, False, img),
            "ins": U.material("pole_insulator", U.srgb((0.62, 0.66, 0.64)), 0.4)}
    mb = U.MeshBuilder()
    mb.add_tube([(0, 0, 0), (0, 0, H)], [r * 0.95, r * 0.72], "wood", sides=7, cap=True, smooth=False,
                uv_v=[0.0, 1.0])
    side = [a for a in arms if abs(a[0]) > 0.01]
    z_arm = min(a[1] for a in side) - 0.12
    half = max(abs(a[0]) for a in side) + 0.2
    mb.add_box((0, 0, z_arm), (2 * half, 0.1, 0.12), "wood")
    for a in arms:
        z0 = a[1] - 0.14 if abs(a[0]) > 0.01 else H
        mb.add_tube([(a[0], 0, z0), (a[0], 0, a[1])], 0.045, "ins", sides=5, smooth=False)
    finish("power_pole", mb, mats, H + max(a[1] for a in arms) - H)


def build_mast():
    U.reset_scene()
    H = float(VT["model_h_m"]["mast_lattice"])
    R = float(VT["radius_m"]["mast_lattice"])
    rc = R * 0.62  # описанный радиус треугольного сечения
    red, white = (0.82, 0.2, 0.12), (0.93, 0.92, 0.9)
    img = lattice_texture("lattice_mast", [red, white])
    mats = {"lat": U.material("mast_lattice", U.srgb(white), 0.7, 0.2, True, img, True),
            "solid": U.material("mast_solid", U.srgb((0.6, 0.62, 0.64)), 0.6, 0.3)}
    mb = U.MeshBuilder()
    corners = [(rc * math.cos(math.radians(90 + 120 * k)), rc * math.sin(math.radians(90 + 120 * k)))
               for k in range(3)]
    zt = H * 0.93
    bays = round(zt / (1.4 * rc * math.sqrt(3.0)) / 2.0) * 2
    for k in range(3):
        (x0, y0), (x1, y1) = corners[k], corners[(k + 1) % 3]
        idx = [mb.add_vert((x0, y0, 0)), mb.add_vert((x1, y1, 0)),
               mb.add_vert((x1, y1, zt)), mb.add_vert((x0, y0, zt))]
        mb.add_face(idx, "lat", uv=[(0, 0), (1, 0), (1, bays / 2), (0, bays / 2)], smooth=False)
    for x, y in corners:
        mb.add_tube([(x, y, 0), (x, y, zt)], 0.07, "solid", sides=3, smooth=False)
    # площадка с антеннами на 2/3 высоты и шпиль
    zp = H * 0.68
    plat = [(R * 0.92 * math.cos(2 * math.pi * k / 6), R * 0.92 * math.sin(2 * math.pi * k / 6), zp)
            for k in range(6)]
    mb.add_face([mb.add_vert(p) for p in plat], "solid", smooth=False)
    mb.add_face([mb.add_vert(p) for p in reversed(plat)], "solid", smooth=False)
    for k in range(3):
        a = math.radians(30 + 120 * k)
        mb.add_box((R * 0.8 * math.cos(a), R * 0.8 * math.sin(a), zp + 1.0), (0.12, 0.35, 1.8), "solid")
    mb.add_tube([(0, 0, zt), (0, 0, H)], [0.12, 0.04], "solid", sides=4, smooth=False)
    finish("mast_lattice", mb, mats, H)


def ostankino_texture(name, h0):
    """Ствол, «шайба», антенна: V = z / h0 по всей высоте (256 × 1024, строка 0 — земля)."""
    w, h = 256, 1024
    v = (np.arange(h) + 0.5) / h
    z = v * h0
    rgb = np.zeros((h, w, 3), np.float32)
    rgb[:] = np.array([0.80, 0.79, 0.76], np.float32)
    # потёки: вертикальные полосы тоном, у основания темнее
    streak = _noise(1, w, 2.5) * 0.04
    rgb += streak[:, :, None] + _noise(h, w, 0.025)[:, :, None]
    rgb *= (0.82 + 0.18 * np.clip(z / 250.0, 0, 1))[:, None, None]
    # тёмные пояса на стволе
    for zb in (90, 130, 170, 210, 250, 290):
        m = np.abs(z - zb) < 1.8
        rgb[m] = np.array([0.34, 0.35, 0.37], np.float32)
    # нижняя часть «тюльпана» темнее, верхние технические этажи серее
    m = (z > 318) & (z < 329)
    rgb[m] *= 0.86
    m = (z > 337) & (z < 352)
    rgb[m] = np.array([0.55, 0.56, 0.58], np.float32) + _noise(int(m.sum()), w, 0.02)[:, :, None]
    # остекление «Седьмого неба»: 24 грани, переплёты на границах граней
    m = (z >= 329) & (z <= 337)
    glass = np.array([0.10, 0.16, 0.23], np.float32)
    rgb[m] = glass
    for k in range(24):
        x = int(round(k * w / 24.0)) % w
        rgb[np.ix_(np.where(m)[0], [x, (x + 1) % w])] = np.array([0.72, 0.72, 0.70], np.float32)
    # антенна: красно-белая разметка
    m = z >= 387
    band = (np.floor((z - 387.0) / 21.8).astype(int)) % 2
    for i in np.where(m)[0]:
        rgb[i] = np.array([0.82, 0.18, 0.12] if band[i] == 0 else [0.93, 0.92, 0.90], np.float32)
    return U.image_from_array(name, rgb.astype(np.float32), os.path.join(TEX, name + ".png"))


def ostankino_legs_texture(name):
    """Грань конуса-основания: бетон с арочным проёмом (alpha = 0 внутри арки)."""
    w, h = 128, 256
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    u = (xx + 0.5) / w
    v = (yy + 0.5) / h
    hw = 0.28
    spring = 0.34
    rise = 0.22
    dx = (u - 0.5) / hw
    inside = (np.abs(dx) < 1.0) & (v < spring + rise * np.sqrt(np.clip(1.0 - dx * dx, 0, 1)))
    a = np.where(inside, 0.0, 1.0).astype(np.float32)
    rgb = np.zeros((h, w, 3), np.float32)
    rgb[:] = np.array([0.74, 0.73, 0.70], np.float32)
    rgb += _noise(h, w, 0.03)[:, :, None]
    return U.image_from_array(name, np.dstack([rgb, a]), os.path.join(TEX, name + ".png"))


def build_tv_tower():
    """Телебашня по образцу Останкинской (540 м): конус-основание на 10 опорах с арками (грани с
    альфа-проёмами), сужающийся бетонный ствол с поясами, «тюльпан» с остеклением на 329–337 м,
    красно-белая антенна. Пропорции — доли H = model_h_m.tv_tower; радиус следа — radius_m."""
    U.reset_scene()
    H = float(VT["model_h_m"]["tv_tower"])
    R = float(VT["radius_m"]["tv_tower"])
    k = H / 540.0
    tex = ostankino_texture("tv_ostankino", H)
    legs_tex = ostankino_legs_texture("tv_legs")
    mats = {"body": U.material("tv_body", U.srgb((0.8, 0.79, 0.76)), 0.8, 0.0, False, tex),
            "legs": U.material("tv_legs", U.srgb((0.74, 0.73, 0.7)), 0.85, 0.0, True, legs_tex, True)}
    mb = U.MeshBuilder()
    # основание: 10 граней усечённого конуса, грань = опора + арка
    zb, r0, r1 = 63.0 * k, (R - 1.0), 9.6
    n = 10
    for i in range(n):
        a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
        idx = [mb.add_vert((r0 * math.cos(a0), r0 * math.sin(a0), 0.0)),
               mb.add_vert((r0 * math.cos(a1), r0 * math.sin(a1), 0.0)),
               mb.add_vert((r1 * math.cos(a1), r1 * math.sin(a1), zb)),
               mb.add_vert((r1 * math.cos(a0), r1 * math.sin(a0), zb))]
        mb.add_face(idx, "legs", uv=[(0, 0), (1, 0), (1, 1), (0, 1)], smooth=False)
    # ствол + «тюльпан»: (z, r) в метрах Останкинской, z масштабируется на k
    prof = [(0, 9.0), (63, 9.0), (300, 5.6), (318, 6.4), (326, 14.5), (329, 19.0), (337, 19.5),
            (342, 17.0), (352, 8.5), (360, 6.2), (385, 5.0)]
    mb.add_tube([(0, 0, z * k) for z, _ in prof], [r for _, r in prof], "body", sides=24, cap=True,
                smooth=True, uv_v=[z / 540.0 for z, _ in prof])
    ant = [(385, 2.4), (440, 1.7), (500, 1.0), (540, 0.12)]
    mb.add_tube([(0, 0, z * k) for z, _ in ant], [r for _, r in ant], "body", sides=10, cap=False,
                smooth=True, uv_v=[(z + (2.0 if i == 0 else 0)) / 540.0 for i, (z, _) in enumerate(ant)])
    finish("tv_tower", mb, mats, H, 1500)


def build_chimney():
    U.reset_scene()
    H = float(VT["model_h_m"]["chimney"])
    R = float(VT["radius_m"]["chimney"])
    rb, rt = R * 0.95, R * 0.58
    img = chimney_texture("chimney")
    mats = {"con": U.material("chimney_concrete", U.srgb((0.62, 0.6, 0.57)), 0.9, 0.0, False, img),
            "soot": U.material("chimney_top", U.srgb((0.08, 0.08, 0.08)), 0.9)}
    mb = U.MeshBuilder()
    zs = [0.0, H * 0.5, H - 1.2, H]
    rs = [rb, (rb + rt) * 0.5, rt * 1.0, rt * 1.12]
    vs = [0.0, 0.5, 0.97, 1.0]
    mb.add_tube([(0, 0, z) for z in zs], rs, "con", sides=14, cap=False, smooth=True, uv_v=vs)
    disc = [(rt * 1.0 * math.cos(2 * math.pi * k / 14), rt * math.sin(2 * math.pi * k / 14), H - 0.6)
            for k in range(14)]
    mb.add_face([mb.add_vert(p) for p in disc], "soot", smooth=False)
    finish("chimney", mb, mats, H)


def main():
    for d in (TEX, OUT, SRC):
        os.makedirs(d, exist_ok=True)
    build_power_tower()
    build_power_pole()
    build_mast()
    build_tv_tower()
    build_chimney()


main()
