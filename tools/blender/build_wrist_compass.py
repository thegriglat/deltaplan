"""Наручный жидкостный компас на правую руку пилота: assets/models/wrist_compass.glb
(+ assets/source/wrist_compass.blend), контракт PH-К4 (docs/contracts/pilot-hud.md).

    blender --background --python tools/blender/build_wrist_compass.py

Параметры — tools/blender/wrist_compass.json (мм). Оси Blender: циферблат смотрит в +Y (= −Z Godot,
наружная нормаль, как Screen приборов), «12 часов» и курсовая черта — +Z Blender (= +Y Godot, к
пальцам), для смотрящего на циферблат справа — −X. Начало координат — центр нижней плоскости корпуса
на поверхности рукава (пустышка WristR, PH-К3). Ремешок охватывает эллипс W×H с центром (0, −H/2).
Ноды верхнего уровня: Case, Strap, Card (вращается вокруг своей Z Godot = оси Y Blender; N на +Y при 0),
Lubber (неподвижная черта), Glass (купол капсулы). Картушка — текстура 256² (метки через 10°,
цифры /10 через 30°, N E S W, красный треугольник у N), штрихи рисуются тут же (numpy, без шрифтов).
"""
import math
import os
import sys

import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

MM = 0.001
P = U.load_json("tools/blender/wrist_compass.json")
CARD_D = P["card_d_mm"]

# ------------------------------------------------------------------ текстура картушки


def _lin(c):
    return tuple(U.srgb(c))


def _lum(c):
    r, g, b = _lin(c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


GLYPHS = {   # штрихи в ячейке шириной 0,6 и высотой 1 (низ — к центру, верх — наружу)
    "N": [[(0.04, 0), (0.04, 1), (0.56, 0), (0.56, 1)]],
    "E": [[(0.52, 1), (0.06, 1), (0.06, 0), (0.52, 0)], [(0.06, 0.5), (0.44, 0.5)]],
    "S": [[(0.55, 0.82), (0.45, 0.95), (0.30, 1.0), (0.15, 0.95), (0.05, 0.82), (0.08, 0.68),
           (0.30, 0.55), (0.50, 0.42), (0.55, 0.28), (0.50, 0.12), (0.38, 0.03), (0.25, 0.0),
           (0.12, 0.05), (0.03, 0.17)]],
    "W": [[(0.0, 1), (0.15, 0), (0.3, 0.7), (0.45, 0), (0.6, 1)]],
    "0": [[(0.3 + 0.27 * math.cos(a), 0.5 + 0.5 * math.sin(a))
           for a in [2 * math.pi * k / 14 for k in range(15)]]],
    "1": [[(0.12, 0.78), (0.3, 1), (0.3, 0)]],
    "2": [[(0.05, 0.8), (0.15, 0.95), (0.3, 1), (0.45, 0.95), (0.55, 0.8), (0.5, 0.62),
           (0.05, 0), (0.55, 0)]],
    "3": [[(0.05, 0.9), (0.3, 1), (0.52, 0.9), (0.52, 0.65), (0.3, 0.52), (0.2, 0.52)],
          [(0.3, 0.52), (0.55, 0.4), (0.55, 0.12), (0.3, 0), (0.05, 0.1)]],
    "4": [[(0.45, 0), (0.45, 1), (0.02, 0.3), (0.58, 0.3)]],
    "5": [[(0.5, 1), (0.1, 1), (0.07, 0.55), (0.3, 0.6), (0.5, 0.5), (0.55, 0.25), (0.4, 0.04),
           (0.25, 0), (0.05, 0.08)]],
    "6": [[(0.5, 0.95), (0.3, 1), (0.08, 0.8), (0.03, 0.4), (0.1, 0.1), (0.3, 0), (0.5, 0.1),
           (0.55, 0.3), (0.45, 0.5), (0.3, 0.55), (0.1, 0.42)]],
    "8": [[(0.3 + 0.22 * math.cos(a), 0.76 + 0.23 * math.sin(a))
           for a in [2 * math.pi * k / 12 for k in range(13)]],
          [(0.3 + 0.27 * math.cos(a), 0.27 + 0.27 * math.sin(a))
           for a in [2 * math.pi * k / 12 for k in range(13)]]],
}
GLYPHS["9"] = [[(0.6 - x, 1 - y) for x, y in s] for s in GLYPHS["6"]]
GLYPHS["7"] = [[(0.02, 1), (0.55, 1), (0.2, 0)]]


class Canvas:
    """Рисование на картушке в мм: x вправо, y вверх, центр картушки — (0, 0)."""

    def __init__(self, n: int, d_mm: float, bg):
        self.n = n
        self.d = d_mm
        self.pxmm = n / d_mm
        u = (np.arange(n) + 0.5) / n
        self.xr = (u[None, :] - 0.5) * d_mm * np.ones((n, 1))      # столбец → право
        self.yu = (u[:, None] - 0.5) * d_mm * np.ones((1, n))      # строка 0 — низ (как v)
        self.img = np.ones((n, n, 3), dtype=np.float32) * np.array(bg, dtype=np.float32)

    def _blend(self, dist, half, color):
        cov = np.clip(0.5 + (half - dist) * self.pxmm, 0.0, 1.0)[..., None]
        self.img = self.img * (1 - cov) + np.array(color, dtype=np.float32) * cov

    def segment(self, a, b, width, color):
        a, b = np.array(a, float), np.array(b, float)
        ab = b - a
        px, py = self.xr - a[0], self.yu - a[1]
        t = np.clip((px * ab[0] + py * ab[1]) / max(ab @ ab, 1e-9), 0, 1)
        self._blend(np.hypot(px - t * ab[0], py - t * ab[1]), width / 2, color)

    def polyline(self, pts, width, color):
        dist = None
        for a, b in zip(pts[:-1], pts[1:]):
            a, b = np.array(a, float), np.array(b, float)
            ab = b - a
            px, py = self.xr - a[0], self.yu - a[1]
            t = np.clip((px * ab[0] + py * ab[1]) / max(ab @ ab, 1e-9), 0, 1)
            d = np.hypot(px - t * ab[0], py - t * ab[1])
            dist = d if dist is None else np.minimum(dist, d)
        self._blend(dist, width / 2, color)

    def polar(self, r, bearing_deg):
        b = math.radians(bearing_deg)
        return (r * math.sin(b), r * math.cos(b))

    def radial(self, bearing, r0, r1, width, color):
        self.segment(self.polar(r0, bearing), self.polar(r1, bearing), width, color)

    def triangle(self, pts, color):
        area = (pts[1][0] - pts[0][0]) * (pts[2][1] - pts[0][1]) \
            - (pts[1][1] - pts[0][1]) * (pts[2][0] - pts[0][0])
        ins = None
        for i in range(3):
            a, b = np.array(pts[i], float), np.array(pts[(i + 1) % 3], float)
            e = (self.xr - a[0]) * (b[1] - a[1]) - (self.yu - a[1]) * (b[0] - a[0])
            e = (-e if area > 0 else e) / np.hypot(*(b - a))   # расстояние до ребра, мм
            ins = e if ins is None else np.minimum(ins, e)
        cov = np.clip(0.5 + ins * self.pxmm, 0, 1)[..., None]
        self.img = self.img * (1 - cov) + np.array(color, dtype=np.float32) * cov

    def disc(self, r, color, ring=None):
        d = np.hypot(self.xr, self.yu) - r
        if ring:
            self._blend(np.abs(d), ring / 2, color)
        else:
            self._blend(d, 0.0, color)

    def text(self, s, r_c, bearing, h, stroke, color):
        """Строка s, центр на радиусе r_c под азимутом bearing, верх букв — наружу."""
        b = math.radians(bearing)
        up = np.array((math.sin(b), math.cos(b)))
        right = np.array((math.cos(b), -math.sin(b)))
        adv = 0.78
        total = (len(s) - 1) * adv + 0.6
        c = np.array(self.polar(r_c, bearing))
        for i, ch in enumerate(s):
            for stroke_pts in GLYPHS[ch]:
                pts = [c + ((gx + i * adv - total / 2) * h) * right + ((gy - 0.5) * h) * up
                       for gx, gy in stroke_pts]
                self.polyline(pts, stroke, color)


def paint_card():
    c = P["colors_srgb"]
    bg, ink, red = _lin(c["card_bg"]), _lin(c["card_ink"]), _lin(c["card_red"])
    cv = Canvas(P["tex_px"], CARD_D, bg)
    R = CARD_D / 2
    for k in range(36):
        b = 10 * k
        if b % 90 == 0:
            continue
        if b % 30 == 0:
            cv.radial(b, R - 3.1, R - 0.7, 1.3, ink)
        else:
            cv.radial(b, R - 2.2, R - 0.7, 0.7, ink)
    for b in (90, 180, 270):
        cv.radial(b, R - 3.9, R - 0.7, 1.9, ink)
    # N выделено формой: красный треугольник остриём к центру, у кромки картушки
    cv.triangle([(-1.9, R - 0.7), (1.9, R - 0.7), (0.0, R - 5.0)], red)
    for b in (30, 60, 120, 150, 210, 240, 300, 330):
        cv.text(str(b // 10), R - 5.9, b, 3.4, 0.62, ink)
    for ch, b in (("N", 0), ("E", 90), ("S", 180), ("W", 270)):
        cv.text(ch, 9.3, b, 6.4, 1.15, red if ch == "N" else ink)
    cv.disc(2.4, ink, ring=0.5)
    cv.disc(0.9, ink)
    return cv.img, bg, ink, red


# ------------------------------------------------------------------ геометрия


def ye(x_mm: float) -> float:
    """Поверхность рукава (эллипс W×H, центр (0, −H/2)) под точкой x, мм."""
    a, h = P["wrist_w_mm"] / 2, P["wrist_h_mm"]
    return -h / 2 + (h / 2) * math.sqrt(max(0.0, 1 - (x_mm / a) ** 2))


def revolve(mb, rows, mat, n=32, flip=False, smooth=True):
    """rows — списки (r, y) мм либо функции φ → (r, y); тело вращения вокруг Y Blender."""
    grid = []
    for row in rows:
        ring = []
        for k in range(n):
            phi = 2 * math.pi * k / n
            r, y = row(phi) if callable(row) else row
            ring.append(Vector((r * math.cos(phi) * MM, y * MM, r * math.sin(phi) * MM)))
        grid.append(ring)
    mb.add_grid(grid, mat, wrap=True, flip=flip, smooth=smooth)


def disc_face(mb, r, y, mat, up=True, n=32, uv=None):
    idx = [mb.add_vert(Vector((r * math.cos(2 * math.pi * k / n) * MM, y * MM,
                               r * math.sin(2 * math.pi * k / n) * MM))) for k in range(n)]
    if not up:
        idx.reverse()
    mb.add_face(idx, mat, uv=uv, smooth=False)


def build_case():
    mb = U.MeshBuilder()
    R = P["case_d_mm"] / 2
    sh, top = P["case_shoulder_y_mm"], P["bezel_top_y_mm"]
    well, fl = P["well_r_mm"], P["well_floor_y_mm"]
    # корпус: юбка по рукаву → плечо; (стенка наружу)
    revolve(mb, [lambda p: (R, ye(R * math.cos(p)) - 0.2), (R, 6.5), (R - 0.5, sh - 0.6),
                 (R - 1.4, sh)], "Case", flip=True)
    # безель-кольцо
    revolve(mb, [(R - 1.4, sh), (R - 1.6, top - 0.5), (R - 2.3, top), (well + 0.9, top),
                 (well, top - 0.5)], "Bezel", flip=True)
    # колодец капсулы: стенка внутрь и дно
    revolve(mb, [(well, top - 0.5), (well, fl)], "Case", flip=False, smooth=False)
    disc_face(mb, well, fl, "Case", up=True)
    return mb


def build_glass():
    mb = U.MeshBuilder()
    well, top = P["well_r_mm"], P["bezel_top_y_mm"]
    dome = P["dome_top_y_mm"]
    rows = [(well + 0.3, top - 0.2), (well - 0.2, top + 1.4), (16.5, top + 2.9), (11.5, dome - 0.55),
            (5.5, dome - 0.1)]
    revolve(mb, rows, "Glass", flip=True)
    # вершина: веер
    r, y = rows[-1][0], rows[-1][1]
    ring = [mb.add_vert(Vector((r * math.cos(2 * math.pi * k / 32) * MM, y * MM,
                                r * math.sin(2 * math.pi * k / 32) * MM))) for k in range(32)]
    mb.add_face(list(reversed(ring)), "Glass", smooth=False)
    return mb


def build_strap():
    mb = U.MeshBuilder()
    a, b = P["wrist_w_mm"] / 2, P["wrist_h_mm"] / 2
    g, t, w = P["strap_gap_mm"], P["strap_t_mm"], P["strap_w_mm"]
    cy = -b
    th0 = math.acos(min(0.99, P["strap_end_x_mm"] / (a + g)))
    t0, t1 = math.pi - th0, th0 + 2 * math.pi
    n = 28

    def pt(rad, th, z):
        return Vector(((a + g + rad) * math.cos(th) * MM, (cy + (b + g + rad) * math.sin(th)) * MM,
                       z * MM))

    ths = [t0 + (t1 - t0) * i / n for i in range(n + 1)]
    inner = [[pt(0, th, -w / 2), pt(0, th, w / 2)] for th in ths]
    outer = [[pt(t, th, -w / 2), pt(t, th, w / 2)] for th in ths]
    mb.add_grid(inner, "Strap", flip=False, smooth=True)
    mb.add_grid(outer, "Strap", flip=True, smooth=True)
    for zi, z in enumerate((-w / 2, w / 2)):
        edge = [[pt(0, th, z), pt(t, th, z)] for th in ths]
        mb.add_grid(edge, "Strap", flip=bool(zi), smooth=False)
    for th, sg in ((ths[0], 1), (ths[-1], -1)):
        q = [mb.add_vert(pt(r_, th, z)) for r_, z in ((0, -w / 2), (t, -w / 2), (t, w / 2), (0, w / 2))]
        mb.add_face(q if sg > 0 else list(reversed(q)), "Strap", smooth=False)
    # пряжка: рамка из четырёх планок на боку ремешка (азимут −25° от +X)
    th = math.radians(-25)
    pos = Vector(((a + g + t) * math.cos(th) * MM, (cy + (b + g + t) * math.sin(th)) * MM, 0))
    tang = Vector((-(a + g + t) * math.sin(th), (b + g + t) * math.cos(th), 0)).normalized()
    nrm = Vector((tang.y, -tang.x, 0))
    rot = Matrix((tang, nrm, Vector((0, 0, 1)))).transposed()
    bw, bl, bt = w + 3.0, 9.0, 1.4
    for off, size in (((-bl / 2, 0, 0), (1.6, bt, bw)), ((bl / 2, 0, 0), (1.6, bt, bw)),
                      ((0, 0, -bw / 2 + 0.8), (bl, bt, 1.6)), ((0, 0, bw / 2 - 0.8), (bl, bt, 1.6))):
        c = pos + rot @ Vector(off) * MM + nrm * (bt / 2 + 0.2) * MM
        mb.add_box(c, tuple(s * MM for s in size), "Buckle", rot=rot)
    return mb


def build_card(mats):
    mb = U.MeshBuilder()
    R = CARD_D / 2
    ht = P["card_t_mm"] / 2
    n = 48
    bgpix = (0.02, 0.02)   # угол текстуры — фон

    def ring(y):
        return [Vector((R * math.cos(2 * math.pi * k / n) * MM, y * MM,
                        R * math.sin(2 * math.pi * k / n) * MM)) for k in range(n)]

    top = [mb.add_vert(p) for p in ring(ht)]
    uv = [(0.5 - p[0] / (CARD_D * MM), 0.5 + p[2] / (CARD_D * MM))
          for p in (mb.verts[i] for i in top)]
    mb.add_face(top, "Card", uv=uv, smooth=False)
    bot = [mb.add_vert(p) for p in ring(-ht)]
    mb.add_face(list(reversed(bot)), "Card", uv=[bgpix] * n, smooth=False)
    mb.add_grid([ring(ht), ring(-ht)], "Card", uv=[[bgpix] * n] * 2, flip=True, wrap=True,
                smooth=False)
    return mb


def build_lubber():
    mb = U.MeshBuilder()
    r0, r1 = P["lubber_r0_mm"], P["well_r_mm"] + 0.6
    w, t = P["lubber_w_mm"], P["lubber_t_mm"]
    # клин-трапеция в плоскости XZ: узкий конец к центру, широкий — у стенки
    quad = [(-w * 0.2, r0), (w * 0.2, r0), (w * 0.5, r1), (-w * 0.5, r1)]   # (x, z) мм
    lo = [mb.add_vert(Vector((x * MM, -t / 2 * MM, z * MM))) for x, z in quad]
    hi = [mb.add_vert(Vector((x * MM, t / 2 * MM, z * MM))) for x, z in quad]
    mb.add_face(hi, "Mark", smooth=False)
    mb.add_face(list(reversed(lo)), "Mark", smooth=False)
    for i in range(4):
        j = (i + 1) % 4
        mb.add_face([lo[i], lo[j], hi[j], hi[i]], "Mark", smooth=False)
    return mb


def main() -> None:
    U.reset_scene()
    c = P["colors_srgb"]
    img_arr, bg, ink, red = paint_card()
    # контраст по яркости (PH-К4: ≥ 4:1)
    lb, li, lr, ll = _lum(c["card_bg"]), _lum(c["card_ink"]), _lum(c["card_red"]), _lum(c["lubber"])
    ratio = lambda a, b: (max(a, b) + 0.05) / (min(a, b) + 0.05)  # noqa: E731
    print("CONTRAST ink/bg %.1f red/bg %.1f lubber/bg %.1f lubber/ink %.1f"
          % (ratio(li, lb), ratio(lr, lb), ratio(ll, lb), ratio(ll, li)))
    assert ratio(li, lb) >= 4 and ratio(lr, lb) >= 4 and ratio(ll, lb) >= 4
    tex = U.image_from_array("CompassCard", img_arr, "")
    mats = {
        "Case": U.material("CompassCase", U.srgb(c["case"]), rough=0.55),
        "Bezel": U.material("CompassBezel", U.srgb(c["bezel"]), rough=0.35, metal=0.7),
        "Strap": U.material("CompassStrap", U.srgb(c["strap"]), rough=0.9, double=True),
        "Buckle": U.material("CompassBuckle", U.srgb(c["buckle"]), rough=0.4, metal=0.8),
        "Card": U.material("CompassCard", (1, 1, 1), rough=0.6, image=tex),
        "Mark": U.material("CompassMark", U.srgb(c["lubber"]), rough=0.5),
        "Glass": U.material("CompassGlass", (1, 1, 1), rough=0.08, double=True),
    }
    gm = mats["Glass"]
    b = gm.node_tree.nodes["Principled BSDF"]
    b.inputs["Alpha"].default_value = 0.08
    b.inputs["Specular IOR Level"].default_value = 0.3
    gm.surface_render_method = "BLENDED"
    try:
        gm.blend_method = "BLEND"
    except Exception:
        pass

    build_case().build("Case", mats)
    build_strap().build("Strap", mats)
    card = build_card(mats).build("Card", mats)
    card.location = (0, P["card_y_mm"] * MM, 0)
    lub = build_lubber().build("Lubber", mats)
    lub.location = (0, P["lubber_y_mm"] * MM, 0)
    build_glass().build("Glass", mats)
    U.export("wrist_compass")


if __name__ == "__main__":
    main()
