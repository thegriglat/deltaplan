"""Низкополигональная парящая хищная птица (коршун/канюк) для атмосферы — естественный признак термика.

Запуск: blender --background --python tools/blender/bird.py
Результат: assets/models/bird.glb (+Y up, вперёд −Z в Godot), исходник assets/source/bird.blend.

Оси Blender: X вправо, +Y вперёд, Z вверх → в Godot X вправо, −Z вперёд, Y вверх. 1 ед. = 1 м.
Размах 1,6 м. Крылья — отдельные группы вершин не нужны: шейдер машет по |x| (расстояние от оси).
"""
import math
import os

import bpy

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SPAN_M = 1.6
DIHEDRAL_M = 0.07       # подъём концов крыльев (парящая птица держит крылья «галочкой»)
BODY_LEN_M = 0.62
COLOR = (0.16, 0.11, 0.07)


def reset() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.preferences.filepaths.save_version = 0


def wing(sign: float) -> tuple[list, list]:
    """Полукрыло: передняя и задняя кромки, «пальцы» маховых на конце."""
    half = SPAN_M * 0.5
    # (x, y) передней кромки от корня к концу и задней — от конца к корню.
    lead = [(0.05, 0.10), (0.25, 0.12), (0.45, 0.10), (0.62, 0.06)]
    trail = [(0.62, -0.10), (0.45, -0.14), (0.25, -0.15), (0.05, -0.13)]
    verts = []
    for x, y in lead + trail:
        z = DIHEDRAL_M * (x / half) ** 1.5
        verts.append((sign * x, y, z))
    faces = [(0, 1, 6, 7), (1, 2, 5, 6), (2, 3, 4, 5)]
    # Пять «пальцев» маховых перьев между концом передней и задней кромки.
    base_lead = verts[3]
    base_trail = verts[4]
    n = 5
    for i in range(n):
        a = i / n
        b = (i + 0.8) / n
        p0 = [base_lead[k] + (base_trail[k] - base_lead[k]) * a for k in range(3)]
        p1 = [base_lead[k] + (base_trail[k] - base_lead[k]) * b for k in range(3)]
        tip_x = sign * (half - 0.02 * abs(i - 2))
        tip_y = 0.04 - 0.035 * i
        tip = (tip_x, tip_y, DIHEDRAL_M * 1.05)
        idx = len(verts)
        verts += [tuple(p0), tuple(p1), tip]
        faces.append((idx, idx + 1, idx + 2))
    return verts, faces


def build() -> bpy.types.Object:
    verts: list = []
    faces: list = []

    def add(vs, fs):
        off = len(verts)
        verts.extend(vs)
        faces.extend([tuple(i + off for i in f) for f in fs])

    # Тело — вытянутый ромб (октаэдр).
    h = BODY_LEN_M * 0.5
    body = [(0, h, 0.0), (0.055, 0.05, 0), (0, 0.05, 0.05), (-0.055, 0.05, 0), (0, 0.05, -0.04), (0, -h + 0.1, 0.0)]
    body_f = [(0, 2, 1), (0, 3, 2), (0, 4, 3), (0, 1, 4), (5, 1, 2), (5, 2, 3), (5, 3, 4), (5, 4, 1)]
    add(body, body_f)
    # Крылья.
    for s in (1.0, -1.0):
        add(*wing(s))
    # Хвост — веер.
    tail = [(0.03, -h + 0.12, 0), (-0.03, -h + 0.12, 0), (-0.11, -h - 0.1, 0.01), (0, -h - 0.13, 0.01), (0.11, -h - 0.1, 0.01)]
    add(tail, [(0, 1, 3), (1, 2, 3), (0, 3, 4)])

    mesh = bpy.data.meshes.new("Bird")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    for p in mesh.polygons:
        p.use_smooth = False
    obj = bpy.data.objects.new("Bird", mesh)
    bpy.context.scene.collection.objects.link(obj)
    mat = bpy.data.materials.new("BirdFeathers")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*COLOR, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.9
    mat.use_backface_culling = False
    mesh.materials.append(mat)
    return obj


def main() -> None:
    reset()
    build()
    models = os.path.join(ROOT, "assets", "models")
    source = os.path.join(ROOT, "assets", "source")
    os.makedirs(models, exist_ok=True)
    os.makedirs(source, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(source, "bird.blend"))
    bpy.ops.export_scene.gltf(filepath=os.path.join(models, "bird.glb"), export_format="GLB",
                              export_yup=True, export_apply=True)
    print("bird: вершин", len(bpy.data.objects["Bird"].data.vertices),
          "граней", len(bpy.data.objects["Bird"].data.polygons), "размах", SPAN_M, "угол", math.degrees(math.atan2(DIHEDRAL_M, SPAN_M / 2)))


main()
