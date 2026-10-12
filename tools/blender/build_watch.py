"""Наручные часы пилота (левая рука, пустышка WristL): assets/models/watch.glb
(+ assets/source/watch.blend, текстуры assets/textures/watch/).

    blender --background --python tools/blender/build_watch.py

Параметры — tools/blender/watch.json (мм). Контракт PH-К4 v1 (docs/contracts/pilot-hud.md,
docs/guide/models.md → «Наручные часы»): начало координат — центр нижней плоскости корпуса на рукаве;
циферблат смотрит в −Z Godot (+Y Blender), «12 часов» и подвижные части при повороте 0 — к +Y Godot
(+Z Blender), заводная головка — на стороне +Y (PH-К4 v2), ушки ремешка — по ±X. Ремешок охватывает эллипс W×H (центр (0, 0, +H/2)
Godot = (0, −H/2, 0) Blender) с зазором. Ноды верхнего уровня: Case, Strap, Dial, Glass, HourHand,
MinuteHand; стрелки — с началом на оси циферблата, вращаются только вокруг своей Z Godot (Y Blender).
"""
import math
import os
import sys

import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402

P = U.load_json("tools/blender/watch.json")
MM = 0.001
TEX = U.SOURCE
SIDES = 40


def mm(v):
    return v * MM


# ---------- текстуры ----------

# Штриховой шрифт цифр: ломаные в рамке 0..1 × 0..1 (y вверх).
GLYPHS = {
    "0": [[(0.5 + 0.5 * math.cos(a), 0.5 + 0.5 * math.sin(a))
           for a in np.linspace(0, 2 * math.pi, 17)]],
    "1": [[(0.15, 0.78), (0.55, 1.0), (0.55, 0.0)]],
    "2": [[(0.02, 0.8), (0.3, 1.0), (0.75, 1.0), (1.0, 0.8), (0.9, 0.55), (0.0, 0.0), (1.0, 0.0)]],
    "3": [[(0.0, 0.9), (0.5, 1.0), (0.95, 0.85), (0.9, 0.6), (0.4, 0.52), (0.92, 0.42),
           (1.0, 0.2), (0.5, 0.0), (0.0, 0.1)]],
    "6": [[(0.9, 0.95), (0.4, 1.0), (0.05, 0.7), (0.0, 0.3), (0.2, 0.05), (0.6, 0.0),
           (0.95, 0.2), (0.9, 0.45), (0.5, 0.55), (0.1, 0.4)]],
    "9": [[(1.0 - x, 1.0 - y) for x, y in
           [(0.9, 0.95), (0.4, 1.0), (0.05, 0.7), (0.0, 0.3), (0.2, 0.05), (0.6, 0.0),
            (0.95, 0.2), (0.9, 0.45), (0.5, 0.55), (0.1, 0.4)]]],
}


def _seg_dist(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = np.clip(((px - ax) * dx + (py - ay) * dy) / max(dx * dx + dy * dy, 1e-9), 0, 1)
    return np.hypot(px - (ax + t * dx), py - (ay + t * dy))


def stroke_text(px, py, text, cx, cy, h, hw):
    """Расстояние до штрихов текста (мм): центр (cx, cy), высота h, полуширина штриха hw."""
    w = 0.62 * h
    gap = 0.22 * h
    total = len(text) * w + (len(text) - 1) * gap
    d = np.full(px.shape, 1e9)
    for i, ch in enumerate(text):
        x0 = cx - total / 2 + i * (w + gap)
        for line in GLYPHS[ch]:
            pts = [(x0 + x * w, cy - h / 2 + y * h) for x, y in line]
            for a, b in zip(pts[:-1], pts[1:]):
                d = np.minimum(d, _seg_dist(px, py, a, b))
    return d


def dial_texture() -> np.ndarray:
    n = P["dial_tex_px"]
    size = P["dial_d_mm"]
    # координаты пикселей в мм: x — вправо для зрителя (−X модели), y — вверх (к «12 часам»)
    u = (np.arange(n) + 0.5) / n
    px, py = np.meshgrid((u - 0.5) * size, (u - 0.5) * size)   # строка = v (0 — низ)
    k = n / size
    img = np.zeros((n, n, 3), dtype=np.float32) + 0.012        # чёрный циферблат
    white = np.zeros((n, n), dtype=np.float32)
    red = np.zeros((n, n), dtype=np.float32)

    def cov(dist, hw):   # покрытие с антиалиасингом в 1 пиксель
        return np.clip(0.5 + (hw - dist) * k, 0, 1)

    # 12 часовых меток у края: обычные 2,6 × 5 мм белые, на 12/3/6/9 — красные 3,6 × 7 мм (цифр нет)
    r_out = size / 2 - 1.0
    for h in range(12):
        a = math.radians(30 * h)
        dx, dy = math.sin(a), math.cos(a)           # от «12» по часовой (вправо = +px)
        main = h % 3 == 0
        ln, hw = (7.0, 1.8) if main else (5.0, 1.3)
        seg = _seg_dist(px, py, (dx * (r_out - ln), dy * (r_out - ln)), (dx * r_out, dy * r_out))
        if main:
            red = np.maximum(red, cov(seg, hw))
        else:
            white = np.maximum(white, cov(seg, hw))
    img += white[:, :, None] * (1.0 - 0.012)
    img = img * (1 - red[:, :, None]) + np.array([0.80, 0.02, 0.01], dtype=np.float32) * red[:, :, None]
    return img


def strap_texture() -> np.ndarray:
    w, h = P["strap_tex_px"]
    mw, mh = P["strap_tex_mm"]
    rng = np.random.default_rng(5)
    base = np.array([0.165, 0.150, 0.135], dtype=np.float32)
    noise = np.zeros((h, w), dtype=np.float32)
    for cells, amp in ((4, 0.5), (16, 0.3), (64, 0.2)):
        g = rng.random((cells, cells)).astype(np.float32)
        big = np.kron(g, np.ones((h // cells + 1, w // cells + 1), dtype=np.float32))[:h, :w]
        noise += amp * big
    noise = (noise - noise.mean()) * 0.5
    img = base[None, None, :] * (1.0 + noise[:, :, None] * 0.6)
    # мелкая кожаная «пупырка» и строчка по краям (светлая нить, штрих 2,4 мм через 4 мм)
    ky, kx = h / mh, w / mw
    ys = (np.arange(h) + 0.5) / ky
    xs = (np.arange(w) + 0.5) / kx
    X, Y = np.meshgrid(xs, ys)
    for edge in (2.0, mh - 2.0):
        line = np.clip(0.5 + (0.28 - np.abs(Y - edge)) * ky, 0, 1)
        dash = (np.mod(X, 4.0) < 2.4).astype(np.float32)
        img = img * (1 - 0.8 * (line * dash)[:, :, None]) + \
            np.array([0.42, 0.38, 0.30], dtype=np.float32) * (0.8 * (line * dash)[:, :, None])
    return img


# ---------- геометрия ----------

def lathe(mb, prof, mat, n=SIDES):
    """Тело вращения вокруг оси Y Blender: prof — [(r, y)] снизу вверх; зазоров нет."""
    rings = [[Vector((r * math.cos(2 * math.pi * k / n), y, r * math.sin(2 * math.pi * k / n)))
              for k in range(n)] for r, y in prof]
    mb.add_grid(rings, mat, wrap=True, flip=True)


def disc(mb, r, y, mat, up=True, n=SIDES):
    idx = [mb.add_vert((r * math.cos(2 * math.pi * k / n), y, r * math.sin(2 * math.pi * k / n)))
           for k in range(n)]
    mb.add_face(idx if not up else list(reversed(idx)), mat, smooth=False)


def build_case(mb):
    rc = mm(P["case_d_mm"]) / 2
    top = mm(P["case_top_mm"])
    yd = mm(P["dial_y_mm"])
    rd = mm(P["dial_d_mm"]) / 2
    prof = [(rc - mm(1.2), 0.0), (rc, mm(1.0)), (rc, mm(9.2)), (rc - mm(0.3), mm(10.2)),
            (rc - mm(0.9), top - mm(0.4)), (rc - mm(1.6), top),
            (rd + mm(0.4), top - mm(0.2)), (rd + mm(0.2), yd + mm(1.0)), (rd, yd)]
    lathe(mb, prof, "Case")
    disc(mb, rc - mm(1.2), 0.0, "Case", up=False)       # дно (на рукаве)
    # заводная головка на стороне +Y Godot (+Z Blender, к пальцам; PH-К4 v2): ножка и рифлёная головка
    yc = mm(6.0)
    mb.add_tube([(0, yc, rc - mm(0.5)), (0, yc, rc + mm(1.2))], mm(1.3), "Case", sides=12,
                up=(0, 1, 0))
    mb.add_tube([(0, yc, rc + mm(1.2)), (0, yc, rc + mm(3.4))], mm(2.4), "Case", sides=12,
                up=(1, 0, 0))
    # ушки: на концах ремешка (по ±X), вровень с ремешком по ширине
    sw = mm(P["strap_width_mm"])
    for sx in (-1, 1):
        mb.add_box((sx * (rc - mm(0.2)), mm(1.7), 0), (mm(3.0), mm(3.4), sw), "Case")


def strap_path():
    """Ломаная ремешка в плоскости XY Blender: от правого ушка по эллипсу сечения снизу к левому."""
    w, h = mm(P["ellipse_w_mm"]), mm(P["ellipse_h_mm"])
    t = mm(P["strap_thick_mm"])
    gap = mm(P["strap_gap_mm"])
    a, b = w / 2 + gap + t / 2, h / 2 + gap + t / 2
    cy = -h / 2
    rc = mm(P["case_d_mm"]) / 2
    phi0 = math.asin(min((rc + mm(1.0)) / a, 0.95))
    pts = [(rc - mm(0.4), mm(1.2))]
    n = 56
    for i in range(n + 1):
        phi = phi0 + (2 * math.pi - 2 * phi0) * i / n
        pts.append((a * math.sin(phi), cy + b * math.cos(phi)))
    pts.append((-(rc - mm(0.4)), mm(1.2)))
    return pts, a, b


def build_strap(mb):
    pts, a, b = strap_path()
    t = mm(P["strap_thick_mm"])
    hw = mm(P["strap_width_mm"]) / 2
    n = len(pts)
    tex_w = mm(P["strap_tex_mm"][0])
    # длина вдоль ломаной — для UV
    s = [0.0]
    for p, q in zip(pts[:-1], pts[1:]):
        s.append(s[-1] + math.hypot(q[0] - p[0], q[1] - p[1]))
    rings, uvs, frames = [], [], []
    for i, p in enumerate(pts):
        tg = Vector((pts[min(i + 1, n - 1)][0] - pts[max(i - 1, 0)][0],
                     pts[min(i + 1, n - 1)][1] - pts[max(i - 1, 0)][1], 0)).normalized()
        nn = Vector((tg.y, -tg.x, 0))      # наружу эллипса (при обходе по часовой снаружи)
        c = Vector((p[0], p[1], 0))
        frames.append((c, tg, nn))
        # углы сечения: внутр.-левый, внешн.-левый, внешн.-правый, внутр.-правый (по Z)
        corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        rings.append([c + nn * (t / 2 * cn) + Vector((0, 0, hw * cz)) for cn, cz in corners])
        u = s[i] / tex_w
        uvs.append([(u, 0.0), (u, 0.0), (u, 1.0), (u, 1.0)])
    # грани по сторонам: наружная (cn=1) и внутренняя (cn=-1) — полная ширина; боковые — по толщине
    # UV: v = 0..1 поперёк ширины; боковые кромки — v=0/1
    for j, (j2) in enumerate([1, 2, 3, 0]):
        uvj = []
        for i in range(n):
            if j in (0, 2):     # кромки по Z=−hw (j=0: внутр→внешн) и Z=+hw (j=2)
                v0 = v1 = 0.0 if j == 0 else 1.0
            elif j == 1:        # внешняя сторона: поперёк ширины
                v0, v1 = 0.0, 1.0
            else:               # внутренняя
                v0, v1 = 1.0, 0.0
            uvj.append(((s[i] / tex_w, v0), (s[i] / tex_w, v1)))
        for i in range(n - 1):
            q = [rings[i][j], rings[i + 1][j], rings[i + 1][j2], rings[i][j2]]
            fuv = [uvj[i][0], uvj[i + 1][0], uvj[i + 1][1], uvj[i][1]]
            idx = [mb.add_vert(v) for v in q]
            # наружу от оси сечения: проверяем по нормали грани
            mid = sum(q, Vector()) / 4
            nrm = (q[1] - q[0]).cross(q[3] - q[0])
            cen = frames[i][0]
            if nrm.dot(mid - cen) < 0:
                idx.reverse()
                fuv.reverse()
            mb.add_face(idx, "Strap", uv=fuv, smooth=False)
    for ring, rev in ((rings[0], False), (rings[-1], True)):
        idx = [mb.add_vert(v) for v in ring]
        c = sum(ring, Vector()) / 4
        nrm = (ring[1] - ring[0]).cross(ring[3] - ring[0])
        out = frames[0][1] * -1 if not rev else frames[-1][1]
        if nrm.dot(out) < 0:
            idx.reverse()
        mb.add_face(idx, "Strap", smooth=False)
    # пряжка: рамка у нижней-левой части ремешка (на ~230° по эллипсу)
    phi = math.radians(232)
    c = Vector((a * math.sin(phi), -mm(P["ellipse_h_mm"]) / 2 + b * math.cos(phi), 0))
    tg = Vector((a * math.cos(phi), -b * math.sin(phi), 0)).normalized()
    nn = Vector((tg.y, -tg.x, 0))
    rot = Matrix(((tg.x, nn.x, 0), (tg.y, nn.y, 0), (0, 0, 1)))
    off = nn * (t / 2 + mm(1.0))
    for dx in (-4.5, 4.5):
        mb.add_box(c + off + tg * mm(dx), (mm(1.8), mm(3.0), mm(22.4)), "Case", rot=rot)
    for dz in (-10.8, 10.8):
        mb.add_box(c + off + Vector((0, 0, mm(dz))), (mm(10.8), mm(3.0), mm(1.8)), "Case", rot=rot)
    # язычок пряжки поперёк рамки
    mb.add_box(c + off, (mm(1.2), mm(3.4), mm(20)), "Case", rot=rot)


def hand_outline(length, w, tail):
    # заострённый «батон»: хвост, плечи, остриё; (x, z) в плоскости циферблата, острие к +Z
    hw = w / 2
    return [(-0.6 * hw, -tail), (0.6 * hw, -tail), (hw, mm(1.0)), (hw, length - mm(3.5)),
            (0.0, length), (-hw, length - mm(3.5)), (-hw, mm(1.0))]


def build_hand(name, mats, y0, length, w, cap_r, cap_y):
    th = mm(P["hand_thick_mm"])
    mb = U.MeshBuilder()
    pts = hand_outline(length, w, mm(3.0))
    bot = [mb.add_vert((x, 0.0, z)) for x, z in pts]
    top = [mb.add_vert((x, th, z)) for x, z in pts]
    mb.add_face(list(reversed(top)), "Hand", smooth=False)
    mb.add_face(bot, "Hand", smooth=False)
    k = len(pts)
    for i in range(k):
        j = (i + 1) % k
        mb.add_face([bot[j], bot[i], top[i], top[j]], "Hand", smooth=False)
    mb.add_tube([(0, cap_y[0], 0), (0, cap_y[1], 0)], cap_r, "Hand", sides=16, up=(1, 0, 0))
    ob = mb.build(name, mats)
    ob.location = (0.0, y0, 0.0)
    return ob


def main():
    U.reset_scene()
    os.makedirs(TEX, exist_ok=True)
    dial_img = U.image_from_array("dial", dial_texture(),
                                  os.path.join(TEX, "watch_dial.png"))
    strap_img = U.image_from_array("strap", strap_texture(),
                                   os.path.join(TEX, "watch_strap.png"))
    mats = {
        "Case": U.material("WatchCase", U.srgb((0.46, 0.47, 0.49)), rough=0.42, metal=0.55),
        "Strap": U.material("WatchStrap", (1, 1, 1), rough=0.85, image=strap_img),
        "Screen": U.material("WatchDial", (1, 1, 1), rough=0.55, image=dial_img),
        "Hand": U.material("WatchHand", U.srgb((0.97, 0.97, 0.92)), rough=0.6),
        "Glass": U.material("WatchGlass", U.srgb((0.9, 0.95, 1.0)), rough=0.12),
    }
    g = mats["Glass"]
    g.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value = 0.08
    g.node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.15
    g.surface_render_method = "BLENDED"
    if hasattr(g, "blend_method"):
        g.blend_method = "BLEND"
    g.use_backface_culling = False

    mb = U.MeshBuilder()
    build_case(mb)
    mb.build("Case", mats)

    mb = U.MeshBuilder()
    build_strap(mb)
    mb.build("Strap", mats)

    U.screen_quad((mm(P["dial_d_mm"]),) * 2, mm(P["dial_y_mm"]), 0.0, circle_seg=48).build(
        "Dial", mats)

    mb = U.MeshBuilder()
    disc(mb, mm(P["dial_d_mm"]) / 2 + mm(0.1), mm(P["glass_y_mm"]), "Glass")
    mb.build("Glass", mats)

    rdial = mm(P["dial_d_mm"]) / 2
    hy, my = mm(P["hour_y_mm"]), mm(P["minute_y_mm"])
    build_hand("HourHand", mats, hy, P["hour_len_k"] * rdial, mm(P["hour_w_mm"]),
               mm(2.0), (mm(P["dial_y_mm"]) - hy + mm(0.3), my - hy))
    build_hand("MinuteHand", mats, my, P["minute_len_k"] * rdial, mm(P["minute_w_mm"]),
               mm(1.4), (0.0, mm(1.4)))
    U.export("watch")


if __name__ == "__main__":
    main()
