"""Вещи у старта: assets/models/world/start_gear.glb (+ assets/source/world/start_gear.blend).

    blender --background --python tools/blender/build_start_gear.py

Контракт SC-K3 (docs/contracts/start-camp.md). Варианты (у каждого меш-ноды <вариант>_LOD0 и _LOD1):
  wing_bag_long  — чехол крыла 5,6 м, лежит, неровный от труб, молния по верху, 4 ручки-стропы;
  wing_bag_short — короткий пакет 4,2 м, 3 ручки;
  harness_pack   — рюкзак с подвеской, лежит на спине, лямки сверху;
  harness_open   — вытряхнутая подвеска-кокон, плашмя, лямки, карабин;
  helmet         — открытый шлем стоя (скорлупа, подкладка, ремешок);
  bottle         — бутылка 1,5 л на боку.
Оси Blender: длина вдоль Y (в Godot — Z, «перёд» = +Y Blender = −Z Godot), Z вверх, низ z = 0.
Материалы по именам (цвет и тон задаёт игра, SC-K5): Fabric, FabricDark, Webbing, Shell, Fitting,
Steel, Bottle, Cap. Цветов вершин и логотипов нет, UV — только плоские (против битых касательных).
"""
import math
import os
import sys

import bpy
from mathutils import Vector, noise

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

OUT = os.path.join(U.MODELS, "world")
SRC = os.path.join(U.SOURCE, "world")


def mats() -> dict:
    return {
        "Fabric": U.material("Fabric", (0.8, 0.8, 0.8), rough=0.85, double=True),
        "FabricDark": U.material("FabricDark", U.srgb((0.12, 0.12, 0.13)), rough=0.85, double=True),
        "Webbing": U.material("Webbing", U.srgb((0.62, 0.6, 0.55)), rough=0.8, double=True),
        "Shell": U.material("Shell", (0.8, 0.8, 0.8), rough=0.4),
        "Fitting": U.material("Fitting", U.srgb((0.15, 0.15, 0.16)), rough=0.5, metal=0.2),
        "Steel": U.material("Steel", U.srgb((0.62, 0.64, 0.66)), rough=0.35, metal=0.9),
        "Bottle": U.material("Bottle", U.srgb((0.75, 0.86, 0.92)), rough=0.25),
        "Cap": U.material("Cap", U.srgb((0.1, 0.35, 0.75)), rough=0.5),
    }


# ---------- помощники ----------

def sgn(x: float) -> float:
    return 1.0 if x >= 0 else -1.0


def loft(mb, rings, mat, caps=(True, True), band_mats=None, skip=None, inward=False):
    """Поверхность по кольцам (замкнутым по j), нормали сами наружу; торцы — n-угольники."""
    R, S = len(rings), len(rings[0])
    base = len(mb.verts)
    for r in rings:
        for p in r:
            mb.add_vert(p)
    c0 = sum((Vector(p) for p in rings[0]), Vector()) / S
    c1 = sum((Vector(p) for p in rings[1]), Vector()) / S
    a, b, d = Vector(rings[0][0]), Vector(rings[1][0]), Vector(rings[0][1])
    out = a - c0
    if out.length < 1e-6:
        out = a - c1
    flip = (b - a).cross(d - a).dot(out) < 0
    if inward:
        flip = not flip
    for i in range(R - 1):
        for j in range(S):
            if skip and skip(i, j):
                continue
            j2 = (j + 1) % S
            q = [base + i * S + j, base + (i + 1) * S + j, base + (i + 1) * S + j2, base + i * S + j2]
            if flip:
                q.reverse()
            mb.add_face(q, band_mats[i] if band_mats else mat, smooth=True)
    for k, ring, direction in ((0, rings[0], c0 - c1),
                               (1, rings[-1], sum((Vector(p) for p in rings[-1]), Vector()) / S
                                - sum((Vector(p) for p in rings[-2]), Vector()) / S)):
        if not caps[k]:
            continue
        pts = [Vector(p) for p in ring]
        n = Vector()
        for i in range(S):
            n += pts[i].cross(pts[(i + 1) % S])
        idx = [mb.add_vert(p) for p in pts]
        if (n.dot(direction) < 0) != inward:
            idx.reverse()
        mb.add_face(idx, mat if not band_mats else band_mats[0 if k == 0 else -1], smooth=False)


def ribbon(mb, rows, mat, up=Vector((0, 0, 1))):
    """Лента из пар точек (левая, правая) вдоль пути, лицом вверх."""
    a, b, d = Vector(rows[0][0]), Vector(rows[1][0]), Vector(rows[0][1])
    flip = (b - a).cross(d - a).dot(up) < 0
    mb.add_grid(rows, mat, flip=flip, smooth=False)


def end_scale(d: float, rd: float) -> float:
    """Скругление торца: d — расстояние до края, rd — радиус скругления."""
    if d >= rd:
        return 1.0
    return max(math.sqrt(max(1.0 - (1.0 - d / rd) ** 2, 0.0)), 0.0)


def ys_for(y0: float, y1: float, m: int, ends=(0.004, 0.045, 0.12)):
    """Положения колец: плотно у торцов, равномерно между. Всего 2*len(ends) + m − 1."""
    lo = y0 + ends[-1]
    hi = y1 - ends[-1]
    return ([y0 + d for d in ends] + [lo + (hi - lo) * i / m for i in range(1, m)]
            + [y1 - d for d in reversed(ends)])


def ring(y, w, h, n, S, lump, x0=0.0, e=1.0):
    """Сечение-суперэллипс, плоский низ z = 0; lump(θ, y) — множитель бугров (от центра)."""
    pts = []
    for k in range(S):
        th = 2 * math.pi * k / S
        c, s = math.cos(th), math.sin(th)
        l = lump(th, y) * e
        x = w * sgn(c) * abs(c) ** (2 / n)
        z = h * (0.5 + 0.5 * sgn(s) * abs(s) ** (2 / n))
        pts.append(Vector((x0 + x * l, y, z * l)))
    return pts


def top_z(r, S):
    return r[S // 4].z


def webbing_arch(mb, y, xs, zt, rise, width=0.016, thick=0.005):
    """Ручка-стропа поперёк верха: дуга в плоскости XZ, лента стоит широкой стороной вдоль Y."""
    x = xs
    pts = [Vector((-x, y, zt(-x) - 0.012)), Vector((-x, y, zt(-x) + rise * 0.55)),
           Vector((-x * 0.4, y, zt(0) + rise)), Vector((x * 0.4, y, zt(0) + rise)),
           Vector((x, y, zt(x) + rise * 0.55)), Vector((x, y, zt(x) - 0.012))]
    mb.add_tube(pts, width, "Webbing", sides=4, cap=False, ellipse=(thick / width, 1.0), up=(0, 1, 0))


def planar_uv(ob) -> None:
    me = ob.data
    uvl = me.uv_layers[0]
    for f in me.polygons:
        for li in range(f.loop_start, f.loop_start + f.loop_total):
            co = me.vertices[me.loops[li].vertex_index].co
            uvl.data[li].uv = (0.5 * co.x + 0.37 * co.y, 0.5 * co.z + 0.21 * co.y - 0.13 * co.x)


# ---------- чехлы крыльев ----------

BAG_W, BAG_H = 0.17, 0.24   # полуширина и высота сечения


def bag_lump(L: float, seed: float):
    def f(th, y):
        top = max(math.sin(th), 0.0)
        tubes = 0.5 + 0.5 * math.cos(2 * math.pi * y / 1.1 + seed)         # бугры от труб вдоль
        n1 = noise.noise(Vector((y * 1.9 + seed, math.cos(th) * 1.3, math.sin(th) * 1.3)))
        return 1.0 - 0.045 + 0.032 * tubes * (0.4 + top) + 0.03 * n1 + 0.02 * math.cos(3 * th + seed)
    return f


def build_bag(name: str, L: float, handles, seed: float, lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    lump = bag_lump(L, seed)
    if lod == 0:
        S, m = 12, (12 if L > 5 else 9)
        ys = ys_for(-L / 2, L / 2, m)
    else:
        S = 6
        ys = [-L / 2 + 0.01, -L / 2 + 0.15, 0.0, L / 2 - 0.15, L / 2 - 0.01]
    rings = []
    for y in ys:
        d = min(y + L / 2, L / 2 - y)
        e = end_scale(max(d, 0.0), 0.17)
        e = max(e, 0.3)
        rings.append(ring(y, BAG_W, BAG_H, 2.8, S, (lump if lod == 0 else lambda t, yy: 1.04), e=e))
    loft(mb, rings, "Fabric")
    if lod == 0:
        # молния по верху: лента FabricDark, бегунок
        rows = [(r[S // 4] + Vector((-0.011, 0, 0.003)), r[S // 4] + Vector((0.011, 0, 0.003)))
                for r in rings[1:-1]]
        ribbon(mb, rows, "FabricDark")
        yp = -L / 2 + 0.9
        zp = top_z(ring(yp, BAG_W, BAG_H, 2.8, S, lump), S)
        mb.add_box((0, yp, zp + 0.012), (0.03, 0.045, 0.016), "Fitting")
        for y in handles:
            def zt(x, y=y):
                r = ring(y, BAG_W, BAG_H, 2.8, S, lump)
                # высота на расстоянии |x| от гребня: линейно между вершинами k=S/4 и S/4±1
                a, b = r[S // 4], r[S // 4 - 1]
                t = min(abs(x) / max(abs(b.x - a.x), 1e-6), 1.0)
                return a.z + (b.z - a.z) * t
            webbing_arch(mb, y, 0.06, zt, 0.03)
    mb.build(f"{name}_LOD{lod}", M)


# ---------- рюкзак с подвеской ----------

def build_pack(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    L, W, H = 0.85, 0.225, 0.32

    def lump(th, y):
        return 0.96 + 0.035 * noise.noise(Vector((y * 3.1 + 2, math.cos(th) * 1.5, math.sin(th) * 1.5))) \
            + 0.025 * math.cos(2 * th) * math.sin(th)
    if lod == 0:
        S = 12
        ys = ys_for(-L / 2, L / 2, 5, ends=(0.004, 0.04, 0.11))
    else:
        S = 6
        ys = [-L / 2 + 0.01, 0.0, L / 2 - 0.01]
    rings = []
    for y in ys:
        e = max(end_scale(min(y + L / 2, L / 2 - y), 0.15), 0.35)
        rings.append(ring(y, W, H, 3.0, S, (lump if lod == 0 else lambda t, yy: 1.0), e=e))
    loft(mb, rings, "Fabric")
    if lod == 0:
        rows = [(r[S // 4] + Vector((-0.012, 0, 0.003)), r[S // 4] + Vector((0.012, 0, 0.003)))
                for r in rings[1:-1]]
        ribbon(mb, rows, "FabricDark")
        # две лямки сверху: от задней части к передней, лёгкий изгиб, пряжки на концах
        for sx in (-1, 1):
            pts = []
            for i in range(6):
                t = i / 5
                y = -0.30 + 0.62 * t
                x = sx * (0.09 + 0.045 * math.sin(math.pi * t) + 0.03 * t)
                r = ring(y, W, H, 3.0, S, lump)
                # высота поверхности на x: интерполяция по кольцу вдоль верхней части
                zs = max(p.z for p in r if abs(p.x - x) < 0.05) if any(abs(p.x - x) < 0.05 for p in r) else r[S // 4].z
                pts.append(Vector((x, y, zs + 0.006)))
            mb.add_tube(pts, 0.014, "Webbing", sides=4, cap=False, ellipse=(1.0, 0.3))
            mb.add_box(pts[-1] + Vector((0, 0.02, 0.006)), (0.04, 0.03, 0.012), "Fitting")
        # ручка на верху
        def zt(x):
            r = ring(0.0, W, H, 3.0, S, lump)
            return r[S // 4].z - abs(x) * 0.25
        webbing_arch(mb, 0.08, 0.07, zt, 0.04)
    mb.build(f"harness_pack_LOD{lod}", M)


# ---------- вытряхнутая подвеска ----------

def build_open(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    y0, y1 = -0.95, 0.58   # тело; лямки и карабин — до +0.95

    def prof(y):
        t = (y - y0) / (y1 - y0)
        w = 0.15 + 0.24 * math.sin(math.pi * min(t, 1.0) ** 0.8) ** 0.7 * (0.4 + 0.6 * t)
        h = 0.15 * (0.45 + 0.55 * math.sin(math.pi * min(t * 1.15, 1.0)) ** 0.5)
        return min(w, 0.38), h

    def lump(th, y):
        return 0.95 + 0.04 * noise.noise(Vector((y * 3.0, math.cos(th) * 1.4, math.sin(th) * 1.4)))
    if lod == 0:
        S = 12
        ys = ys_for(y0, y1, 8, ends=(0.004, 0.04, 0.11))
    else:
        S = 6
        ys = [-0.94, 0.1, 0.94]
    rings = []
    for y in ys:
        if lod == 0:
            w, h = prof(y)
            e = max(end_scale(min(y - y0, y1 - y), 0.12), 0.3)
        else:
            w, h = {-0.94: (0.1, 0.07), 0.1: (0.3, 0.145), 0.94: (0.05, 0.02)}[y]
            e = 1.0
        rings.append(ring(y, w, h, 2.6, S, (lump if lod == 0 else lambda t, yy: 1.0), e=e))
    loft(mb, rings, "Fabric")
    if lod == 0:
        rows = [(r[S // 4] + Vector((-0.012, 0, 0.003)), r[S // 4] + Vector((0.012, 0, 0.003)))
                for r in rings[1:-1]]
        ribbon(mb, rows, "FabricDark")
        # плечевые лямки от груди к карабину
        ztop = lambda y: top_z(ring(y, *prof(y), 2.6, S, lump), S)
        zc = 0.014
        cx, cy = 0.0, 0.88
        for sx in (-1, 1):
            a = Vector((sx * 0.12, 0.48, ztop(0.48) - 0.01))
            pts = [a, Vector((sx * 0.14, 0.62, 0.02)), Vector((sx * 0.09, 0.76, zc)),
                   Vector((sx * 0.04, 0.86, zc))]
            mb.add_tube(pts, 0.015, "Webbing", sides=4, cap=False, ellipse=(1.0, 0.35))
        # регулятор на лямках
        mb.add_box((0.0, 0.70, 0.016), (0.1, 0.03, 0.014), "Fitting")
        # карабин: замкнутая петля, лежит плашмя
        car = [Vector((0.035 * math.cos(2 * math.pi * k / 8), 0.91 + 0.04 * math.sin(2 * math.pi * k / 8), 0.01))
               for k in range(8)]
        mb.add_tube(car, 0.009, "Steel", sides=4, closed=True)
        # две ножные петли лежат поверх тела
        for sx in (-1, 1):
            yc = -0.32
            cz = ztop(yc) * 0.8 + 0.01
            loop = [Vector((sx * 0.12 + 0.07 * math.cos(2 * math.pi * k / 6), yc + 0.13 * math.sin(2 * math.pi * k / 6), cz))
                    for k in range(6)]
            mb.add_tube(loop, 0.011, "Webbing", sides=3, closed=True, ellipse=(1.0, 0.5))
    mb.build(f"harness_open_LOD{lod}", M)


# ---------- шлем ----------

def build_helmet(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    rx, ry, rz = 0.115, 0.145, 0.20
    S = 14 if lod == 0 else 8
    els = [0, 25, 50, 70, 82] if lod == 0 else [0, 75]

    def dome(scale, els_):
        rings = []
        for e in els_:
            a = math.radians(e)
            c, s = math.cos(a), math.sin(a)
            r = []
            for k in range(S):
                th = 2 * math.pi * k / S
                # лёгкая грушевидность: затылок шире, лоб уже
                sk = 1.0 + 0.05 * math.sin(th) * -1
                r.append(Vector((rx * c * math.cos(th) * scale * sk, ry * c * math.sin(th) * scale,
                                 rz * (s ** 0.9 if s > 0 else 0.0) * scale + (0.0 if scale == 1 else 0.0))))
            rings.append(r)
        return rings
    shell = dome(1.0, els)

    def opening(i, j):
        # передняя часть (+Y, θ около π/2) открыта в нижних поясах
        th = 2 * math.pi * (j + 0.5) / S
        return lod == 0 and i <= 1 and abs(th - math.pi / 2) < 0.9
    loft(mb, shell, "Shell", caps=(False, True), skip=opening)
    if lod == 0:
        lin = dome(0.93, [0, 35, 65, 82])
        loft(mb, lin, "FabricDark", caps=(False, False), skip=opening, inward=True)
        # ремешок: две ветви лежат на земле от нижней кромки, пряжка
        for sx in (-1, 1):
            a = Vector((sx * rx * 0.98, 0.0, 0.004))
            pts = [a, Vector((sx * 0.112, 0.05, 0.006)), Vector((sx * 0.1, 0.1, 0.006)),
                   Vector((sx * 0.07, 0.135, 0.006)), Vector((sx * 0.03, 0.14, 0.006))]
            mb.add_tube(pts, 0.011, "Webbing", sides=4, cap=False, ellipse=(1.0, 0.25), up=(0, 0, 1))
        mb.add_box((0.0, 0.135, 0.008), (0.04, 0.02, 0.014), "Fitting")
    mb.build(f"helmet_LOD{lod}", M)


# ---------- бутылка ----------

def build_bottle(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    zc = 0.045
    if lod == 0:
        S = 10
        prof = [(0.034, -0.165), (0.045, -0.15), (0.045, 0.075), (0.036, 0.108), (0.0155, 0.130),
                (0.0185, 0.134), (0.0185, 0.165)]
        bmats = ["Bottle"] * 4 + ["Cap"] * 2
        bmats = ["Bottle"] * 5 + ["Cap"]
    else:
        S = 4
        prof = [(0.045, -0.165), (0.032, 0.165)]
        bmats = ["Bottle"]
    rings = []
    for r, y in prof:
        off = math.pi / S if lod == 0 else 0.0
        rings.append([Vector((r * math.cos(2 * math.pi * k / S + off), y,
                              zc + r * math.sin(2 * math.pi * k / S + off))) for k in range(S)])
    loft(mb, rings, "Bottle", band_mats=bmats)
    mb.build(f"bottle_LOD{lod}", M)


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    M = mats()
    for lod in (0, 1):
        build_bag("wing_bag_long", 5.6, (-1.45, -0.5, 0.55, 1.45), 0.7, lod, M)
        build_bag("wing_bag_short", 4.2, (-0.95, 0.0, 0.95), 2.1, lod, M)
        build_pack(lod, M)
        build_open(lod, M)
        build_helmet(lod, M)
        build_bottle(lod, M)
    for ob in bpy.context.scene.objects:
        if ob.type == "MESH":
            planar_uv(ob)
            bb = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
            lo = [min(v[i] for v in bb) for i in range(3)]
            hi = [max(v[i] for v in bb) for i in range(3)]
            print(f"GEAR {ob.name}: {U.tri_count([ob.name])} tris, size x{hi[0]-lo[0]:.3f} "
                  f"y{hi[1]-lo[1]:.3f} z{hi[2]-lo[2]:.3f}, min z {lo[2]:.3f}, "
                  f"center x{(hi[0]+lo[0])/2:.3f} y{(hi[1]+lo[1])/2:.3f}")
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "start_gear.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "start_gear.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)
    print(f"EXPORTED start_gear: {U.tri_count()} tris")


main()
