"""Кусты для лугов: assets/models/shrubs/shrubs.glb (+ assets/source/shrubs/shrubs.blend).

    blender --background --python tools/blender/build_shrubs.py

Варианты (VARIANTS): karagana (караганник — низкий широкий купол), rosehip (шиповник — плотный
округлый куст), willow (ивняк — вытянутые вверх лопасти). Куст = несколько «лопастей» (эллипсоиды
на икосферах × шум: крупные бугры листвы + мелкая рябь). У каждого варианта три меша-ноды
<имя>_LOD0 / _LOD1 / _LOD2: центральная лопасть на икосфере 4 / 2, остальные 3 / 2 (мелкие — на одно меньше)
и LOD2 — одна общая оболочка на икосфере 2 (80 треугольников).
Размер нормирован: высота 1 м, низ на −EMBED (куст «врос»), вверх +Y (Godot). Цвет листвы,
затенение низа и покачивание — в scripts/terrain/shrub_scatter.gdshader; масштаб, поворот и
оттенок экземпляра задаёт scripts/terrain/shrub_scatter.gd.
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

OUT = os.path.join(U.MODELS, "shrubs")
SRC = os.path.join(U.SOURCE, "shrubs")
EMBED = 0.06

# имя, сид, число лопастей, (ширина разброса, высота) центров, размер лопасти (гор., верт.),
# сила бугров, сила ряби
VARIANTS = [
    ("karagana", 5, 7, (0.9, 0.35), (0.45, 0.42), 0.2, 0.08),
    ("rosehip", 17, 6, (0.55, 0.45), (0.42, 0.5), 0.18, 0.09),
    ("willow", 29, 6, (0.45, 0.9), (0.28, 0.6), 0.16, 0.08),
]


def lobes_of(seed: int, count: int, spread, size) -> list:
    """Лопасти: (центр, полуоси, смещение шума). Первая — центральная и самая крупная."""
    rnd = random.Random(seed)
    out = []
    for i in range(count):
        if i == 0:
            c = Vector((0.0, 0.0, size[1] * 0.9))
            k = 1.15
        else:
            a = 2.0 * math.pi * i / (count - 1) + rnd.uniform(-0.4, 0.4)
            r = spread[0] * 0.5 * rnd.uniform(0.45, 1.0)
            c = Vector((r * math.cos(a), r * math.sin(a),
                        size[1] * 0.75 + spread[1] * rnd.uniform(0.0, 1.0)))
            k = rnd.uniform(0.7, 1.0)
        ax = Vector((size[0] * k * rnd.uniform(0.85, 1.1), size[0] * k * rnd.uniform(0.85, 1.1),
                     size[1] * k))
        off = Vector((rnd.uniform(0, 100), rnd.uniform(0, 100), rnd.uniform(0, 100)))
        out.append((c, ax, off))
    return out


def lumpy(d: Vector, off: Vector, amp: float, ripple: float) -> float:
    """Множитель радиуса: крупные бугры листвы + мелкая рябь (как пучки веток)."""
    return (1.0 + amp * noise.noise(d * 1.8 + off)
            + ripple * noise.noise(d * 5.5 + off * 1.3)
            + ripple * 0.6 * noise.noise(d * 11.0 + off * 0.7))


def add_ellipsoid(bm, subdiv: int, c: Vector, ax: Vector, off: Vector, amp: float,
                  ripple: float) -> None:
    tmp = bmesh.new()
    bmesh.ops.create_icosphere(tmp, subdivisions=subdiv, radius=1.0)
    for v in tmp.verts:
        d = v.co.normalized()
        k = lumpy(d, off, amp, ripple)
        p = Vector((d.x * ax.x, d.y * ax.y, d.z * ax.z)) * k + c
        # низ лопасти не уходит глубоко под землю
        if p.z < 0.0:
            p.z *= 0.5
        v.co = p
    me = bpy.data.meshes.new("tmp")
    tmp.to_mesh(me)
    tmp.free()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)


def build(name: str, lod: int, lobes: list, amp: float, ripple: float) -> bpy.types.Object:
    bm = bmesh.new()
    if lod < 2:
        for i, (c, ax, off) in enumerate(lobes):
            sub = (4 if i == 0 else 3) - lod - (1 if lod == 1 and i == 0 else 0) - (1 if i > 3 else 0)
            add_ellipsoid(bm, max(sub, 1), c, ax, off, amp, ripple * (1.0 - 0.5 * lod))
    else:
        # оболочка: эллипсоид по габаритам лопастей, те же крупные бугры
        lo = Vector((min(c.x - a.x for c, a, _ in lobes), min(c.y - a.y for c, a, _ in lobes),
                     0.0))
        hi = Vector((max(c.x + a.x for c, a, _ in lobes), max(c.y + a.y for c, a, _ in lobes),
                     max(c.z + a.z for c, a, _ in lobes)))
        ctr = (lo + hi) * 0.5
        ax = (hi - lo) * 0.5 * 0.92
        add_ellipsoid(bm, 2, ctr, ax, lobes[0][2], amp, 0.0)
    me = bpy.data.meshes.new(f"{name}_LOD{lod}")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(me.name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def normalize(obs, mat) -> None:
    """Общий масштаб/сдвиг для всех LOD: высота 1 м, центр по горизонтали в 0, низ на −EMBED."""
    ref = obs[0].data.vertices
    xs = [v.co.x for v in ref]
    ys = [v.co.y for v in ref]
    zs = [v.co.z for v in ref]
    s = 1.0 / (max(zs) - min(zs))
    cx = 0.5 * (max(xs) + min(xs))
    cy = 0.5 * (max(ys) + min(ys))
    z0 = min(zs)
    for ob in obs:
        for v in ob.data.vertices:
            v.co = Vector(((v.co.x - cx) * s, (v.co.y - cy) * s, (v.co.z - z0) * s - EMBED))
        ob.data.materials.append(mat)
        ob.data.update()
        for p in ob.data.polygons:
            p.use_smooth = True


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    mat = U.material("shrub", (0.2, 0.28, 0.12), rough=0.85)
    for name, seed, count, spread, size, amp, ripple in VARIANTS:
        lobes = lobes_of(seed, count, spread, size)
        obs = [build(name, lod, lobes, amp, ripple) for lod in range(3)]
        normalize(obs, mat)
        t = [U.tri_count([o.name]) for o in obs]
        print(f"SHRUB {name}: LOD0 {t[0]}, LOD1 {t[1]}, LOD2 {t[2]} tris")
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "shrubs.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "shrubs.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)
    print(f"EXPORTED shrubs: {U.tri_count()} tris")


main()
