"""Кадры тележки трайка v2 без пилота и с пилотом (assets/models/trike/trike.glb, pilot.glb в позе sit) — TK-4, TK-6.

    blender --background --python tools/blender/render_trike.py [-- [--out DIR] [--pilot] [--only trike|pilot|closeup|eye]]

Cycles на GPU (OPTIX, иначе CUDA; на этой машине CUDA), 256 выборок без шумодава (в сборке нет OIDN, OPTIX-устройства нет; TRIKE_SAMPLES, TRIKE_DENOISE=1), без xvfb. Только PNG 1600x1000, видео не делается (решение 2026-10-22).
Без ключей: сначала сцена без пилота — trike_front34, trike_side, trike_rear34, trike_top; затем с пилотом
(pilot.glb в то же начало без смещения, действие sit) — pilot_front34, pilot_side, pilot_rear34, pilot_front, pilot_top
и крупно посадка seat_closeup_side, seat_closeup_front, seat_closeup_feet. Каталог: build/screenshots/trike-model
(переопределить: --out или env TRIKE_OUT). --pilot — рендерить только сцену с пилотом (кадры pilot_* и seat_closeup_*).
Оси Blender (импорт glTF): нос +Y, вверх +Z. Кадры рамкуются по габариту тележки без пилота, поэтому совпадают в обеих сериях.
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
OUT = "/home/greg/deltaplan/build/screenshots/trike-model"
SAMPLES = int(os.environ.get("TRIKE_SAMPLES", "256"))
DENOISE = os.environ.get("TRIKE_DENOISE", "0") == "1"


def args() -> dict:
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    d = {"out": os.environ.get("TRIKE_OUT", OUT), "pilot": "--pilot" in a, "only": ""}
    for k in ("--out", "--only"):
        if k in a:
            d[k[2:]] = a[a.index(k) + 1]
    return d


def load(pilot: bool) -> list:
    U.reset_scene()
    RV.RES = RES
    RV.setup_scene()
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y = RES
    gpu(sc)
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, "trike", "trike.glb"))
    new = [o for o in bpy.data.objects if o not in before]
    for o in new:
        if o.type in ("CAMERA", "LIGHT"):
            bpy.data.objects.remove(o)
    objs = [o for o in new if o.name in bpy.data.objects]
    for o in objs:  # только LOD0
        if o.type == "MESH" and o.name.split(".")[0] in ("Trike_LOD1", "Trike_LOD2", "Prop_LOD1"):
            o.hide_render = True
            o.hide_viewport = True
    if pilot:
        pil = RV.import_glb("pilot")
        for n in [o.name for o in pil if o.name.split(".")[0] == "Icosphere"]:
            bpy.data.objects.remove(bpy.data.objects[n])  # служебный шар (2 м) из glTF_not_exported
        RV.set_pose("sit")
    # земля — тонкая плоскость на уровне низа колёс
    meshes = [o for o in objs if o.type == "MESH" and not o.hide_render]
    lo, hi = RV.bbox(meshes)  # габарит и земля — по тележке без пилота
    bpy.ops.mesh.primitive_plane_add(size=30, location=((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
    gnd = bpy.context.active_object
    gnd.name = "Ground"
    gnd.data.materials.append(U.material("ground", (0.55, 0.57, 0.52), rough=0.95))
    bpy.context.view_layer.update()
    return meshes


def gpu(sc) -> None:
    """Cycles на GPU: OPTIX, иначе CUDA."""
    sc.render.engine = "CYCLES"
    cy = sc.cycles
    cy.samples = SAMPLES
    cy.use_denoising = DENOISE
    cy.device = "CPU"
    pref = bpy.context.preferences.addons["cycles"].preferences
    for kind in ("OPTIX", "CUDA"):
        try:
            pref.compute_device_type = kind
            pref.get_devices()
        except Exception:  # noqa: BLE001
            continue
        gpus = [d for d in pref.devices if d.type == kind]
        if gpus:
            for d in pref.devices:
                d.use = d.type == kind
            cy.device = "GPU"
            try:
                cy.denoiser = "OPTIX" if kind == "OPTIX" else "OPENIMAGEDENOISE"
            except TypeError:  # перечень шумодавов зависит от сборки; остаётся по умолчанию
                pass
            print("CYCLES", kind, [d.name for d in gpus])
            return
    print("CYCLES: GPU не найден, CPU")


def shot(cam, path: str) -> None:
    sc = bpy.context.scene
    sc.camera = cam
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDERED", path)


def shots(meshes: list, out: str, prefix: str) -> None:
    lo, hi = RV.bbox(meshes)
    c = (lo + hi) / 2
    size = (hi - lo).length
    d = size * 2.4
    cams = {
        "front34": RV.camera("c1", c + Vector((-0.75, 0.9, 0.5)).normalized() * d, c, lens=50),
        "rear34": RV.camera("c2", c + Vector((0.8, -0.85, 0.45)).normalized() * d, c, lens=50),
        "side": RV.camera("c3", c + Vector((d, 0, 0)), c, ortho=RV.fit(lo, hi, (1, 2))),
        "top": RV.camera("c4", c + Vector((0, 0, d)), c, up=(0, 1, 0), ortho=RV.fit(lo, hi, (0, 1))),
    }
    if prefix == "pilot":  # спереди: между колесом и пилотом, чуть сверху
        cams["front"] = RV.camera("c5", c + Vector((0, 1, 0.12)).normalized() * d, c, lens=50)
    for n, cam in cams.items():
        shot(cam, os.path.join(out, f"{prefix}_{n}.png"))


def closeups(out: str) -> None:
    """Крупно посадка: бок (ортографика), спереди 3/4 и ступни."""
    tgt = Vector((0, 0.55, -1.65))
    cams = {
        "seat_closeup_side": RV.camera("k1", tgt + Vector((4, 0, 0)), tgt, ortho=2.4),
        "seat_closeup_front": RV.camera("k2", Vector((-1.1, 2.0, -1.0)), tgt, lens=50),
        "seat_closeup_feet": RV.camera("k3", Vector((0.9, 2.0, -1.55)), Vector((0, 1.1, -2.1)), lens=50),
    }
    for n, cam in cams.items():
        shot(cam, os.path.join(out, n + ".png"))


def eye_views(out: str) -> None:
    """TK-12: вид из глаз пилота (seat.eye), вниз 10 градусов, FOV 90 (горизонтальный), с условной штангой.

    Штанга — цилиндр по bar (d, half_width вдоль X, центр в trim/full_pull/full_push); шлем и тело пилота скрыты
    (камера внутри головы). Кадры: eye_view (три положения разными цветами), eye_view_pull / _trim / _push.
    """
    P = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "trike_params.json")))
    B = P["bar"]
    eye = Vector(P["seat"]["eye"])
    for o in bpy.data.objects:
        if o.name.split(".")[0] in ("PilotBody", "Helmet"):
            o.hide_render = True
    cols = {"pull": (0.9, 0.1, 0.1), "trim": (0.1, 0.7, 0.1), "push": (0.1, 0.2, 0.95)}
    bars = {}
    for k, key in (("pull", "full_pull"), ("trim", "trim"), ("push", "full_push")):
        c = B[key]
        bpy.ops.mesh.primitive_cylinder_add(radius=B["d"] / 2, depth=2 * B["half_width"], vertices=24,
                                            location=(c[0], c[1], c[2]), rotation=(0, math.pi / 2, 0))
        ob = bpy.context.active_object
        ob.name = "Bar_" + k
        ob.data.materials.append(U.material("bar_" + k, cols[k], rough=0.4))
        bars[k] = ob
    bpy.context.view_layer.update()
    pitch = math.radians(-10.0)
    tgt = eye + Vector((0, math.cos(pitch), math.sin(pitch)))
    cam = RV.camera("eye", eye, tgt, lens=18.0)  # sensor 36 мм, lens 18 -> горизонтальный FOV 90
    shot(cam, os.path.join(out, "eye_view.png"))
    for k in bars:
        for kk, ob in bars.items():
            ob.hide_render = kk != k
        shot(cam, os.path.join(out, f"eye_view_{k}.png"))


def main() -> None:
    a = args()
    os.makedirs(a["out"], exist_ok=True)
    if a["only"] in ("", "trike") and not a["pilot"]:
        shots(load(False), a["out"], "trike")
    if a["only"] in ("", "pilot", "closeup", "eye") or a["pilot"]:
        meshes = load(True)
        if a["only"] in ("", "pilot"):
            shots(meshes, a["out"], "pilot")
        if a["only"] in ("", "closeup"):
            closeups(a["out"])
        if a["only"] in ("", "eye"):
            eye_views(a["out"])


if __name__ == "__main__":
    main()
