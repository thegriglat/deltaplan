"""Скриншоты породы деревьев (4 варианта, вид «с дельтаплана»).

    xvfb-run -a blender --background --python tools/blender/render_trees.py -- <порода> [out_dir] [эталон]
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import render_views as RV  # noqa: E402

def load_tree(key: str, dx: float, dy: float = 0.0) -> dict:
    """Импорт tree_<key>.glb со сдвигом; ключ — имя ноды (V0_LOD0, ...)."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, "trees", "tree_%s.glb" % key))
    objs = {o.name.split(".")[0]: o for o in bpy.data.objects if o not in before}
    for o in objs.values():
        if o.parent is None:
            o.location.x += dx
            o.location.y += dy
    return objs


def keep(objs: dict, names: list) -> None:
    for n, o in list(objs.items()):
        if o.type == "MESH" and n not in names:
            bpy.data.objects.remove(o)


def main() -> None:
    """-- <порода> [<каталог>] [<эталон>]: кадры породы для шлюза: front.png (варианты V0..V3 LOD0
    рядом) и iso45.png (сверху под 45° с ~300 м, рядом эталонная порода, по умолчанию birch)."""
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    key = argv[0] if argv else "oak"
    out = argv[1] if len(argv) > 1 else os.path.join(U.ROOT, "docs", "models", "screenshots", "trees", key)
    ref = argv[2] if len(argv) > 2 else "birch"
    os.makedirs(out, exist_ok=True)
    U.reset_scene()
    RV.setup_scene()
    gap = 22.0
    for v in range(4):
        o = load_tree(key, (v - 1.5) * gap)
        keep(o, ["V%d_LOD0" % v])
    r = load_tree(ref, 2.5 * gap)
    keep(r, ["V0_LOD0"])
    bpy.context.view_layer.update()
    c = Vector((gap * 0.5, 0, 14))
    cam = RV.camera("front", c - Vector((0, 90, 0)), c, ortho=gap * 6.6 * 9 / 16 * 1.6)
    RV.render(cam, os.path.join(out, "front.png"))
    # вид пилота: несколько деревьев (поле 3×3 вариантов) сверху под 45°, ~300 м
    U.reset_scene()
    RV.setup_scene()
    for i in range(3):
        for j in range(3):
            v = (i * 3 + j) % 4
            o = load_tree(key, (i - 1) * 14.0, j * 14.0 - 14.0)
            keep(o, ["V%d_LOD0" % v])
    r = load_tree(ref, 50.0, 0.0)
    keep(r, ["V0_LOD0"])
    c = Vector((12, 0, 5))
    d = Vector((0, -1, 1)).normalized()
    cam = RV.camera("iso45", c + d * 300, c, lens=50)
    cam.data.clip_end = 1000
    RV.render(cam, os.path.join(out, "iso45.png"))


if __name__ == "__main__":
    main()
