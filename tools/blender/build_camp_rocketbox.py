"""Люди лагеря Microsoft Rocketbox (MIT): FBX + TGA → assets/models/world/rocketbox/<имя>/.

    blender -b -P tools/blender/build_camp_rocketbox.py -- <каталог аватара> [<каталог вывода>]

Каталог аватара — как в репозитории Rocketbox (Assets/Avatars/Adults/<имя>/): Export/<имя>.fbx (или <имя>.fbx
в корне) и Textures/*.tga. Как скачать — tools/blender/build_camp_rocketbox.sh (всё по шагам; исходники в git не
кладём, ~90 МБ на человека). Основа — tools/research/rocketbox/repack.py (ветка research/rocketbox).

Что делает:
 1. импорт FBX; анимация FBX (Take 001) снимается первой — иначе Apply сбрасывает трансформ арматуры;
 2. скелет «lite»: лицевые кости слиты в голову, пальцы — в кисть, носок — в стопу (22 кости; имена Biped
    «Bip01 …» сохранены — по ним ретаргет анимаций, tools/blender/camp_rocketbox_retarget.gd);
 3. трансформы в данные (метры, единичный корень) и поворот на 180° вокруг вертикали: лицом к −Z в Godot;
 4. LOD на одном скелете: Body_LOD0 (исходник, 6,7–8,8 тыс. треугольников), Body_LOD1 (5000), Body_LOD2 (2500) —
    Decimate collapse, равномерно (защита лица группой даёт перекос, docs/research/rocketbox.md § 4);
 5. текстуры 512² рядом с glb (внешние файлы, не внутри glb): {body,head}_color.jpg, {body,head}_normal.png,
    opacity.png (волосы, альфа); specular не используется. Импорт Godot — VRAM-сжатие и мипмапы (.import пишет
    build_camp_rocketbox.sh);
 6. <имя>.json: треугольники LOD, рост, кости, средние цвета (верх, низ, кожа, волосы — для дальнего LOD
    человечков camp_person.glb), sRGB 0..1.
"""
import json
import os
import sys
from pathlib import Path

import bpy
from mathutils import Matrix

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glb_extern  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
argv = sys.argv[sys.argv.index("--") + 1:]
AV = Path(argv[0])
NAME = AV.name
OUT = Path(argv[1]) if len(argv) > 1 else ROOT / "assets" / "models" / "world" / "rocketbox"
OUT = OUT / NAME
TRIS = [5000, 2500]  # LOD1, LOD2 (LOD0 — исходник)
TEX = 512
P = "Bip01 "
BODY = ["Pelvis", "Spine", "Spine1", "Spine2", "Neck", "Head"]


def short(n: str) -> str:
    return n[len(P):] if n.startswith(P) else n


def is_face(n: str) -> bool:
    """Лицевые кости Biped (глаза, челюсть, брови, рот…) — всё, что не туловище, руки и ноги."""
    s = short(n)
    if s in BODY or s == "Footsteps" or n == "Bip01":
        return False
    return s[:2] not in ("L ", "R ")


def tris_of(ob) -> int:
    dg = bpy.context.evaluated_depsgraph_get()
    me = ob.evaluated_get(dg).to_mesh()
    n = sum(len(p.vertices) - 2 for p in me.polygons)
    ob.evaluated_get(dg).to_mesh_clear()
    return n


def vg_merge(ob, name_from: str, name_to: str) -> None:
    g = ob.vertex_groups.get(name_from)
    if not g:
        return
    to = ob.vertex_groups.get(name_to) or ob.vertex_groups.new(name=name_to)
    for v in ob.data.vertices:
        for ge in v.groups:
            if ge.group == g.index and ge.weight > 0:
                to.add([v.index], ge.weight, "ADD")
    ob.vertex_groups.remove(g)


fbx = AV / "Export" / f"{NAME}.fbx"
if not fbx.exists():
    fbx = AV / f"{NAME}.fbx"
tex_dir = AV / "Textures"
prefix = next(tex_dir.glob("*_body_color.tga")).name.split("_")[0]
OUT.mkdir(parents=True, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=str(fbx))
for o in bpy.data.objects:
    o.animation_data_clear()
for a in list(bpy.data.actions):
    bpy.data.actions.remove(a)
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
src = next(o for o in bpy.data.objects if o.type == "MESH")

# --- 2. скелет lite
merge = {}
for b in arm.data.bones:
    s = short(b.name)
    if is_face(b.name):
        merge[b.name] = P + "Head"
    elif s[:2] in ("L ", "R ") and "Finger" in s:
        merge[b.name] = P + s[:2] + "Hand"
    elif b.name.endswith("Toe0"):
        merge[b.name] = b.name.replace("Toe0", "Foot")
for k, v in merge.items():
    vg_merge(src, k, v)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
for k in merge:
    eb = arm.data.edit_bones.get(k)
    if eb:
        arm.data.edit_bones.remove(eb)
bpy.ops.object.mode_set(mode="OBJECT")

# --- 3. трансформы в данные + разворот лицом к +Y Blender (−Z Godot)
bpy.ops.object.select_all(action="DESELECT")
src.select_set(True)
bpy.context.view_layer.objects.active = src
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
turn = Matrix.Rotation(3.141592653589793, 4, "Z")
src.matrix_world = turn @ src.matrix_world
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
arm.matrix_world = turn @ arm.matrix_world
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
src.parent = arm
src.matrix_parent_inverse = arm.matrix_world.inverted()
for m in src.modifiers:
    if m.type == "ARMATURE":
        m.object = arm
arm.name = "Skeleton"
for o in list(bpy.data.objects):
    if o.type == "EMPTY":
        bpy.data.objects.remove(o)
while len(src.data.uv_layers) > 1:
    src.data.uv_layers.remove(src.data.uv_layers[-1])
# лицом к +Y Blender: носки стоп впереди пяток
zs = [v.co.z for v in src.data.vertices]
z0 = min(zs)
low = [v.co for v in src.data.vertices if v.co.z < z0 + 0.03]
assert sum(c.y for c in low) / len(low) > -0.05, "модель смотрит не туда"

# --- 4. LOD
src.name = "Body_LOD0"
src.data.name = "Body_LOD0"
lods = [src]
for i, target in enumerate(TRIS, start=1):
    cp = src.copy()
    cp.data = src.data.copy()
    bpy.context.scene.collection.objects.link(cp)
    cp.name = f"Body_LOD{i}"
    cp.data.name = cp.name
    dec = cp.modifiers.new("Decimate", "DECIMATE")
    dec.decimate_type = "COLLAPSE"
    dec.use_collapse_triangulate = True
    lo, hi = 0.02, 1.0
    for _ in range(14):  # бисекция коэффициента на целевое число треугольников
        dec.ratio = (lo + hi) / 2
        if tris_of(cp) > target:
            hi = dec.ratio
        else:
            lo = dec.ratio
    dec.ratio = lo
    bpy.context.view_layer.objects.active = cp
    bpy.ops.object.modifier_move_to_index(modifier="Decimate", index=0)
    bpy.ops.object.modifier_apply(modifier="Decimate")
    lods.append(cp)


# --- 5. текстуры 512 и материалы
def tex(kind: str, src_name: str, ext: str, alpha: bool = False):
    im = bpy.data.images.load(str(tex_dir / f"{prefix}_{src_name}.tga"))
    if im.size[0] > TEX:
        im.scale(TEX, TEX)
    fmt = "JPEG" if ext == "jpg" else "PNG"
    sc = bpy.context.scene
    sc.render.image_settings.file_format = fmt
    sc.render.image_settings.color_mode = "RGBA" if alpha else "RGB"
    sc.render.image_settings.quality = 90
    sc.render.image_settings.compression = 100
    path = OUT / f"{kind}.{ext}"
    im.save_render(str(path), scene=sc)
    bpy.data.images.remove(im)
    out = bpy.data.images.load(str(path))
    out.name = kind
    return out


imgs = {
    "body_color": tex("body_color", "body_color", "jpg"),
    "body_normal": tex("body_normal", "body_normal", "png"),
    "head_color": tex("head_color", "head_color", "jpg"),
    "head_normal": tex("head_normal", "head_normal", "png"),
    "opacity": tex("opacity", "opacity_color", "png", alpha=True),
}


def mk_mat(name: str, color, normal=None, alpha: bool = False):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Roughness"].default_value = 0.85
    bsdf.inputs["Metallic"].default_value = 0.0
    nt.links.new(bsdf.outputs[0], out.inputs[0])
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = color
    nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"])
    if alpha:
        nt.links.new(t.outputs["Alpha"], bsdf.inputs["Alpha"])
        m.blend_method = "CLIP"
        m.alpha_threshold = 0.5
        m.use_backface_culling = False
    else:
        color.alpha_mode = "NONE"
    if normal:
        normal.colorspace_settings.name = "Non-Color"
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = normal
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(n.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    return m


mats = {
    "body": mk_mat("Body", imgs["body_color"], imgs["body_normal"]),
    "head": mk_mat("Head", imgs["head_color"], imgs["head_normal"]),
    "opacity": mk_mat("Hair", imgs["opacity"], None, alpha=True),
}
mat_key = [s.material.name.split("_")[-1] for s in src.material_slots]  # до замены (общие data у LOD нет)
for ob in lods:
    for i, slot in enumerate(ob.material_slots):
        ob.data.materials[i] = mats[ob.material_slots[i].material.name.split("_")[-1]]


# --- 6. средние цвета областей (по UV центров граней LOD0): верх — туловище/руки, низ — бёдра/голени
def px(img):
    w, h = img.size
    return w, h, list(img.pixels[:])


def region_of(v) -> str:
    best, bw = "", 0.0
    for ge in v.groups:
        if ge.weight > bw:
            best, bw = src.vertex_groups[ge.group].name, ge.weight
    s = short(best)
    if any(k in s for k in ("Spine", "Clavicle", "UpperArm")):
        return "top"
    if any(k in s for k in ("Thigh", "Calf")):
        return "bottom"
    if s in ("Head", "Neck"):
        return "skin"
    return ""


cache = {k: px(imgs[k]) for k in ("body_color", "head_color", "opacity")}
acc = {"top": [0.0, 0.0, 0.0, 0.0], "bottom": [0.0, 0.0, 0.0, 0.0], "skin": [0.0, 0.0, 0.0, 0.0],
       "hair": [0.0, 0.0, 0.0, 0.0]}
me = src.data
uvl = me.uv_layers.active.data
for p in me.polygons:
    key = mat_key[p.material_index]
    if key == "opacity":
        reg, img = "hair", "opacity"
    else:
        reg = region_of(me.vertices[p.vertices[0]])
        img = "body_color" if key == "body" else "head_color"
        if reg == "skin" and key != "head":
            continue
        if reg == "":
            continue
    u = sum(uvl[li].uv[0] for li in p.loop_indices) / p.loop_total
    v = sum(uvl[li].uv[1] for li in p.loop_indices) / p.loop_total
    w, h, pix = cache[img]
    x = min(w - 1, max(0, int((u % 1.0) * w)))
    y = min(h - 1, max(0, int((v % 1.0) * h)))
    k = (y * w + x) * 4
    if img == "opacity" and pix[k + 3] < 0.5:
        continue
    a = p.area
    for c in range(3):
        acc[reg][c] += pix[k + c] * a
    acc[reg][3] += a
colors = {r: [round(s[c] / max(1e-9, s[3]), 3) for c in range(3)] for r, s in acc.items()}

# --- 7. экспорт
for ob in lods:
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.ops.object.vertex_group_limit_total(limit=4)
    bpy.ops.object.vertex_group_clean(group_select_mode="ALL", limit=0.001)
info = {
    "name": NAME,
    "source": f"Microsoft Rocketbox Assets/Avatars/Adults/{NAME} (MIT, Copyright (c) 2020 Microsoft)",
    "bones": len(arm.data.bones),
    "lods": {ob.name: tris_of(ob) for ob in lods},
    "height_m": round(max(zs) - z0, 3),
    "tex": TEX,
    "colors_srgb": colors,
}
glb = OUT / f"{NAME}.glb"
bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(filepath=str(glb), export_format="GLB", use_selection=True, export_apply=False,
                          export_skins=True, export_animations=False, export_image_format="AUTO",
                          export_yup=True, export_texcoords=True, export_normals=True, export_extras=False,
                          export_materials="EXPORT", export_influence_nb=4, export_cameras=False,
                          export_lights=False)
n = glb_extern.externalize(str(glb), {k: str(OUT / Path(imgs[k].filepath).name) for k in imgs})
assert n == len(imgs), f"внешних текстур {n} из {len(imgs)}"
(OUT / f"{NAME}.json").write_text(json.dumps(info, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
print("ROCKETBOX", json.dumps(info, ensure_ascii=False))
