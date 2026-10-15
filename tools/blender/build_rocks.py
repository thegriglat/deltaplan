"""Камни и глыбы для разброса у земли: assets/models/rocks/rocks.glb (+ assets/source/rocks/rocks.blend).

    blender --background --python tools/blender/build_rocks.py

Варианты (VARIANTS): 9 крупных (boulder0 — окатанный валун, chunk0/1 — угловатые глыбы, slab0/1 —
плиты со сколами, wedge0 — клин, tooth0 — стоячий зуб, comb0/1 — вытянутые «гребешки» коренной
породы) и 4 мелких (pebble0 — окатыш, chip0 — скол, flake0 — плоский обломок, wedge1 — клин).
У каждого три меша-ноды <имя>_LOD0 / _LOD1 / _LOD2 — одна форма: многогранник из плоскостей
(пересечения троек плоскостей → выпуклая оболочка, плоские грани, острые рёбра, раздельные нормали):
LOD0 — все плоскости (20–80 треугольников), LOD2 — главные плоскости (12–20), LOD1 — между;
мелкие (pebble0, chip0, flake0, wedge1) — один меш 12–20 треугольников во всех трёх нодах.
boulder0 — окатанный валун (икосфера 3 + шум: 320 / 80 / 20). pebble0 — оболочка 10 точек, гладкое
затенение. Мелкий рельеф — трипланарная нормаль в rock_scatter.gdshader (UV у мешей нет).
Размер нормирован для каждого LOD: наибольший горизонтальный размер 1 м (у гребешков — вдоль X,
масштаб по осям задаёт rock_scatter.gd), высота как у LOD0, низ на −0,15·высоты, вверх +Y (Godot).
Масштаб, поворот и оттенок экземпляра задаёт scripts/terrain/rock_scatter.gd.
"""
import itertools
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector, noise

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

OUT = os.path.join(U.MODELS, "rocks")
SRC = os.path.join(U.SOURCE, "rocks")

# имя, вид, сид, параметры, подразбиения LOD0
# blob: ell, срезов, глубина срезов, шум, частота; poly: полуоси, доп. плоскостей, разброс наклона
VARIANTS = [
    ("boulder0", "blob", 11, dict(ell=(1.0, 0.85, 0.7), cuts=4, depth=0.22, amp=0.07, freq=1.6), 3),
    ("chunk0", "poly", 37, dict(ell=(1.0, 0.85, 0.7), extra=6, jit=0.45, lo=0.72), 4),
    ("chunk1", "poly", 59, dict(ell=(1.0, 0.7, 0.8), extra=8, jit=0.5, lo=0.68), 4),
    ("slab0", "poly", 41, dict(ell=(1.0, 0.8, 0.16), extra=4, jit=0.10, lo=0.80), 4),
    ("slab1", "poly", 43, dict(ell=(1.0, 0.65, 0.26), extra=5, jit=0.16, lo=0.78), 4),
    ("wedge0", "wedge", 47, dict(ell=(1.0, 0.6, 0.5), extra=7), 4),
    ("tooth0", "poly", 67, dict(ell=(0.55, 0.45, 1.0), extra=5, jit=0.22, lo=0.8), 4),
    ("comb0", "comb", 71, dict(ell=(1.0, 0.30, 0.26)), 4),
    ("comb1", "comb", 73, dict(ell=(1.0, 0.38, 0.34)), 4),
    ("pebble0", "pebble", 83, dict(ell=(1.0, 0.75, 0.55), n=10), 0),
    ("chip0", "poly", 97, dict(ell=(1.0, 0.7, 0.5), extra=2, jit=0.5, lo=0.7), 3),
    ("flake0", "poly", 101, dict(ell=(1.0, 0.75, 0.2), extra=1, jit=0.14, lo=0.8), 3),
    ("wedge1", "wedge", 103, dict(ell=(1.0, 0.65, 0.5), extra=2), 3),
]
EMBED = 0.15


def _unit(rnd: random.Random, zlo: float = -0.4) -> Vector:
    z = rnd.uniform(zlo, 0.95)
    a = rnd.uniform(0.0, 2.0 * math.pi)
    r = math.sqrt(max(0.0, 1.0 - z * z))
    return Vector((r * math.cos(a), r * math.sin(a), z)).normalized()


def _jit(rnd: random.Random, n: Vector, j: float) -> Vector:
    return (n + Vector((rnd.uniform(-j, j), rnd.uniform(-j, j), rnd.uniform(-j, j)))).normalized()


def _support(ell, n: Vector) -> float:
    return math.sqrt((ell[0] * n.x) ** 2 + (ell[1] * n.y) ** 2 + (ell[2] * n.z) ** 2)


def poly_planes(kind: str, seed: int, p: dict):
    """Плоскости (нормаль, расстояние от центра): (main, extra) — главные и мелкие сколы по порядку."""
    rnd = random.Random(seed)
    ell = p["ell"]
    main, extra = [], []
    if kind == "poly":
        for ax in (Vector((1, 0, 0)), Vector((-1, 0, 0)), Vector((0, 1, 0)), Vector((0, -1, 0)),
                   Vector((0, 0, 1)), Vector((0, 0, -1))):
            n = _jit(rnd, ax, p["jit"])
            main.append((n, _support(ell, n) * rnd.uniform(0.9, 1.0)))
        for _ in range(p["extra"]):
            n = _unit(rnd)
            extra.append((n, _support(ell, n) * rnd.uniform(p["lo"], 0.95)))
    elif kind == "wedge":
        h = ell[2]
        a = rnd.uniform(0.9, 1.2)
        main.append((Vector((0, 0, -1)), 0.35 * h))
        for sgn in (1, -1):
            n = _jit(rnd, Vector((0, sgn * math.sin(a), math.cos(a))), 0.06)
            main.append((n, 0.55 * h))
            n = _jit(rnd, Vector((sgn * 1.0, 0, 0.3 * rnd.uniform(-1, 1))), 0.12)
            main.append((n, ell[0] * rnd.uniform(0.85, 1.0)))
        for _ in range(p.get("extra", 5)):
            n = _unit(rnd)
            extra.append((n, _support(ell, n) * rnd.uniform(0.75, 0.9)))
    else:  # comb: вытянутый гребень — плоское основание, склоны, скошенные торцы, сколы по хребту
        h = ell[2]
        main.append((Vector((0, 0, -1)), 0.3 * h))
        for sgn in (1, -1):
            n = _jit(rnd, Vector((0, sgn * 0.8, 0.6)), 0.12)
            main.append((n, ell[1] * 0.62 + 0.25 * h))
            n = _jit(rnd, Vector((sgn * 0.9, rnd.uniform(-0.3, 0.3), 0.45)), 0.1)
            main.append((n, ell[0] * rnd.uniform(0.78, 0.95)))
        for sgn in (1, -1):
            n = _jit(rnd, Vector((0, sgn * 1.0, 0.0)), 0.1)
            extra.append((n, ell[1] * rnd.uniform(0.9, 1.0)))
        for _ in range(p.get("extra", 5)):
            n = _unit(rnd, 0.2)
            extra.append((n, _support(ell, n) * rnd.uniform(0.7, 0.9)))
    return main, extra


def hull_points(planes):
    """Вершины пересечения троек плоскостей, лежащие внутри всех остальных."""
    pts = []
    for (n1, d1), (n2, d2), (n3, d3) in itertools.combinations(planes, 3):
        m = Matrix((n1, n2, n3))
        if abs(m.determinant()) < 1e-6:
            continue
        x = m.inverted() @ Vector((d1, d2, d3))
        if all(n.dot(x) <= d + 1e-5 for n, d in planes):
            pts.append(x)
    return pts


def hull_mesh(name: str, pts, smooth: bool) -> bpy.types.Object:
    bm = bmesh.new()
    vs = [bm.verts.new(p) for p in pts]
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bmesh.ops.convex_hull(bm, input=bm.verts[:])
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(0.5), verts=bm.verts[:], edges=bm.edges[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    del vs
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for poly in me.polygons:
        poly.use_smooth = smooth
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def tris(planes) -> int:
    pts = hull_points(planes)
    bm = bmesh.new()
    for p in pts:
        bm.verts.new(p)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bmesh.ops.convex_hull(bm, input=bm.verts[:])
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(0.5), verts=bm.verts[:], edges=bm.edges[:])
    n = sum(len(f.verts) - 2 for f in bm.faces)
    bm.free()
    return n


def lod_planes(main, extra):
    """LOD0 — все плоскости; LOD2 — главные + сколы до 12 треугольников; LOD1 — между."""
    t0 = tris(main + extra)
    if t0 <= 20:
        return [main + extra] * 3
    k2 = 0
    while tris(main + extra[:k2]) < 12 and k2 < len(extra):
        k2 += 1
    t2 = tris(main + extra[:k2])
    k1 = k2
    while tris(main + extra[:k1]) < 0.5 * (t0 + t2) and k1 < len(extra):
        k1 += 1
    return [main + extra, main + extra[:k1], main + extra[:k2]]


def blob_points(seed: int, p: dict, subdiv: int):
    rnd = random.Random(seed ^ 0x5A5A)
    off = Vector((rnd.uniform(0, 100), rnd.uniform(0, 100), rnd.uniform(0, 100)))
    planes = [(_unit(rnd, -0.2), 1.0 - rnd.uniform(0.5, 1.0) * p["depth"] * 2.0) for _ in range(p["cuts"])]
    ell, amp, freq = p["ell"], p["amp"], p["freq"]

    def fb(d: Vector) -> Vector:
        n1 = noise.noise(d * freq + off)
        n2 = noise.noise(d * freq * 3.1 + off * 1.7)
        q = d * (1.0 + amp * n1 + amp * 0.35 * n2)
        for n, k in planes:
            s = q.dot(n)
            if s > k:
                q = q - n * (s - k) * 0.95
        q = Vector((q.x * ell[0], q.y * ell[1], q.z * ell[2]))
        if q.z < -0.35 * ell[2]:
            zb = -0.35 * ell[2]
            q.z = zb + (q.z - zb) * 0.25
        return q

    return fb


def build_blob(name: str, subdiv: int, f) -> bpy.types.Object:
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0, calc_uvs=False)
    for v in bm.verts:
        v.co = f(v.co.normalized())
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def pebble_object(name: str, seed: int, p: dict) -> bpy.types.Object:
    """Окатыш: выпуклая оболочка ~10 точек на эллипсоиде (16 треугольников), гладкое затенение."""
    rnd = random.Random(seed)
    ell = p["ell"]
    pts = []
    for _ in range(p["n"]):
        d = _unit(rnd, -0.3)
        pts.append(Vector((d.x * ell[0], d.y * ell[1], d.z * ell[2])) * rnd.uniform(0.85, 1.0))
    return hull_mesh(name, pts, True)


def normalize(obs, mat, smooth: bool) -> None:
    """Каждый LOD отдельно: наибольший гориз. размер 1 м, высота как у LOD0, низ на −EMBED·высоты."""
    h0 = None
    for ob in obs:
        vs = ob.data.vertices
        xs = [v.co.x for v in vs]
        ys = [v.co.y for v in vs]
        zs = [v.co.z for v in vs]
        s = 1.0 / max(max(xs) - min(xs), max(ys) - min(ys))
        cx = 0.5 * (max(xs) + min(xs))
        cy = 0.5 * (max(ys) + min(ys))
        sz = s
        if h0 is None:
            h0 = (max(zs) - min(zs)) * s
        else:
            sz = h0 / (max(zs) - min(zs))
        z0 = min(zs)
        for v in vs:
            v.co = Vector(((v.co.x - cx) * s, (v.co.y - cy) * s, (v.co.z - z0) * sz - EMBED * h0))
        ob.data.materials.append(mat)
        ob.data.update()
        if smooth:
            bpy.context.view_layer.objects.active = ob
            for o in bpy.context.selected_objects:
                o.select_set(False)
            ob.select_set(True)
            bpy.ops.object.shade_smooth_by_angle(angle=math.radians(35.0))


def main() -> None:
    U.reset_scene()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    mat = U.material("rock", (0.36, 0.34, 0.31), rough=0.9)
    for name, kind, seed, prm, sub in VARIANTS:
        names = ["%s_LOD%d" % (name, lod) for lod in range(3)]
        if kind == "blob":
            f = blob_points(seed, prm, sub)
            obs = [build_blob(names[lod], max(sub - lod, 1), f) for lod in range(3)]
            smooth = True
        elif kind == "pebble":
            ob = pebble_object(names[0], seed, prm)
            obs = [ob] + [ob.copy() for _ in range(2)]
            for i in (1, 2):
                obs[i].data = ob.data.copy()
                obs[i].name = names[i]
                bpy.context.scene.collection.objects.link(obs[i])
            smooth = False
        else:
            main_p, extra_p = poly_planes(kind, seed, prm)
            obs = [hull_mesh(names[lod], hull_points(pl), False)
                   for lod, pl in enumerate(lod_planes(main_p, extra_p))]
            smooth = False
        normalize(obs, mat, smooth)
        print("ROCK %s: tris %s" % (name, [U.tri_count([o.name]) for o in obs]))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "rocks.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "rocks.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)
    print("EXPORTED rocks: %d tris" % U.tri_count())


main()
