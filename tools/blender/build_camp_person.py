"""Человечек у лагеря (SC-K4): assets/models/world/camp_person.glb (+ assets/source/world/camp_person.blend).

    blender --background --python tools/blender/build_camp_person.py

Пять мешей на верхнем уровне: Legs, Torso, Head, ArmR, ArmL. Начало каждого — шарнир (SC-K4),
вершины заданы относительно шарнира; объект стоит в шарнире. Blender +Z вверх = Godot +Y,
Blender +Y (лицо) = Godot −Z. Рост 1,75 м. Материалы: Cloth, SkinTint, Skin, Hair, Shoes.
Один материал-тонируемый на меш (Legs/Torso/Arm* — Cloth, Head — SkinTint). Бюджет ≤ 900 треугольников.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

PAL = {
    "Cloth": ((0.85, 0.85, 0.85), 0.9),
    "SkinTint": ((0.86, 0.66, 0.54), 0.7),
    "Skin": ((0.82, 0.62, 0.50), 0.7),
    "Hair": ((0.13, 0.09, 0.06), 0.8),
    "Shoes": ((0.10, 0.09, 0.08), 0.8),
}


def loft(mb, rings, mat, sides=8, cap_lo=True, cap_hi=True, smooth=True):
    """rings: [(z, cx, cy, rx, ry)], снизу вверх. rx == 0 — вершина-остриё (веер)."""
    idx = []
    for z, cx, cy, rx, ry in rings:
        if rx <= 0:
            idx.append([mb.add_vert((cx, cy, z))])
        else:
            idx.append([mb.add_vert((cx + rx * math.cos(2 * math.pi * k / sides),
                                     cy + ry * math.sin(2 * math.pi * k / sides), z))
                        for k in range(sides)])
    for a, b in zip(idx[:-1], idx[1:]):
        for k in range(sides):
            k2 = (k + 1) % sides
            if len(a) == 1:
                mb.add_face([a[0], b[k2], b[k]], mat, smooth=smooth)
            elif len(b) == 1:
                mb.add_face([a[k], a[k2], b[0]], mat, smooth=smooth)
            else:
                mb.add_face([a[k], a[k2], b[k2], b[k]], mat, smooth=smooth)
    if cap_lo and len(idx[0]) > 1:
        mb.add_face(list(reversed(idx[0])), mat, smooth=False)
    if cap_hi and len(idx[-1]) > 1:
        mb.add_face(idx[-1], mat, smooth=False)


def legs(mats):
    mb = U.MeshBuilder()
    for sx in (-1, 1):
        x = sx * 0.09
        # штаны: щиколотка → колено → бедро (штанина чуть расширена книзу)
        loft(mb, [(0.08, x, 0, 0.055, 0.055), (0.30, x, 0, 0.062, 0.062), (0.52, x, 0.005, 0.072, 0.07),
                  (0.75, x, 0, 0.088, 0.09), (0.95, x, 0, 0.092, 0.10)], "Cloth", sides=8, cap_lo=False)
        # ботинок: подошва, носок вперёд (+Y)
        loft(mb, [(0.0, x, 0.05, 0.045, 0.12), (0.035, x, 0.05, 0.052, 0.125), (0.085, x, 0.025, 0.048, 0.085)],
             "Shoes", sides=8)
    return mb.build("Legs", {m: mats[m] for m in mb.mat_names})


def torso(mats):
    mb = U.MeshBuilder()
    # куртка: подол, талия, грудь, плечи; воротник
    loft(mb, [(0.0, 0, 0, 0.175, 0.105), (0.20, 0, 0, 0.165, 0.10), (0.40, 0, 0, 0.19, 0.115),
              (0.50, 0, 0, 0.205, 0.105), (0.55, 0, 0, 0.075, 0.07)], "Cloth", sides=10, cap_lo=False)
    loft(mb, [(0.50, 0, 0, 0.065, 0.065), (0.57, 0, 0, 0.065, 0.065)], "Cloth", sides=8, cap_lo=False, cap_hi=False)
    return mb.build("Torso", {m: mats[m] for m in mb.mat_names})


def head(mats):
    mb = U.MeshBuilder()
    loft(mb, [(0.0, 0, 0, 0.048, 0.048), (0.11, 0, 0, 0.045, 0.045)], "SkinTint", sides=8, cap_lo=False, cap_hi=False)
    # голова: яйцо
    loft(mb, [(0.07, 0, 0.005, 0.0, 0.0), (0.09, 0, 0.005, 0.05, 0.06), (0.15, 0, 0, 0.078, 0.092),
              (0.21, 0, 0, 0.074, 0.088), (0.245, 0, 0, 0.04, 0.05), (0.255, 0, 0, 0.0, 0.0)],
         "SkinTint", sides=10)
    # нос
    mb.add_box((0, 0.098, 0.155), (0.022, 0.03, 0.04), "SkinTint")
    # кепка: купол и козырёк
    loft(mb, [(0.19, 0, -0.002, 0.082, 0.098), (0.225, 0, 0, 0.08, 0.095), (0.25, 0, 0, 0.05, 0.062),
              (0.262, 0, 0, 0.0, 0.0)], "Hair", sides=10, cap_lo=False)
    mb.add_box((0, 0.125, 0.195), (0.12, 0.07, 0.012), "Hair")
    return mb.build("Head", {m: mats[m] for m in mb.mat_names})


def arm(mats, name, sx):
    mb = U.MeshBuilder()
    # рукав (локально: начало в плече, рука вдоль −Z)
    loft(mb, [(0.0, 0, 0, 0.052, 0.052), (-0.22, 0, 0, 0.044, 0.044), (-0.45, 0, 0, 0.040, 0.040)],
         "Cloth", sides=8, cap_lo=True, cap_hi=True)
    # кисть: запястье → пальцы; большой палец — клин к бедру (внутрь)
    loft(mb, [(-0.45, 0, 0, 0.028, 0.02), (-0.52, 0, 0, 0.04, 0.02), (-0.62, 0, 0.003, 0.026, 0.015)],
         "Skin", sides=6, cap_lo=False)
    ix = -sx * 0.036
    a = mb.add_vert((ix, 0.0, -0.49))
    b = mb.add_vert((ix, 0.0, -0.55))
    c = mb.add_vert((ix + -sx * 0.012, 0.0, -0.53))
    d = mb.add_vert((ix * 0.55, 0.012, -0.5))
    e = mb.add_vert((ix * 0.55, -0.012, -0.5))
    for f in ([a, b, c], [a, d, b], [a, e, d], [b, d, e], [a, c, e], [b, e, c]):
        mb.add_face(f, "Skin", smooth=False)
    return mb.build(name, {m: mats[m] for m in mb.mat_names})


def build():
    U.reset_scene()
    mats = {n: U.material(n, U.srgb(c), rough=r) for n, (c, r) in PAL.items()}
    # шарниры (Blender: x, y, z) = (Godot x, −z, y)
    parts = [(legs(mats), (0, 0, 0)), (torso(mats), (0, 0, 0.95)), (head(mats), (0, 0, 1.50)),
             (arm(mats, "ArmR", 1), (0.22, 0, 1.42)), (arm(mats, "ArmL", -1), (-0.22, 0, 1.42))]
    import bmesh
    for ob, loc in parts:
        ob.location = loc
        bm = bmesh.new()
        bm.from_mesh(ob.data)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)  # наружу у замкнутых частей
        bm.to_mesh(ob.data)
        bm.free()
    out = os.path.join(U.MODELS, "world")
    src = os.path.join(U.SOURCE, "world")
    os.makedirs(out, exist_ok=True)
    os.makedirs(src, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(src, "camp_person.blend"), check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out, "camp_person.glb"), export_format="GLB", export_yup=True,
                              use_selection=False, export_apply=True, export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)
    for ob, _ in parts:
        print("TRIS", ob.name, sum(len(p.vertices) - 2 for p in ob.data.polygons))
    print("EXPORTED camp_person: %d tris" % U.tri_count())


build()
