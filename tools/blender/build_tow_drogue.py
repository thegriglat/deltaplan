"""Дрог-парашют троса: assets/models/world/tow_drogue.glb (+ assets/source/world/tow_drogue.blend).

    blender --background --python tools/blender/build_tow_drogue.py

Контракт TW-К8 v2 (docs/contracts/tow.md). Узлы tow_drogue_LOD0/1/2 (≤150 / ≤60 / ≤16 треугольников);
tow_drogue_attach — точка на тросе, в начале координат, сюда сходятся стропы. Купол жёсткий (раскрытый),
по +Z Godot от attach (в Blender −Y); −Z модели — направление движения троса. Клинья купола чередуют цвет.
Цвета — вершинные (Col), текстур нет; материалы Canopy, Line, Hardware (общий). Параметры — build_tow_drogue.json.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

P = U.load_json("tools/blender/build_tow_drogue.json")
C = {k: tuple(U.srgb(v)) for k, v in P["colors"].items()}
AX = Vector((0, -1, 0))  # ось купола от attach (= +Z Godot)


def mats() -> dict:
    return {"Canopy": U.material("Canopy", (1.0, 1.0, 1.0), rough=0.8, double=True),
            "Line": U.material("Line", (1.0, 1.0, 1.0), rough=0.85),
            "Hardware": U.material("Hardware", (1.0, 1.0, 1.0), rough=0.4, metal=0.7)}


def build_lod(cfg: dict):
    mb = U.MeshBuilder()
    mb._tags = {}
    R, D, L = P["canopy_radius"], P["canopy_depth"], P["line_length"]
    rim_ax = math.sqrt(max(L * L - R * R, 0.0))  # стропы длиной L от attach до кромки
    apex_ax = rim_ax + D
    n = cfg["segs"]
    th = [math.radians(t) for t in cfg["thetas_deg"]]

    def pt(t, k):
        a = 2 * math.pi * k / n
        r = R * math.sin(t)
        ax = apex_ax - D * (1 - math.cos(t))
        return AX * ax + Vector((r * math.cos(a), 0, r * math.sin(a)))

    # купол: веер у вершины и кольца четырёхугольников; клин k — цвет по чётности
    rings = [[pt(t, k) for k in range(n)] for t in th[1:]]
    apex = AX * apex_ax
    ia = mb.add_vert(apex)
    ridx = [[mb.add_vert(p) for p in ring] for ring in rings]

    def tag(color):
        mb._tags[len(mb.faces) - 1] = color

    for k in range(n):
        k2 = (k + 1) % n
        col = "gore_a" if k % 2 == 0 else "gore_b"
        mb.add_face((ia, ridx[0][k2], ridx[0][k]), "Canopy")
        tag(col)
        for i in range(len(ridx) - 1):
            mb.add_face((ridx[i][k], ridx[i][k2], ridx[i + 1][k2], ridx[i + 1][k]), "Canopy")
            tag(col)
    # стропы: от кромки в начало координат
    for k in range(cfg["lines"]):
        a = 2 * math.pi * k / cfg["lines"]
        rim = AX * rim_ax + Vector((R * math.cos(a), 0, R * math.sin(a)))
        s = len(mb.faces)
        mb.add_tube([rim, Vector((0, 0, 0))], P["line_radius"], "Line", cfg["line_sides"], False)
        for i in range(s, len(mb.faces)):
            mb._tags[i] = "line"
    if cfg["swivel"]:  # вертлюг на тросе
        sw = P["swivel"]
        s = len(mb.faces)
        mb.add_tube([Vector((0, sw["length"] / 2, 0)), Vector((0, -sw["length"] / 2, 0))], sw["radius"], "Hardware", 4, True)
        for i in range(s, len(mb.faces)):
            mb._tags[i] = "steel"
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
    for lod, cfg in enumerate(P["lod"]):
        ob = finish(build_lod(cfg), f"tow_drogue_LOD{lod}", M)
        t = U.tri_count([ob.name])
        print(f"DROGUE LOD{lod}: {t} tris")
        assert t <= P["lod_tris_max"][lod], (lod, t)
    U.empty("tow_drogue_attach", (0, 0, 0))
    os.makedirs(U.MODELS + "/world", exist_ok=True)
    os.makedirs(U.SOURCE + "/world", exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(U.SOURCE, "world", "tow_drogue.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(U.MODELS, "world", "tow_drogue.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True, export_extras=False,
                              export_vertex_color="ACTIVE", export_active_vertex_color_when_no_material=False,
                              export_cameras=False, export_lights=False)
    print("EXPORTED tow_drogue")


main()
