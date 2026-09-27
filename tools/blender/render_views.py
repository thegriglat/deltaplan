"""Приёмочные рендеры моделей из готовых .glb (то, что получает игра).

    blender --background --python tools/blender/render_views.py -- <kind> <out_dir> [views]
kind: glider_training | glider_kingpost | glider_sport | pilot | instrument | vario_90s
views (через запятую): bottom, front, side, iso45, cockpit (только крылья), rear, under34.
По умолчанию — bottom,front,side,iso45 (+cockpit у крыльев). Для скриншотов в репозитории:
    docs/models/screenshots/<kind>/<view>.png
Все виды: 1280×720, одинаковый нейтральный светлый фон и свет. Кабинный вид собирается из
крыла + pilot.glb (в HangPoint) + instrument.glb (в InstrumentMount) + vario_90s.glb
(в VarioMount), камера — в пустышке Head.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

RES = (1280, 720)
BG = (0.80, 0.81, 0.83)


def import_glb(name: str, parent_matrix: Matrix = None) -> list:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(U.MODELS, name + ".glb"))
    new = [o for o in bpy.data.objects if o not in before]
    if parent_matrix is not None:
        holder = bpy.data.objects.new(name + "_holder", None)
        bpy.context.scene.collection.objects.link(holder)
        holder.matrix_world = parent_matrix
        for o in new:
            if o.parent is None:
                o.parent = holder
    bpy.context.view_layer.update()
    return new


def setup_scene() -> None:
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = RES
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"
    sc.render.image_settings.compression = 100
    sc.view_settings.view_transform = "Standard"
    sc.render.dither_intensity = 0.0  # без шума — PNG сжимается лучше
    sc.eevee.taa_render_samples = 32
    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    bgn = world.node_tree.nodes["Background"]
    bgn.inputs["Color"].default_value = (*U.srgb(BG), 1)
    bgn.inputs["Strength"].default_value = 0.9
    sc.world = world
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 3.0
    sun.angle = math.radians(3)
    so = bpy.data.objects.new("Sun", sun)
    sc.collection.objects.link(so)
    so.rotation_euler = (math.radians(35), math.radians(-20), math.radians(30))


def bbox(objs) -> tuple:
    pts = []
    for o in objs:
        if o.type == "MESH":
            pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


def camera(name: str, pos, target, up=(0, 0, 1), ortho: float = 0.0, lens: float = 50.0):
    cam = bpy.data.cameras.new(name)
    if ortho > 0:
        cam.type = "ORTHO"
        cam.ortho_scale = ortho
    cam.lens = lens
    cam.clip_start = 0.02
    cam.clip_end = 200
    ob = bpy.data.objects.new(name, cam)
    bpy.context.scene.collection.objects.link(ob)
    # камера смотрит вдоль своей −Z, вверх — +Y
    f = (Vector(target) - Vector(pos)).normalized()
    r = f.cross(Vector(up)).normalized()
    u = r.cross(f)
    m = Matrix((r, u, -f)).transposed().to_4x4()
    m.translation = Vector(pos)
    ob.matrix_world = m
    return ob


def fit(lo, hi, axes) -> float:
    """Ортомасштаб по двум осям картинки (горизонт., вертик.) с полями."""
    aspect = RES[0] / RES[1]
    w = (hi - lo)[axes[0]]
    h = (hi - lo)[axes[1]]
    return max(w, h * aspect) * 1.12


def render(cam, path: str) -> None:
    sc = bpy.context.scene
    sc.camera = cam
    if cam.data.type == "PANO":
        sc.render.engine = "CYCLES"
        sc.cycles.samples = 96
        sc.cycles.use_denoising = False
        sc.cycles.device = "CPU"
    else:
        sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDERED", path)


def add_cameras(objs, views: list, kind: str) -> dict:
    lo, hi = bbox(objs)
    c = (lo + hi) / 2
    d = (hi - lo).length * 2 + 1
    cams = {}
    if "bottom" in views:
        cams["bottom"] = camera("bottom", c - Vector((0, 0, d)), c, up=(0, 1, 0),
                                ortho=fit(lo, hi, (0, 1)))
    if "front" in views:
        cams["front"] = camera("front", c + Vector((0, d, 0)), c, ortho=fit(lo, hi, (0, 2)))
    if "rear" in views:
        cams["rear"] = camera("rear", c - Vector((0, d, 0)), c, ortho=fit(lo, hi, (0, 2)))
    if "side" in views:
        cams["side"] = camera("side", c + Vector((d, 0, 0)), c, ortho=fit(lo, hi, (1, 2)))
    size = (hi - lo).length
    lens = 50.0
    ext = sorted(hi - lo)
    # вытянутые объекты (крыло) кадрируются по ширине, компактные (пилот, прибор) — с запасом
    dist = size * (1.45 if ext[2] > 2.5 * ext[1] else 2.6)
    if "iso45" in views:
        dirv = Vector((1, 1, 1)).normalized()  # спереди-справа-сверху, 45° по азимуту
        cams["iso45"] = camera("iso45", c + dirv * dist, c, lens=lens)
    if "under34" in views:
        dirv = Vector((0.6, 0.9, -0.55)).normalized()  # снизу-спереди, как фото с земли
        cams["under34"] = camera("under34", c + dirv * dist, c, lens=lens)
    if "cockpit" in views:
        # кабинная камера из pilot.glb (CockpitCamera), вертикальный угол обзора 95°
        cc = bpy.data.objects.get("CockpitCamera")
        m = cc.matrix_world if cc else Matrix.Translation((0, 0.37, -1.12))
        pos = m.translation
        fwd = (m.to_3x3() @ Vector((0, 1, 0))).normalized()
        cam = camera("cockpit", pos, pos + fwd, lens=12.0 / math.tan(math.radians(47.5)))
        cam.data.sensor_fit = "VERTICAL"
        cam.data.sensor_height = 24.0
        helmet = bpy.data.objects.get("Helmet")
        if helmet:
            helmet.hide_render = True
        cams["cockpit"] = cam
    for spec in os.environ.get("EXTRA_CAMS", "").split(";"):
        # имя:азимут_от_носа:возвышение:дистанция_в_размерах:фокус — свободный ракурс под фото
        if spec and spec.split(":")[0] in views:
            name, az, el, k, lens2 = spec.split(":")
            az, el = math.radians(float(az)), math.radians(float(el))
            dirv = Vector((math.sin(az) * math.cos(el), math.cos(az) * math.cos(el), math.sin(el)))
            cams[name] = camera(name, c + dirv * size * float(k), c, lens=float(lens2))
    return cams


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:]
    kind, out_dir = argv[0], argv[1]
    is_wing = kind.startswith("glider_")
    default = "bottom,front,side,iso45" + (",cockpit" if is_wing else "")
    views = (argv[2] if len(argv) > 2 else default).split(",")
    U.reset_scene()
    setup_scene()
    objs = import_glb(kind)
    if is_wing and os.environ.get("WITH_PILOT"):  # для сравнения с фото: с пилотом и прибором
        import_glb("pilot", bpy.data.objects["HangPoint"].matrix_world.copy())
        import_glb("instrument", bpy.data.objects["InstrumentMount"].matrix_world.copy())
        import_glb("vario_90s", bpy.data.objects["VarioMount"].matrix_world.copy())
    cams = add_cameras(objs, [v for v in views if v != "cockpit"], kind)
    os.makedirs(out_dir, exist_ok=True)
    for name, cam in cams.items():
        render(cam, os.path.join(out_dir, name + ".png"))
    if "cockpit" in views and is_wing and not os.environ.get("WITH_PILOT"):
        # кабинный вид: + пилот в точке подвеса, + прибор на стойке
        hang = bpy.data.objects["HangPoint"].matrix_world.copy()
        import_glb("pilot", hang)
        mount = bpy.data.objects["InstrumentMount"].matrix_world.copy()
        vario = bpy.data.objects["VarioMount"].matrix_world.copy()
        import_glb("instrument", mount)
        import_glb("vario_90s", vario)
        cam = add_cameras(objs, ["cockpit"], kind)["cockpit"]
        render(cam, os.path.join(out_dir, "cockpit.png"))


if __name__ == "__main__":
    main()
