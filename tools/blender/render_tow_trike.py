"""TT-7: кадры дельталёта в сборе — тележка (trike.glb) + крыло trike_ixess15 + пилот sit.

    blender --background --python tools/blender/render_tow_trike.py [-- [--out DIR] [--only side,top,...]]

Начало координат обеих моделей — HangPoint (точка подвески): крыло и тележка ставятся началом в одну точку, как в игре
(scripts/flight/glider_visual.gd: «начало координат модели — HangPoint», тележка висит на нём маятником). Тангаж крыла
относительно тележки — psi (TT-К6: tools/research/tow-trike/trapeze.json → glider_params.psi_deg, нос вверх) вокруг
HangPoint: так штанга при trim лежит в руках пилота внутри треугольника тележки; тележка на колёсах горизонтальна,
земля — по низу колёс. Пилот — pilot.glb в начале тележки без смещения, действие sit (TK-К3).
Кадры: side, front34, rear34, top (на земле) и flight_below_side (в полёте: без земли, небо, снизу-сбоку, сборка горизонтальна).
Выход: JPEG q88, build/screenshots/tow-trike/tow_trike_<ракурс>.jpg. Оси Blender (glTF): нос +Y, вверх +Z.
Рендер Eevee (без GPU-замка).
"""
import json
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import render_views as RV  # noqa: E402

RES = (1600, 1000)
OUT = "/home/greg/deltaplan/build/screenshots/tow-trike"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FLIGHT_PITCH_DEG = 0.0   # установившийся горизонтальный полёт буксировщика (trim TT-К6)


def args() -> dict:
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    d = {"out": os.environ.get("TOW_TRIKE_OUT", OUT), "only": ""}
    for k in ("--out", "--only"):
        if k in a:
            d[k[2:]] = a[a.index(k) + 1]
    return d


def new_objs(fn) -> list:
    before = set(bpy.data.objects)
    fn()
    objs = [o for o in bpy.data.objects if o not in before]
    for o in objs:
        if o.type in ("CAMERA", "LIGHT") and o.name in bpy.data.objects:
            bpy.data.objects.remove(o)
    return [o for o in objs if o.name in bpy.data.objects]


def holder(name: str, objs: list, rot_x_deg: float):
    """Пустышка в HangPoint (начало), к ней — корневые объекты модели."""
    h = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(h)
    h.rotation_euler = (math.radians(rot_x_deg), 0, 0)
    for o in objs:
        if o.parent is None:
            o.parent = h
    return h


def build(flight: bool, keel_deg: float) -> list:
    """Сцена; возвращает меши сборки. Вращение сборки в полёте — внешний holder."""
    U.reset_scene()
    RV.RES = RES
    RV.setup_scene()
    sc = bpy.context.scene
    sc.render.image_settings.file_format = "JPEG"
    sc.render.image_settings.quality = 88
    trike = new_objs(lambda: bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, "trike", "trike.glb")))
    for o in trike:  # только LOD0
        if o.type == "MESH" and o.name.split(".")[0] in ("Trike_LOD1", "Trike_LOD2", "Prop_LOD1"):
            o.hide_render = o.hide_viewport = True
    wing = new_objs(lambda: bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, "glider_trike_ixess15.glb")))
    pil = RV.import_glb("pilot")
    drop = [o.name for o in pil if o.name.split(".")[0] == "Icosphere"]
    pil = [o for o in pil if o.name not in drop]
    for n in drop:
        bpy.data.objects.remove(bpy.data.objects[n])
    RV.set_pose("sit")
    # земля по низу колёс тележки (без крыла, пилота)
    tm = [o for o in trike if o.type == "MESH" and not o.hide_render]
    lo, hi = RV.bbox(tm)
    w = holder("WingPitch", wing, keel_deg)  # тангаж крыла вокруг HangPoint
    root = bpy.data.objects.new("Assembly", None)
    sc.collection.objects.link(root)
    w.parent = root
    for o in trike + pil:
        if o.parent is None:
            o.parent = root
    root.rotation_euler = (math.radians(FLIGHT_PITCH_DEG if flight else 0.0), 0, 0)
    if not flight:
        bpy.ops.mesh.primitive_plane_add(size=600, location=((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
        gnd = bpy.context.active_object
        gnd.data.materials.append(U.material("ground", (0.45, 0.55, 0.35), rough=0.95))
    else:  # небо: градиент по высоте вида
        wd = sc.world.node_tree
        wd.nodes["Background"].inputs["Color"].default_value = (*U.srgb((0.45, 0.65, 0.92)), 1)
    bpy.context.view_layer.update()
    return [o for o in trike + wing + pil if o.type == "MESH" and not o.hide_render]


def shot(cam, path: str) -> None:
    sc = bpy.context.scene
    sc.camera = cam
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDERED", path)


def main() -> None:
    a = args()
    os.makedirs(a["out"], exist_ok=True)
    only = [s for s in a["only"].split(",") if s]
    tz = json.load(open(os.path.join(ROOT, "tools", "research", "tow-trike", "trapeze.json"), encoding="utf-8"))
    keel = float(tz["glider_params"]["psi_deg"]["value"])
    for flight in (False, True):
        if only and not any(s.startswith("flight") == flight for s in only):
            continue
        meshes = build(flight, keel)
        lo, hi = RV.bbox(meshes)
        c = (lo + hi) / 2
        d = (hi - lo).length * 1.5
        if flight:
            cams = {"flight_below_side": RV.camera("c", c + Vector((-0.8, 0.45, -0.35)).normalized() * d, c, lens=40)}
        else:
            cams = {
                "side": RV.camera("c1", c + Vector((d * 1.6, 0, 0)), c, ortho=RV.fit(lo, hi, (1, 2))),
                "front34": RV.camera("c2", c + Vector((-0.75, 0.9, 0.35)).normalized() * d, c, lens=40),
                "rear34": RV.camera("c3", c + Vector((0.8, -0.85, 0.35)).normalized() * d, c, lens=40),
                "top": RV.camera("c4", c + Vector((0, 0, d * 1.6)), c, up=(0, 1, 0), ortho=RV.fit(lo, hi, (0, 1))),
            }
        for n, cam in cams.items():
            if not only or n in only:
                shot(cam, os.path.join(a["out"], f"tow_trike_{n}.jpg"))


if __name__ == "__main__":
    main()
