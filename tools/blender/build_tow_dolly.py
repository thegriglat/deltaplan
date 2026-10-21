"""Тележка аэробуксировки: assets/models/world/tow_dolly.glb (+ assets/source/world/tow_dolly.blend).

    blender --background --python tools/blender/build_tow_dolly.py

Контракт TW-К8 v3 (docs/contracts/tow.md). Узлы tow_dolly_LOD0/1/2 (≤800 / ≤200 / ≤40 треугольников);
tow_dolly_keel — точка опоры киля (центр ложемента), tow_dolly_bar — опора штанги (середина перекладины).
Оси Blender: +Y вперёд (в Godot −Z), Z вверх, начало на земле под центром тележки. Ложемент киля наклонён
на keel_angle_deg носом вверх. Цвета — вершинные (Col), текстур нет; материалы Hardware (общий), Paint, Rubber.
Параметры и источники размеров — build_tow_dolly.json (BHPA §2.7.4 G).
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

P = U.load_json("tools/blender/build_tow_dolly.json")
C = {k: tuple(U.srgb(v)) for k, v in P["colors"].items()}
A = math.radians(P["keel_angle_deg"])
KDIR = Vector((0, math.cos(A), math.sin(A)))


def mats() -> dict:
    return {n: U.material(n, (1.0, 1.0, 1.0), rough=r, metal=m) for n, r, m in
            (("Hardware", 0.5, 0.5), ("Paint", 0.6, 0.0), ("Rubber", 0.9, 0.0))}


def keel_point() -> Vector:
    k = P["keel_post"]
    return Vector((0, k["y"], k["height"]))


def bar_point() -> Vector:
    b = P["bar_rest"]
    return Vector((0, b["y"], b["height"]))


def build_lod(lod: int):
    mb = U.MeshBuilder()
    mb._tags = {}

    def part(color, fn, *a, **kw):
        s = len(mb.faces)
        fn(*a, **kw)
        for i in range(s, len(mb.faces)):
            mb._tags[i] = color

    W, wb, w = P["track"], P["wheelbase"], P["wheel"]
    fr, k, cr, br = P["frame"], P["keel_post"], P["keel_cradle"], P["bar_rest"]
    kp, bp = keel_point(), bar_point()
    if lod == 2:
        part("frame", mb.add_box, (0, 0, fr["z"]), (W, wb, 0.04), "Hardware")
        part("steel", mb.add_tube, [(0, k["y"], fr["z"]), kp], 0.03, "Hardware", 4)
        part("steel", mb.add_tube, [(-br["width"] / 2, bp.y, bp.z), (br["width"] / 2, bp.y, bp.z)], 0.03, "Hardware", 4)
        return mb
    tr = fr["tube_radius"]
    s_t = 6 if lod == 0 else 3
    # рама: два продольных лонжерона и поперечины
    for sx in (-1, 1):
        part("frame", mb.add_tube, [(sx * W / 2, -wb / 2, fr["z"]), (sx * W / 2, wb / 2, fr["z"])], tr, "Hardware", s_t)
    for y in ([-wb / 2, 0.0, wb / 2] if lod == 0 else [-wb / 2, wb / 2]):
        part("frame", mb.add_tube, [(-W / 2, y, fr["z"]), (W / 2, y, fr["z"])], tr, "Hardware", s_t)
    # колёса на осях
    sw = 14 if lod == 0 else 6
    for y in (-wb / 2, wb / 2):
        for sx in (-1, 1):
            xc = sx * (W / 2 + w["width"] / 2)
            part("tyre", mb.add_tube, [(xc - w["width"] / 2, y, w["radius"]), (xc + w["width"] / 2, y, w["radius"])],
                 w["radius"], "Rubber", sw, True, up=(0, 1, 0))
            if lod == 0:
                part("steel", mb.add_tube, [(sx * W / 2, y, w["radius"]), (xc, y, w["radius"])], 0.015, "Hardware", 6)
    # стойка и ложемент киля (наклон keel_angle_deg носом вверх)
    part("paint", mb.add_tube, [(0, k["y"], fr["z"]), kp - KDIR * 0.0 - Vector((0, 0, 0.03))], k["radius"], "Paint", s_t)
    L = cr["length"]
    part("steel", mb.add_tube, [kp - KDIR * L / 2, kp + KDIR * L / 2], cr["radius"], "Hardware", s_t)
    if lod == 0:  # обшивка-лоток: две боковые стенки с мягкой накладкой
        side = Vector((1, 0, 0))
        up = KDIR.cross(side)  # нормаль ложемента
        for sx in (-1, 1):
            c = kp + side * sx * cr["width"] / 2 + up * 0.03
            part("pad", mb.add_box, c, (0.015, L, 0.06), "Rubber", rot=_rot(KDIR))
        part("pad", mb.add_box, kp + up * 0.0, (cr["width"], L, 0.012), "Rubber", rot=_rot(KDIR))
    # перекладина под штангу + стойки
    for sx in (-1, 1):
        part("paint", mb.add_tube, [(sx * br["width"] / 2, br["y"], fr["z"]), (sx * br["width"] / 2, br["y"], bp.z)],
             br["radius"], "Paint", s_t)
    part("paint", mb.add_tube, [(-br["width"] / 2, bp.y, bp.z), (br["width"] / 2, bp.y, bp.z)], br["radius"], "Paint", s_t)
    if lod == 0:  # раскосы стойки киля к раме и дышло
        for sx in (-1, 1):
            part("frame", mb.add_tube, [(sx * W / 2, k["y"] - 0.3, fr["z"]), (0, k["y"], kp.z - 0.25)], 0.012, "Hardware", 4)
        part("frame", mb.add_tube, [(0, wb / 2, fr["z"]), (0, wb / 2 + 0.3, fr["z"] - 0.05)], tr, "Hardware", s_t)
    return mb


def _rot(d: Vector):
    """Матрица 3x3: локальный +Y -> d, локальный X -> X мира."""
    x = Vector((1, 0, 0))
    z = x.cross(d).normalized()
    from mathutils import Matrix
    return Matrix((x, d, z)).transposed()


def finish(mb, name, M):
    ob = mb.build(name, M)
    me = ob.data
    ca = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    for poly in me.polygons:
        c = C[mb._tags.get(poly.index, "frame")]
        for li in poly.loop_indices:
            ca.data[li].color = (*c, 1.0)
    me.color_attributes.active_color = ca
    return ob


def main() -> None:
    U.reset_scene()
    M = mats()
    for lod in (0, 1, 2):
        ob = finish(build_lod(lod), f"tow_dolly_LOD{lod}", M)
        t = U.tri_count([ob.name])
        print(f"DOLLY LOD{lod}: {t} tris")
        assert t <= P["lod_tris_max"][lod], (lod, t)
    U.empty("tow_dolly_keel", keel_point())
    U.empty("tow_dolly_bar", bar_point())
    os.makedirs(U.MODELS + "/world", exist_ok=True)
    os.makedirs(U.SOURCE + "/world", exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(U.SOURCE, "world", "tow_dolly.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(U.MODELS, "world", "tow_dolly.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True, export_extras=False,
                              export_vertex_color="ACTIVE", export_active_vertex_color_when_no_material=False,
                              export_cameras=False, export_lights=False)
    print("EXPORTED tow_dolly")


main()
