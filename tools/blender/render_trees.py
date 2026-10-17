"""Скриншоты деревьев: docs/models/screenshots/trees/<вид>.png (LOD0 | LOD1 | LOD2 спереди)
и trees_iso45.png (все виды LOD0 под 45° сверху — как их видит пилот).

    xvfb-run -a blender --background --python tools/blender/render_trees.py [-- out_dir]
    ... -- --models <порода> <каталог> [эталон]  — превью новой породы (варианты + вид 45°)
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


def load_variants(key: str, dx0: float, step: float, lod: str = "LOD0") -> list:
    """glb породы с вариантами V{v}_LOD*: оставить только lod, раздвинуть по X. Список объектов."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, "trees", "tree_%s.glb" % key))
    new = [o for o in bpy.data.objects if o not in before]
    keep = []
    for o in new:
        if o.type == "MESH" and o.name.split(".")[0].endswith("_" + lod):
            keep.append(o)
        elif o.parent is None or o.type == "MESH":
            bpy.data.objects.remove(o)
    keep.sort(key=lambda o: o.name)
    for i, o in enumerate(keep):
        o.location.x = dx0 + i * step
    bpy.context.view_layer.update()
    return keep


def models_preview(key: str, out: str, ref: str = "birch") -> None:
    """Превью породы для шлюза: <out>/variants.png — варианты LOD0 сбоку, справа старая порода
    ref для масштаба; <out>/iso45.png — те же сверху под 45° с ~300 м (как лес видит пилот)."""
    os.makedirs(out, exist_ok=True)
    for name in ("variants", "iso45"):
        U.reset_scene()
        RV.setup_scene()
        step = 14.0
        vs = load_variants(key, 0.0, step)
        rf = load_variants(ref, len(vs) * step, step)[:1]
        objs = vs + rf
        lo, hi = RV.bbox(objs)
        if name == "variants":
            c = Vector(((lo.x + hi.x) / 2, 0, hi.z / 2))
            cam = RV.camera("front", c - Vector((0, 80, 0)), c,
                            ortho=max((hi.x - lo.x) * 1.08 * 9 / 16, hi.z * 1.1) * 16 / 9)
        else:
            # земля — чтобы силуэт читался, как с высоты
            bpy.ops.mesh.primitive_plane_add(size=400, location=((lo.x + hi.x) / 2, 0, -0.05))
            mat = bpy.data.materials.new("G")
            mat.diffuse_color = (0.25, 0.32, 0.15, 1)
            bpy.context.object.data.materials.append(mat)
            c = Vector(((lo.x + hi.x) / 2, 0, hi.z * 0.4))
            d = Vector((0, -1, 1)).normalized()
            dist = 300.0
            lens = 36.0 * dist / ((hi.x - lo.x) * 1.15)
            cam = RV.camera("iso45", c + d * dist, c, lens=lens)
            cam.data.clip_end = 1000
        RV.render(cam, os.path.join(out, name + ".png"))


def main() -> None:
    global ORDER
    argv0 = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if argv0[:1] == ["--models"]:  # --models <порода> <каталог> [эталон]
        models_preview(argv0[1], argv0[2], argv0[3] if len(argv0) > 3 else "birch")
        return
    ORDER = [k for k in ORDER if os.path.exists(os.path.join(U.MODELS, "trees", "tree_%s.glb" % k))]
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
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
