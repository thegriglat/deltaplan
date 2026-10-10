"""Ветряк и кабинка канатной дороги для слоя OSM (L6, osm-look OL-3):
assets/models/osm/{wind_tower,wind_rotor,cable_cabin}.glb (+ assets/source/osm/*.blend, *.png).

    blender --background --python tools/blender/build_osm_wind_cable.py

Лоупольные меши + процедурные текстуры (numpy, CC0-материалов не берём). Единицы — м, оси Blender
(+Z вверх, экспорт «+Y up»: Blender (x, y, z) → Godot (x, z, −y)).

wind_tower.glb — ветряк 2–3 МВт с высотой ступицы HUB_H = 80 м (код масштабирует равномерно по h/80):
  * нода Tower — конусная башня (радиус основания 2,0 м, как osm_pilot.verticals.radius_m.wind),
    начало — центр основания на земле; текстура окрашенной стали со швами, фланцами, потёками, дверью;
  * нода Nacelle — гондола, начало — ось рыскания на верхушке башни, нос по +X (Godot +X);
  * пустышка Hub (ребёнок Nacelle) — центр ступицы в системе гондолы: нос + верх по ступице.
wind_rotor.glb — ротор: нода Rotor, начало — центр ступицы, ось вращения — локальная Z Godot
  (обтекатель смотрит в +Z), три лопасти в плоскости XY, радиус 40,5 м; лопасть — 7 сечений
  профиля с круткой, текстура лопасти (серый корень, белая, красные полосы на конце).
cable_cabin.glb — кабинка канатки: нода Cabin, начало — точка зацепа на тросе, кабина ниже
  (вниз по −Y Godot), вдоль троса — локальная Z Godot, двери по бокам ±X; зажим, подвес, корпус
  с остеклением (текстура 256²).
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

OUT = os.path.join(U.MODELS, "osm")
SRC = os.path.join(U.SOURCE, "osm")

HUB_H = 80.0           # высота ступицы эталонной модели, м
TOWER_R0, TOWER_R1 = 2.0, 1.35
TOP_Z = 78.8           # верх башни = ось рыскания гондолы
HUB_OFF = (4.2, 0.0, 1.2)  # ступица в системе гондолы (x — вперёд по носу, z — вверх)
BLADE_R = 40.5         # от центра ступицы до конца лопасти


# --- процедурные текстуры -----------------------------------------------------------------------


def smooth_noise(h: int, w: int, ny: int, nx: int, seed: int) -> np.ndarray:
    """Гладкий шум 0..1: случайная сетка ny×nx, билинейно растянутая на h×w (периодично по x)."""
    rng = np.random.default_rng(seed)
    g = rng.random((ny + 1, nx + 1))
    g[:, nx] = g[:, 0]
    ys = np.linspace(0, ny, h, endpoint=False)
    xs = np.linspace(0, nx, w, endpoint=False)
    y0 = ys.astype(int)
    x0 = xs.astype(int)
    fy = (ys - y0)[:, None]
    fx = (xs - x0)[None, :]
    fy = fy * fy * (3 - 2 * fy)
    fx = fx * fx * (3 - 2 * fx)
    a = g[y0][:, x0] * (1 - fx) + g[y0][:, x0 + 1] * fx
    b = g[y0 + 1][:, x0] * (1 - fx) + g[y0 + 1][:, x0 + 1] * fx
    return a * (1 - fy) + b * fy


def fbm(h: int, w: int, ny: int, nx: int, seed: int, octaves: int = 4) -> np.ndarray:
    out = np.zeros((h, w))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * smooth_noise(h, w, ny * 2 ** o, nx * 2 ** o, seed + o)
        tot += amp
        amp *= 0.5
    return out / tot


def tower_texture() -> np.ndarray:
    """256×1024, строка 0 — низ (v = 0 у основания). 80 м башни по v, окружность по u."""
    W, H = 256, 1024
    v = (np.arange(H) + 0.5) / H           # 0..1 снизу вверх
    z = v * TOP_Z                            # метры над землёй
    base = np.array([0.86, 0.87, 0.86])
    img = np.ones((H, W, 3)) * base
    # потёки: шум, растянутый по вертикали
    streak = fbm(H, W, 3, 40, 11, 3)
    img *= (0.93 + 0.12 * streak)[..., None]
    # общая пятнистость
    img *= (0.96 + 0.08 * fbm(H, W, 24, 8, 21, 3))[..., None]
    # сварные швы каждые ~3,3 м и фланцы секций (26,3 и 52,6 м)
    for zs in np.arange(3.3, TOP_Z, 3.3):
        r = int(zs / TOP_Z * H)
        img[max(r - 1, 0):r + 1] *= 0.93
    for zs in (TOP_Z / 3, 2 * TOP_Z / 3):
        r = int(zs / TOP_Z * H)
        img[r - 3:r + 3] *= 0.82
        # ржавый потёк под фланцем
        rust = np.clip(fbm(H, W, 2, 60, 31, 2) - 0.45, 0, 1) * 1.6
        fall = np.exp(-np.clip(r - np.arange(H), 0, None) / 40.0)
        fall[np.arange(H) > r] = 0
        m = (rust * fall[:, None] * 0.55)[..., None]
        img = img * (1 - m) + m * np.array([0.55, 0.4, 0.3]) * img
    # грязь у основания (первые 7 м) и мелкая зернистость
    dirt = np.clip(1.0 - z / 7.0, 0, 1)[:, None] ** 1.5
    dirt = dirt * (0.4 + 0.6 * fbm(H, W, 20, 16, 41, 3))
    img *= (1 - 0.45 * dirt)[..., None]
    # дверь: u 0.21..0.29 (≈1,1 м), 0,2..2,4 м
    c0, c1 = int(0.21 * W), int(0.29 * W)
    r0, r1 = int(0.2 / TOP_Z * H), int(2.4 / TOP_Z * H)
    img[r0:r1, c0:c1] = np.array([0.30, 0.34, 0.38])
    img[r0:r1, c0:c0 + 2] = 0.55
    img[r0:r1, c1 - 2:c1] = 0.55
    img[r1 - 2:r1, c0:c1] = 0.55
    img[r0:r0 + 2, c0:c1] = 0.55
    # красная полоса-маркировка у верха (авиационная метка) — узкая, 1,5 м
    r0, r1 = int(70.0 / TOP_Z * H), int(71.5 / TOP_Z * H)
    img[r0:r1] = img[r0:r1] * 0.3 + np.array([0.75, 0.12, 0.1]) * 0.7
    img += (np.random.default_rng(5).random((H, W, 1)) - 0.5) * 0.02
    return np.clip(img, 0, 1)


def blade_texture() -> np.ndarray:
    """128×512: u — по периметру сечения (шов в u=0), v — вдоль лопасти от корня (0) до конца (1)."""
    W, H = 128, 512
    v = (np.arange(H) + 0.5) / H
    r = 1.4 + v * (BLADE_R - 1.4)
    img = np.ones((H, W, 3)) * np.array([0.93, 0.94, 0.93])
    img *= (0.96 + 0.07 * fbm(H, W, 16, 6, 51, 3))[..., None]
    # корень — серый металл/стеклопластик до 5 м
    root = np.clip((5.0 - r) / 3.0, 0, 1)[:, None, None]
    img = img * (1 - root) + root * np.array([0.55, 0.57, 0.6]) * img
    # передняя кромка (u≈0 и u≈1) — слегка желтее и темнее от эрозии на внешней трети
    u = (np.arange(W) + 0.5) / W
    edge = np.exp(-np.minimum(u, 1 - u) / 0.04)[None, :]
    outer = np.clip((r - 20) / 20.0, 0, 1)[:, None]
    img *= (1 - 0.12 * edge * outer)[..., None]
    # красные полосы на конце (последние 3 м через 1,5 м)
    for a, b in ((BLADE_R - 3.0, BLADE_R - 1.9), (BLADE_R - 1.0, BLADE_R)):
        m = ((r >= a) & (r <= b))[:, None, None]
        img = np.where(m, np.array([0.78, 0.14, 0.1]) * (0.95 + 0.05 * img), img)
    # швы: тонкие линии вдоль лопасти на u=0.5 (задняя кромка)
    img[:, int(0.5 * W) - 1:int(0.5 * W) + 1] *= 0.88
    return np.clip(img, 0, 1)


# --- ветряк -------------------------------------------------------------------------------------


def build_tower(mats: dict, img_tower) -> None:
    mb = U.MeshBuilder()
    sides = 16
    rings_z = [0.0, TOP_Z * 0.5, TOP_Z]
    rr = [TOWER_R0, 0.5 * (TOWER_R0 + TOWER_R1), TOWER_R1]
    pts = [(0.0, 0.0, z) for z in rings_z]
    mb.add_tube(pts, rr, "tower", sides=sides, cap=False, uv_v=[z / TOP_Z for z in rings_z])
    tower = mb.build("Tower", mats)
    # гондола: тело с носом по +X, начало на верхушке башни
    nb = U.MeshBuilder()
    sections = [(-5.4, 0.8), (-3.4, 1.35), (-0.5, 1.7), (2.8, 1.7), (3.6, 1.25)]
    npts = [(x, 0.0, 1.2) for x, _ in sections]
    nb.add_tube(npts, [r for _, r in sections], "nacelle", sides=12, cap=True, ellipse=(1.0, 0.8))
    # вентиляционная надстройка и метеомачта
    nb.add_box((-1.8, 0.0, 2.55), (2.2, 1.1, 0.35), "nacelle")
    nb.add_box((-4.2, 0.0, 2.35), (0.1, 0.1, 1.3), "mast")
    nac = nb.build("Nacelle", mats)
    nac.location = (0.0, 0.0, TOP_Z)
    for ob in (tower, nac):
        ob.select_set(False)
    # переносим вершины гондолы в локальную систему (location задан → вершины были в мировых z=1.2…)
    # вершины построены относительно оси рыскания (z — от верха башни), location сдвигает на TOP_Z
    hub = U.empty("Hub", HUB_OFF, parent=None, size=0.5)
    hub.parent = nac
    hub.matrix_parent_inverse = Matrix.Identity(4)
    hub.location = HUB_OFF


def blade_mesh(mb: "U.MeshBuilder", angle: float) -> None:
    stations = [(1.4, 2.0, 1.0, 12.0), (3.5, 3.8, 0.5, 14.0), (9.0, 4.0, 0.3, 11.0),
                (16.0, 3.4, 0.24, 6.0), (28.0, 2.4, 0.19, 2.5), (38.0, 1.5, 0.15, 0.5),
                (BLADE_R, 0.9, 0.12, 0.0)]
    section = [(0.0, 0.0), (0.18, 0.5), (0.5, 0.36), (1.0, 0.0), (0.55, -0.24), (0.2, -0.38)]
    rows = []
    uvs = []
    ca, sa = math.cos(angle), math.sin(angle)
    n = len(section)
    for i, (r, chord, tk, twist) in enumerate(stations):
        tw = math.radians(twist)
        ring = []
        for c, t in section:
            x = (c - 0.3) * chord
            y = t * tk * chord
            xr = x * math.cos(tw) - y * math.sin(tw)
            yr = x * math.sin(tw) + y * math.cos(tw)
            # лопасть вдоль Z; поворот вокруг оси ротора Y на angle
            px, pz = xr * ca + r * sa, -xr * sa + r * ca
            ring.append((px, yr, pz))
        ring.append(ring[0])
        rows.append(ring)
        v = (r - 1.4) / (BLADE_R - 1.4)
        uvs.append([(k / n, v) for k in range(n + 1)])
    mb.add_grid(rows, "blade", uvs, flip=True, smooth=True)


def build_rotor(mats: dict) -> None:
    mb = U.MeshBuilder()
    for k in range(3):
        blade_mesh(mb, k * 2 * math.pi / 3)
    # обтекатель-ступица: удлинённый эллипсоид, нос в −Y Blender (= +Z Godot)
    mb.add_ellipsoid((0, 0, 0), (1.55, 2.8, 1.55), "spinner", seg=12, rings=6,
                     rot=Matrix.Identity(3))
    ob = mb.build("Rotor", mats)
    # эллипсоид вытянут по ±Y: обрезаем заднюю половину сдвигом вершин (за ступицей — гондола)
    for v in ob.data.vertices:
        if v.co.y > 0.5:
            v.co.y = 0.5 + (v.co.y - 0.5) * 0.35
    ob.data.update()


# --- кабинка ------------------------------------------------------------------------------------

CAB_W, CAB_H, CAB_L = 2.2, 2.1, 2.4   # ширина, высота, длина вдоль троса
CAB_TOP = -1.5                          # крыша кабины от точки зацепа
CAB_R = 0.45                            # радиус скругления сечения
WIN_LO, WIN_HI = 0.55, 1.65             # остекление: высота над полом кабины, м


def cabin_profile(n_arc: int = 3) -> list:
    """Сечение корпуса в плоскости XZ (x — поперёк, z — высота, 0 — зацеп): ломаная по часовой,
    начиная с середины дна; возвращает [(x, z)]."""
    w, h, r = CAB_W / 2, CAB_H, CAB_R
    z_top = CAB_TOP
    z_bot = CAB_TOP - h
    pts = [(0.0, z_bot)]
    # правая сторона вверх (дно → правый нижний угол → правая стенка → правый верхний угол → крыша)
    for cx, cz, a0 in ((w - r, z_bot + r, -90), (w - r, z_top - r, 0)):
        for k in range(n_arc + 1):
            a = math.radians(a0 + 90 * k / n_arc)
            pts.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    pts.append((0.0, z_top))
    for cx, cz, a0 in ((-w + r, z_top - r, 90), (-w + r, z_bot + r, 180)):
        for k in range(n_arc + 1):
            a = math.radians(a0 + 90 * k / n_arc)
            pts.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    # убрать дубликаты подряд
    out = []
    for p in pts:
        if not out or (abs(p[0] - out[-1][0]) > 1e-6 or abs(p[1] - out[-1][1]) > 1e-6):
            out.append(p)
    if abs(out[0][0] - out[-1][0]) < 1e-6 and abs(out[0][1] - out[-1][1]) < 1e-6:
        out.pop()
    return out


def cabin_texture(prof: list) -> tuple:
    """256×256: u — по периметру сечения (начало — середина дна), v — вдоль кабины.
    Возвращает (картинка, u-координаты точек сечения)."""
    n = len(prof)
    seg = [math.dist(prof[i], prof[(i + 1) % n]) for i in range(n)]
    total = sum(seg)
    us = [0.0]
    for s in seg:
        us.append(us[-1] + s / total)
    W, H = 256, 256
    img = np.zeros((H, W, 3))
    red = np.array([0.72, 0.1, 0.09])
    white = np.array([0.9, 0.9, 0.88])
    glass = np.array([0.18, 0.26, 0.34])
    for cx in range(W):
        u = (cx + 0.5) / W
        k = max(i for i in range(n) if us[i] <= u)
        f = (u - us[k]) / max(us[k + 1] - us[k], 1e-9)
        p0, p1 = prof[k], prof[(k + 1) % n]
        x = p0[0] + (p1[0] - p0[0]) * f
        zc = p0[1] + (p1[1] - p0[1]) * f
        zr = zc - (CAB_TOP - CAB_H)    # высота над полом кабины
        side = abs(x) > CAB_W / 2 - CAB_R * 0.55
        for cy in range(H):
            v = (cy + 0.5) / H
            c = white if zr > CAB_H * 0.5 else red
            if zr > CAB_H - 0.25:
                c = white * 0.92
            if zr < 0.12:
                c = np.array([0.15, 0.15, 0.16])
            if side and WIN_LO < zr < WIN_HI and 0.07 < v < 0.93:
                # стекло с бликом: светлее кверху
                c = glass * (0.8 + 0.5 * (zr - WIN_LO) / (WIN_HI - WIN_LO))
                # стойки: двери по центру и рамка
                if abs(v - 0.5) < 0.012 or abs(v - 0.07) < 0.01 or abs(v - 0.93) < 0.01:
                    c = np.array([0.12, 0.12, 0.13])
            if side and abs(v - 0.5) < 0.006 and zr < WIN_LO:
                c = c * 0.5
            img[cy, cx] = c
    # торцы (v ≈ 0.01 — сплошной цвет корпуса): строка 0..3 — красная
    img += (smooth_noise(H, W, 20, 20, 77)[..., None] - 0.5) * 0.04
    img[:3] = red * 0.95
    return np.clip(img, 0, 1), us[:n]


def build_cabin(mats_cab: dict, img_cab, us: list, prof: list) -> None:
    mb = U.MeshBuilder()
    n = len(prof)
    half = CAB_L / 2
    # корпус: три кольца по оси Y — торец, середина, торец; торцы чуть сужены
    ys = [-half, 0.0, half]
    ks = [0.93, 1.0, 0.93]
    ctr_z = CAB_TOP - CAB_H / 2
    rows, uvs = [], []
    for y, k in zip(ys, ks):
        ring = [(p[0] * k, y, ctr_z + (p[1] - ctr_z) * k) for p in prof]
        ring.append(ring[0])
        rows.append(ring)
        v = (y + half) / CAB_L
        uvs.append([(us[i] if i < n else 1.0, v) for i in range(n + 1)])
    mb.add_grid(rows, "cabin", uvs, flip=False, smooth=False)
    for sgn, y, k in ((-1, -half, 0.93), (1, half, 0.93)):
        idx = [mb.add_vert((p[0] * k, y, ctr_z + (p[1] - ctr_z) * k)) for p in prof]
        face = list(reversed(idx)) if sgn > 0 else idx
        mb.add_face(face, "cabin", [(0.5, 0.005)] * len(face), smooth=False)
    # подвес: штанга от зажима к крыше, зажим на тросе, ролики
    mb.add_box((0, 0, -0.75), (0.1, 0.1, 1.5), "metal")
    mb.add_box((0, 0, -0.1), (0.3, 0.55, 0.28), "metal")
    mb.add_box((0, 0, CAB_TOP - 0.05), (0.9, 0.5, 0.12), "metal")
    ob = mb.build("Cabin", mats_cab)
    ob.data.update()


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)

    # --- ветряк: башня + гондола
    img_t = U.image_from_array("wind_tower_tex", tower_texture(), os.path.join(SRC, "wind_tower.png"))
    mats = {
        "tower": U.material("tower", (0.86, 0.87, 0.86), rough=0.55, image=img_t),
        "nacelle": U.material("nacelle", U.srgb((0.88, 0.89, 0.88)), rough=0.5),
        "mast": U.material("mast", U.srgb((0.2, 0.2, 0.22)), rough=0.6, metal=0.3),
    }
    build_tower(mats, img_t)
    tris = U.tri_count()
    print("TRIS wind_tower", tris)
    U.export("osm/wind_tower")

    # --- ротор
    U.reset_scene()
    img_b = U.image_from_array("wind_blade_tex", blade_texture(), os.path.join(SRC, "wind_blade.png"))
    mats_r = {
        "blade": U.material("blade", (0.93, 0.94, 0.93), rough=0.4, image=img_b, double=True),
        "spinner": U.material("spinner", U.srgb((0.9, 0.9, 0.9)), rough=0.35),
    }
    build_rotor(mats_r)
    print("TRIS wind_rotor", U.tri_count())
    U.export("osm/wind_rotor")

    # --- кабинка
    U.reset_scene()
    prof = cabin_profile()
    img_arr, us = cabin_texture(prof)
    img_c = U.image_from_array("cable_cabin_tex", img_arr, os.path.join(SRC, "cable_cabin.png"))
    mats_c = {
        "cabin": U.material("cabin", (0.9, 0.9, 0.9), rough=0.45, image=img_c, double=True),
        "metal": U.material("metal", U.srgb((0.3, 0.3, 0.33)), rough=0.5, metal=0.5),
    }
    build_cabin(mats_c, img_c, us, prof)
    print("TRIS cable_cabin", U.tri_count())
    U.export("osm/cable_cabin")


main()
