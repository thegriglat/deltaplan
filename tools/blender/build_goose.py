"""Низкополигональный гусь с раскрытыми горизонтальными крыльями (К13, пасхалка «Клин гусей»).

Запуск: blender --background --python tools/blender/build_goose.py
Результат: assets/easter_eggs/geese/goose.glb (Y вверх, вперёд −Z в Godot), исходник assets/source/easter_eggs/goose.blend.

Оси Blender: X вправо, +Y вперёд, Z вверх → в Godot X вправо, −Z вперёд, Y вверх. 1 ед. = 1 м.
Размах 1,6 м, длина клюв–хвост ≈ 0,87 м. Начало координат — центр тела у корня крыльев.
Тело — в |x| ≤ 0,12 м; вершины крыла — только за |x| > 0,12 м, четыре ряда по размаху (корень, 2 промежуточных, кончик):
взмах делает вершинный шейдер потребителя по abs(VERTEX.x). Один меш, один материал, цвета — цвета вершин.
"""
import os

import bpy

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HALF_SPAN_M = 0.8

# Колец тела: (y, полуширина, полувысота, z центра, цвет верха, цвет низа). Кольцо — ромб из 4 вершин.
GREY = (0.36, 0.30, 0.23)
BELLY = (0.62, 0.58, 0.50)
DARK = (0.07, 0.065, 0.06)
BEAK = (0.03, 0.03, 0.03)
RINGS = [
    (-0.30, 0.05, 0.025, 0.000, GREY, GREY),
    (-0.16, 0.10, 0.065, 0.000, GREY, BELLY),
    (0.00, 0.115, 0.080, 0.000, GREY, BELLY),
    (0.13, 0.090, 0.070, 0.005, GREY, BELLY),
    (0.22, 0.035, 0.035, 0.030, DARK, DARK),
    (0.32, 0.025, 0.025, 0.045, DARK, DARK),
    (0.39, 0.036, 0.034, 0.050, DARK, DARK),
    (0.425, 0.016, 0.013, 0.048, BEAK, BEAK),
]
TAIL_TIP = (0.0, -0.40, 0.0)
BEAK_TIP = (0.0, 0.45, 0.046)
# Ряды крыла: (x, y передней кромки, y задней кромки, z) — от корня к кончику.
WING_ROWS = [(0.13, 0.10, -0.22, 0.0), (0.35, 0.10, -0.20, 0.0), (0.58, 0.05, -0.15, 0.0)]
WING_TIP = (0.80, -0.02, -0.12, 0.0)
WING_ROW_COLOR = [GREY, GREY, (0.22, 0.18, 0.14), DARK]


def reset() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.preferences.filepaths.save_version = 0


def build() -> bpy.types.Object:
    verts, faces, cols = [], [], []

    def v(p, c):
        verts.append(p)
        cols.append(c)
        return len(verts) - 1

    # Тело: хвост-точка, кольца, клюв-точка.
    prev = None
    ring_ids = []
    for y, hw, hh, zc, ctop, cbot in RINGS:
        ring_ids.append([v((0, y, zc + hh), ctop), v((hw, y, zc), ctop), v((0, y, zc - hh), cbot), v((-hw, y, zc), ctop)])
    tail = v(TAIL_TIP, GREY)
    beak = v(BEAK_TIP, BEAK)
    r0, rn = ring_ids[0], ring_ids[-1]
    for k in range(4):
        faces.append((tail, r0[(k + 1) % 4], r0[k]))
        faces.append((beak, rn[k], rn[(k + 1) % 4]))
    for a, b in zip(ring_ids, ring_ids[1:]):
        for k in range(4):
            k2 = (k + 1) % 4
            faces.append((a[k], a[k2], b[k2], b[k]))
    # Хвост-веер (плоский треугольник на уровне z=0, ширина 0,16 м) — нужен, чтобы хвост не был «иглой».
    t0 = v((0.07, -0.20, 0.0), GREY)
    t1 = v((-0.07, -0.20, 0.0), GREY)
    t2 = v((0.0, -0.42, 0.0), DARK)
    faces.append((t0, t2, t1))
    # Крылья.
    for s in (1.0, -1.0):
        rows = []
        for i, (x, yl, yt, z) in enumerate(WING_ROWS):
            rows.append((v((s * x, yl, z), WING_ROW_COLOR[i]), v((s * x, yt, z), WING_ROW_COLOR[i])))
        x, yl, yt, z = WING_TIP
        tip = v((s * x, (yl + yt) / 2, z), WING_ROW_COLOR[3])
        tip_l = v((s * (x - 0.1), yl + 0.01, z), WING_ROW_COLOR[3])  # ряд перед кончиком: перья-«пальцы»
        for (l0, t0_), (l1, t1_) in zip(rows, rows[1:]):
            faces.append((l0, t0_, t1_, l1) if s > 0 else (l0, l1, t1_, t0_))
        l, t = rows[-1]
        faces.append((l, t, tip) if s > 0 else (l, tip, t))
        faces.append((l, tip, tip_l) if s > 0 else (l, tip_l, tip))

    mesh = bpy.data.meshes.new("Goose")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    attr = mesh.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    for i, c in enumerate(cols):
        attr.data[i].color = (*c, 1.0)
    for p in mesh.polygons:
        p.use_smooth = False
    obj = bpy.data.objects.new("Goose", mesh)
    bpy.context.scene.collection.objects.link(obj)
    mat = bpy.data.materials.new("GooseFeathers")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.9
    node = nt.nodes.new("ShaderNodeVertexColor")
    node.layer_name = "Col"
    nt.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
    mat.use_backface_culling = False
    mesh.materials.append(mat)
    return obj


def main() -> None:
    reset()
    obj = build()
    out = os.path.join(ROOT, "assets", "easter_eggs", "geese")
    source = os.path.join(ROOT, "assets", "source", "easter_eggs")
    os.makedirs(out, exist_ok=True)
    os.makedirs(source, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(source, "goose.blend"))
    bpy.ops.export_scene.gltf(filepath=os.path.join(out, "goose.glb"), export_format="GLB", export_yup=True,
                              export_apply=True, export_vertex_color="ACTIVE")
    me = obj.data
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    print("goose: вершин", len(me.vertices), "треугольников", tris, "размах", max(xs) - min(xs), "длина", max(ys) - min(ys))


main()
