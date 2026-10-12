"""Камни и глыбы для разброса у земли: assets/models/rocks/rocks.glb (+ assets/source/rocks/rocks.blend).

    blender --background --python tools/blender/build_rocks.py

Варианты (VARIANTS): 9 крупных (boulder0 — окатанный валун, chunk0/1 — угловатые глыбы, slab0/1 —
плиты со сколами, wedge0 — клин, tooth0 — стоячий зуб, comb0/1 — вытянутые «гребешки» коренной
породы) и 4 мелких (pebble0 — окатыш, chip0 — скол, flake0 — плоский обломок, wedge1 — клин).
У каждого три меша-ноды <имя>_LOD0 / _LOD1 / _LOD2 — одна форма на икосферах sub / sub-1 / sub-2
(крупные 1280 / 320 / 80 треугольников; мелкие 320 / 80 / 20).
Форма "poly" — выпуклый многогранник из плоскостей (плоские грани, острые рёбра: луч из центра
до ближайшей плоскости) + слабый шум; "blob" — эллипсоид × срезы × шум (только окатанные).
Размер нормирован: наибольший горизонтальный размер 1 м (у гребешков — вдоль X, масштаб по осям
задаёт rock_scatter.gd), низ на −0,15·высоты (камень «врос»), вверх +Y (Godot).
UV — развёртка икосферы (цвет берётся трипланарно в rock_scatter.gdshader, UV — про запас).
Масштаб, поворот и оттенок экземпляра задаёт scripts/terrain/rock_scatter.gd.
"""
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector, noise

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

OUT = os.path.join(U.MODELS, "rocks")
SRC = os.path.join(U.SOURCE, "rocks")

# имя, вид, сид, параметры, подразбиения LOD0
# blob: ell, срезов, глубина срезов, шум, частота; poly: полуоси, доп. плоскостей, разброс наклона
VARIANTS = [
    ("boulder0", "blob", 11, dict(ell=(1.0, 0.85, 0.7), cuts=4, depth=0.22, amp=0.07, freq=1.6), 4),
    ("chunk0", "poly", 37, dict(ell=(1.0, 0.85, 0.7), extra=6, jit=0.45, lo=0.72), 4),
    ("chunk1", "poly", 59, dict(ell=(1.0, 0.7, 0.8), extra=8, jit=0.5, lo=0.68), 4),
    ("slab0", "poly", 41, dict(ell=(1.0, 0.8, 0.16), extra=4, jit=0.10, lo=0.80), 4),
    ("slab1", "poly", 43, dict(ell=(1.0, 0.65, 0.26), extra=5, jit=0.16, lo=0.78), 4),
    ("wedge0", "wedge", 47, dict(ell=(1.0, 0.6, 0.5)), 4),
    ("tooth0", "poly", 67, dict(ell=(0.55, 0.45, 1.0), extra=5, jit=0.22, lo=0.8), 4),
    ("comb0", "comb", 71, dict(ell=(1.0, 0.30, 0.26)), 4),
    ("comb1", "comb", 73, dict(ell=(1.0, 0.38, 0.34)), 4),
    ("pebble0", "blob", 83, dict(ell=(1.0, 0.75, 0.55), cuts=3, depth=0.2, amp=0.08, freq=2.0), 3),
    ("chip0", "poly", 97, dict(ell=(1.0, 0.7, 0.5), extra=5, jit=0.5, lo=0.7), 3),
    ("flake0", "poly", 101, dict(ell=(1.0, 0.75, 0.2), extra=3, jit=0.14, lo=0.8), 3),
    ("wedge1", "wedge", 103, dict(ell=(1.0, 0.65, 0.5)), 3),
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
    """Плоскости (нормаль, расстояние от центра) в итоговых осях."""
    rnd = random.Random(seed)
    ell = p["ell"]
    pl = []
    if kind == "poly":
        for ax in (Vector((1, 0, 0)), Vector((-1, 0, 0)), Vector((0, 1, 0)), Vector((0, -1, 0)),
                   Vector((0, 0, 1)), Vector((0, 0, -1))):
            n = _jit(rnd, ax, p["jit"])
            pl.append((n, _support(ell, n) * rnd.uniform(0.9, 1.0)))
        for _ in range(p["extra"]):
            n = _unit(rnd)
            pl.append((n, _support(ell, n) * rnd.uniform(p["lo"], 0.95)))
    elif kind == "wedge":
        h = ell[2]
        a = rnd.uniform(0.9, 1.2)
        pl.append((Vector((0, 0, -1)), 0.35 * h))
        for sgn in (1, -1):
            n = _jit(rnd, Vector((0, sgn * math.sin(a), math.cos(a))), 0.06)
            pl.append((n, 0.55 * h))
            n = _jit(rnd, Vector((sgn * 1.0, 0, 0.3 * rnd.uniform(-1, 1))), 0.12)
            pl.append((n, ell[0] * rnd.uniform(0.85, 1.0)))
        for _ in range(2):
            n = _unit(rnd)
            pl.append((n, _support(ell, n) * rnd.uniform(0.75, 0.9)))
    else:  # comb: вытянутый гребень — плоское основание, два наклонных склона, скошенные торцы
        h = ell[2]
        pl.append((Vector((0, 0, -1)), 0.3 * h))
        for sgn in (1, -1):
            n = _jit(rnd, Vector((0, sgn * 0.8, 0.6)), 0.12)
            pl.append((n, ell[1] * 0.62 + 0.25 * h))
            n = _jit(rnd, Vector((0, sgn * 1.0, 0.0)), 0.1)
            pl.append((n, ell[1] * rnd.uniform(0.9, 1.0)))
            n = _jit(rnd, Vector((sgn * 0.9, rnd.uniform(-0.3, 0.3), 0.45)), 0.1)
            pl.append((n, ell[0] * rnd.uniform(0.78, 0.95)))
        for _ in range(3):  # сколы по хребту
            n = _unit(rnd, 0.2)
            pl.append((n, _support(ell, n) * rnd.uniform(0.7, 0.9)))
    return pl


def make_shape(kind: str, seed: int, p: dict):
    """Функция формы: единичное направление → точка поверхности (одинакова для всех LOD)."""
    rnd = random.Random(seed ^ 0x5A5A)
    off = Vector((rnd.uniform(0, 100), rnd.uniform(0, 100), rnd.uniform(0, 100)))
    if kind == "blob":
        planes = []
        for _ in range(p["cuts"]):
            planes.append((_unit(rnd, -0.2), 1.0 - rnd.uniform(0.5, 1.0) * p["depth"] * 2.0))
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

    pl = poly_planes(kind, seed, p)

    def fp(d: Vector) -> Vector:
        t = 1e9
        for n, k in pl:
            c = n.dot(d)
            if c > 1e-5:
                t = min(t, k / c)
        # слабая шероховатость: крупная неровность граней + мелкая зернистость
        r = 1.0 + 0.035 * noise.noise(d * 2.3 + off) + 0.012 * noise.noise(d * 8.0 + off * 1.3)
        return d * (t * r)

    return fp


def build_mesh(name: str, subdiv: int, f) -> bpy.types.Object:
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0, calc_uvs=True)
    for v in bm.verts:
        v.co = f(v.co.normalized())
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    del uv
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def normalize(obs, mat) -> None:
    """Общий масштаб/сдвиг для всех LOD: макс. гориз. размер 1 м, низ на −EMBED·высоты."""
    ref = obs[0].data.vertices
    xs = [v.co.x for v in ref]
    ys = [v.co.y for v in ref]
    zs = [v.co.z for v in ref]
    s = 1.0 / max(max(xs) - min(xs), max(ys) - min(ys))
    cx = 0.5 * (max(xs) + min(xs))
    cy = 0.5 * (max(ys) + min(ys))
    h = (max(zs) - min(zs)) * s
    z0 = min(zs)
    for ob in obs:
        for v in ob.data.vertices:
            v.co = Vector(((v.co.x - cx) * s, (v.co.y - cy) * s, (v.co.z - z0) * s - EMBED * h))
        ob.data.materials.append(mat)
        ob.data.update()
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
        f = make_shape(kind, seed, prm)
        obs = [build_mesh("%s_LOD%d" % (name, lod), max(sub - lod, 1), f) for lod in range(3)]
        normalize(obs, mat)
        print("ROCK %s: LOD0 %d tris" % (name, U.tri_count([obs[0].name])))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "rocks.blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "rocks.glb"), export_format="GLB",
                              export_yup=True, use_selection=False, export_apply=True,
                              export_extras=False, export_vertex_color="NONE",
                              export_cameras=False, export_lights=False)
    print("EXPORTED rocks: %d tris" % U.tri_count())


main()
