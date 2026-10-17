"""Дом с крышей из профлиста (RV-К6, модель tin_house): assets/models/houses/house_tin_house.glb
(+ assets/source/houses/house_tin_house.blend).

    [xvfb-run -a] blender --background --python tools/blender/build_house_tin_house.py
    ... -- --preview <каталог>      # дополнительно отрендерить кадры (Eevee) для проверки

Одноэтажный прямоугольный дом 8 x 6 м (длинная сторона вдоль X), стены (по контуру) 2,8 м,
низкая двускатная крыша 12 градусов из профлиста: конёк вдоль X, свес 0,5 м по длинным сторонам
и 0,3 м по торцам. Начало — центр контура на уровне земли. Blender (x, y, z) -> Godot (x, z, -y):
фасад с дверью смотрит на Godot +Z (Blender -Y).

Ноды LOD0 (<= 800 треугольников), LOD1 (<= 200), LOD2 (<= 40, коробка + крыша), у каждой
материалы Wall_tin_house / Roof_tin_house / Wood_tin_house. Текстуры процедурные и светлые
(цвет экземпляра умножается на альбедо), стены 256, кровля 256, дерево/стекло/бетон 128 пикселей.
Дерево, стёкла окон и бетон ступени/трубы — один атлас Wood_tin_house (раскладка в wood_atlas()).
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

NAME = "tin_house"
OUT = os.path.join(U.MODELS, "houses")
SRC = os.path.join(U.SOURCE, "houses")

L, W, H = 8.0, 6.0, 2.8          # контур по стенам и высота стен у карниза, м
ALPHA = math.radians(12.0)       # уклон кровли
OV_SIDE, OV_GABLE = 0.5, 0.3     # свесы
T_ROOF = 0.06                    # толщина листа с обрешёткой
TILE = 2.0                       # метров на повтор текстуры стен и кровли
RIDGE = H + W / 2 * math.tan(ALPHA)

# атлас Wood: u,v в 0..1 (v вверх): дерево — левая половина, стекло — правый верх, бетон — правый низ
ATLAS = {"wood": (0.02, 0.02, 0.48, 0.98), "glass": (0.52, 0.52, 0.98, 0.98),
         "concrete": (0.52, 0.02, 0.98, 0.48)}


# ---------- текстуры ----------

def _periodic_noise(n: int, rng, octaves=((2, 0.5), (4, 0.3), (8, 0.2))) -> np.ndarray:
    """Бесшовный (по обеим осям) шум n x n: сумма синусов с целыми периодами, 0..1."""
    y, x = np.mgrid[0:n, 0:n] / n * 2 * np.pi
    f = np.zeros((n, n))
    for k, amp in octaves:
        for _ in range(3):
            a, b = rng.integers(-k, k + 1, 2)
            f += amp * np.sin(a * x + b * y + rng.uniform(0, 6.28)) / 3
    f -= f.min()
    return f / max(f.max(), 1e-6)


def wall_texture(n=256) -> np.ndarray:
    """Светлая окрашенная обшивка вагонкой: 8 досок на повтор, стыки, лёгкая потёртость."""
    rng = np.random.default_rng(11)
    y = np.arange(n)[:, None] / n          # строка 0 — низ картинки
    board = (y * 8) % 1.0
    img = np.full((n, n, 3), (0.86, 0.85, 0.82))
    shade = 0.93 + 0.07 * _periodic_noise(n, rng)
    seam = np.exp(-((np.minimum(board, 1 - board) / 0.035) ** 2))   # тёмная щель между досками
    hi = np.exp(-(((board - 0.88) / 0.05) ** 2)) * 0.05              # светлая кромка
    k = shade - 0.20 * seam + hi
    per_board = rng.uniform(0.96, 1.03, 8)[(y[:, 0] * 8).astype(int) % 8][:, None]
    img *= (k * per_board)[:, :, None]
    # потёки грязи снизу
    dirt = _periodic_noise(n, rng, ((3, 0.6), (6, 0.4)))
    img *= (1.0 - 0.10 * dirt * (1 - y))[:, :, None]
    return img


def roof_texture(n=256) -> np.ndarray:
    """Профлист: 16 волн поперёк u, вдоль v — полосы; стык листов раз в повтор; пятна ржавчины.
    Строка 0 — низ картинки (v = 0); волны идут вдоль v (по скату)."""
    rng = np.random.default_rng(23)
    x = np.arange(n)[None, :] / n
    y = np.arange(n)[:, None] / n
    wave = np.cos(2 * np.pi * 16 * x)                          # профиль волны
    base = np.array((0.70, 0.73, 0.75))                       # оцинковка
    img = np.broadcast_to(base, (n, n, 3)).copy()
    lit = 0.88 + 0.12 * wave                                   # гребень светлее, впадина темнее
    col_var = rng.uniform(0.94, 1.04, 16)[(x[0] * 16).astype(int) % 16][None, :]
    img *= (lit * col_var)[:, :, None]
    # ржавчина: низкочастотные пятна, сильнее во впадинах
    rust = _periodic_noise(n, rng, ((2, 0.5), (3, 0.3), (6, 0.2)))
    m = np.clip((rust - 0.62) * 3.0, 0, 1) * (0.55 - 0.25 * wave)
    rust_col = np.array((0.60, 0.40, 0.30))
    img = img * (1 - m[:, :, None]) + rust_col * m[:, :, None] * 0.95
    # шляпки саморезов рядами у стыка листов и потёки вдоль v
    streak = _periodic_noise(n, rng, ((1, 0.2), (12, 0.8)))
    img *= (0.97 + 0.04 * streak)[:, :, None]
    for row in (0.05, 0.55):
        for xi in range(0, 16, 2):
            cx, cy = (xi + 0.5) / 16, row
            d2 = ((x - cx) ** 2 + (y - cy) ** 2) * n * n
            img *= (1 - 0.35 * np.exp(-d2 / 3.0))[:, :, None]
    # стык листов по нижней кромке повтора
    img *= (1 - 0.25 * np.exp(-((y / 0.01) ** 2)))[:, :, None]
    return img


def wood_atlas(n=128) -> np.ndarray:
    """Дерево (доски вертикально), стекло окна с переплётом, бетон. Раскладка — ATLAS."""
    rng = np.random.default_rng(37)
    img = np.zeros((n, n, 3))
    yy, xx = np.mgrid[0:n, 0:n] / n
    # дерево: доски по u (левая половина = 4 доски)
    plank = (xx * 8) % 1.0
    w = np.array((0.74, 0.66, 0.55))
    grain = 0.9 + 0.1 * np.sin(yy * 60 + np.sin(xx * 40) * 3) * rng.uniform(0.6, 1.0)
    wood = w * (grain * (1 - 0.3 * np.exp(-((np.minimum(plank, 1 - plank) / 0.05) ** 2))))[:, :, None]
    img[:] = wood
    # стекло (правый верх): тёмное с градиентом и белёсым бликом, переплёт крестом
    gl = np.array((0.10, 0.14, 0.18))
    gx = (xx - 0.5) / 0.5
    gy = (yy - 0.5) / 0.5
    glass = gl * (0.8 + 0.5 * (1 - gy))[:, :, None]
    glass += 0.10 * np.clip(1 - np.abs((gx + gy) - 0.4) * 6, 0, 1)[:, :, None]
    bar = (np.abs(gx - 0.5) < 0.035) | (np.abs(gy - 0.5) < 0.035)
    glass[bar] = (0.62, 0.55, 0.46)
    m = (xx >= 0.5) & (yy >= 0.5)
    img[m] = glass[m]
    # бетон (правый низ)
    conc = np.array((0.66, 0.65, 0.62)) * (0.9 + 0.1 * rng.random((n, n)))[:, :, None]
    m = (xx >= 0.5) & (yy < 0.5)
    img[m] = conc[m]
    return img


# ---------- геометрия ----------

class Part:
    """Набор выпуклых тел: грань ориентируется наружу относительно центра тела."""

    def __init__(self, mb: U.MeshBuilder):
        self.mb = mb

    def face(self, pts, mat, uvf, center):
        pts = [Vector(p) for p in pts]
        n = (pts[1] - pts[0]).cross(pts[2] - pts[0])
        if n.dot(pts[0] - Vector(center)) < 0:
            pts = pts[::-1]
        idx = [self.mb.add_vert(p) for p in pts]
        self.mb.add_face(idx, mat, [uvf(p, n) for p in pts], smooth=False)

    def hexa(self, v, faces, mat, uvf):
        """v — вершины тела, faces — списки индексов граней."""
        c = sum((Vector(p) for p in v), Vector()) / len(v)
        for f in faces:
            self.face([v[i] for i in f], mat, uvf, c)

    def box(self, c, size, mat, uvf):
        hx, hy, hz = (s / 2 for s in size)
        v = [(c[0] + sx * hx, c[1] + sy * hy, c[2] + sz * hz)
             for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        self.hexa(v, [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4),
                      (1, 5, 7, 3)], mat, uvf)


def uv_wall(p, n):
    """Стены: мировая развёртка по доминирующей оси нормали, TILE м на повтор."""
    if abs(n.y) >= abs(n.x):
        return (p.x / TILE + 0.5, p.z / TILE)
    return (p.y / TILE + 0.5, p.z / TILE)


def uv_roof(p, n):
    """Кровля: u поперёк волн = вдоль конька (x), v по скату (вниз от конька)."""
    s = 1.0 if p.y >= 0 else -1.0
    down = p.y * s * math.cos(ALPHA) - p.z * math.sin(ALPHA)
    return (p.x / TILE, down / TILE)


def uv_atlas(region):
    u0, v0, u1, v1 = ATLAS[region]

    def f(p, n):
        # плоский план: разворот по доминирующей оси нормали в 0..1 внутри области
        a = (abs(n.x), abs(n.y), abs(n.z))
        if a[2] >= a[0] and a[2] >= a[1]:
            s, t = p.x, p.y
        elif a[1] >= a[0]:
            s, t = p.x, p.z
        else:
            s, t = p.y, p.z
        return (u0 + (u1 - u0) * ((s * 0.7) % 1.0), v0 + (v1 - v0) * ((t * 0.7) % 1.0))
    return f


def uv_full(region):
    """Грань целиком на область атласа (стекло, дверная доска): углы -> углы прямоугольника."""
    u0, v0, u1, v1 = ATLAS[region]
    # UV зависят от позиции в грани; для квадов окон задаём через uv_quad ниже
    return u0, v0, u1, v1


def quad_uv(part, corners, mat, region, center):
    """Четырёхугольник, растянутый на область атласа (corners по кругу, первый — левый нижний)."""
    u0, v0, u1, v1 = ATLAS[region]
    uvs = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
    pts = [Vector(p) for p in corners]
    n = (pts[1] - pts[0]).cross(pts[2] - pts[0])
    if n.dot(pts[0] - Vector(center)) < 0:
        pts, uvs = pts[::-1], uvs[::-1]
    idx = [part.mb.add_vert(p) for p in pts]
    part.mb.add_face(idx, mat, uvs, smooth=False)


# детали фасада: (x центра, y стены, w, h, низ окна)
FRONT_Y, BACK_Y = -W / 2, W / 2
WINDOWS = [(-2.8, FRONT_Y, 1.2, 1.0), (2.5, FRONT_Y, 1.2, 1.0),
           (-2.2, BACK_Y, 1.2, 1.0), (1.2, BACK_Y, 1.2, 1.0),
           (L / 2, 0.0, 1.0, 1.0)]       # торец +X; (x, y) — центр окна на стене
DOOR = (0.2, FRONT_Y, 1.0, 2.05)
SILL = 0.9


def build_roof(part, mat, half_l):
    """Две плиты кровли. Нижняя поверхность проходит через верх стены (карниз H) и конёк."""
    ty = math.tan(ALPHA)
    dz = T_ROOF / math.cos(ALPHA)
    yo = W / 2 + OV_SIDE
    for s in (-1, 1):
        zb_o = H - OV_SIDE * ty            # низ у края свеса
        zb_r = H + W / 2 * ty              # низ в коньке
        xs = (-half_l, half_l)
        v = []
        for x in xs:
            v += [(x, s * yo, zb_o), (x, s * yo, zb_o + dz), (x, 0, zb_r), (x, 0, zb_r + dz)]
        # индексы: x0: 0 край-низ, 1 край-верх, 2 конёк-низ, 3 конёк-верх; x1: +4
        faces = [(0, 2, 6, 4), (1, 5, 7, 3), (0, 4, 5, 1), (2, 3, 7, 6), (0, 1, 3, 2),
                 (4, 6, 7, 5)]
        part.hexa(v, faces, mat, uv_roof)


def build_lod(level: int):
    mb = U.MeshBuilder()
    p = Part(mb)
    mw, mr, mo = "Wall", "Roof", "Wood"
    hl = L / 2
    ty = math.tan(ALPHA)
    c = (0, 0, H / 2)
    # стены: длинные — прямоугольники, торцы — пятиугольники с фронтоном
    for y in (-W / 2, W / 2):
        p.face([(-hl, y, 0), (hl, y, 0), (hl, y, H), (-hl, y, H)], mw, uv_wall, c)
    for x in (-hl, hl):
        p.face([(x, -W / 2, 0), (x, W / 2, 0), (x, W / 2, H), (x, 0, RIDGE), (x, -W / 2, H)],
               mw, uv_wall, c)
    build_roof(p, mr, hl + OV_GABLE)
    if level == 2:
        return mb
    # конёк
    if level == 0:
        p.box((0, 0, RIDGE + T_ROOF / math.cos(ALPHA) + 0.02), (L + 2 * OV_GABLE, 0.22, 0.05),
              mr, uv_roof)
    # дверь: доска на стене + ступень
    dx, dy, dw, dh = DOOR
    off = 0.04
    if level == 0:
        p.box((dx, dy - off / 2, dh / 2), (dw + 0.16, off, dh + 0.08), mo, uv_atlas("wood"))
        p.box((dx, dy - off - 0.02, dh / 2), (dw, 0.04, dh), mo, uv_atlas("wood"))
        p.box((dx, dy - 0.45, 0.1), (1.6, 0.8, 0.2), mo, uv_atlas("concrete"))
    else:
        quad_uv(p, [(dx - dw / 2, dy - 0.03, 0), (dx + dw / 2, dy - 0.03, 0),
                    (dx + dw / 2, dy - 0.03, dh), (dx - dw / 2, dy - 0.03, dh)],
                mo, "wood", (dx, dy + 1, dh / 2))
    # окна
    for (wx, wy, ww, wh) in WINDOWS:
        z0 = SILL
        if wy == 0.0:   # торец +X
            sgn = 1 if wx > 0 else -1
            xo = wx
            if level == 0:
                p.box((xo + sgn * 0.025, 0, z0 + wh / 2), (0.05, ww + 0.2, wh + 0.2), mo,
                      uv_atlas("wood"))
            quad_uv(p, [(xo + sgn * 0.055, -ww / 2 * sgn, z0), (xo + sgn * 0.055, ww / 2 * sgn, z0),
                        (xo + sgn * 0.055, ww / 2 * sgn, z0 + wh),
                        (xo + sgn * 0.055, -ww / 2 * sgn, z0 + wh)], mo, "glass",
                    (xo - sgn, 0, z0))
        else:
            sgn = -1 if wy < 0 else 1
            if level == 0:
                p.box((wx, wy + sgn * 0.025, z0 + wh / 2), (ww + 0.2, 0.05, wh + 0.2), mo,
                      uv_atlas("wood"))
            yy = wy + sgn * 0.055
            quad_uv(p, [(wx - ww / 2, yy, z0), (wx + ww / 2, yy, z0), (wx + ww / 2, yy, z0 + wh),
                        (wx - ww / 2, yy, z0 + wh)], mo, "glass", (wx, wy - sgn, z0))
    if level == 0:
        # печная труба: 8-гранная трубка на скате
        pipe_x, pipe_y = 2.0, 1.2
        zb = RIDGE - pipe_y * ty
        r = 0.09
        ring = [(pipe_x + r * math.cos(a * math.pi / 4), pipe_y + r * math.sin(a * math.pi / 4))
                for a in range(8)]
        ztop = zb + 0.9
        for i in range(8):
            a, b = ring[i], ring[(i + 1) % 8]
            p.face([(a[0], a[1], zb), (b[0], b[1], zb), (b[0], b[1], ztop), (a[0], a[1], ztop)],
                   mo, uv_atlas("concrete"), (pipe_x, pipe_y, zb))
        p.face([(a[0], a[1], ztop) for a in ring], mo, uv_atlas("concrete"),
               (pipe_x, pipe_y, ztop - 1))
    return mb


def build():
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    imgs = {
        "Wall": U.image_from_array("wall_" + NAME, wall_texture()),
        "Roof": U.image_from_array("roof_" + NAME, roof_texture()),
        "Wood": U.image_from_array("wood_" + NAME, wood_atlas()),
    }
    rough = {"Wall": 0.85, "Roof": 0.5, "Wood": 0.8}
    mats = {k: U.material("%s_%s" % (k, NAME), (1, 1, 1), rough=rough[k], image=imgs[k])
            for k in imgs}
    mats["Roof"].node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value = 0.0
    tris = {}
    for lv in range(3):
        mb = build_lod(lv)
        ob = mb.build("LOD%d" % lv, mats)
        tris[lv] = U.tri_count([ob.name])
    print("TRIS", tris)
    assert tris[0] <= 800 and tris[1] <= 200 and tris[2] <= 40, tris
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "house_%s.blend" % NAME),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "house_%s.glb" % NAME),
                              export_format="GLB", export_yup=True, use_selection=False,
                              export_apply=True, export_extras=False,
                              export_image_format="JPEG", export_jpeg_quality=85,
                              export_cameras=False, export_lights=False)
    print("EXPORTED house_%s: %s tris" % (NAME, tris))


# ---------- превью ----------

def render_previews(outdir: str):
    os.makedirs(outdir, exist_ok=True)
    sc = bpy.context.scene
    lods = {o.name: o for o in sc.objects if o.type == "MESH"}
    lods["LOD1"].location = (11, 0, 0)
    lods["LOD2"].location = (22, 0, 0)
    bpy.ops.mesh.primitive_plane_add(size=120, location=(11, 0, -0.01))
    g = bpy.context.object
    gm = bpy.data.materials.new("ground")
    gm.diffuse_color = (0.25, 0.4, 0.15, 1)
    gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.2, 0.32, 0.12, 1)
    g.data.materials.append(gm)
    sun = bpy.data.lights.new("sun", "SUN")
    sun.energy = 4.0
    so = bpy.data.objects.new("sun", sun)
    sc.collection.objects.link(so)
    so.rotation_euler = (math.radians(50), 0, math.radians(-30))
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.7, 0.9, 1)
    w.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    sc.world = w
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = 1280, 720
    sc.eevee.taa_render_samples = 16
    sc.render.image_settings.file_format = "JPEG"
    sc.render.image_settings.quality = 88
    sc.view_settings.view_transform = "Standard"
    cam_d = bpy.data.cameras.new("cam")
    cam = bpy.data.objects.new("cam", cam_d)
    sc.collection.objects.link(cam)
    sc.camera = cam

    def shot(name, pos, target, lens=35):
        cam_d.lens = lens
        cam.location = pos
        cam.rotation_euler = (Vector(target) - Vector(pos)).to_track_quat('-Z', 'Y').to_euler()
        sc.render.filepath = os.path.join(outdir, name)
        bpy.ops.render.render(write_still=True)

    # LOD0: фасад сбоку-спереди и вид сверху под 45 градусов; все LOD рядом (ряд вдоль X)
    shot("side_lod0.jpg", (4, -16, 2.0), (0, 0, 1.8), 40)
    shot("top45_lod0.jpg", (13, -13, 11), (0, 0, 1.5), 40)
    shot("top45_lods.jpg", (11, -32, 24), (11, 0, 1.0), 35)
    shot("side_lods.jpg", (11, -36, 3), (11, 0, 1.8), 35)


def main():
    build()
    if "--preview" in sys.argv:
        render_previews(sys.argv[sys.argv.index("--preview") + 1])


main()
