"""Полусобранный дельтаплан у старта: assets/models/world/glider_kit.glb
(+ assets/source/world/glider_kit.blend). Контракт SC-K3 (docs/contracts/start-camp.md).

    blender --background --python tools/blender/build_glider_kit.py

Варианты (у каждого меш-ноды <вариант>_LOD0 — ближний и <вариант>_LOD1 — грубый силуэт):
  kit_bundle — сложенный каркас пучком ~5,5 м (две передние кромки, киль, поперечина; торцы труб
               открыты, рядом кингпост) на расстёгнутом раскрытом чехле; парус в рулоне рядом;
  kit_frame  — трапеция плашмя: стойки 1,65 м, базовая штанга 1,4 м, узел вершины, колёса на концах
               штанги (frame_parts.py, wheel_parts.py); вершина к −Z.
Оси Blender: +Y вперёд (в Godot −Z), Z вверх, начало — центр пятна, низ z = 0. Материалы (имена —
контракт): Fabric (чехол, тон игры), FabricDark (подкладка, без тона), Sail (парус, тон игры),
Webbing, Tube, Fitting, Steel, Tire. Цветов вершин нет, UV у ткани не нужны.
"""
import math
import os
import sys

import bpy
from mathutils import Vector, noise

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import frame_parts as F  # noqa: E402
import wheel_parts as W  # noqa: E402

OUT = os.path.join(U.MODELS, "world")
SRC = os.path.join(U.SOURCE, "world")


def mats() -> dict:
    tire = U.material("Tire", (1, 1, 1), rough=0.88, image=W.tire_texture())
    fitting = U.material("Fitting", U.srgb((0.2, 0.21, 0.22)), rough=0.45, metal=0.5)
    return {
        "Fabric": U.material("Fabric", (0.8, 0.8, 0.8), rough=0.85, double=True),
        "FabricDark": U.material("FabricDark", U.srgb((0.12, 0.12, 0.13)), rough=0.9, double=True),
        "Sail": U.material("Sail", (0.8, 0.8, 0.8), rough=0.7, double=True),
        "Webbing": U.material("Webbing", U.srgb((0.2, 0.2, 0.19)), rough=0.85, double=True),
        "Tube": U.material("Tube", U.srgb((0.72, 0.73, 0.75)), rough=0.4, metal=0.6, double=True),
        "Fitting": fitting,
        "Steel": U.material("Steel", U.srgb((0.55, 0.56, 0.58)), rough=0.35, metal=0.85),
        "Tire": tire,
        # имена материалов wheel_parts.py → контрактные
        "Wheel": tire,
        "WheelRim": fitting,
    }


def smooth01(x: float) -> float:
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


# ---------- kit_bundle ----------

BAG_L, BAG_W = 5.6, 0.9
BX, BZ = -0.15, 0.012          # ось пучка по X, уровень земли под трубами (чехол почти плоский)


def bag_z(x: float, y: float) -> float:
    """Расстёгнутый чехол: плоское дно, края загнуты вверх, рябь складок."""
    a = abs(x)
    curl = 0.16 * smooth01((a - 0.30) / 0.15)
    end = 0.05 * smooth01((abs(y) - 2.6) / 0.2)
    ripple = 0.012 * (noise.noise(Vector((x * 3.1, y * 1.3, 0.4))) + 1)
    return ripple + curl + end


def build_bag(mb, lod: int) -> None:
    nx, ny = (8, 14) if lod == 0 else (2, 2)
    hw, hl = BAG_W / 2, BAG_L / 2
    pts = []
    for j in range(ny + 1):
        y = -hl + BAG_L * j / ny
        row = []
        for i in range(nx + 1):
            x = -hw + BAG_W * i / nx
            if lod == 0:
                # торцы скруглены: ширина сужается у концов
                k = 1 - 0.18 * smooth01((abs(y) - 2.5) / 0.3) ** 2
                row.append(Vector((x * k, y, bag_z(x, y))))
            else:
                row.append(Vector((x, y, 0.0 if i in (nx // 2,) else 0.12 * (i != nx // 2))))
        pts.append(row)
    if lod == 0:
        mb.add_grid(pts, "Fabric", flip=True)
        # подкладка тёмная: полоса вдоль середины — расстёгнутая молния
        for s in (-1, 1):
            zip_ = [Vector((s * 0.2, -hl + BAG_L * j / 12, bag_z(s * 0.2, -hl + BAG_L * j / 12) + 0.004))
                    for j in range(13)]
            mb.add_tube(zip_, 0.006, "Steel", sides=4, cap=False)
        # две ручки-стропы поперёк
        for y in (-1.2, 1.4):
            mb.add_tube([Vector((x, y, bag_z(x, y) + 0.008)) for x in (-0.4, -0.2, 0.0, 0.2, 0.4)],
                        0.012, "Webbing", sides=4, ellipse=(1.0, 0.35), up=(0, 1, 0), cap=False)
    else:
        mb.add_grid(pts, "Fabric", flip=True, smooth=False)


def open_end(mb, end, direction, r: float, mat: str, sides: int, lod: int) -> None:
    """Открытый торец трубы: тёмный диск в глубине трубы (внутренность видна)."""
    if lod == 0:
        d = Vector(direction).normalized()
        c = Vector(end) - d * 0.03
        mb.add_tube([c, c - d * 0.001], r * 0.93, "FabricDark", sides=sides)


def build_bundle(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    build_bag(mb, lod)
    sd = 10 if lod == 0 else 4
    z0 = BZ + 0.005
    # пучок: [x, z, радиус, y_от, y_до]
    tubes = [(BX - 0.028, z0 + 0.0245, 0.0245, -2.75, 2.75),   # передняя кромка
             (BX + 0.028, z0 + 0.0245, 0.0245, -2.72, 2.78),   # передняя кромка
             (BX, z0 + 0.0245 + 0.045, 0.0285, -2.55, 2.6),    # киль
             (BX + 0.075, z0 + 0.021, 0.021, -2.35, 2.30)]     # поперечина
    if lod == 0:
        for x, z, r, ya, yb in tubes:
            pts = [Vector((x, ya + (yb - ya) * k / 4, z)) for k in range(5)] if False else \
                [Vector((x, ya, z)), Vector((x, yb, z))]
            mb.add_tube(pts, r, "Tube", sides=sd, cap=False)
            open_end(mb, pts[0], pts[1] - pts[0], r, "Tube", sd, lod)
            open_end(mb, pts[1], pts[0] - pts[1], r, "Tube", sd, lod)
        # хомуты-ленты на пучке
        for y in (-1.6, 0.0, 1.7):
            ring = [Vector((BX + 0.02 + 0.075 * math.cos(2 * math.pi * k / 10),
                            y, z0 + 0.052 + 0.058 * math.sin(2 * math.pi * k / 10))) for k in range(10)]
            mb.add_tube(ring, 0.006, "Webbing", sides=4, closed=True, up=(0, 1, 0))
        # узел у носа: пластина и болт через кромки
        ex, ey = Vector((1, 0, 0)), Vector((0, 0, 1))
        pts2 = F.rounded_outline([(-0.06, -0.04), (0.06, -0.04), (0.06, 0.07), (-0.06, 0.07)], 0.02, 2)
        F.add_prism(mb, [(x, y) for x, y in pts2], (BX + 0.01, 2.3, z0 + 0.04), ex, ey, 0.004, "Fitting")
        F.add_bolt(mb, (BX + 0.01, 2.3, z0 + 0.05), (0, 1, 0), 0.07, 0.006, "Steel")
        # кингпост рядом
        kx = BX - 0.2
        mb.add_tube([Vector((kx, -0.6, BZ + 0.025)), Vector((kx, 1.3, BZ + 0.025))], 0.022, "Tube",
                    sides=12, cap=False)
        open_end(mb, (kx, -0.6, BZ + 0.025), (0, -1, 0), 0.022, "Tube", 12, lod)
        open_end(mb, (kx, 1.3, BZ + 0.025), (0, 1, 0), 0.022, "Tube", 12, lod)
        mb.add_tube([Vector((kx, 1.3, BZ + 0.025)), Vector((kx, 1.36, BZ + 0.025))], 0.016, "Fitting",
                    sides=8)
    else:
        for x, z, r, ya, yb in tubes[:3]:
            mb.add_tube([Vector((x, ya, z)), Vector((x, yb, z))], r, "Tube", sides=4)
        kx = BX - 0.2
        mb.add_tube([Vector((kx, -0.6, BZ + 0.025)), Vector((kx, 1.36, BZ + 0.025))], 0.022, "Tube",
                    sides=4)
    # парус в рулоне
    rx, rz = 0.2, BZ + 0.15
    ns = 20 if lod == 0 else 5
    ring_n = 12 if lod == 0 else 5
    ys = [-2.3 + 4.6 * k / ns for k in range(ns + 1)]
    rows = []
    for y in ys:
        base_r = 0.14 + (0.012 * noise.noise(Vector((y * 2.2, 0.3, 1.1))) if lod == 0 else 0)
        end = smooth01((abs(y) - 2.15) / 0.15)
        r = base_r * (1 - 0.5 * end)
        row = []
        for k in range(ring_n):
            a = 2 * math.pi * k / ring_n
            rr = r * (1 + (0.04 * noise.noise(Vector((k * 1.7, y * 3, 0))) if lod == 0 else 0))
            row.append(Vector((rx + rr * math.cos(a), y, rz + rr * math.sin(a))))
        rows.append(row)
    mb.add_grid(rows, "Sail", wrap=True, flip=True)
    for ring, rev in ((rows[0], False), (rows[-1], True)):
        idx = [mb.add_vert(v) for v in ring]
        mb.add_face(list(reversed(idx)) if rev else idx, "Sail", smooth=False)
    if lod == 0:  # стропы-стяжки рулона
        for y in (-1.5, 0.2, 1.7):
            ring = [Vector((rx + 0.148 * math.cos(2 * math.pi * k / 12), y,
                            rz + 0.148 * math.sin(2 * math.pi * k / 12))) for k in range(12)]
            mb.add_tube(ring, 0.008, "Webbing", sides=4, closed=True, up=(0, 1, 0))
    mb.build(f"kit_bundle_LOD{lod}", M)


# ---------- kit_frame ----------

W_HALF = 0.7          # половина базовой штанги (1,4 м)
UP_LEN = 1.65
R_UP, R_BAR = 0.0165, 0.0145
BAR_Z = W.R_OUT       # штанга на высоте радиуса колеса: колёса стоят на земле
APEX_Z = 0.03         # вершина лежит на земле, стойки чуть наклонены


def build_frame(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    dy = math.sqrt(UP_LEN ** 2 - W_HALF ** 2 - (BAR_Z - APEX_Z) ** 2)
    y_bar, y_apex = -dy / 2, dy / 2
    apex = Vector((0, y_apex, APEX_Z))
    sd = 12 if lod == 0 else 4
    corners = [Vector((s * W_HALF, y_bar, BAR_Z)) for s in (-1, 1)]
    for c in corners:
        mb.add_tube([c, apex], R_UP, "Tube", sides=sd)
    xs = [-(W_HALF + 0.035), -W_HALF, 0, W_HALF, W_HALF + 0.035] if lod == 0 else [-(W_HALF + 0.035), W_HALF + 0.035]
    mb.add_tube([Vector((x, y_bar, BAR_Z)) for x in xs], R_BAR, "Tube", sides=sd)
    if lod == 0:
        ex, ey = Vector((1, 0, 0)), Vector((0, 1, 0))
        # узел вершины: две пластины сверху и снизу стоек, болт, втулка кингпоста
        d = (apex - corners[0]).normalized()
        ax_ = Vector((0, 0, 1))
        outline = F.rounded_outline([(-0.045, -0.07), (0.045, -0.07), (0.03, 0.06), (-0.03, 0.06)], 0.012, 2)
        for dz in (-1, 1):
            F.add_prism(mb, outline, apex + Vector((0, -0.04, dz * (R_UP + 0.003))), ex, ey, 0.004, "Fitting")
        F.add_bolt(mb, apex + Vector((0, -0.02, 0)), ax_, 2 * R_UP + 0.025, 0.0065, "Steel")
        mb.add_tube([apex + Vector((0, 0.0, 0.0)), apex + Vector((0, 0.07, 0.0))], 0.02, "Fitting", sides=10)
        # угловые узлы: пластины штанга–стойка с болтом
        for s, c in zip((-1, 1), corners):
            p2 = F.rounded_outline([(-0.04, -0.04), (0.05, -0.04), (0.05, 0.05), (-0.04, 0.05)], 0.012, 2)
            for dz in (-1, 1):
                F.add_prism(mb, p2, c + Vector((s * -0.01, 0.0, dz * (R_BAR + 0.003))), ex, ey, 0.004, "Fitting")
            F.add_bolt(mb, c + Vector((s * -0.01, 0.0, 0)), ax_, 2 * R_BAR + 0.025, 0.006, "Steel")
        for s in (-1, 1):  # заглушки концов штанги
            e = Vector((s * (W_HALF + 0.035), y_bar, BAR_Z))
            mb.add_tube([e, e + Vector((s * 0.012, 0, 0))], R_BAR * 1.08, "FabricDark", sides=12)
        for s in (-1, 1):
            W.add_wheel(mb, Vector((s * (W_HALF + 0.07), y_bar, BAR_Z)), s, s * (W_HALF + 0.035))
    else:
        for s in (-1, 1):
            c = Vector((s * (W_HALF + 0.07), y_bar, BAR_Z))
            mb.add_tube([c - Vector((0.025, 0, 0)), c + Vector((0.025, 0, 0))], W.R_OUT, "Tire", sides=6)
    mb.build(f"kit_frame_LOD{lod}", M)


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    M = mats()
    for lod in (0, 1):
        build_bundle(lod, M)
        build_frame(lod, M)
    for ob in bpy.context.scene.objects:
        if ob.type == "MESH":
            me = ob.data
            uvl = me.uv_layers[0]
            for f in me.polygons:  # ткань без текстуры, но без вырожденных UV (касательные)
                for li in range(f.loop_start, f.loop_start + f.loop_total):
                    if not any(m.name == "Tire" for m in me.materials[f.material_index:f.material_index + 1]):
                        co = me.vertices[me.loops[li].vertex_index].co
                        uvl.data[li].uv = (0.5 * co.x + 0.37 * co.y, 0.5 * co.z + 0.21 * co.y)
            print(f"KIT {ob.name}: {U.tri_count([ob.name])} tris "
                  f"bbox z {min(v.co.z for v in me.vertices):.3f}")
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "glider_kit.blend"), check_existing=False,
                                compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "glider_kit.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)
    U.externalize_shared(os.path.join(OUT, "glider_kit.glb"))
    print(f"EXPORTED glider_kit: {U.tri_count()} tris")


main()
