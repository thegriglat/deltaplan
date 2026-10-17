"""Ронделавель (RV-К6): assets/models/houses/house_rondavel.glb (+ assets/source/houses/house_rondavel.blend).

    [xvfb-run -a] blender --background --python tools/blender/build_house_rondavel.py [-- --preview DIR]

Круглая хижина: глинобитная стена (диаметр 5 м, высота 2,3 м), коническая соломенная крыша со
свесом 0,75 м (кромка на ~1,4 м, конёк 5 м), дверь из досок. Метры, +Y вверх (Blender Z), начало —
центр дома на уровне земли, дверь на Godot +Z (Blender −Y).
Ноды LOD0 (24 грани по кругу, дверь, окно), LOD1 (12 граней, дверь), LOD2 (8 граней, цилиндр + конус).
Материалы Wall_rondavel, Roof_rondavel, Wood_rondavel; текстуры процедурные (numpy), светлые,
плиточные, 128/128/64 px, встроены в glb (Godot выносит их рядом: house_rondavel_house_rondavel_*.png), PNG не сохраняются отдельно.
Одна геометрия «в профиле»: конус крыши — линия r(z) со слабой вогнутостью (солома стекает).
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

NAME = "rondavel"
OUT = os.path.join(U.ROOT, "assets", "models", "houses")
SRC = os.path.join(U.ROOT, "assets", "source", "houses")
R_WALL, H_WALL = 2.5, 2.3      # радиус и высота стены
R_EAVE = 3.25                  # радиус свеса (0,75 м за стеной)
Z_TOP = 5.0                    # конёк
THICK = 0.22                   # толщина соломы на кромке
TILE = 2.0                     # м на плитку текстуры


def roof_z(r):
    """Высота поверхности крыши на радиусе r: от конька до верха стены, слегка вогнутая
    (степень 1,1: у кромки склон круче), за стеной — продолжение касательной."""
    p, dz = 1.1, Z_TOP - H_WALL
    if r <= R_WALL:
        return Z_TOP - dz * (r / R_WALL) ** p
    return H_WALL - (r - R_WALL) * dz * p / R_WALL


# ---------- текстуры ----------
def fbm(h, w, rng, beta=2.0, aniso=(1.0, 1.0)):
    """Плиточный шум: белый шум в Фурье, спектр 1/f^beta; aniso растягивает по осям (y, x)."""
    fy = np.fft.fftfreq(h)[:, None] * aniso[0]
    fx = np.fft.fftfreq(w)[None, :] * aniso[1]
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1.0
    spec = (rng.standard_normal((h, w)) + 1j * rng.standard_normal((h, w))) / f ** (beta / 2)
    spec[0, 0] = 0
    n = np.real(np.fft.ifft2(spec))
    n -= n.mean()
    return n / (np.abs(n).max() + 1e-9)


def tex_wall():
    rng = np.random.default_rng(11)
    n = 0.55 * fbm(128, 128, rng, 2.2) + 0.30 * fbm(128, 128, rng, 1.0) + 0.15 * rng.standard_normal((128, 128))
    base = np.array([0.80, 0.77, 0.72])           # светлый нейтрально-тёплый, цвет задаёт палитра
    img = base[None, None, :] * (1.0 + 0.16 * n[:, :, None])
    # редкие трещины-тёмные пятна
    c = fbm(128, 128, rng, 1.6)
    img *= 1.0 - 0.18 * np.clip((c - 0.55) * 4, 0, 1)[:, :, None]
    return img


def tex_roof():
    rng = np.random.default_rng(12)
    # пучки соломы вдоль склона (v): вытянуто по v → высокая частота по u
    streak = fbm(128, 128, rng, 1.2, aniso=(0.12, 1.0))
    mid = fbm(128, 128, rng, 2.0)
    n = 0.7 * streak + 0.3 * mid
    base = np.array([0.78, 0.69, 0.50])
    img = base[None, None, :] * (1.0 + 0.30 * n[:, :, None])
    # поперечные перевязи
    rows = (np.arange(128) % 32 < 2).astype(float)[:, None, None]
    img *= 1.0 - 0.12 * rows
    return img


def tex_wood():
    rng = np.random.default_rng(13)
    n = fbm(64, 64, rng, 1.5, aniso=(0.1, 1.0))
    base = np.array([0.52, 0.40, 0.28])
    img = base[None, None, :] * (1.0 + 0.25 * n[:, :, None])
    planks = (np.arange(64) % 16 < 1).astype(float)[None, :, None]   # стыки досок
    img *= 1.0 - 0.45 * planks
    return img


# ---------- геометрия ----------
def lathe(mb, rings, seg, mat, uv_fn, hint):
    """Поверхность вращения: rings — [(r, z)] сверху вниз или снизу вверх; шов по u продублирован.
    hint(c) → вектор «наружу» для центра грани; порядок вершин подбирается по нему."""
    rows = []
    for (r, z) in rings:
        rows.append([(r * math.cos(2 * math.pi * k / seg - math.pi / 2),
                      r * math.sin(2 * math.pi * k / seg - math.pi / 2), z) for k in range(seg + 1)])
    uv = [[uv_fn(i, k, seg, rings) for k in range(seg + 1)] for i in range(len(rings))]
    # проверка ориентации по первой грани
    # третья вершина — rows[0][1], не rows[1][1]: у конуса из двух колец верхнее кольцо вырождено в точку
    a, b, c = (Vector(rows[0][0]), Vector(rows[1][0]), Vector(rows[0][1]))
    nrm = (b - a).cross(c - a)
    cen = (Vector(rows[0][0]) + Vector(rows[1][1])) * 0.5   # центр грани k=0
    flip = nrm.dot(hint(cen)) < 0
    mb.add_grid(rows, mat, uv, flip=flip, smooth=True, wrap=False)


def build_lod(seg, lod):
    mb = U.MeshBuilder()
    # стена
    hw = H_WALL if lod < 2 else 2.1   # LOD2: конус без излома идёт ниже верха стены
    lathe(mb, [(R_WALL, 0.0), (R_WALL, hw)], seg, "Wall_rondavel",
          lambda i, k, s, rg: (8.0 * k / s, rg[i][1] / TILE),
          lambda c: Vector((c.x, c.y, 0.0)))
    # крыша: профиль от кромки к коньку
    top = {0: [R_EAVE, 2.5, 1.7, 0.95, 0.4, 0.0], 1: [R_EAVE, 2.0, 0.9, 0.0], 2: [R_EAVE, 0.0]}[lod]
    prof = [(r, roof_z(r)) for r in top]
    def roof_uv(i, k, s, rg):
        # v — длина по склону от кромки
        d = sum(math.hypot(rg[j + 1][0] - rg[j][0], rg[j + 1][1] - rg[j][1]) for j in range(i))
        return (8.0 * k / s, d / 1.5)
    lathe(mb, prof, seg, "Roof_rondavel", roof_uv, lambda c: Vector((c.x, c.y, 2.0)))
    # кромка и подбой (низ свеса)
    ze = roof_z(R_EAVE)
    if lod <= 1:
        lathe(mb, [(R_EAVE, ze), (R_EAVE, ze - THICK)], seg, "Roof_rondavel",
              lambda i, k, s, rg: (8.0 * k / s, 0.0 + i * 0.15), lambda c: Vector((c.x, c.y, 0.0)))
    zb = ze - THICK if lod <= 1 else ze
    if lod < 2:
      lathe(mb, [(R_EAVE, zb), (R_WALL, H_WALL)], seg, "Roof_rondavel",
          lambda i, k, s, rg: (8.0 * k / s, 0.5 + i * 0.5), lambda c: Vector((0, 0, -1.0)))
    # дверь (Godot +Z = Blender −Y) и окно
    if lod <= 1:
        mb.add_box((0.0, -R_WALL, 0.8), (0.95, 0.12, 1.6), "Wood_rondavel")
    if lod == 0:
        mb.add_box((0.0, -R_WALL, 1.68), (1.15, 0.16, 0.14), "Wood_rondavel")       # перемычка
        a = math.radians(70)   # окно-щель сбоку
        c = (R_WALL * math.cos(a), R_WALL * math.sin(a), 1.35)
        mb.add_box(c, (0.4, 0.4, 0.5), "Wood_rondavel", rot=_rotz(a + math.pi / 2))
    return mb


def _rotz(a):
    from mathutils import Matrix
    return Matrix.Rotation(a, 3, "Z")


def uv_door_fix(ob):
    """Доски: UV коробок — по умолчанию (0,0); развернуть по габариту, чтобы текстура не вырождалась."""
    me = ob.data
    wi = [i for i, m in enumerate(me.materials) if m.name == "Wood_rondavel"]
    if not wi:
        return
    uvl = me.uv_layers["UVMap"]
    for p in me.polygons:
        if p.material_index in wi:
            for li in p.loop_indices:
                v = me.vertices[me.loops[li].vertex_index].co
                uvl.data[li].uv = (v.x * 0.9 + v.y * 0.9, v.z * 0.5)


def build():
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    mats = {}
    for key, fn, rough in (("Wall", tex_wall, 0.95), ("Roof", tex_roof, 0.98), ("Wood", tex_wood, 0.85)):
        img = U.image_from_array("%s_%s" % (key.lower(), NAME), fn(),
                                 "")
        mats["%s_%s" % (key, NAME)] = U.material("%s_%s" % (key, NAME), (1.0, 1.0, 1.0),
                                                 rough=rough, image=img)
    tris = []
    for lod, seg in ((0, 24), (1, 12), (2, 8)):
        ob = build_lod(seg, lod).build("LOD%d" % lod, mats)
        uv_door_fix(ob)
        tris.append(U.tri_count(["LOD%d" % lod]))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "house_%s.blend" % NAME),
                                check_existing=False, compress=True)
    glb = os.path.join(OUT, "house_%s.glb" % NAME)
    bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", export_yup=True,
                              use_selection=False, export_apply=True, export_extras=False,
                              export_vertex_color="NONE", export_cameras=False, export_lights=False)
    print("EXPORTED house_%s: tris LOD0/1/2 = %s, glb %d B" % (NAME, tris, os.path.getsize(glb)))


# ---------- превью ----------
def preview(outdir):
    os.makedirs(outdir, exist_ok=True)
    sc = bpy.context.scene
    for i, off in ((1, 8.0), (2, 15.0)):
        bpy.data.objects["LOD%d" % i].location.x = off
    bpy.ops.mesh.primitive_plane_add(size=60, location=(7, 0, -0.01))
    g = bpy.context.object
    gm = bpy.data.materials.new("ground")
    gm.diffuse_color = (0.42, 0.36, 0.22, 1)
    gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.42, 0.36, 0.22, 1)
    g.data.materials.append(gm)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.5
    sun.rotation_euler = (math.radians(50), 0, math.radians(-35))
    sc.collection.objects.link(sun)
    sc.world = bpy.data.worlds.new("w")
    sc.world.use_nodes = True
    sc.world.node_tree.nodes["Background"].inputs[0].default_value = (0.6, 0.72, 0.9, 1)
    sc.world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    sc.camera = cam
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = 1280, 720
    sc.eevee.taa_render_samples = 12
    sc.render.image_settings.file_format = "JPEG"
    sc.render.image_settings.quality = 88
    sc.view_settings.view_transform = "Standard"
    shots = {
        "side": ((7.5, -36.0, 2.6), (7.5, 0, 2.4), 38),     # сбоку (дверь к камере), все три LOD
        "top45": ((7.5, -24.0, 24.0), (7.5, 0, 1.2), 38),   # сверху под 45°
        "door_close": ((-2.0, -12.5, 1.6), (0.0, 0, 2.0), 40),
    }
    for nm, (pos, tgt, fov) in shots.items():
        cam.location = pos
        cam.data.angle = math.radians(fov)
        cam.rotation_euler = (Vector(tgt) - Vector(pos)).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = os.path.join(outdir, "rondavel_%s.jpg" % nm)
        bpy.ops.render.render(write_still=True)
    print("PREVIEWS", outdir)


build()
if "--preview" in sys.argv:
    preview(sys.argv[sys.argv.index("--preview") + 1])
