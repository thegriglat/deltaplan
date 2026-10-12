"""Общие помощники для генерации моделей в Blender (tools/blender/*.py).

Оси Blender: X вправо, +Y вперёд, Z вверх. Экспорт glTF с «+Y up» переводит их в оси Godot:
X вправо, −Z вперёд, Y вверх (Blender (x, y, z) → Godot (x, z, −y)). 1 ед. = 1 м.

MeshBuilder копит вершины/грани/UV/материалы и создаёт один меш-объект — так каждая
часть модели (Sail, Frame, ControlFrame…) выходит одной нодой с несколькими материалами.
"""
import json
import math
import os

import bpy
import numpy as np
from mathutils import Matrix, Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODELS = os.path.join(ROOT, "assets", "models")
SOURCE = os.path.join(ROOT, "assets", "source")


def load_json(rel: str) -> dict:
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return json.load(f)


def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.preferences.filepaths.save_version = 0  # без .blend1
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.objects):
        for item in list(coll):
            coll.remove(item)


def material(name: str, rgb, rough: float = 0.6, metal: float = 0.0,
             double: bool = False, image=None, alpha_clip: bool = False) -> bpy.types.Material:
    """Простой PBR-материал (Principled BSDF). image — текстура цвета (bpy Image)."""
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    m.diffuse_color = (*rgb, 1.0)
    m.use_backface_culling = not double
    if image is not None:
        tex = m.node_tree.nodes.new("ShaderNodeTexImage")
        tex.image = image
        m.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        if alpha_clip:
            # альфа-отсечение: экспортёр glTF видит Math «больше чем» → alphaMode MASK
            gt = m.node_tree.nodes.new("ShaderNodeMath")
            gt.operation = "GREATER_THAN"
            gt.inputs[1].default_value = 0.5
            m.node_tree.links.new(tex.outputs["Alpha"], gt.inputs[0])
            m.node_tree.links.new(gt.outputs[0], bsdf.inputs["Alpha"])
            m.surface_render_method = "DITHERED"
    return m


def image_from_array(name: str, rgb: np.ndarray, save_path: str = "") -> bpy.types.Image:
    """rgb: (H, W, 3|4) float 0..1, строка 0 — низ картинки (v = 0), как UV Blender."""
    h, w, ch = rgb.shape
    img = bpy.data.images.new(name, width=w, height=h, alpha=ch == 4)
    rgba = np.ones((h, w, 4), dtype=np.float32)
    rgba[:, :, :ch] = np.clip(rgb, 0.0, 1.0)
    img.pixels.foreach_set(rgba.ravel())
    if save_path:
        img.filepath_raw = save_path
        img.file_format = "PNG"
        img.save()
    img.pack()
    return img


def srgb(c):
    """Цвет из sRGB 0..1 (как в редакторе) в линейный для Blender."""
    return tuple(((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c)


class MeshBuilder:
    def __init__(self):
        self.verts: list = []
        self.faces: list = []
        self.uvs: list = []      # по одному списку UV на грань
        self.mats: list = []     # индекс материала на грань
        self.smooth: list = []
        self.mat_names: list = []
        self.colors: dict = {}   # индекс вершины → (x, y) второй UV (UV2); есть — пишется слой
        self.vcol: list = []     # цвет вершин RGBA (маска износа, bake_wear); есть — пишется слой

    def _mat(self, name: str) -> int:
        if name not in self.mat_names:
            self.mat_names.append(name)
        return self.mat_names.index(name)

    def add_face(self, idx, mat: str, uv=None, smooth: bool = True) -> None:
        self.faces.append(tuple(idx))
        self.uvs.append(uv or [(0.0, 0.0)] * len(idx))
        self.mats.append(self._mat(mat))
        self.smooth.append(smooth)

    def add_vert(self, p) -> int:
        self.verts.append(tuple(p))
        return len(self.verts) - 1

    def add_grid(self, pts, mat: str, uv=None, flip: bool = False, smooth: bool = True,
                 wrap: bool = False, wrap_rows: bool = False, colors=None) -> None:
        """pts[i][j] — сетка точек; uv[i][j] — (u, v). wrap — замкнуть по j, wrap_rows — по i.
        colors[i][j] — (x, y) второй UV вершины (UV2), например маска анимации паруса."""
        rows, cols = len(pts), len(pts[0])
        base = len(self.verts)
        for i, row in enumerate(pts):
            for j, p in enumerate(row):
                if colors is not None:
                    self.colors[len(self.verts)] = tuple(colors[i][j])
                self.verts.append(tuple(p))
        jmax = cols if wrap else cols - 1
        for i in range(rows if wrap_rows else rows - 1):
            i2 = (i + 1) % rows
            for j in range(jmax):
                j2 = (j + 1) % cols
                q = [base + i * cols + j, base + i2 * cols + j,
                     base + i2 * cols + j2, base + i * cols + j2]
                fuv = None
                if uv is not None:
                    fuv = [uv[i][j], uv[i2][j], uv[i2][j2], uv[i][j2]]
                if flip:
                    q.reverse()
                    if fuv:
                        fuv.reverse()
                self.add_face(q, mat, fuv, smooth)

    def add_tube(self, pts, radius, mat: str, sides: int = 8, cap: bool = True,
                 ellipse=(1.0, 1.0), up=(0.0, 0.0, 1.0), smooth: bool = True,
                 closed: bool = False, uv_v=None) -> None:
        """Труба вдоль ломаной pts. radius — число или список на точку.
        ellipse — (k_side, k_up): сечение-эллипс (обтекатель стойки). closed — кольцо."""
        pts = [Vector(p) for p in pts]
        n = len(pts)
        rads = radius if isinstance(radius, (list, tuple)) else [radius] * n
        upv = Vector(up)
        rings = []
        for i, p in enumerate(pts):
            if closed:
                t = (pts[(i + 1) % n] - pts[i - 1]).normalized()
            else:
                t = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized()
            ref = upv if abs(t.dot(upv)) < 0.95 else Vector((1, 0, 0))
            side = t.cross(ref).normalized()
            nup = side.cross(t).normalized()
            ring = []
            for k in range(sides):
                a = 2 * math.pi * k / sides
                ring.append(p + rads[i] * (math.cos(a) * ellipse[0] * side
                                           + math.sin(a) * ellipse[1] * nup))
            rings.append(ring)
        if closed:
            cap = False
        if uv_v is not None:  # развёртка коры: шов по u продублирован
            rings = [r + [r[0]] for r in rings]
            uv = [[(k / sides, uv_v[i]) for k in range(sides + 1)] for i in range(n)]
            self.add_grid(rings, mat, uv, flip=False, smooth=smooth)
        else:
            self.add_grid(rings, mat, flip=False, smooth=smooth, wrap=True, wrap_rows=closed)
        if cap:
            for ring, rev in ((rings[0], False), (rings[-1], True)):
                idx = [self.add_vert(v) for v in ring[:sides]]
                self.add_face(list(reversed(idx)) if rev else idx, mat, smooth=False)

    def add_ellipsoid(self, center, radii, mat: str, seg: int = 12, rings: int = 8,
                      rot: Matrix = None) -> None:
        c = Vector(center)
        rot = rot or Matrix.Identity(3)
        grid = []
        for i in range(rings + 1):
            th = math.pi * i / rings
            row = []
            for j in range(seg):
                ph = 2 * math.pi * j / seg
                v = Vector((radii[0] * math.sin(th) * math.cos(ph),
                            radii[1] * math.sin(th) * math.sin(ph),
                            radii[2] * math.cos(th)))
                row.append(c + rot @ v)
            grid.append(row)
        self.add_grid(grid, mat, wrap=True)

    def add_box(self, center, size, mat: str, rot: Matrix = None, uv_top=None) -> None:
        """Коробка (плоские грани). uv_top — UV для грани +Y... не используется."""
        c = Vector(center)
        rot = rot or Matrix.Identity(3)
        hx, hy, hz = (s * 0.5 for s in size)
        corners = [c + rot @ Vector((sx * hx, sy * hy, sz * hz))
                   for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
        quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4),
                 (1, 5, 7, 3)]
        for q in quads:
            idx = [self.add_vert(corners[k]) for k in q]
            self.add_face(idx, mat, smooth=False)

    def build(self, name: str, materials: dict, parent=None) -> bpy.types.Object:
        me = bpy.data.meshes.new(name)
        me.from_pydata(self.verts, [], self.faces)
        uvl = me.uv_layers.new(name="UVMap")
        li = 0
        for f, fuv in zip(me.polygons, self.uvs):
            for k in range(f.loop_total):
                uvl.data[f.loop_start + k].uv = fuv[k]
            li += f.loop_total
        if self.colors:
            # вторая UV (TEXCOORD_1 → UV2 в Godot): (r, g) из «цвета» вершины. Цвет вершин не
            # используем — по glTF COLOR_0 умножается на цвет материала.
            uv2 = me.uv_layers.new(name="UV2")
            for f in me.polygons:
                for k in range(f.loop_total):
                    li = f.loop_start + k
                    uv2.data[li].uv = self.colors.get(me.loops[li].vertex_index, (0, 0))[:2]
            me.uv_layers.active_index = 0
        if self.vcol:
            ca = me.color_attributes.new("Wear", "FLOAT_COLOR", "POINT")
            ca.data.foreach_set("color", [c for rgba in self.vcol for c in rgba])
            me.color_attributes.active_color = ca
        me.polygons.foreach_set("material_index", self.mats)
        me.polygons.foreach_set("use_smooth", self.smooth)
        for mn in self.mat_names:
            me.materials.append(materials[mn])
        me.validate()
        me.update()
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        if parent is not None:
            ob.parent = parent
        return ob


def empty(name: str, loc, parent=None, matrix: Matrix = None, size: float = 0.1):
    """Пустышка (в Godot — Node3D). loc/matrix — в мировых координатах."""
    ob = bpy.data.objects.new(name, None)
    ob.empty_display_type = "ARROWS"
    ob.empty_display_size = size
    bpy.context.scene.collection.objects.link(ob)
    m = matrix if matrix is not None else Matrix.Translation(Vector(loc))
    if parent is not None:
        ob.parent = parent
        ob.matrix_parent_inverse = Matrix.Identity(4)
        m = parent.matrix_world.inverted() @ m
    ob.matrix_basis = m
    return ob


def look_matrix(pos, target, up=(0, 0, 1)) -> Matrix:
    """Матрица, у которой локальная +Y Blender (= −Z в Godot) смотрит на target."""
    y = (Vector(target) - Vector(pos)).normalized()
    x = y.cross(Vector(up)).normalized()
    z = x.cross(y).normalized()
    m = Matrix((x, y, z)).transposed().to_4x4()
    m.translation = Vector(pos)
    return m


def tri_count(obj_names=None) -> int:
    n = 0
    for ob in bpy.context.scene.objects:
        if ob.type == "MESH" and (obj_names is None or ob.name in obj_names):
            n += sum(len(p.vertices) - 2 for p in ob.data.polygons)
    return n


def externalize_shared(glb_path: str) -> None:
    """Общая текстура шины — внешним файлом (uri), а не копией внутри glb: одна текстура в памяти."""
    import glb_extern
    tire = os.path.join(ROOT, "assets", "textures", "wheel", "tire.png")
    glb_extern.externalize(glb_path, {"wheel_tire": tire})


def export(stem: str, vertex_color: str = "NONE") -> None:
    os.makedirs(MODELS, exist_ok=True)
    os.makedirs(SOURCE, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(SOURCE, stem + ".blend"),
                                check_existing=False, compress=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(MODELS, stem + ".glb"),
                              export_format="GLB", export_yup=True, use_selection=False,
                              export_apply=True, export_extras=False,
                              export_vertex_color=vertex_color,
                              export_cameras=False, export_lights=False)
    externalize_shared(os.path.join(MODELS, stem + ".glb"))
    print("EXPORTED %s: %d tris" % (stem, tri_count()))


def rounded_rect(w: float, h: float, r: float, seg: int = 4) -> list:
    """Контур прямоугольника со скруглёнными углами в плоскости XZ (против часовой)."""
    pts = []
    for cx, cz, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90),
                       (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)):
        for k in range(seg + 1):
            a = math.radians(a0 + 90 * k / seg)
            pts.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    return pts


def screen_quad(size, y: float, zc: float, circle_seg: int = 0) -> MeshBuilder:
    """Экран прибора в плоскости XZ, смотрит в +Y Blender (= −Z Godot).
    UV 0..1 на весь экран: при взгляде спереди u слева направо, v снизу вверх (Blender;
    в glTF/Godot v переворачивается — сверху вниз). Справа от зрителя — −X.
    circle_seg > 0 — круглый экран (циферблат), UV — по описанному квадрату."""
    mb = MeshBuilder()
    sw, sh = size
    if circle_seg:
        pts = [(0.5 * sw * math.cos(2 * math.pi * k / circle_seg),
                0.5 * sh * math.sin(2 * math.pi * k / circle_seg)) for k in range(circle_seg)]
    else:
        pts = [(sw / 2, -sh / 2), (-sw / 2, -sh / 2), (-sw / 2, sh / 2), (sw / 2, sh / 2)]
    idx = [mb.add_vert((x, y, zc + z)) for x, z in pts]
    uv = [(0.5 - x / sw, 0.5 + z / sh) for x, z in pts]
    # порядок обхода: нормаль в +Y
    if circle_seg:
        idx.reverse()
        uv.reverse()
    mb.add_face(idx, "Screen", uv=uv, smooth=False)
    return mb


def _smoothstep(a: float, b: float, x: float) -> float:
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def bake_wear(mb: MeshBuilder, zone_mats=(), inset: float = 0.003, inset_min_area: float = 4e-5,
              ao_rays: int = 24, ao_dist: float = 0.02, skip_mats=()) -> None:
    """Маска износа в цвет вершин (mb.vcol, RGBA), детерминированно. Каналы:
    R — износ рёбер: выпуклый излом по сварке вершин по позиции (макс. угол между нормалями
        граней, сходящихся в точке), 0 на плоскостях;
    G — грязь во впадинах: AO вершины (лучи по полусфере из BVH-дерева самой модели);
    B — «зона кнопок» (грани материалов zone_mats);  A = 1.
    Плоские (smooth=False) грани площадью > inset_min_area получают вставку (пояс шириной inset,
    внутренние вершины R=0): иначе у большой грани все вершины были бы на ребре и износ залил бы
    её целиком — пояс даёт фаску износа по краю при линейной интерполяции."""
    from mathutils.bvhtree import BVHTree
    V = [Vector(v) for v in mb.verts]

    def fnorm(f):
        n = Vector()
        for i in range(len(f)):
            a, b = V[f[i]], V[f[(i + 1) % len(f)]]
            n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x),
                         (a.x - b.x) * (a.y + b.y)))
        return n.normalized() if n.length > 1e-12 else Vector((0, 0, 1))

    def fcen(f):
        return sum((V[i] for i in f), Vector()) / len(f)

    norms = [fnorm(f) for f in mb.faces]
    cens = [fcen(f) for f in mb.faces]
    groups: dict = {}
    for fi, f in enumerate(mb.faces):
        if mb.mat_names[mb.mats[fi]] in skip_mats:
            continue
        for vi in f:
            key = tuple(round(c * 1e4) for c in V[vi])
            groups.setdefault(key, []).append(fi)
    R = [0.0] * len(V)
    for fi, f in enumerate(mb.faces):
        for vi in f:
            key = tuple(round(c * 1e4) for c in V[vi])
            fs = groups.get(key, [])
            worst = 0.0
            for a in fs:
                for b in fs:
                    if a >= b:
                        continue
                    ang = norms[a].angle(norms[b])
                    if (cens[b] - cens[a]).dot(norms[a]) < 1e-6 and \
                            (cens[a] - cens[b]).dot(norms[b]) < 1e-6:   # выпуклый излом
                        worst = max(worst, ang)
            R[vi] = _smoothstep(0.15, 1.0, worst)
    Z = [0.0] * len(V)
    for fi, f in enumerate(mb.faces):
        if mb.mat_names[mb.mats[fi]] in zone_mats:
            for vi in f:
                Z[vi] = 1.0
    # вставка поясов у больших плоских граней
    faces, uvs, mats, smooth = [], [], [], []
    for fi, f in enumerate(mb.faces):
        area = 0.5 * sum(((V[f[i]] - V[f[0]]).cross(V[f[(i + 1) % len(f)]] - V[f[0]])
                          for i in range(1, len(f) - 1)), Vector()).length
        if mb.smooth[fi] or area < inset_min_area or mb.mat_names[mb.mats[fi]] in skip_mats:
            faces.append(f); uvs.append(mb.uvs[fi]); mats.append(mb.mats[fi])
            smooth.append(mb.smooth[fi])
            continue
        c = cens[fi]
        rad = sum((V[i] - c).length for i in f) / len(f)
        k = min(0.45, inset / max(rad, 1e-6))
        inner = []
        for vi in f:
            V.append(V[vi].lerp(c, k)); R.append(0.0); Z.append(Z[vi])
            inner.append(len(V) - 1)
        n = len(f)
        for i in range(n):
            j = (i + 1) % n
            faces.append((f[i], f[j], inner[j], inner[i]))
            uvs.append([(0.0, 0.0)] * 4); mats.append(mb.mats[fi]); smooth.append(False)
        faces.append(tuple(inner)); uvs.append([(0.0, 0.0)] * n)
        mats.append(mb.mats[fi]); smooth.append(False)
    mb.verts = [tuple(v) for v in V]
    mb.faces, mb.uvs, mb.mats, mb.smooth = faces, uvs, mats, smooth
    # AO вершин: нормаль — среднее нормалей граней, лучи по полусфере (золотая спираль)
    tris = []
    for f in faces:
        for i in range(1, len(f) - 1):
            tris.append((f[0], f[i], f[i + 1]))
    tree = BVHTree.FromPolygons([tuple(v) for v in V], tris)
    vn = [Vector() for _ in V]
    for f in faces:
        n = fnorm(f)
        for vi in f:
            vn[vi] += n
    mb.vcol = []
    golden = math.pi * (3.0 - math.sqrt(5.0))
    for vi, v in enumerate(V):
        n = vn[vi].normalized() if vn[vi].length > 1e-9 else Vector((0, 0, 1))
        t = n.cross(Vector((0, 0, 1)) if abs(n.z) < 0.9 else Vector((1, 0, 0))).normalized()
        b = n.cross(t)
        hit = 0.0
        for k in range(ao_rays):
            h = (k + 0.5) / ao_rays
            r = math.sqrt(1.0 - h)
            ph = golden * k
            d = (t * (r * math.cos(ph)) + b * (r * math.sin(ph)) + n * math.sqrt(h)).normalized()
            if tree.ray_cast(v + n * 1e-4, d, ao_dist)[0] is not None:
                hit += 1.0
        mb.vcol.append((R[vi], min(1.0, hit / ao_rays * 1.6), Z[vi], 1.0))
