"""Скриншоты деревьев: docs/models/screenshots/trees/<вид>.png (LOD0 | LOD1 | LOD2 спереди)
и trees_iso45.png (все виды LOD0 под 45° сверху — как их видит пилот).

    xvfb-run -a blender --background --python tools/blender/render_trees.py [-- out_dir]
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import render_views as RV  # noqa: E402

ORDER = ["pine", "cedar", "larch", "birch", "spruce"]


def load_tree(key: str, dx: float) -> dict:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, "trees", "tree_%s.glb" % key))
    objs = {o.name.split(".")[0]: o for o in bpy.data.objects if o not in before}
    for o in objs.values():
        if o.parent is None:
            o.location.x += dx
    return objs


def main() -> None:
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
