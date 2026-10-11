"""Круглый рулон сена (EE, К11): assets/easter_eggs/hay_bales/hay_bale.glb (+ assets/source/hay_bale.blend).

    blender --background --python tools/blender/build_hay_bale.py

Диаметр 1,5 м, ширина 1,2 м; ось цилиндра — X (Blender X = Godot X), Blender +Z вверх = Godot +Y.
Начало — низ в центре (AABB Godot: x ±0,6, y 0..1,5, z ±0,75). Один меш, один материал (белый),
цвет — цвета вершин (COLOR_0): бок — солома, торцы темнее, кольца намотки. Бок сглажен, торцы плоские.
Бюджет — до 200 треугольников.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

R, HW, SEG = 0.75, 0.6, 16
OUT = os.path.join(U.ROOT, "assets", "easter_eggs", "hay_bales")
SIDE = (0.80, 0.66, 0.34)
# кольца торца от края к центру: (внешний радиус кольца, цвет)
RINGS = [(R, (0.62, 0.50, 0.25)), (0.5, (0.54, 0.43, 0.20)), (0.25, (0.60, 0.48, 0.23))]


def lin(c):
    return U.srgb(c)


def build():
    U.reset_scene()
    mat = U.material("straw", (1.0, 1.0, 1.0), rough=0.95, double=False)
    mb = U.MeshBuilder()
    col = {}  # индекс вершины -> цвет

    def vert(p, c):
        i = mb.add_vert(p)
        col[i] = lin(c)
        return i

    def pt(x, r, k):
        a = 2 * math.pi * k / SEG
        return (x, r * math.cos(a), R + r * math.sin(a))

    # бок
    for k in range(SEG):
        k2 = (k + 1) % SEG
        q = [vert(pt(-HW, R, k), SIDE), vert(pt(HW, R, k), SIDE),
             vert(pt(HW, R, k2), SIDE), vert(pt(-HW, R, k2), SIDE)]
        mb.add_face(q[::-1], "straw", smooth=True)
    # торцы: кольца-аннулусы и центральный диск
    for sgn in (-1, 1):
        x = sgn * HW
        for ri, (ro, c) in enumerate(RINGS):
            ri_in = RINGS[ri + 1][0] if ri + 1 < len(RINGS) else 0.0
            if ri_in > 0:
                for k in range(SEG):
                    k2 = (k + 1) % SEG
                    q = [vert(pt(x, ro, k), c), vert(pt(x, ro, k2), c),
                         vert(pt(x, ri_in, k2), c), vert(pt(x, ri_in, k), c)]
                    mb.add_face(q[::-1] if sgn < 0 else q, "straw", smooth=False)
            else:
                q = [vert(pt(x, ro, k), c) for k in range(SEG)]
                mb.add_face(q[::-1] if sgn < 0 else q, "straw", smooth=False)
    ob = mb.build("hay_bale", {"straw": mat})
    me = ob.data
    ca = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    # build() вызывает validate(), порядок вершин сохраняется (дубликатов нет)
    for poly in me.polygons:
        for li in poly.loop_indices:
            c = col[me.loops[li].vertex_index]
            ca.data[li].color = (*c, 1.0)
    me.color_attributes.active_color = ca
    # normals на торцах плоские: smooth=False; бок: сглаженные нормали Blender дают цилиндр
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(U.SOURCE, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(U.SOURCE, "hay_bale.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "hay_bale.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="ACTIVE",
                              export_active_vertex_color_when_no_material=False,
                              export_cameras=False, export_lights=False)
    print("EXPORTED hay_bale: %d tris" % U.tri_count())


build()
