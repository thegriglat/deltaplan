"""Скриншоты деревьев: docs/models/screenshots/trees/<вид>.png (LOD0 | LOD1 | LOD2 спереди)
и trees_iso45.png (все виды LOD0 под 45° сверху — как их видит пилот).

    xvfb-run -a blender --background --python tools/blender/render_trees.py [-- out_dir | --species <вид> <каталог>]
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import render_views as RV  # noqa: E402

ORDER = ["pine", "cedar", "larch", "birch", "spruce", "oak", "palm", "tropical"]


def load_tree(key: str, dx: float) -> dict:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, "trees", "tree_%s.glb" % key))
    objs = {o.name.split(".")[0]: o for o in bpy.data.objects if o not in before}
    for o in objs.values():
        if o.parent is None:
            o.location.x += dx
    return objs


def person(x: float, y: float = 0.0) -> None:
    """Масштабная фигурка 1,75 м (капсула + голова) для превью."""
    bpy.ops.mesh.primitive_cylinder_add(radius=0.22, depth=1.45, location=(x, y, 0.725))
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.13, location=(x, y, 1.62))


def variants_of(objs: dict) -> list:
    return sorted({n.split("_")[0] for n in objs if n.startswith("V") and "_LOD" in n})


def main_variants(key: str, out: str) -> None:
    """Породы с вариантами V{v}_LOD*: кадр 1 — все варианты LOD0 в ряд сбоку (+ фигурка 1,75 м),
    кадр 2 — вид сверху под 45° с ~300 м (все LOD0 группой + лес из копий), кадр 3 — LOD0|LOD1|LOD2."""
    U.reset_scene()
    RV.setup_scene()
    objs = load_tree(key, 0)
    vs = variants_of(objs)
    hs = {}
    for v in vs:
        zs = [(objs[v + "_LOD0"].matrix_world @ Vector(c)).z for c in objs[v + "_LOD0"].bound_box]
        hs[v] = max(zs)
    hmax = max(hs.values())
    gap = hmax * 0.8
    for i, v in enumerate(vs):
        for n in ("LOD0", "LOD1", "LOD2"):
            o = objs[v + "_" + n]
            o.location.x = i * gap
            if n != "LOD0":
                o.hide_render = True
                o.hide_viewport = True
    person(-gap * 0.5)
    bpy.context.view_layer.update()
    c = Vector((gap * (len(vs) - 1) / 2, 0, hmax / 2))
    cam = RV.camera("front", c - Vector((0, 120, 0)), c, ortho=max(gap * len(vs) * 1.05,
                                                                  hmax * 1.1 * 16 / 9))
    RV.render(cam, os.path.join(out, key + "_variants.png"))
    # LOD0 | LOD1 | LOD2 варианта 0
    for n, k in (("LOD0", 0), ("LOD1", 1), ("LOD2", 2)):
        for v in vs:
            o = objs[v + "_" + n]
            o.hide_render = o.hide_viewport = v != vs[0]
            o.location.x = k * gap
    bpy.context.view_layer.update()
    c = Vector((gap, 0, hs[vs[0]] / 2))
    cam = RV.camera("lods", c - Vector((0, 120, 0)), c, ortho=max(3 * gap * 1.02,
                                                                 hs[vs[0]] * 1.1 * 16 / 9))
    RV.render(cam, os.path.join(out, key + "_lods.png"))
    # сверху под 45°, ~300 м: лес 7×7 из 4 вариантов LOD0 на сетке 14 м со случайным разбросом
    U.reset_scene()
    RV.setup_scene()
    import random
    rnd = random.Random(5)
    base = load_tree(key, 0)
    for o in list(base.values()):
        if o.type == "MESH" and not o.name.startswith(vs[0] + "_LOD0"):
            pass
    bpy.data.objects.remove(base[vs[0] + "_LOD0"])
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        bpy.data.objects.remove(o)
    for gx in range(-4, 5):
        for gy in range(-4, 5):
            before = set(bpy.data.objects)
            bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, "trees", "tree_%s.glb" % key))
            new = [o for o in bpy.data.objects if o not in before]
            pick = rnd.choice(vs)
            for o in new:
                if o.type == "MESH" and o.name.split(".")[0] != pick + "_LOD0":
                    bpy.data.objects.remove(o)
                elif o.parent is None:
                    o.location = (gx * 16 + rnd.uniform(-3, 3), gy * 16 + rnd.uniform(-3, 3), 0)
    person(0.0, -3.0)
    c = Vector((0, 0, 8))
    d = Vector((0, -1, 1)).normalized()
    cam = RV.camera("iso45", c + d * 300, c, lens=50)
    cam.data.clip_end = 1000
    RV.render(cam, os.path.join(out, key + "_forest_iso45.png"))


def main() -> None:
    global ORDER
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if argv and argv[0] == "--species":  # -- --species <вид> <каталог>: породы с вариантами
        os.makedirs(argv[2], exist_ok=True)
        main_variants(argv[1], argv[2])
        return
    ORDER = [k for k in ORDER if os.path.exists(os.path.join(U.MODELS, "trees", "tree_%s.glb" % k))]
    out = argv[0] if argv else os.path.join(U.ROOT, "docs", "models", "screenshots", "trees")
    os.makedirs(out, exist_ok=True)
    for key in ORDER:
        U.reset_scene()
        RV.setup_scene()
        objs = load_tree(key, 0)
        zs = [(objs["LOD0"].matrix_world @ Vector(c)).z for c in objs["LOD0"].bound_box]
        h, z0 = max(zs), min(zs)
        gap = h * 0.62
        objs["LOD1"].location.x = gap
        objs["LOD2"].location.x = 2 * gap
        bpy.context.view_layer.update()
        c = Vector((gap, 0, (h + z0) / 2))
        cam = RV.camera("front", c - Vector((0, 60, 0)), c, ortho=max(3 * gap * 1.02,
                                                                      (h - z0) * 1.1 * 16 / 9))
        RV.render(cam, os.path.join(out, key + ".png"))
    # все виды рядом, вид сверху под 45° (как с дельтаплана)
    U.reset_scene()
    RV.setup_scene()
    for i, key in enumerate(ORDER):
        objs = load_tree(key, (i - 2) * 12.0)
        for n in ("LOD1", "LOD2"):
            bpy.data.objects.remove(objs[n])
    c = Vector((0, 0, 9))
    d = Vector((0, -1, 1)).normalized()
    cam = RV.camera("iso45", c + d * 105, c, lens=50)
    RV.render(cam, os.path.join(out, "trees_iso45.png"))


if __name__ == "__main__":
    main()
