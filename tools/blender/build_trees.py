"""Деревья Алтая: assets/models/trees/tree_<вид>.glb (+ assets/source/trees/*.blend).

    xvfb-run -a blender --background --python tools/blender/build_trees.py [-- pine birch ...]

Виды и параметры — tools/blender/tree_params.json: pine (сосна), cedar (кедр), larch
(лиственница), birch (берёза), spruce (ель). В каждом .glb три меша-ноды:
  LOD0 — ствол, ветви, карточки хвои/листвы с альфой (≤ ~2k треугольников), вблизи;
  LOD1 — ствол + ~10 % укрупнённых карточек (~150 треугольников), средняя дальность;
  LOD2 — импостор: две скрещённые плоскости с запечённой в Blender картинкой (4 треугольника).
Начало координат — основание ствола, вверх +Y (Godot), высота — реальная (height_m), 1 ед. = 1 м.
Ещё пишутся картинки-импосторы assets/models/trees/tree_<вид>_impostor.png и общий атлас
trees_impostor_atlas.png (ячейки 256×512: pine, cedar, larch, birch / spruce) — для шейдера
дальних деревьев. Нужен xvfb-run (Eevee запекает импостор).
"""
import math
import os
import random
import sys

import bpy
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import tree_textures as TT  # noqa: E402

OUT = os.path.join(U.MODELS, "trees")
SRC = os.path.join(U.SOURCE, "trees")
ORDER = ["pine", "cedar", "larch", "birch", "spruce"]


def crown_radius(sp: dict, zc: float) -> float:
    """Радиус кроны (доля высоты) на относительной высоте кроны zc ∈ [0, 1]."""
    r = sp["crown_radius"]
    shape = sp["crown"]
    if shape == "cone":
        return r * (1 - zc) ** 0.95 + 0.004
    if shape == "ovoid":
        return r * math.sin(math.pi * (0.12 + 0.85 * zc)) ** 0.6 * (1 - 0.25 * zc)
    if shape == "umbrella":
        return r * math.sin(math.pi * (0.25 + 0.72 * zc)) ** 0.5
    return r * math.sin(math.pi * min(zc * 0.95 + 0.05, 1.0)) ** 0.7  # birch


def trunk_path(sp: dict, rng: random.Random) -> list:
    h = sp["height_m"] * sp["trunk_top"]
    lean = sp["lean"] * sp["height_m"]
    ph = rng.uniform(0, 6.28)
    pts = []
    for i in range(11):
        t = i / 10
        pts.append(Vector((lean * t * t + 0.02 * h * math.sin(ph + 5 * t) * t,
                           0.01 * h * math.cos(ph + 4 * t) * t, h * t)))
    return pts


def trunk_radius(sp: dict, t: float) -> float:
    r0 = sp["trunk_radius_m"]
    return r0 * (1 - 0.88 * t) * (1 + 0.35 * max(0.0, 0.08 - t) / 0.08)


def card(mb: U.MeshBuilder, base: Vector, d: Vector, n: Vector, size: float) -> None:
    """Карточка: низ (v = 0) у ветки, вдоль d; нормаль n."""
    side = d.cross(n).normalized() * size * 0.5
    tip = base + d * size
    q = [base - side, base + side, tip + side, tip - side]
    idx = [mb.add_vert(p) for p in q]
    mb.add_face(idx, "Leaf", uv=[(0, 0), (1, 0), (1, 1), (0, 1)], smooth=False)


def clump(mb: U.MeshBuilder, p: Vector, d: Vector, size: float, rng: random.Random,
          hanging: bool) -> None:
    """Пучок из двух скрещённых карточек: одна «лежит» (видна сверху), вторая стоит."""
    d = d.normalized()
    if hanging:
        d = (d * 0.5 + Vector((0, 0, -1))).normalized()
    up = Vector((0, 0, 1))
    n1 = (up - d * d.dot(up))
    n1 = n1.normalized() if n1.length > 1e-3 else Vector((1, 0, 0))
    rot = Matrix.Rotation(rng.uniform(-0.5, 0.5), 3, d)
    n1 = rot @ n1
    n2 = d.cross(n1).normalized()
    base = p - d * size * 0.15
    card(mb, base, d, n1, size)
    card(mb, base, d, n2, size)


def build_mesh(sp: dict, lod: int, seed: int, lod_cfg: dict) -> U.MeshBuilder:
    rng = random.Random(seed)
    mb = U.MeshBuilder()
    H = sp["height_m"]
    path = trunk_path(sp, rng)
    ts = [i / (len(path) - 1) for i in range(len(path))]
    sides = 8 if lod == 0 else 5
    if lod == 1:
        path, ts = path[::3], ts[::3]
    mb.add_tube(path, [trunk_radius(sp, t) for t in ts], "Bark", sides=sides,
                uv_v=[t * sp["trunk_top"] for t in ts])
    clumps = []
    top_z = H * sp["trunk_top"]
    cb = sp["crown_base"] * H
    n_wh = sp["whorls"]
    hanging = sp["droop"] > 0.3
    for k in range(n_wh):
        zc = (k + rng.uniform(-0.3, 0.3)) / max(n_wh - 1, 1)
        zc = min(max(zc, 0.0), 1.0)
        z = cb + (top_z * 0.97 - cb) * zc
        tz = z / top_z
        center = path[0].lerp(path[-1], tz) if lod == 1 else _on_path(path, tz)
        R = crown_radius(sp, zc) * H
        for j in range(sp["per_whorl"]):
            az = 2 * math.pi * (j + rng.uniform(-0.3, 0.3)) / sp["per_whorl"] + k * 2.4
            L = R * rng.uniform(0.8, 1.1)
            el = math.radians(sp["branch_angle_deg"] + rng.uniform(-10, 10))
            d = Vector((math.cos(az) * math.cos(el), math.sin(az) * math.cos(el), math.sin(el)))
            end = center + d * L - Vector((0, 0, sp["droop"] * L))
            mid = center + d * L * 0.5 - Vector((0, 0, sp["droop"] * L * 0.2))
            if lod == 0 and L > 0.3:
                br = max(trunk_radius(sp, tz) * 0.35, 0.012)
                if sp["droop"] >= 0.2:  # изогнутая ветвь
                    mb.add_tube([center, mid, end], [br, br * 0.6, br * 0.25], "Bark", sides=3,
                                cap=False, uv_v=[0.3, 0.32, 0.34])
                else:
                    mb.add_tube([center, end], [br, br * 0.25], "Bark", sides=3, cap=False,
                                uv_v=[0.3, 0.34])
            for c in range(sp["clumps_per_branch"]):
                t = 0.35 + 0.65 * (c + 1) / sp["clumps_per_branch"]
                p = (center.lerp(mid, t * 2) if t < 0.5 else mid.lerp(end, t * 2 - 1))
                p += Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.5, 0.5))) \
                    * 0.06 * L
                dd = (end - center).normalized() if (end - center).length > 1e-3 else d
                size = sp["clump_size"] * H * rng.uniform(0.75, 1.25) * (0.55 + 0.45 * R / (
                    sp["crown_radius"] * H))
                clumps.append((p, dd, size))
    # вершина: у хвойных — пучки вдоль верхушки ствола
    if sp["crown"] in ("cone", "ovoid", "umbrella"):
        for i in range(3):
            z = top_z * (0.93 + 0.025 * i)
            clumps.append((_on_path(path, z / top_z), Vector((rng.uniform(-.2, .2), rng.uniform(
                -.2, .2), 1)), sp["clump_size"] * H * 0.7))
    if lod == 1:
        rng.shuffle(clumps)
        keep = max(8, int(len(clumps) * lod_cfg["lod1_clump_fraction"]))
        clumps = [(p, d, s * lod_cfg["lod1_clump_scale"]) for p, d, s in clumps[:keep]]
    for p, d, s in clumps:
        clump(mb, p, d, s, rng, hanging)
    return mb


def _on_path(path: list, t: float) -> Vector:
    f = min(max(t, 0.0), 1.0) * (len(path) - 1)
    i = min(int(f), len(path) - 2)
    return path[i].lerp(path[i + 1], f - i)


def bake_impostor(obj, sp: dict, px: tuple, path: str):
    """Ортокамера сбоку, прозрачный фон, Eevee. Возвращает (картинка, ширина, высота) в м."""
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = px
    sc.render.film_transparent = True
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.dither_intensity = 0.0
    sc.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.6, 0.65, 0.7, 1)
    sc.world = world
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(50), 0, math.radians(20))
    sc.collection.objects.link(sun)
    bb = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    height = max(p.z for p in bb)
    half_w = max(max(abs(p.x) for p in bb), max(abs(p.y) for p in bb))
    scale = max(height * 1.02, 2 * half_w * 1.04 * px[1] / px[0])
    width = scale * px[0] / px[1]
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = scale
    sc.collection.objects.link(cam)
    cam.matrix_world = Matrix.Translation((0, -50, scale / 2)) @ Matrix.Rotation(
        math.radians(90), 4, "X")
    sc.camera = cam
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    for o in (sun, cam):
        bpy.data.objects.remove(o)
    sc.render.film_transparent = False
    img = bpy.data.images.load(path)
    img.pack()
    return img, width, scale


def impostor_mesh(width: float, height: float) -> U.MeshBuilder:
    mb = U.MeshBuilder()
    w = width / 2
    for a, b in ((Vector((-w, 0, 0)), Vector((w, 0, 0))), (Vector((0, w, 0)), Vector((0, -w, 0)))):
        q = [a, b, b + Vector((0, 0, height)), a + Vector((0, 0, height))]
        idx = [mb.add_vert(p) for p in q]
        mb.add_face(idx, "Impostor", uv=[(0, 0), (1, 0), (1, 1), (0, 1)], smooth=False)
    return mb


def build(key: str, params: dict) -> None:
    sp = params["species"][key]
    lod_cfg = params["lod"]
    U.reset_scene()
    seed = ORDER.index(key) * 101 + 7
    leaf = TT.foliage(sp["leaf"], sp["leaf_color"], sp["leaf_color2"], seed)
    bark = TT.bark(sp["bark"], sp["bark_color"], sp["bark_color_low"], seed)
    leaf_img = U.image_from_array("leaf_" + key, leaf, os.path.join(SRC, key + "_leaf.png"))
    bark_img = U.image_from_array("bark_" + key, bark, os.path.join(SRC, key + "_bark.png"))
    mats = {
        "Bark": U.material("Bark_" + key, (1, 1, 1), rough=0.9, image=bark_img),
        "Leaf": U.material("Leaf_" + key, (1, 1, 1), rough=0.8, double=True, image=leaf_img,
                           alpha_clip=True),
    }
    lod0 = build_mesh(sp, 0, seed, lod_cfg).build("LOD0", mats)
    lod1 = build_mesh(sp, 1, seed, lod_cfg).build("LOD1", mats)
    lod1.hide_render = True
    imp_path = os.path.join(OUT, "tree_%s_impostor.png" % key)
    img, w, h = bake_impostor(lod0, sp, tuple(lod_cfg["impostor_px"]), imp_path)
    lod1.hide_render = False
    mats["Impostor"] = U.material("Impostor_" + key, (1, 1, 1), rough=0.9, double=True,
                                  image=img, alpha_clip=True)
    impostor_mesh(w, h).build("LOD2", mats)
    lod1.location.x = 0  # все LOD в одной точке; видимость переключает игра
    tris = {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons)
            for o in bpy.context.scene.objects if o.type == "MESH"}
    print("TREE %s: %s" % (key, tris))
    os.makedirs(SRC, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "tree_%s.blend" % key),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "tree_%s.glb" % key),
                              export_format="GLB", export_yup=True, export_apply=True,
                              export_cameras=False, export_lights=False)


def atlas(keys: list, px: tuple) -> None:
    """Общий атлас импосторов 1024×1024: 4 ячейки 256×512 в ряд, два ряда."""
    cw, ch = px
    out = np.zeros((1024, 1024, 4), dtype=np.float32)
    for i, key in enumerate(keys):
        img = bpy.data.images.load(os.path.join(OUT, "tree_%s_impostor.png" % key))
        a = np.array(img.pixels[:], dtype=np.float32).reshape(ch, cw, 4)
        col, row = i % 4, 1 - i // 4  # ряд 0 — верхний в картинке
        out[row * ch:(row + 1) * ch, col * cw:(col + 1) * cw] = a
    U.image_from_array("atlas", out, os.path.join(OUT, "trees_impostor_atlas.png"))


def main() -> None:
    params = U.load_json("tools/blender/tree_params.json")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SRC, exist_ok=True)
    for key in argv or ORDER:
        build(key, params)
    if not argv:
        U.reset_scene()
        atlas(ORDER, tuple(params["lod"]["impostor_px"]))


if __name__ == "__main__":
    main()
