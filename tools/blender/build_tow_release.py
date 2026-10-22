"""Отцеп с уздечкой: assets/models/world/tow_release.glb (+ assets/source/world/tow_release.blend).

    blender --background --python tools/blender/build_tow_release.py

Контракт TW-К8 (docs/contracts/tow.md). Узлы tow_release_LOD0 / _LOD1 (≤300 / ≤40 треугольников);
tow_release_attach — точка на подвеске пилота (начало координат), tow_release_rope — точка крепления троса
(передняя кромка кольца-замка). Метры, как пилот; +Y Blender — вперёд (в Godot −Z). Состав: V-образная уздечка
из двух строп от подвески, кольцо отцепа с замком-защёлкой и ручка отцепа (шнур + рукоять). Цвета — вершинные (Col),
текстур нет; материалы Hardware (общий), Cord. Параметры — build_tow_release.json.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

P = U.load_json("tools/blender/build_tow_release.json")
C = {k: tuple(U.srgb(v)) for k, v in P["colors"].items()}


def mats() -> dict:
    return {n: U.material(n, (1.0, 1.0, 1.0), rough=r, metal=m) for n, r, m in
            (("Hardware", 0.4, 0.7), ("Cord", 0.85, 0.0))}


def build_lod(lod: int):
    mb = U.MeshBuilder()
    mb._tags = {}

    def part(color, fn, *a):
        s = len(mb.faces)
        fn(*a)
        for i in range(s, len(mb.faces)):
            mb._tags[i] = color

    sp, ly = P["bridle_half_span"], P["bridle_len_y"]
    r, lk, h = P["ring"], P["lock"], P["handle"]
    ring_c = Vector((0, r["y"], r["z"]))
    sides = 4 if lod == 0 else 3
    for sx in (-1, 1):  # две стропы V
        mid = [(sx * sp * 0.5, ly * 0.5, r["z"] * 0.5)] if lod == 0 else []
        part("cord", mb.add_tube, [(sx * sp, 0, 0)] + mid + [(0, r["y"] - r["major"], r["z"])], 0.006 if lod == 0 else 0.008, "Cord",
             sides, True)
    # кольцо-замок: тор в плоскости XZ (ось вдоль Y)
    n = 12 if lod == 0 else 0
    if lod == 0:
        pts = [ring_c + Vector((r["major"] * math.cos(2 * math.pi * i / n), 0, r["major"] * math.sin(2 * math.pi * i / n)))
               for i in range(n)]
        part("steel", mb.add_tube, pts, r["minor"], "Hardware", 4, False, (1, 1), (0, 1, 0), True, True)
        # замок-защёлка: стержень через кольцо
        part("lock", mb.add_tube, [ring_c + Vector((0, -lk["length"] / 2 * 0.0, -r["major"] - 0.01)),
                                   ring_c + Vector((0, 0, r["major"] + 0.01))], lk["radius"] * 0.8, "Hardware", 6)
        # втулка замка на кольце
        part("lock", mb.add_tube, [ring_c + Vector((0, -0.02, r["major"])), ring_c + Vector((0, 0.02, r["major"]))],
             lk["radius"], "Hardware", 8)
        # ручка: шнур от замка к рукояти + рукоять
        g = Vector(h["grab"])
        part("grip", mb.add_tube, [ring_c + Vector((0, 0, r["major"])), ring_c + Vector((0.05, -0.12, 0.05)),
                                   g + Vector((0, 0.0, 0.1))], h["cord_r"], "Cord", 4, True)
        part("grip", mb.add_tube, [g + Vector((0, 0, 0.1)), g - Vector((0, 0, 0.0))], h["grip_r"], "Cord", 6)
    else:
        part("steel", mb.add_tube, [ring_c + Vector((0, 0, -r["major"])), ring_c + Vector((0, 0, r["major"]))],
             r["major"] * 0.5, "Hardware", 4)
        part("grip", mb.add_tube, [ring_c, Vector(h["grab"])], 0.01, "Cord", 3)
    return mb


def finish(mb, name, M):
    ob = mb.build(name, M)
    me = ob.data
    ca = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    for poly in me.polygons:
        c = C[mb._tags.get(poly.index, "steel")]
        for li in poly.loop_indices:
            ca.data[li].color = (*c, 1.0)
    me.color_attributes.active_color = ca
    return ob


def main() -> None:
    U.reset_scene()
    M = mats()
    for lod in (0, 1):
        ob = finish(build_lod(lod), f"tow_release_LOD{lod}", M)
        t = U.tri_count([ob.name])
        print(f"RELEASE LOD{lod}: {t} tris")
        assert t <= P["lod_tris_max"][lod], (lod, t)
    r = P["ring"]
    U.empty("tow_release_attach", (0, 0, 0))
    U.empty("tow_release_rope", (0, r["y"] + r["major"] + r["minor"], r["z"]))
    os.makedirs(U.MODELS + "/world", exist_ok=True)
    os.makedirs(U.SOURCE + "/world", exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(U.SOURCE, "world", "tow_release.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(U.MODELS, "world", "tow_release.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True, export_extras=False,
                              export_vertex_color="ACTIVE", export_active_vertex_color_when_no_material=False,
                              export_cameras=False, export_lights=False)
    print("EXPORTED tow_release")


main()
