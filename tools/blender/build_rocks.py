"""Камни и глыбы для разброса у земли: assets/models/rocks/rocks.glb (+ assets/source/rocks/rocks.blend).

    blender --background --python tools/blender/build_rocks.py

Варианты (VARIANTS): 6 валунов/глыб (boulder0..5 — от окатанных до угловатых плит курумника)
и 3 мелких камня (stone0..2). У каждого три меша-ноды <имя>_LOD0 / _LOD1 / _LOD2 — одна и та же
форма на икосферах 4 / 3 / 2 подразбиений (1280 / 320 / 80 треугольников; мелкие — 3 / 2 / 1).
Форма = эллипсоид × срезы плоскостями (грани глыб) × шум, низ приплюснут. Размер нормирован:
наибольший горизонтальный размер 1 м, низ на −0,15·высоты (камень «врос»), вверх +Y (Godot).
UV — развёртка икосферы (цвет берётся трипланарно в rock_scatter.gdshader, UV — про запас).
Масштаб, поворот и оттенок экземпляра задаёт scripts/terrain/rock_scatter.gd.
"""
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector, noise

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

OUT = os.path.join(U.MODELS, "rocks")
SRC = os.path.join(U.SOURCE, "rocks")

# имя, сид, эллипсоид (x, y, z), число срезов, глубина срезов, сила шума, частота шума, подразбиения LOD0
VARIANTS = [
    ("boulder0", 11, (1.0, 0.85, 0.7), 3, 0.18, 0.16, 1.6, 4),   # окатанный валун
    ("boulder1", 23, (1.0, 0.7, 0.55), 5, 0.12, 0.12, 2.0, 4),   # приплюснутый
    ("boulder2", 37, (1.0, 0.9, 0.9), 7, 0.10, 0.10, 1.8, 4),    # угловатая глыба
    ("boulder3", 41, (1.0, 0.6, 0.45), 6, 0.08, 0.08, 2.4, 4),   # плита курумника
    ("boulder4", 59, (0.9, 1.0, 0.75), 8, 0.14, 0.09, 2.2, 4),   # многогранная глыба
    ("boulder5", 67, (1.0, 0.55, 1.1), 4, 0.16, 0.14, 1.4, 4),   # стоячий «зуб» скалы
    ("stone0", 71, (1.0, 0.8, 0.5), 3, 0.12, 0.14, 2.0, 3),
    ("stone1", 83, (1.0, 0.7, 0.6), 5, 0.10, 0.10, 2.4, 3),
    ("stone2", 97, (0.8, 1.0, 0.45), 4, 0.14, 0.12, 1.8, 3),
]
EMBED = 0.15


def make_shape(seed: int, ell, cuts: int, cut_depth: float, amp: float, freq: float):
    """Функция формы: единичное направление → точка поверхности (одинакова для всех LOD)."""
    rnd = random.Random(seed)
    planes = []
    for _ in range(cuts):
        z = rnd.uniform(-0.2, 0.9)
        a = rnd.uniform(0.0, 2.0 * math.pi)
        r = math.sqrt(max(0.0, 1.0 - z * z))
        n = Vector((r * math.cos(a), r * math.sin(a), z)).normalized()
        planes.append((n, 1.0 - rnd.uniform(0.5, 1.0) * cut_depth * 2.0))
    off = Vector((rnd.uniform(0, 100), rnd.uniform(0, 100), rnd.uniform(0, 100)))

    def f(d: Vector) -> Vector:
        n1 = noise.noise(d * freq + off)
        n2 = noise.noise(d * freq * 3.1 + off * 1.7)
        p = d * (1.0 + amp * n1 + amp * 0.35 * n2)
        for n, k in planes:
            s = p.dot(n)
            if s > k:
                p = p - n * (s - k) * 0.92
        p = Vector((p.x * ell[0], p.y * ell[1], p.z * ell[2]))
        if p.z < -0.35 * ell[2]:
            zb = -0.35 * ell[2]
            p.z = zb + (p.z - zb) * 0.25
        return p

    return f


def build_mesh(name: str, subdiv: int, f) -> bpy.types.Object:
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0, calc_uvs=True)
    for v in bm.verts:
        v.co = f(v.co.normalized())
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    del uv
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def normalize(obs, mat) -> None:
    """Общий масштаб/сдвиг для всех LOD: макс. гориз. размер 1 м, низ на −EMBED·высоты."""
    ref = obs[0].data.vertices
    xs = [v.co.x for v in ref]
    ys = [v.co.y for v in ref]
    zs = [v.co.z for v in ref]
    s = 1.0 / max(max(xs) - min(xs), max(ys) - min(ys))
    cx = 0.5 * (max(xs) + min(xs))
    cy = 0.5 * (max(ys) + min(ys))
    h = (max(zs) - min(zs)) * s
    z0 = min(zs)
    for ob in obs:
        for v in ob.data.vertices:
            v.co = Vector(((v.co.x - cx) * s, (v.co.y - cy) * s, (v.co.z - z0) * s - EMBED * h))
        ob.data.materials.append(mat)
        ob.data.update()
        bpy.context.view_layer.objects.active = ob
        for o in bpy.context.selected_objects:
            o.select_set(False)
        ob.select_set(True)
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(42.0))


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    mat = U.material("rock", (0.36, 0.34, 0.31), rough=0.9)
    for name, seed, ell, cuts, depth, amp, freq, sub in VARIANTS:
        f = make_shape(seed, ell, cuts, depth, amp, freq)
        obs = [build_mesh("%s_LOD%d" % (name, lod), max(sub - lod, 1), f) for lod in range(3)]
        normalize(obs, mat)
        print("ROCK %s: LOD0 %d tris" % (name, U.tri_count([obs[0].name])))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "rocks.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "rocks.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)
    print("EXPORTED rocks: %d tris" % U.tri_count())


main()
