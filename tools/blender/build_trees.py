"""Деревья Алтая: assets/models/trees/tree_<вид>.glb (+ assets/source/trees/*.blend).

    xvfb-run -a blender --background --python tools/blender/build_trees.py [-- pine birch ...]

Виды и параметры — tools/blender/tree_params.json: pine (сосна), cedar (кедр), larch
(лиственница), birch (берёза), spruce (ель). В каждом .glb — lod.variants вариантов дерева
(сиды от базового породы; игра выбирает вариант по хешу места), у варианта v три меша-ноды
V{v}_LOD0, V{v}_LOD1, V{v}_LOD2; текстуры коры и хвои/листвы общие на породу:
  LOD0 — ствол, ветви, карточки хвои/листвы с альфой (≤ ~2k треугольников), вблизи;
  LOD1 — тот же каркас (skeleton), упрощённый: ствол 5 граней, без ветвей, пучки каждой ветки
         слиты в 1 крупный (~150–400 треугольников), средняя дальность;
  LOD2 — импостор: две скрещённые плоскости с запечённой в Blender картинкой (4 треугольника).
Начало координат — основание ствола, вверх +Y (Godot), высота — реальная (height_m), 1 ед. = 1 м.
Ещё пишутся картинки-импосторы assets/models/trees/tree_<вид>_v<v>_impostor.png и общий атлас
trees_impostor_atlas.png (вариант 0; ячейки 256×512: pine, cedar, larch, birch / spruce) — для
шейдера дальних деревьев. Нужен xvfb-run (Eevee запекает импостор).
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
BAKE_WORLD = 0.5  # яркость белого неба при запекании импостора
BAKE_SUN = 1.5    # солнце при запекании (светотень кроны)


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


def card(mb: U.MeshBuilder, base: Vector, d: Vector, n: Vector, size: float,
         aspect: float = 1.0) -> None:
    """Карточка: низ (v = 0) у ветки, вдоль d; нормаль n; ширина = size · aspect."""
    side = d.cross(n).normalized() * size * 0.5 * aspect
    tip = base + d * size
    q = [base - side, base + side, tip + side, tip - side]
    idx = [mb.add_vert(p) for p in q]
    for i in idx:  # UV2.x = 1 — метка карточки кроны для tree_model.gdshader (нормали изнанки)
        mb.colors[i] = (1.0, 0.0)
    mb.add_face(idx, "Leaf", uv=[(0, 0), (1, 0), (1, 1), (0, 1)], smooth=True)


def card_dir(d0: Vector, sp: dict) -> Vector:
    """Направление карточек пучка по направлению ветки d0 (свисание / «кисть вверх»)."""
    d0 = d0.normalized()
    if sp["droop"] > 0.3:
        return (d0 * 0.5 + Vector((0, 0, -1))).normalized()
    k = sp.get("clump_up", 0.0)
    return (d0 * (1 - k) + Vector((0, 0, 1)) * k).normalized()


def base_k(sp: dict) -> float:
    """На сколько (доля размера) низ карточки отстоит от точки пучка назад вдоль карточки."""
    return 0.45 if sp.get("clump_up", 0.0) > 0 else 0.15


def clump(mb: U.MeshBuilder, p: Vector, d0: Vector, size: float, rot_a: float,
          sp: dict, cards: int, bk: float) -> None:
    """Пучок скрещённых карточек. d0 — направление ветки. Хвойные с clump_up > 0 (сосна, кедр)
    ставят пучок концом вверх — побеги сосны торчат к небу, а не расходятся веером, как лист
    пальмы; ель и лиственница — лапы вдоль ветки, берёза — свисающие пряди.
    cards = 3 — ещё лежачая карточка (крона плотнее при взгляде сверху, с дельтаплана).
    bk — низ карточки на bk·size позади p (0,5 — карточка по центру на p)."""
    d0 = d0.normalized()
    up = Vector((0, 0, 1))
    h = Vector((-d0.y, d0.x, 0))
    h = h.normalized() if h.length > 1e-3 else Vector((0, 1, 0))
    d = card_dir(d0, sp)
    n1 = d.cross(h).normalized()  # ветка горизонтальна → карточка лежит; торчит вверх → «лицом» наружу
    n1 = Matrix.Rotation(rot_a, 3, d) @ n1
    n2 = d.cross(n1).normalized()
    asp = sp.get("card_aspect", 1.0)
    base = p - d * size * bk
    card(mb, base, d, n1, size, asp)
    card(mb, base, d, n2, size, asp)
    if cards >= 3:
        dh = Vector((d0.x, d0.y, 0))
        dh = dh.normalized() if dh.length > 1e-3 else Vector((1, 0, 0))
        card(mb, p - dh * size * 0.45 + up * size * 0.2, dh, up, size * 0.9, asp)


def skeleton(sp: dict, seed: int) -> dict:
    """Общий каркас LOD0 и LOD1: ствол, ветви мутовок, точки пучков, верхушка — один поток rng.
    Сухие сучья — своим потоком (seed + 1): они есть только в LOD0 и не сдвигают остальное."""
    rng = random.Random(seed)
    H = sp["height_m"]
    path = trunk_path(sp, rng)
    top_z = H * sp["trunk_top"]
    cb = sp["crown_base"] * H
    n_wh = sp["whorls"]
    rise = sp.get("branch_rise", 0.0)
    c0 = sp.get("clump_from", 0.35)
    branches = []
    for k in range(n_wh):
        zc = (k + rng.uniform(-0.3, 0.3)) / max(n_wh - 1, 1)
        zc = min(max(zc, 0.0), 1.0)
        z = cb + (top_z * 0.97 - cb) * zc
        tz = z / top_z
        center = _on_path(path, tz)
        R = crown_radius(sp, zc) * H
        for j in range(sp["per_whorl"]):
            az = 2 * math.pi * (j + rng.uniform(-0.3, 0.3)) / sp["per_whorl"] + k * 2.4
            L = R * rng.uniform(0.8, 1.1)
            el = math.radians(sp["branch_angle_deg"] + rng.uniform(-10, 10))
            d = Vector((math.cos(az) * math.cos(el), math.sin(az) * math.cos(el), math.sin(el)))
            end = center + d * L - Vector((0, 0, (sp["droop"] - rise) * L))
            mid = center + d * L * 0.5 - Vector((0, 0, sp["droop"] * L * 0.2))
            dd = (end - center).normalized() if (end - center).length > 1e-3 else d
            cl = []
            for c in range(sp["clumps_per_branch"]):
                t = c0 + (1 - c0) * (c + 1) / sp["clumps_per_branch"]
                p = (center.lerp(mid, t * 2) if t < 0.5 else mid.lerp(end, t * 2 - 1))
                p += Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.5, 0.5))) \
                    * 0.06 * L
                size = sp["clump_size"] * H * rng.uniform(0.75, 1.25) * (0.55 + 0.45 * R / (
                    sp["crown_radius"] * H))
                cl.append((p, dd, size, rng.uniform(-0.5, 0.5)))
            branches.append({"center": center, "mid": mid, "end": end, "L": L, "tz": tz,
                             "clumps": cl})
    tops = []  # вершина: у хвойных — пучки вдоль верхушки ствола
    if sp["crown"] in ("cone", "ovoid", "umbrella"):
        for i in range(3):
            z = top_z * (0.93 + 0.025 * i)
            tops.append((_on_path(path, z / top_z), Vector((rng.uniform(-.2, .2), rng.uniform(
                -.2, .2), 1)), sp["clump_size"] * H * 0.7, rng.uniform(-0.5, 0.5)))
    srng = random.Random(seed + 1)
    stubs = []  # сухие сучья ниже кроны (сосна, лиственница в лесу): голый ствол не «пальмовый»
    for i in range(sp.get("stubs", 0)):
        tz = srng.uniform(0.12, 0.95) * cb / top_z
        az = srng.uniform(0, 2 * math.pi)
        L = H * srng.uniform(0.03, 0.07)
        el = math.radians(srng.uniform(-25, 10))
        stubs.append((tz, Vector((math.cos(az) * math.cos(el), math.sin(az) * math.cos(el),
                                  math.sin(el))) * L))
    return {"path": path, "branches": branches, "tops": tops, "stubs": stubs}


def merge_clumps(cl: list, sp: dict, groups: int, size_k: float) -> list:
    """LOD1: пучки ветки → groups крупных (по порядку вдоль ветки). Центр — центр масс карточек
    группы (с учётом их смещения вдоль карточки), размер — площадь та же (√Σs²) × size_k."""
    bk = base_k(sp)
    n = len(cl)
    out = []
    for g in range(groups):
        part = cl[g * n // groups:(g + 1) * n // groups]
        if not part:
            continue
        m = Vector((0, 0, 0))
        dsum = Vector((0, 0, 0))
        for p, dd, s, _ in part:
            m += p + card_dir(dd, sp) * s * (0.5 - bk)
            dsum += dd
        m /= len(part)
        size = math.sqrt(sum(s * s for _, _, s, _ in part)) * size_k
        out.append((m, dsum.normalized(), size, part[0][3]))
    return out


def build_mesh(sp: dict, lod: int, sk: dict, lod_cfg: dict) -> U.MeshBuilder:
    """LOD0 — каркас целиком; LOD1 — тот же каркас упрощённо: ствол 5 граней, без ветвей и
    сучьев, пучки каждой ветки слиты в lod1_groups крупных, верхушка та же."""
    mb = U.MeshBuilder()
    path = sk["path"]
    ts = [i / (len(path) - 1) for i in range(len(path))]
    if lod == 1:  # 4 узла, включая вершину
        path, ts = [path[i] for i in (0, 3, 6, 10)], [ts[i] for i in (0, 3, 6, 10)]
    mb.add_tube(path, [trunk_radius(sp, t) for t in ts], "Bark", sides=8 if lod == 0 else 5,
                uv_v=[t * sp["trunk_top"] for t in ts])
    bk = base_k(sp)
    if lod == 0:
        full = sk["path"]
        for tz, v in sk["stubs"]:
            c = _on_path(full, tz)
            mb.add_tube([c, c + v], [max(trunk_radius(sp, tz) * 0.25, 0.015), 0.006], "Bark",
                        sides=3, cap=False, uv_v=[0.3, 0.32])
        for b in sk["branches"]:
            if b["L"] > 0.3:
                br = max(trunk_radius(sp, b["tz"]) * 0.35, 0.012)
                if sp["droop"] >= 0.2:  # изогнутая (провисающая) ветвь
                    mb.add_tube([b["center"], b["mid"], b["end"]], [br, br * 0.6, br * 0.25],
                                "Bark", sides=3, cap=False, uv_v=[0.3, 0.32, 0.34])
                else:
                    mb.add_tube([b["center"], b["end"]], [br, br * 0.25], "Bark", sides=3,
                                cap=False, uv_v=[0.3, 0.34])
            for p, dd, s, ra in b["clumps"]:
                clump(mb, p, dd, s, ra, sp, sp.get("cards", 2), bk)
        for p, dd, s, ra in sk["tops"]:
            clump(mb, p, dd, s, ra, sp, 2, bk)
        return mb
    groups = sp.get("lod1_groups", lod_cfg["lod1_groups"])
    size_k = sp.get("lod1_size_k", lod_cfg["lod1_size_k"])
    for b in sk["branches"]:
        for p, dd, s, ra in merge_clumps(b["clumps"], sp, groups, size_k):
            clump(mb, p, dd, s, ra, sp, 2, 0.5)
    for p, dd, s, ra in sk["tops"]:
        clump(mb, p, dd, s, ra, sp, 2, bk)
    return mb


def crown_normals(obj, sp: dict) -> None:
    """Нормали карточек — от центра кроны наружу (+ немного вверх), а не плоские: крона
    освещается как объём, без «перьев», где каждая карточка то светлая, то чёрная."""
    me = obj.data
    H = sp["height_m"]
    cb, top = sp["crown_base"] * H, sp["trunk_top"] * H
    cz, hh = (cb + top) * 0.5, max((top - cb) * 0.5, 1.0)
    R = max(sp["crown_radius"] * H, 0.5)
    leaf = [i for i, m in enumerate(me.materials) if m and m.name.startswith("Leaf")]
    me.update()
    cur = [Vector(n.vector) for n in me.corner_normals]
    out = []
    for poly in me.polygons:
        for li in range(poly.loop_start, poly.loop_start + poly.loop_total):
            if poly.material_index not in leaf:
                out.append(cur[li])
                continue
            v = me.vertices[me.loops[li].vertex_index].co
            o = Vector((v.x / R, v.y / R, (v.z - cz) / hh))
            o = o.normalized() if o.length > 1e-3 else Vector((0, 0, 1))
            fn = Vector(poly.normal)
            if fn.dot(o) < 0:
                fn = -fn
            out.append((o * 0.6 + fn * 0.4 + Vector((0, 0, 0.1))).normalized())
    me.normals_split_custom_set(out)


def _backface_fix(mat, on: bool) -> None:
    """Для запекания импостора: Eevee переворачивает нормаль у изнанки карточки; с нормалями
    кроны (crown_normals) изнанка должна светиться так же — как в игре (tree_model.gdshader)."""
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    # без блика: белое небо запекания иначе «серит» хвою (в игре SPECULAR = 0.2 при шероховатой хвое)
    bsdf.inputs["Specular IOR Level"].default_value = 0.0 if on else 0.5
    if not on:
        for n in [n for n in nt.nodes if n.name.startswith("BF_")]:
            nt.nodes.remove(n)
        return
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    geo.name = "BF_geo"
    neg = nt.nodes.new("ShaderNodeVectorMath")
    neg.name = "BF_neg"
    neg.operation = "SCALE"
    neg.inputs["Scale"].default_value = -1.0
    mix = nt.nodes.new("ShaderNodeMix")
    mix.name = "BF_mix"
    mix.data_type = "VECTOR"
    nt.links.new(geo.outputs["Normal"], neg.inputs[0])
    nt.links.new(geo.outputs["Backfacing"], mix.inputs["Factor"])
    nt.links.new(geo.outputs["Normal"], mix.inputs[4])
    nt.links.new(neg.outputs["Vector"], mix.inputs[5])
    nt.links.new(mix.outputs[1], bsdf.inputs["Normal"])


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
    # свет запекания — нейтральный и неяркий: картинка ≈ альбедо кроны с мягкой светотенью;
    # освещает её уже игра (нормали импостора вверх, как у кроны моделей), иначе импостор
    # «освещён дважды» — светлее и серее моделей на смене LOD
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = BAKE_WORLD
    sc.world = world
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = BAKE_SUN
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
        for i in idx:  # как у карточек кроны: нормаль своя, изнанку не переворачивать
            mb.colors[i] = (1.0, 0.0)
        mb.add_face(idx, "Impostor", uv=[(0, 0), (1, 0), (1, 1), (0, 1)], smooth=True)
    return mb


def impostor_normals(obj) -> None:
    """Нормали креста-импостора — почти вверх (как у билбордов forest_impostors.gdshader и у
    кроны моделей), а не горизонтальные: иначе импостор вдвое темнее модели и на смене LOD
    заметна тёмная полоса леса."""
    me = obj.data
    me.update()
    out = []
    for poly in me.polygons:
        fn = Vector(poly.normal)
        for _ in range(poly.loop_total):
            out.append((Vector((0, 0, 1)) * 0.8 + fn * 0.2).normalized())
    me.normals_split_custom_set(out)


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
    n_var = int(params["lod"].get("variants", 8))
    tris = {}
    for v in range(n_var):
        _variant(key, sp, lod_cfg, mats, seed + 1009 * v, v, tris)
    print("TREE %s: %s" % (key, tris))
    os.makedirs(SRC, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SRC, "tree_%s.blend" % key),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "tree_%s.glb" % key),
                              export_format="GLB", export_yup=True, export_apply=True,
                              export_cameras=False, export_lights=False)


def _variant(key: str, sp: dict, lod_cfg: dict, mats: dict, seed: int, v: int,
             tris: dict) -> None:
    """Вариант v породы: V{v}_LOD0, V{v}_LOD1 из одного каркаса, V{v}_LOD2 — импостор,
    запечённый с V{v}_LOD0 (картинка tree_<вид>_v<v>_impostor.png). Все LOD в начале координат."""
    sk = skeleton(sp, seed)
    pre = "V%d_" % v
    lod0 = build_mesh(sp, 0, sk, lod_cfg).build(pre + "LOD0", mats)
    lod1 = build_mesh(sp, 1, sk, lod_cfg).build(pre + "LOD1", mats)
    crown_normals(lod0, sp)
    crown_normals(lod1, sp)
    hidden = [o for o in bpy.context.scene.objects if o.type == "MESH" and o != lod0]
    for o in hidden:
        o.hide_render = True
    _backface_fix(mats["Leaf"], True)
    mats["Bark"].node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.0
    imp_path = os.path.join(OUT, "tree_%s_v%d_impostor.png" % (key, v))
    img, w, h = bake_impostor(lod0, sp, tuple(lod_cfg["impostor_px"]), imp_path)
    for o in hidden:
        o.hide_render = False
    _backface_fix(mats["Leaf"], False)
    mats["Bark"].node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.5
    imats = dict(mats)
    imats["Impostor"] = U.material("Impostor_%s_v%d" % (key, v), (1, 1, 1), rough=0.9,
                                   double=True, image=img, alpha_clip=True)
    lod2 = impostor_mesh(w, h).build(pre + "LOD2", imats)
    impostor_normals(lod2)
    for o in (lod0, lod1, lod2):
        tris[o.name] = sum(len(p.vertices) - 2 for p in o.data.polygons)


def atlas(keys: list, px: tuple) -> None:
    """Общий атлас импосторов 1024×1024: 4 ячейки 256×512 в ряд, два ряда — вариант 0 каждой
    породы (дальние билборды ForestImpostors; от 350 м разница вариантов не видна)."""
    cw, ch = px
    out = np.zeros((1024, 1024, 4), dtype=np.float32)
    for i, key in enumerate(keys):
        img = bpy.data.images.load(os.path.join(OUT, "tree_%s_v0_impostor.png" % key))
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
