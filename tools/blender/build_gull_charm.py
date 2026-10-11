"""Брелок-чайка на трапецию (К15): светлая фигурка с расправленными длинными узкими крыльями.

Запуск: blender --background --python tools/blender/build_gull_charm.py
Результат: assets/easter_eggs/bar_charm/gull_charm.glb (Y вверх, вперёд −Z в Godot), исходник assets/source/easter_eggs/gull_charm.blend.

Оси Blender: X вправо, +Y вперёд, Z вверх → в Godot X вправо, −Z вперёд, Y вверх. 1 ед. = 1 м.
Размах 6 см, длина клюв–хвост 4 см. Начало координат — точка подвеса: колечко на спине над центром масс,
вся фигурка ниже (max z ≈ 0). Один меш, один материал, цвета вершин. Шнурок в модель не входит.
"""
import math
import os

import bpy

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

WHITE = (0.80, 0.81, 0.83)
BELLY = (0.88, 0.88, 0.88)
GREY = (0.55, 0.57, 0.60)
TIP = (0.20, 0.21, 0.23)
BEAK = (0.95, 0.70, 0.08)
RING = (0.60, 0.60, 0.62)

# Кольца тела: (y, полуширина, полувысота, z центра, цвет верха, цвет низа).
RINGS = [
    (-0.017, 0.0015, 0.0010, -0.0100, GREY, GREY),
    (-0.009, 0.0040, 0.0030, -0.0095, WHITE, BELLY),
    (0.000, 0.0055, 0.0045, -0.0095, WHITE, BELLY),
    (0.008, 0.0040, 0.0035, -0.0095, WHITE, BELLY),
    (0.0125, 0.0020, 0.0020, -0.0085, WHITE, WHITE),
    (0.0160, 0.0022, 0.0020, -0.0080, WHITE, WHITE),
    (0.0170, 0.0012, 0.0010, -0.0080, BEAK, BEAK),
]
TAIL_TIP = (0.0, -0.020, -0.0100)
BEAK_TIP = (0.0, 0.020, -0.0080)
# Ряды крыла (x, y передней кромки, y задней кромки, z, цвет): локоть выше корня, кончик опущен — «чайка».
WING_ROWS = [
    (0.004, 0.006, -0.008, -0.0085, WHITE),
    (0.013, 0.005, -0.006, -0.0040, WHITE),
    (0.022, 0.001, -0.007, -0.0065, GREY),
]
WING_TIP = (0.030, -0.012, -0.0105, TIP)
RING_R, RING_TUBE, RING_Z = 0.0022, 0.0008, -0.0030   # колечко: ось вдоль X, верх ≈ 0


def reset() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.preferences.filepaths.save_version = 0


def build() -> bpy.types.Object:
    verts, faces, cols = [], [], []

    def v(p, c):
        verts.append(p)
        cols.append(c)
        return len(verts) - 1

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
    # Хвост-веер.
    t0 = v((0.006, -0.012, -0.0098), WHITE)
    t1 = v((-0.006, -0.012, -0.0098), WHITE)
    t2 = v((0.0, -0.020, -0.0100), GREY)
    faces.append((t0, t2, t1))
    # Крылья.
    for s in (1.0, -1.0):
        rows = [(v((s * x, yl, z), c), v((s * x, yt, z), c)) for x, yl, yt, z, c in WING_ROWS]
        for (l0, t0_), (l1, t1_) in zip(rows, rows[1:]):
            faces.append((l0, t0_, t1_, l1) if s > 0 else (l0, l1, t1_, t0_))
        x, yl, z, c = WING_TIP
        tip = v((s * x, yl, z), c)
        l, t = rows[-1]
        faces.append((l, t, tip) if s > 0 else (l, tip, t))
    # Колечко на спине (восьмиугольный бублик из трёх граней в сечении).
    nm, nt = 8, 3
    ids = []
    for i in range(nm):
        a = 2 * math.pi * i / nm
        cy, cz = RING_R * math.sin(a), RING_Z + RING_R * math.cos(a)
        row = []
        for j in range(nt):
            b = 2 * math.pi * j / nt
            r = RING_TUBE
            row.append(v((r * math.cos(b), cy + r * math.sin(b) * math.sin(a), cz + r * math.sin(b) * math.cos(a)), RING))
        ids.append(row)
    for i in range(nm):
        for j in range(nt):
            i2, j2 = (i + 1) % nm, (j + 1) % nt
            faces.append((ids[i][j], ids[i][j2], ids[i2][j2], ids[i2][j]))

    mesh = bpy.data.meshes.new("GullCharm")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    attr = mesh.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    for i, c in enumerate(cols):
        attr.data[i].color = (*c, 1.0)
    for p in mesh.polygons:
        p.use_smooth = False
    obj = bpy.data.objects.new("GullCharm", mesh)
    bpy.context.scene.collection.objects.link(obj)
    mat = bpy.data.materials.new("GullCharmMat")
    mat.use_nodes = True
    nt_ = mat.node_tree
    bsdf = nt_.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.8
    node = nt_.nodes.new("ShaderNodeVertexColor")
    node.layer_name = "Col"
    nt_.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
    mat.use_backface_culling = False
    mesh.materials.append(mat)
    return obj


def main() -> None:
    reset()
    obj = build()
    out = os.path.join(ROOT, "assets", "easter_eggs", "bar_charm")
    source = os.path.join(ROOT, "assets", "source", "easter_eggs")
    os.makedirs(out, exist_ok=True)
    os.makedirs(source, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(source, "gull_charm.blend"))
    bpy.ops.export_scene.gltf(filepath=os.path.join(out, "gull_charm.glb"), export_format="GLB", export_yup=True,
                              export_apply=True, export_vertex_color="ACTIVE")
    me = obj.data
    xs = [p.co.x for p in me.vertices]
    ys = [p.co.y for p in me.vertices]
    zs = [p.co.z for p in me.vertices]
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    print("gull_charm: вершин", len(me.vertices), "треугольников", tris, "размах", max(xs) - min(xs),
          "длина", max(ys) - min(ys), "max z", max(zs), "min z", min(zs))


main()
