"""Дом на сваях с верандой (RV-К6): assets/models/houses/house_stilt_house.glb
(+ assets/source/houses/house_stilt_house.blend), влажные тропики.

    [xvfb-run -a] blender --background --python tools/blender/build_house_stilt_house.py [-- --preview <каталог>]

Метры, Blender +Z вверх = Godot +Y; начало — центр контура на земле (низ свай z = 0), длинная
сторона вдоль X. Контур по стенам 8 × 6 м; сваи 1,5 м (стойки веранды продолжены до крыши),
пол 1,5…1,65, стены 2,6 м, двускатная крыша 25° по оси X (свес сзади 0,6 м, спереди 1,3 м, с торцов
0,6 м), веранда 1,0 м вдоль всего фасада и лесенка 0,45 м — до 1,45 м за контуром. Фасад (веранда) —
Blender −Y = Godot +Z. Ноды LOD0 (≤ 800 треугольников), LOD1 (≤ 200), LOD2 (≤ 40: коробка + крыша
+ угловые сваи). Материалы Wall_/Roof_/Wood_stilt_house, текстуры процедурные 256 × 256, светлые.
Wood: дерево в v 0,1…0,7, тёмное стекло окон в v 0,82…0,98 (зерно вдоль v).
"""
import math
import os
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

NAME = "stilt_house"
OUT = os.path.join(U.MODELS, "houses")
SRC = os.path.join(U.SOURCE, "houses")
HX, HY = 4.0, 3.0            # половины контура по стенам
PILE_H, FLOOR_T, WALL_H = 1.5, 0.15, 2.6
Z_FLOOR = PILE_H + FLOOR_T   # верх пола
Z_EAVE = Z_FLOOR + WALL_H    # верх стен
PITCH = math.radians(25)
Z_RIDGE = Z_EAVE + HY * math.tan(PITCH)
OV_X, OV_BACK, OV_FRONT = 0.6, 0.6, 1.3
DECK = 1.0                   # глубина веранды (к −Y)
SZ = 256


# ---------------------------------------------------------------- текстуры
def _noise(rng, h, w, sc):
    """Гладкий шум: случайная сетка sc×sc, растянутая билинейно (тайлится)."""
    g = rng.random((sc, sc)).astype(np.float32)
    y = np.linspace(0, sc, h, endpoint=False)
    x = np.linspace(0, sc, w, endpoint=False)
    y0, x0 = y.astype(int), x.astype(int)
    fy, fx = (y - y0)[:, None], (x - x0)[None, :]
    a = g[y0][:, x0]
    b = g[y0][:, (x0 + 1) % sc]
    c = g[(y0 + 1) % sc][:, x0]
    d = g[(y0 + 1) % sc][:, (x0 + 1) % sc]
    return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy


def tex_wall(rng):
    """Горизонтальные доски 0,2 м (UV 1 = 1,6 м → 8 досок), светло-серые, нейтральные."""
    img = np.zeros((SZ, SZ, 3), np.float32)
    n = 8
    bh = SZ // n
    grain = _noise(rng, SZ, SZ, 4) * 0.5 + _noise(rng, SZ, SZ, 32)[:, ::1] * 0.2
    for i in range(n):
        tone = 0.80 + 0.08 * rng.random()
        img[i * bh:(i + 1) * bh] = tone
    img *= (0.88 + 0.12 * grain[:, :, None] / grain.max())
    for i in range(n):  # зазор между досками
        img[i * bh:i * bh + 2] *= 0.55
        img[i * bh + 2:i * bh + 4] *= 0.8
    return img * np.array([1.0, 0.98, 0.94], np.float32)


def tex_roof(rng):
    """Профлист: 8 волн по u (UV 1 = 1 м), нахлёст листов раз в 1 UV по v, пятна ржавчины."""
    u = np.linspace(0, 1, SZ, endpoint=False)
    wave = 0.5 + 0.5 * np.cos(2 * math.pi * 8 * u)
    img = np.empty((SZ, SZ, 3), np.float32)
    img[:] = (0.46 + 0.12 * wave)[None, :, None] * np.array([1.0, 0.93, 0.86], np.float32)
    rust = _noise(rng, SZ, SZ, 6) * 0.6 + _noise(rng, SZ, SZ, 24) * 0.4
    m = 0.55 * np.clip((rust - 0.62) * 4.0, 0, 1)[:, :, None]
    img = img * (1 - m) + m * np.array([0.50, 0.34, 0.26], np.float32) * (0.8 + 0.3 * wave[None, :, None])
    img[:3] *= 0.7  # линия нахлёста листов
    return img


def tex_wood(rng):
    """Серо-коричневое дерево с зерном вдоль v (0,1…0,7) и тёмное стекло окна (0,82…0,98)."""
    img = np.zeros((SZ, SZ, 3), np.float32)
    n = _noise(rng, SZ, SZ, 8)
    streak = _noise(rng, 8, SZ, 64)
    streak = np.repeat(streak[:1], SZ, axis=0)
    t = 0.50 + 0.25 * n + 0.18 * (streak - 0.5)
    img[:] = t[:, :, None] * np.array([1.0, 0.86, 0.70], np.float32)
    # v строки 0 — низ картинки (UV Blender); стекло в строках 0,82…0,98
    r0, r1 = int(0.82 * SZ), int(0.98 * SZ)
    grad = np.linspace(0.20, 0.08, r1 - r0)[:, None]
    img[r0:r1] = grad[:, :, None] * np.array([0.7, 0.9, 1.0], np.float32) + 0.0
    img[r0:r0 + 6, :, :] *= 1.5  # блик у верхнего края стекла (низ картинки = v меньше)
    return img


# ---------------------------------------------------------------- геометрия
class House:
    def __init__(self):
        self.mb = U.MeshBuilder()

    def quad(self, pts, mat, uv):
        idx = [self.mb.add_vert(p) for p in pts]
        self.mb.add_face(idx, mat, uv, smooth=False)

    def tri(self, pts, mat, uv):
        self.quad(pts, mat, uv)

    def box(self, lo, hi, mat="Wood", skip=(), uv_scale=1.6):
        """Коробка lo..hi; skip — грани без построения: 'x-','x+','y-','y+','z-','z+'."""
        (x0, y0, z0), (x1, y1, z1) = lo, hi
        faces = {
            "x-": [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)],
            "x+": [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
            "y-": [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
            "y+": [(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)],
            "z-": [(x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0)],
            "z+": [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        }
        for k, pts in faces.items():
            if k in skip:
                continue
            self.quad(pts, mat, self.uv_planar(pts, mat, k[0], uv_scale))

    def uv_planar(self, pts, mat, axis, s):
        a, b = {"x": (1, 2), "y": (0, 2), "z": (0, 1)}[axis]
        if mat == "Wood":
            # зерно вдоль v: длинная сторона грани → v в 0,1…0,7, короткая → u
            ea = max(p[a] for p in pts) - min(p[a] for p in pts)
            eb = max(p[b] for p in pts) - min(p[b] for p in pts)
            la, lb = pts and (a, b)
            long_ax, short_ax = (a, b) if ea >= eb else (b, a)
            lo_l = min(p[long_ax] for p in pts)
            ext = max(ea, eb)
            u0 = (hash((round(pts[0][0], 2), round(pts[0][1], 2), round(pts[0][2], 2))) % 97) / 97
            return [(u0 + p[short_ax] * 0.5, 0.1 + 0.6 * (p[long_ax] - lo_l) / max(ext, 1e-6))
                    for p in pts]
        return [(p[a] / s, p[b] / s) for p in pts]

    def window(self, center, w, h, face):
        """Окно на стене: рама (дерево) и стекло, чуть над стеной. face: 'y-','y+','x-','x+'."""
        cx, cy, cz = center
        for off, ww, hh, glass in ((0.012, w, h, False), (0.025, w - 0.14, h - 0.14, True)):
            if face[0] == "y":
                sg = -1 if face[1] == "-" else 1
                y = cy + sg * off
                pts = [(cx - ww / 2, y, cz - hh / 2), (cx + ww / 2, y, cz - hh / 2),
                       (cx + ww / 2, y, cz + hh / 2), (cx - ww / 2, y, cz + hh / 2)]
                if sg > 0:
                    pts.reverse()
            else:
                sg = -1 if face[1] == "-" else 1
                x = cx + sg * off
                pts = [(x, cy - ww / 2, cz - hh / 2), (x, cy + ww / 2, cz - hh / 2),
                       (x, cy + ww / 2, cz + hh / 2), (x, cy - ww / 2, cz + hh / 2)]
                if sg < 0:
                    pts.reverse()
            if glass:
                uv = [(0.3, 0.84), (0.6, 0.84), (0.6, 0.96), (0.3, 0.96)]
                if (face[0] == "y") == (sg > 0) or False:
                    pass
            else:
                uv = [(0.1, 0.2), (0.3, 0.2), (0.3, 0.6), (0.1, 0.6)]
            self.quad(pts, "Wood", uv)


def roof_slopes(h, hi_detail):
    """Два ската, двусторонние. Возвращает ничего — добавляет грани."""
    xe = HX + OV_X
    ye_f, ye_b = HY + OV_FRONT, HY + OV_BACK
    t = math.tan(PITCH)
    zf, zb = Z_RIDGE - ye_f * t, Z_RIDGE - ye_b * t
    lf, lb = ye_f / math.cos(PITCH), ye_b / math.cos(PITCH)
    # фронт (−Y): от конька вниз; нормаль вверх-наружу
    h.quad([(-xe, 0, Z_RIDGE), (-xe, -ye_f, zf), (xe, -ye_f, zf), (xe, 0, Z_RIDGE)], "Roof",
           [(-xe, 0), (-xe, lf / 2), (xe, lf / 2), (xe, 0)])
    h.quad([(-xe, 0, Z_RIDGE), (xe, 0, Z_RIDGE), (xe, ye_b, zb), (-xe, ye_b, zb)], "Roof",
           [(-xe, 0), (xe, 0), (xe, lb / 2), (-xe, lb / 2)])
    # u в UV = x (1 UV = 1 м); для ширины 9,2 м тайлится
    return xe


def gable_walls(h):
    for sx in (-1, 1):
        x = sx * HX
        pts = [(x, -HY, Z_EAVE), (x, HY, Z_EAVE), (x, 0, Z_RIDGE)]
        if sx < 0:
            pts.reverse()
        uv = [(p[1] / 1.6, p[2] / 1.6) for p in pts]
        h.tri(pts, "Wall", uv)


def walls_main(h, detail):
    """Четыре стены: длинные — прямоугольники снаружи, торцы — прямоугольник + щипец."""
    z0, z1 = Z_FLOOR, Z_EAVE
    s = 1.6
    # фасад −Y (виден с веранды) и тыл +Y
    h.quad([(-HX, -HY, z0), (HX, -HY, z0), (HX, -HY, z1), (-HX, -HY, z1)], "Wall",
           [(-HX / s, z0 / s), (HX / s, z0 / s), (HX / s, z1 / s), (-HX / s, z1 / s)])
    h.quad([(HX, HY, z0), (-HX, HY, z0), (-HX, HY, z1), (HX, HY, z1)], "Wall",
           [(HX / s, z0 / s), (-HX / s, z0 / s), (-HX / s, z1 / s), (HX / s, z1 / s)])
    for sx in (-1, 1):
        x = sx * HX
        pts = [(x, -HY, z0), (x, HY, z0), (x, HY, z1), (x, -HY, z1)]
        if sx < 0:
            pts.reverse()
        h.quad(pts, "Wall", [(p[1] / s, p[2] / s) for p in pts])
    gable_walls(h)


def piles(h, positions, section, skip=("z-",), top=PILE_H):
    r = section / 2
    for (x, y) in positions:
        h.box((x - r, y - r, 0), (x + r, y + r, top), "Wood", skip=skip)


def build_lod(lod):
    h = House()
    xs5 = [-3.6, -1.8, 0, 1.8, 3.6]
    if lod == 0:
        # сваи под домом: 5 × 3 (передний ряд — вместе со стойками веранды отдельно)
        piles(h, [(x, y) for x in xs5 for y in (-2.7, 0.0, 2.7)], 0.2, skip=("z-", "z+"))
        # продольные и поперечные балки под полом
        for y in (-2.7, 0.0, 2.7):
            h.box((-HX, y - 0.07, PILE_H - 0.2), (HX, y + 0.07, PILE_H), "Wood", skip=("x-", "x+", "z-"))
        h.box((-HX - 0.02, -HY - DECK, PILE_H), (HX + 0.02, HY + 0.02, Z_FLOOR), "Wood", skip=("z-",))
        walls_main(h, True)
        # окна и дверь
        zc = Z_FLOOR + 1.45
        h.window((-2.6, -HY, zc), 1.1, 1.0, "y-")
        h.window((2.6, -HY, zc), 1.1, 1.0, "y-")
        for x in (-2.0, 2.0):
            h.window((x, HY, zc), 1.0, 1.0, "y+")
        for sx in (-1, 1):
            h.window((sx * HX, 0.0, zc), 1.0, 1.0, "x-" if sx < 0 else "x+")
        # дверь (рама + тёмный проём в виде дерева): 1,0 × 2,0 м по центру фасада
        h.window((0.0, -HY, Z_FLOOR + 1.0), 1.0, 2.0, "y-")
        roof_slopes(h, True)
        # стойки веранды (продолжение свай) до крыши
        t = math.tan(PITCH)
        yp = -(HY + DECK - 0.1)
        for x in (-3.9, -1.3, 1.3, 3.9):
            ztop = Z_RIDGE + yp * t
            h.box((x - 0.07, yp - 0.07, 0), (x + 0.07, yp + 0.07, ztop), "Wood", skip=("z-", "z+"))
        # перила: верхний и средний поручни, два пролёта (проём для лестницы в центре)
        for (xa, xb) in ((-3.9, -0.7), (0.7, 3.9)):
            for zr in (Z_FLOOR + 0.95, Z_FLOOR + 0.45):
                h.box((xa, yp - 0.03, zr), (xb, yp + 0.03, zr + 0.06), "Wood", skip=("x-", "x+"))
        # лесенка: 3 ступени
        y0 = -(HY + DECK)
        for i in range(3):
            d = 0.15 * (i + 1)
            h.box((-0.5, y0 - d, 0.0), (0.5, y0, 1.15 - 0.4 * i), "Wood", skip=("z-", "y+"))
    elif lod == 1:
        piles(h, [(x, y) for x in (-3.6, 0, 3.6) for y in (-2.7, 2.7)], 0.2, skip=("z-", "z+"))
        h.box((-HX - 0.02, -HY - DECK, PILE_H), (HX + 0.02, HY + 0.02, Z_FLOOR), "Wood", skip=("z-",))
        walls_main(h, False)
        zc = Z_FLOOR + 1.45
        h.window((-2.6, -HY, zc), 1.1, 1.0, "y-")
        h.window((2.6, -HY, zc), 1.1, 1.0, "y-")
        h.window((0.0, -HY, Z_FLOOR + 1.0), 1.0, 2.0, "y-")
        roof_slopes(h, False)
        t = math.tan(PITCH)
        yp = -(HY + DECK - 0.1)
        for x in (-3.9, 3.9):
            h.box((x - 0.07, yp - 0.07, 0), (x + 0.07, yp + 0.07, Z_RIDGE + yp * t), "Wood",
                  skip=("z-", "z+"))
        h.box((-3.9, yp - 0.03, Z_FLOOR + 0.95), (3.9, yp + 0.03, Z_FLOOR + 1.01), "Wood",
              skip=("x-", "x+", "z-"))
    else:
        # LOD2: коробка + крыша + четыре угловые сваи (по две наружные грани)
        for sx in (-1, 1):
            for sy in (-1, 1):
                x, y = sx * 3.6, sy * 2.7
                h.quad([(x - 0.1, y + sy * 0.1, 0), (x + 0.1, y + sy * 0.1, 0),
                        (x + 0.1, y + sy * 0.1, PILE_H), (x - 0.1, y + sy * 0.1, PILE_H)][::sy if sy > 0 else -1],
                       "Wood", [(0.1, 0.1), (0.2, 0.1), (0.2, 0.6), (0.1, 0.6)])
                h.quad([(x + sx * 0.1, y - 0.1, 0), (x + sx * 0.1, y + 0.1, 0),
                        (x + sx * 0.1, y + 0.1, PILE_H), (x + sx * 0.1, y - 0.1, PILE_H)][::-1 if sx > 0 else 1],
                       "Wood", [(0.1, 0.1), (0.2, 0.1), (0.2, 0.6), (0.1, 0.6)])
        h.box((-HX, -HY - DECK, PILE_H), (HX, HY, Z_FLOOR), "Wood", skip=("z-", "x-", "x+", "y+", "z+"))
        # стены: ставим коробку без низа/верха
        walls_main(h, False)
        roof_slopes(h, False)
    return h


# ---------------------------------------------------------------- сборка
def build():
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    rng = np.random.default_rng(1313)
    imgs = {
        "Wall": U.image_from_array("Wall_" + NAME, tex_wall(rng)),
        "Roof": U.image_from_array("Roof_" + NAME, tex_roof(rng)),
        "Wood": U.image_from_array("Wood_" + NAME, tex_wood(rng)),
    }
    mats = {
        "Wall": U.material("Wall_" + NAME, (1, 1, 1), rough=0.9, image=imgs["Wall"]),
        "Roof": U.material("Roof_" + NAME, (1, 1, 1), rough=0.55, metal=0.0, double=True, image=imgs["Roof"]),
        "Wood": U.material("Wood_" + NAME, (1, 1, 1), rough=0.85, image=imgs["Wood"]),
    }
    limits = [800, 200, 40]
    for lod in range(3):
        h = build_lod(lod)
        used = {m: mats[m] for m in h.mb.mat_names}
        ob = h.mb.build("LOD%d" % lod, used)
        t = U.tri_count([ob.name])
        print("STILT_HOUSE LOD%d: %d tris" % (lod, t))
        assert t <= limits[lod], "LOD%d: %d > %d" % (lod, t, limits[lod])
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "house_%s.blend" % NAME),
                                check_existing=False, compress=True)
    glb = os.path.join(OUT, "house_%s.glb" % NAME)
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", export_yup=True,
                              use_selection=False, export_apply=True, export_extras=False,
                              export_vertex_color="NONE", export_cameras=False,
                              export_lights=False)
    print("EXPORTED %s: %d bytes" % (glb, os.path.getsize(glb)))
    return glb


# ---------------------------------------------------------------- превью
def preview(glb, out):
    import render_views as RV
    from mathutils import Vector
    os.makedirs(out, exist_ok=True)
    U.reset_scene()
    RV.setup_scene()
    bpy.ops.import_scene.gltf(filepath=glb)
    objs = {o.name.split(".")[0]: o for o in bpy.data.objects if o.type == "MESH"}
    for ob in objs.values():  # glTF: ноды на корне, у LOD нет родителя-пустышки
        ob.rotation_mode = "XYZ"
    gap = 14.0
    objs["LOD1"].location.x += gap
    objs["LOD2"].location.x += 2 * gap
    bpy.context.view_layer.update()
    sc = bpy.context.scene
    ground = bpy.data.objects.new("ground", bpy.data.meshes.new("ground"))
    me = ground.data
    me.from_pydata([(-12, -12, -0.02), (3 * gap, -12, -0.02), (3 * gap, 12, -0.02), (-12, 12, -0.02)],
                   [], [(0, 1, 2, 3)])
    gm = bpy.data.materials.new("g")
    gm.diffuse_color = (0.3, 0.4, 0.2, 1)
    gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.1, 0.2, 0.06, 1)
    me.materials.append(gm)
    sc.collection.objects.link(ground)
    c = Vector((gap, 0, 2.5))
    side = RV.camera("side", c + Vector((0, -80, 0)), c, ortho=3 * gap * 1.0)
    RV.render(side, os.path.join(out, "side.png"))
    # сверху под 45° (с фасада), все LOD рядом
    d = Vector((0, -1, 1)).normalized()
    iso = RV.camera("iso45", c + d * 90, c, ortho=3 * gap * 0.95)
    RV.render(iso, os.path.join(out, "iso45.png"))
    # крупно LOD0: вид с угла
    c0 = Vector((0, 0, 2.5))
    d0 = Vector((-0.6, -1, 0.7)).normalized()
    big = RV.camera("lod0", c0 + d0 * 40, c0, ortho=15)
    RV.render(big, os.path.join(out, "lod0_corner.png"))


def main():
    glb = build()
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if "--preview" in argv:
        preview(glb, argv[argv.index("--preview") + 1])


main()
