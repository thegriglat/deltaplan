"""Лебёдка буксировки: assets/models/world/tow_winch.glb (+ assets/source/world/tow_winch.blend).

    blender --background --python tools/blender/build_tow_winch.py

Контракт TW-К8 (docs/contracts/tow.md). Узлы tow_winch_LOD0 / _LOD1 / _LOD2 (≤1500 / ≤200 / ≤40 треугольников),
tow_winch_rope_out — точка выхода троса (направляющий шкив на мачте). Оси Blender: +Y — к пилоту (в Godot −Z,
направление троса), Z вверх, начало на земле в центре рамы. Цвета — вершинные (атрибут Col), текстур нет;
материалы: Hardware (общий для проекта), Paint, Rope — белые, цвет даёт вершина. Параметры — build_tow_winch.json.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

P = U.load_json("tools/blender/build_tow_winch.json")
C = {k: tuple(U.srgb(v)) for k, v in P["colors"].items()}


def mats() -> dict:
    return {n: U.material(n, (1.0, 1.0, 1.0), rough=r, metal=m) for n, r, m in
            (("Hardware", 0.5, 0.5), ("Paint", 0.6, 0.0), ("Rope", 0.9, 0.0))}


def cyl_x(mb, x0, x1, y, z, r, mat, sides):
    """Цилиндр вдоль X (барабан)."""
    mb.add_tube([(x0, y, z), (x1, y, z)], r, mat, sides=sides, cap=True, up=(0, 0, 1))


def box(mb, c, s, mat):
    mb.add_box(c, s, mat)


def build_lod(lod: int, M: dict):
    f, d, e, m = P["frame"], P["drum"], P["engine"], P["mast"]
    mb = U.MeshBuilder()
    mb._tags = {}

    def part(color, fn, *a):
        s = len(mb.faces)
        fn(*a)
        for i in range(s, len(mb.faces)):
            mb._tags[i] = color

    L, W, H, B = f["length"], f["width"], f["height"], f["beam"]
    zf = H
    if lod == 2:
        part("paint", box, mb, (0, 0, 0.5), (W, L, 1.0), "Paint")
        part("steel", mb.add_tube, [(0, m["y"], 0.0), (0, m["y"], m["height"])], 0.06, "Hardware", 4)
        return mb, 0
    # рама: два полоза и поперечины
    sk = 8 if lod == 0 else 4
    for sx in (-1, 1):
        part("frame", box, mb, (sx * (W / 2 - B / 2), 0, zf / 2), (B, L, zf), "Hardware")
    for y in ([-L / 2 + B, 0.0, L / 2 - B] if lod == 0 else [-L / 2 + B, L / 2 - B]):
        part("frame", box, mb, (0, y, zf - B / 2), (W - 2 * B, B, B), "Hardware")
    if lod == 0:  # лыжи-загиб спереди
        for sx in (-1, 1):
            part("frame", mb.add_tube, [(sx * (W / 2 - B / 2), L / 2, 0.05), (sx * (W / 2 - B / 2), L / 2 + 0.18, 0.2)],
                 B * 0.5, "Hardware", 6)
    # двигатель + кожух
    part("paint", box, mb, (0, e["y"], zf + e["z"] / 2 * 0 + e["size"][2] / 2), tuple(e["size"]), "Paint")
    if lod == 0:
        part("dark", box, mb, (0, e["y"] - e["size"][1] / 2 - 0.02, zf + 0.4), (0.5, 0.04, 0.4), "Hardware")
        part("steel", mb.add_tube, [(0.2, e["y"] - 0.2, zf + e["size"][2]), (0.2, e["y"] - 0.2, zf + e["size"][2] + 0.35)],
             0.05, "Hardware", 8)  # выхлоп
        # привод барабана
        part("steel", mb.add_tube, [(W / 2 - 0.12, e["y"] + 0.45, zf + 0.45), (W / 2 - 0.12, d["y"], d["z"] + zf - 0.2)],
             0.025, "Hardware", 6)
    # барабан: корпус, щёки, трос
    sd = 20 if lod == 0 else 8
    zc = d["z"] + zf - 0.28
    hw = d["width"] / 2
    part("steel", cyl_x, mb, -hw, hw, d["y"], zc, d["radius"], "Hardware", sd)
    part("paint", cyl_x, mb, -hw - d["flange_t"], -hw, d["y"], zc, d["flange_radius"], "Paint", sd)
    part("paint", cyl_x, mb, hw, hw + d["flange_t"], d["y"], zc, d["flange_radius"], "Paint", sd)
    if lod == 0:
        part("rope", cyl_x, mb, -hw + 0.02, hw - 0.02, d["y"], zc, d["radius"] + 0.07, "Rope", sd)
        # ось и стойки подшипников
        for sx in (-1, 1):
            part("frame", box, mb, (sx * (hw + 0.1), d["y"], (zf + zc) / 2), (0.07, 0.25, zc - zf), "Hardware")
        # рукоять тормоза
        part("dark", mb.add_tube, [(W / 2 - 0.05, d["y"] - 0.3, zf + 0.1), (W / 2 + 0.2, d["y"] - 0.3, zf + 0.7)],
             0.02, "Hardware", 6)
    # мачта-направляющая и шкив
    ytop = m["y"]
    part("steel", mb.add_tube, [(0, ytop, zf), (0, ytop, m["height"])], m["radius"], "Hardware", sk)
    if lod == 0:
        for sx in (-1, 1):  # подкосы
            part("frame", mb.add_tube, [(sx * 0.35, ytop - 0.7, zf), (0, ytop, m["height"] - 0.2)], 0.025, "Hardware", 6)
    sh = m["sheave_radius"]
    part("steel", mb.add_tube, [(-0.035, ytop + 0.06, m["height"]), (0.035, ytop + 0.06, m["height"])], sh, "Hardware",
         16 if lod == 0 else 6)
    # трос от барабана к шкиву
    if lod == 0:
        part("rope", mb.add_tube, [(0, d["y"] + d["radius"] + 0.06, zc), (0, ytop, m["height"] + sh)], 0.012, "Rope", 4,
             True)
    return mb, 1


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
        mb, _ = build_lod(lod, M)
        ob = finish(mb, f"tow_winch_LOD{lod}", M)
        t = U.tri_count([ob.name])
        print(f"WINCH LOD{lod}: {t} tris")
        assert t <= P["lod_tris_max"][lod], (lod, t)
    m = P["mast"]
    U.empty("tow_winch_rope_out", (0, m["y"] + m["sheave_radius"] + 0.06, m["height"]))
    os.makedirs(U.MODELS + "/world", exist_ok=True)
    os.makedirs(U.SOURCE + "/world", exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(U.SOURCE, "world", "tow_winch.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(U.MODELS, "world", "tow_winch.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True, export_extras=False,
                              export_vertex_color="ACTIVE", export_active_vertex_color_when_no_material=False,
                              export_cameras=False, export_lights=False)
    print("EXPORTED tow_winch")


main()
