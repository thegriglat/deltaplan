"""Кадры и видео тележки трайка (assets/models/trike/trike.glb) — TK-4.

    xvfb-run -a blender --background --python tools/blender/render_trike.py [-- [--out DIR] [--pilot] [--only shots|video]]

Без ключей: 4 PNG 1600x1000 (trike_front34, trike_side, trike_rear34, trike_top) и prop_spin.mp4
(5 с, 24 кадр/с, rear34 крупно на винт, 2 об/с по анимации prop_spin, motion blur Eevee)
в build/screenshots/trike-model (переопределить: --out или env TRIKE_OUT).
--pilot — добавить assets/models/pilot.glb в то же начало в позе sit (для TK-6; без ключа пилота нет).
Оси Blender (импорт glTF): нос +Y, вверх +Z. Кадры из PNG собираются через ffmpeg (libx264, yuv420p).
"""
import math
import os
import subprocess
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import render_views as RV  # noqa: E402

RES = (1600, 1000)
OUT = "/home/greg/deltaplan/build/screenshots/trike-model"
VIDEO_S, FPS, SPIN_RPS = 5, 24, 2.0


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
    sc.eevee.taa_render_samples = 48
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
        RV.set_pose("sit")
        objs += pil
    # земля — тонкая плоскость на уровне низа колёс
    meshes = [o for o in objs if o.type == "MESH" and not o.hide_render]
    lo, hi = RV.bbox(meshes)
    bpy.ops.mesh.primitive_plane_add(size=30, location=((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
    gnd = bpy.context.active_object
    gnd.name = "Ground"
    gnd.data.materials.append(U.material("ground", (0.55, 0.57, 0.52), rough=0.95))
    bpy.context.view_layer.update()
    return meshes


def shots(meshes: list, out: str) -> None:
    lo, hi = RV.bbox(meshes)
    c = (lo + hi) / 2
    size = (hi - lo).length
    d = size * 2.4
    cams = {
        "trike_front34": RV.camera("c1", c + Vector((-0.75, 0.9, 0.5)).normalized() * d, c, lens=50),
        "trike_rear34": RV.camera("c2", c + Vector((0.8, -0.85, 0.45)).normalized() * d, c, lens=50),
        "trike_side": RV.camera("c3", c + Vector((d, 0, 0)), c, ortho=RV.fit(lo, hi, (1, 2))),
        "trike_top": RV.camera("c4", c + Vector((0, 0, d)), c, up=(0, 1, 0),
                               ortho=RV.fit(lo, hi, (0, 1))),
    }
    for n, cam in cams.items():
        RV.render(cam, os.path.join(out, n + ".png"))


def video(meshes: list, out: str) -> None:
    sc = bpy.context.scene
    prop = bpy.data.objects["Propeller"]
    act = prop.animation_data.action
    # ускорить анимацию prop_spin до SPIN_RPS: сжать ключи по времени, цикл вне диапазона
    k = 1.0 / SPIN_RPS
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.co.x *= k
            kp.handle_left.x *= k
            kp.handle_right.x *= k
            kp.interpolation = "LINEAR"
        fc.modifiers.new("CYCLES")
        fc.update()
    sc.render.fps = FPS
    sc.render.use_motion_blur = True
    sc.render.motion_blur_shutter = 0.5
    sc.eevee.taa_render_samples = 32
    sc.render.resolution_percentage = 100
    p = prop.matrix_world.translation
    c = p + Vector((0, 0.6, 0.0))
    cam = RV.camera("vid", c + Vector((1.5, -2.4, 0.9)), c, lens=50)
    sc.camera = cam
    n = VIDEO_S * FPS
    frames = os.path.join(out, "_prop_frames")
    os.makedirs(frames, exist_ok=True)
    sc.render.filepath = os.path.join(frames, "f_")
    sc.frame_start, sc.frame_end = 1, n
    sc.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(animation=True)
    mp4 = os.path.join(out, "prop_spin.mp4")
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-framerate", str(FPS), "-i",
                    os.path.join(frames, "f_%04d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    mp4], check=True)
    for f in os.listdir(frames):
        os.remove(os.path.join(frames, f))
    os.rmdir(frames)
    print("VIDEO", mp4)


def main() -> None:
    a = args()
    os.makedirs(a["out"], exist_ok=True)
    meshes = load(a["pilot"])
    if a["only"] in ("", "shots"):
        shots(meshes, a["out"])
    if a["only"] in ("", "video"):
        video(meshes, a["out"])


if __name__ == "__main__":
    main()
