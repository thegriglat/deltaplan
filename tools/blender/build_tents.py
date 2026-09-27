"""Туристические палатки лагеря у старта: assets/models/world/tents.glb
(+ assets/source/world/tents.blend).

    blender --background --python tools/blender/build_tents.py

Типы (у каждого две меш-ноды <тип>_LOD0 — ближний, ~1–2 тыс. треугольников, и <тип>_LOD1 —
дальний, несколько десятков треугольников):
  dome2   — купольная 2-местная: две дуги крест-накрест, тент провисает между дугами,
            тамбур спереди с пологом входа, растяжки и колышки;
  tunnel3 — туннельная 3-местная: три дуги-обруча, провис между ними, скаты к колышкам
            спереди (тамбур с пологом входа) и сзади, растяжки;
  tarp    — тент-навес «от солнца»: полотно на двух стойках спереди, задний край у земли.
Оси Blender: вход смотрит в +Y (в Godot — −Z), низ — z = 0 (юбка уходит на SKIRT ниже, чтобы на
неровной земле палатка не висела), центр — середина пятна палатки без тамбура/растяжек.
Материалы (по именам; цвет ткани задаёт scripts/world_objects/tent_camp.gd):
  Fabric — ткань тента (тонируется цветом палатки), Door — полог входа (тот же цвет темнее),
  Trim — тёмная полоса у земли (дно-«ванна», юбка), Pole — дуги и стойки, Line — растяжки и колышки.
Цветов и логотипов в модели нет — без брендов.
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
SKIRT = 0.06


def mats() -> dict:
    return {
        "Fabric": U.material("Fabric", (0.8, 0.8, 0.8), rough=0.8, double=True),
        "Door": U.material("Door", (0.55, 0.55, 0.55), rough=0.8, double=True),
        "Trim": U.material("Trim", U.srgb((0.16, 0.16, 0.17)), rough=0.85, double=True),
        "Pole": U.material("Pole", U.srgb((0.22, 0.23, 0.25)), rough=0.5, metal=0.3),
        "Line": U.material("Line", U.srgb((0.78, 0.76, 0.7)), rough=0.7),
    }


def wrinkle(p: Vector, amp: float, seed: float) -> float:
    """Лёгкие складки ткани: крупная рябь + мелкая."""
    return amp * (noise.noise(p * 2.3 + Vector((seed, 0, 0)))
                  + 0.45 * noise.noise(p * 6.1 + Vector((0, seed, 0))))


def peg(mb: U.MeshBuilder, at: Vector, toward: Vector) -> None:
    """Колышек: тонкий брусок, наклонён от палатки."""
    d = Vector((toward.x, toward.y, 0.0))
    d = d.normalized() if d.length > 1e-6 else Vector((0, 1, 0))
    top = at + Vector((0, 0, 0.08)) - d * 0.03
    mb.add_tube([at - Vector((0, 0, 0.12)) + d * 0.02, top], 0.012, "Line", sides=4)


def guy(mb: U.MeshBuilder, a: Vector, b: Vector) -> None:
    """Растяжка от точки на палатке a к колышку b."""
    mb.add_tube([a, b + Vector((0, 0, 0.06))], 0.006, "Line", sides=3, cap=False)
    peg(mb, b, b - a)


# ---------- купольная 2-местная ----------

DOME = {"a": 0.74, "b": 1.06, "h": 1.08, "vest": 0.62, "sq": 3.0}


def dome_point(phi: float, t: float, lod0: bool) -> Vector:
    """Точка тента: phi — угол по кругу (π/2 — вход, +Y), t — 0 у земли … 1 на макушке."""
    a, b, h = DOME["a"], DOME["b"], DOME["h"]
    c, s = math.cos(phi), math.sin(phi)
    n = DOME["sq"]
    r = (abs(c) ** n + abs(s) ** n) ** (-1.0 / n)  # скруглённый прямоугольник пятна
    k = math.cos(t * math.pi / 2) ** 0.7
    # провис тента между дугами (дуги — по диагоналям, 45°), сильнее посередине высоты
    sag = 0.13 * math.cos(2 * phi) ** 2 * math.sin(math.pi * min(t * 1.2, 1.0)) ** 0.8
    # тамбур спереди: ткань вытянута к колышку входа
    fr = max(0.0, s) ** 3 * (1 - t) ** 1.3
    x = a * r * c * k * (1 - sag)
    y = b * r * s * k * (1 - sag) + DOME["vest"] * fr
    z = h * math.sin(t * math.pi / 2) * (1 - 0.25 * fr * (1 - t))
    p = Vector((x, y, z))
    if lod0:
        # складки: радиально, гаснут к дугам и макушке
        w = wrinkle(p, 0.012, 3.0) * (1 - t) * (0.4 + math.cos(2 * phi) ** 2)
        p += Vector((c, s, 0)) * w
    return p


def build_dome(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    na, nt = (36, 10) if lod == 0 else (10, 3)
    ts = [i / nt * (0.999 if lod == 0 else 1.0) for i in range(nt + 1)]
    if lod == 0:
        ts.insert(1, 0.045)  # тёмная полоса дна-«ванны» у земли
    rows = [[dome_point(2 * math.pi * j / na, t, lod == 0) for j in range(na)] for t in ts]
    # юбка ниже земли
    rows.insert(0, [Vector((p.x, p.y, -SKIRT)) for p in rows[0]])
    ts.insert(0, 0.0)
    base = len(mb.verts)
    for row in rows:
        for p in row:
            mb.add_vert(p)
    cols = na
    for i in range(len(rows) - 1):
        for j in range(cols):
            j2 = (j + 1) % cols
            q = [base + i * cols + j, base + i * cols + j2,
                 base + (i + 1) * cols + j2, base + (i + 1) * cols + j]
            phi = 2 * math.pi * (j + 0.5) / cols
            tc = 0.5 * (ts[i] + ts[i + 1])  # доля высоты середины грани
            mat = "Fabric"
            if lod == 0:
                if i <= 1:
                    mat = "Trim"
                elif abs(phi - math.pi / 2) < 0.42 and tc < 0.62:
                    mat = "Door"
            mb.add_face(q, mat, smooth=True)
    if lod == 0:
        # макушка — веер в точку
        top = mb.add_vert(dome_point(0.0, 1.0, False) + Vector((0, 0, 0.004)))
        last = base + (len(rows) - 1) * cols
        for j in range(cols):
            mb.add_face([last + j, last + (j + 1) % cols, top], "Fabric")
        # две дуги крест-накрест (поверх тента)
        for d0 in (math.pi / 4, 3 * math.pi / 4):
            pts = []
            for k in range(-12, 13):
                t = 1 - abs(k) / 12
                phi = d0 if k < 0 else d0 + math.pi
                p = dome_point(phi, min(t, 0.995), False)
                pts.append(p + Vector((p.x, p.y, p.z * 2)).normalized() * 0.018)
            mb.add_tube(pts, 0.014, "Pole", sides=5)
        # колышки по углам, растяжки с середины дуг, растяжка тамбура
        for d0 in (math.pi / 4, 3 * math.pi / 4, 5 * math.pi / 4, 7 * math.pi / 4):
            corner = dome_point(d0, 0.0, False)
            peg(mb, corner * 1.04, corner)
            hi = dome_point(d0, 0.55, False)
            out = Vector((corner.x, corner.y, 0)).normalized()
            guy(mb, hi, corner + out * 0.9)
        front = dome_point(math.pi / 2, 0.0, False)
        peg(mb, front + Vector((0, 0.05, 0)), Vector((0, 1, 0)))
        back = dome_point(-math.pi / 2, 0.0, False)
        guy(mb, dome_point(-math.pi / 2, 0.45, False), back + Vector((0, -0.8, 0)))
    mb.build(f"dome2_LOD{lod}", M)


# ---------- туннельная 3-местная ----------

# обручи: (y, полуширина, высота); вход — +Y
HOOPS = [(1.05, 1.02, 1.12), (0.0, 1.08, 1.22), (-1.0, 0.92, 0.98)]
FRONT_PEG = 2.05
REAR_PEG = -1.65


def tunnel_profile(y: float) -> tuple:
    """(полуширина, высота) сечения тента на расстоянии y вдоль палатки."""
    yf, wf, hf = HOOPS[0]
    yr, wr, hr = HOOPS[-1]
    if y >= yf:
        s = (y - yf) / (FRONT_PEG - yf)
        return wf * (1 - 0.72 * s), hf * max(1 - s, 0.0) ** 1.15
    if y <= yr:
        s = (yr - y) / (yr - REAR_PEG)
        return wr * (1 - 0.7 * s), hr * max(1 - s, 0.0) ** 1.1
    for (y0, w0, h0), (y1, w1, h1) in zip(HOOPS[1:], HOOPS[:-1]):
        if y0 <= y <= y1:
            s = (y - y0) / (y1 - y0)
            sag = math.sin(math.pi * s)
            return (w0 + (w1 - w0) * s) * (1 - 0.035 * sag), (h0 + (h1 - h0) * s) * (1 - 0.06 * sag)
    return wr, hr


def tunnel_point(y: float, th: float, lod0: bool, lift: float = 0.0) -> Vector:
    w, h = tunnel_profile(y)
    c = math.cos(th)
    s = max(math.sin(th), 0.0)
    p = Vector(((w + lift) * c, y, (h + lift) * s ** 0.6))
    if lod0 and 0.0 < th < math.pi:
        near_hoop = min(abs(y - hy) for hy, _, _ in HOOPS)
        p.z += wrinkle(p, 0.014, 7.0) * min(near_hoop / 0.4, 1.0) * s
        p.x += wrinkle(p, 0.01, 11.0) * c * min(near_hoop / 0.4, 1.0)
    return p


def build_tunnel(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    if lod == 0:
        ys = [REAR_PEG + (FRONT_PEG - REAR_PEG) * i / 30 for i in range(31)]
        nth = 16
    else:
        ys = [REAR_PEG, HOOPS[2][0], HOOPS[1][0], HOOPS[0][0], FRONT_PEG]
        nth = 4
    grid = []
    for y in ys:
        ring = [tunnel_point(y, math.pi * k / nth, lod == 0) for k in range(nth + 1)]
        if lod == 0:  # тёмная полоса дна-«ванны» у земли вместо нижних точек сечения
            ring[0] = Vector((ring[0].x, y, 0.07 * min(tunnel_profile(y)[1] / 0.5, 1.0)))
            ring[-1] = Vector((ring[-1].x, y, ring[0].z))
        grid.append([Vector((ring[0].x, y, -SKIRT))] + ring + [Vector((ring[-1].x, y, -SKIRT))])
    base = len(mb.verts)
    cols = len(grid[0])
    for row in grid:
        for p in row:
            mb.add_vert(p)
    yf = HOOPS[0][0]
    for i in range(len(grid) - 1):
        ym = 0.5 * (ys[i] + ys[i + 1])
        for j in range(cols - 1):
            q = [base + i * cols + j, base + (i + 1) * cols + j,
                 base + (i + 1) * cols + j + 1, base + i * cols + j + 1]
            mat = "Fabric"
            if lod == 0:
                thm = math.pi * (j - 0.5) / nth
                if j == 0 or j == cols - 2:
                    mat = "Trim"
                elif ym > yf + 0.08 and ym < FRONT_PEG - 0.3 and abs(thm - math.pi / 2) < 0.75:
                    mat = "Door"
            mb.add_face(q, mat, smooth=True)
    if lod == 0:
        for y, _, _ in HOOPS:
            pts = [tunnel_point(y, math.pi * k / 14, False, 0.02) for k in range(15)]
            pts[0].z = pts[-1].z = 0.0
            mb.add_tube(pts, 0.012, "Pole", sides=5)
            for th in (math.pi / 4, 3 * math.pi / 4):
                a = tunnel_point(y, th, False, 0.02)
                side = 1 if th < math.pi / 2 else -1
                guy(mb, a, Vector((side * 2.0, y + 0.25 * math.copysign(1, y), 0)))
            for side in (-1, 1):
                w, _ = tunnel_profile(y)
                peg(mb, Vector((side * (w + 0.06), y, 0)), Vector((side, 0, 0)))
        peg(mb, Vector((0, FRONT_PEG + 0.04, 0)), Vector((0, 1, 0)))
        peg(mb, Vector((0, REAR_PEG - 0.04, 0)), Vector((0, -1, 0)))
        guy(mb, tunnel_point(HOOPS[0][0], math.pi / 2, False, 0.02), Vector((0, FRONT_PEG + 0.7, 0)))
        guy(mb, tunnel_point(HOOPS[2][0], math.pi / 2, False, 0.02), Vector((0, REAR_PEG - 0.6, 0)))
    mb.build(f"tunnel3_LOD{lod}", M)


# ---------- тент-навес ----------

TARP_W = 3.0     # поперёк (X)
TARP_L = 2.7     # вдоль (Y), вход (открытая сторона) — +Y
TARP_H = 1.65    # высота стоек переднего края
TARP_LOW = 0.22  # задний край у земли


def tarp_point(u: float, v: float, lod0: bool) -> Vector:
    """u ∈ [−1, 1] поперёк, v ∈ [0, 1] от заднего края к переднему."""
    x = u * TARP_W / 2
    y = -TARP_L / 2 + v * TARP_L
    z = TARP_LOW + (TARP_H - TARP_LOW) * v ** 0.9
    # провис: передний край между стойками, полотно посередине
    z -= 0.12 * (1 - u * u) * v ** 2 + 0.1 * math.sin(math.pi * v) * (1 - 0.5 * u * u)
    p = Vector((x, y, z))
    if lod0:
        p.z += wrinkle(p, 0.02, 5.0) * math.sin(math.pi * v) * (1 - 0.6 * abs(u))
        # складки от углов к центру
        p.z += 0.012 * math.sin(9 * (u * 0.8 + v)) * (1 - u * u) * math.sin(math.pi * v)
    return p


def build_tarp(lod: int, M: dict) -> None:
    mb = U.MeshBuilder()
    nu, nv = (16, 12) if lod == 0 else (3, 2)
    grid = [[tarp_point(-1 + 2 * j / nu, i / nv, lod == 0) for j in range(nu + 1)]
            for i in range(nv + 1)]
    mb.add_grid(grid, "Fabric", smooth=True, flip=True)
    x = TARP_W / 2 - 0.06
    yf = TARP_L / 2
    for sx in (-1, 1):
        top = tarp_point(sx, 1.0, False) + Vector((sx * -0.06, 0, 0.12))
        top.x = sx * x
        if lod == 0:
            mb.add_tube([Vector((sx * x, yf, -0.1)), top], 0.018, "Pole", sides=6)
            guy(mb, top, Vector((sx * (x + 0.9), yf + 1.1, 0)))
            back = tarp_point(sx, 0.0, False)
            guy(mb, back, Vector((sx * (x + 0.3), -yf - 0.55, 0)))
        else:
            mb.add_box((sx * x, yf, 0.75), (0.05, 0.05, 1.6), "Fabric")
    if lod == 0:
        guy(mb, tarp_point(0, 0.0, False), Vector((0, -yf - 0.6, 0)))
    mb.build(f"tarp_LOD{lod}", M)


def planar_uv(ob) -> None:
    """UV по положению вершин (ткань без текстуры, но без вырожденных UV: Godot строит по ним
    касательные, нулевые UV дают битые касательные и пятна на свету)."""
    me = ob.data
    uvl = me.uv_layers[0]
    for f in me.polygons:
        for li in range(f.loop_start, f.loop_start + f.loop_total):
            co = me.vertices[me.loops[li].vertex_index].co
            uvl.data[li].uv = (0.5 * co.x + 0.37 * co.y, 0.5 * co.z + 0.21 * co.y - 0.13 * co.x)


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    M = mats()
    for lod in (0, 1):
        build_dome(lod, M)
        build_tunnel(lod, M)
        build_tarp(lod, M)
    for ob in bpy.context.scene.objects:
        if ob.type == "MESH":
            planar_uv(ob)
            print(f"TENT {ob.name}: {U.tri_count([ob.name])} tris")
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "tents.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "tents.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)
    print(f"EXPORTED tents: {U.tri_count()} tris")


main()
