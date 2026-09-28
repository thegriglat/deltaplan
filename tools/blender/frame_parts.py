"""Мелкие детали трапеции для build_gliders.py: пластины узлов, болты с гайками, наконечники тросов
(ушко + коуш + обжимная втулка), профильная (каплевидная) труба, стропа подвески и карабин.
Всё строится в MeshBuilder (bl_util) по месту, параметрически. Оси Blender: X вправо, +Y вперёд, Z вверх.
Размеры — docs/research/control_frame_refs.md.
"""
import math

from mathutils import Vector


def add_prism(mb, pts2d, origin, ex, ey, thickness: float, mat: str) -> None:
    """Плоская пластина: контур pts2d (против часовой в осях ex, ey), толщина вдоль ex × ey."""
    o = Vector(origin)
    n = ex.cross(ey).normalized() * (thickness * 0.5)
    ring = [o + ex * x + ey * y for x, y in pts2d]
    top = [mb.add_vert(p + n) for p in ring]
    bot = [mb.add_vert(p - n) for p in ring]
    mb.add_face(top, mat, smooth=False)
    mb.add_face(list(reversed(bot)), mat, smooth=False)
    k = len(ring)
    for i in range(k):
        j = (i + 1) % k
        q = [mb.add_vert(ring[i] - n), mb.add_vert(ring[j] - n), mb.add_vert(ring[j] + n),
             mb.add_vert(ring[i] + n)]
        mb.add_face(q, mat, smooth=False)


def rounded_outline(pts2d, r: float, seg: int = 3) -> list:
    """Скруглить углы выпуклого многоугольника (для пластин узлов)."""
    out = []
    k = len(pts2d)
    for i in range(k):
        p = Vector(pts2d[i])
        a = (Vector(pts2d[i - 1]) - p).normalized()
        b = (Vector(pts2d[(i + 1) % k]) - p).normalized()
        p0, p1 = p + a * r, p + b * r
        for s in range(seg + 1):
            t = s / seg
            q = p0.lerp(p, t).lerp(p.lerp(p1, t), t)  # квадратичная Безье
            out.append((q.x, q.y))
    return out


def add_bolt(mb, center, axis, length: float, r: float, mat: str) -> None:
    """Болт поперёк узла: стержень + шестигранная головка и гайка на концах."""
    c = Vector(center)
    ax = Vector(axis).normalized()
    h = length * 0.5
    mb.add_tube([c - ax * h, c + ax * h], r, mat, sides=6)
    for s in (-1, 1):
        p = c + ax * (s * h)
        mb.add_tube([p - ax * 0.0035, p + ax * 0.0035], r * 1.9, mat, sides=6)


def add_wire_end(mb, anchor, wire_to, bolt_axis, wire_r: float, mat: str,
                 tang_len: float = 0.035) -> Vector:
    """Наконечник троса у болта anchor: ушко-пластина (tang) к тросу, коуш-петля, обжимная
    втулка. Возвращает точку, откуда начинается сам трос."""
    a = Vector(anchor)
    d = (Vector(wire_to) - a).normalized()
    bax = Vector(bolt_axis).normalized()
    # ушко: плоская пластина в плоскости (d, ⊥болту), с отверстием-скруглением на концах
    ey = bax.cross(d).normalized()
    w = 0.0065
    pts = rounded_outline([(-0.006, -w), (tang_len, -w * 0.8), (tang_len, w * 0.8), (-0.006, w)],
                          0.004, 1)
    add_prism(mb, [(y, x) for x, y in pts], a, ey, d, 0.0025, mat)
    # коуш — петля троса вокруг конца ушка (кольцо в плоскости d–ey)
    tc = a + d * (tang_len + 0.004)
    ring = [tc + d * (0.009 * math.cos(2 * math.pi * i / 8)) + ey * (0.005 * math.sin(2 * math.pi * i / 8))
            for i in range(8)]
    mb.add_tube(ring, 0.0022, mat, sides=4, closed=True)
    # обжимная втулка (никопресс) по тросу
    s0 = tc + d * 0.012
    mb.add_tube([s0, s0 + d * 0.028], max(wire_r * 1.9, 0.0055), mat, sides=6,
                ellipse=(1.0, 0.7), up=tuple(ey))
    return s0 + d * 0.02


def airfoil_ring(n: int, chord: float, thick: float, le_frac: float):
    """Каплевидное сечение обтекателя стойки: [(поперёк, вдоль хорды)] — вдоль хорды +вперёд,
    ось трубы на le_frac хорды от носка."""
    pts = []
    half = n // 2
    for i in range(n):
        if i <= half:
            t = 1 - (1 - math.cos(math.pi * i / half)) / 2  # от хвоста (1) к носку (0)
            s = 1
        else:
            t = (1 - math.cos(math.pi * (i - half) / half)) / 2
            s = -1
        th = 5 * thick / chord * (0.2969 * math.sqrt(t) - 0.126 * t - 0.3516 * t ** 2
                                  + 0.2843 * t ** 3 - 0.1036 * t ** 4)
        pts.append((s * th * chord, (le_frac - t) * chord))
    return pts


def add_profile_tube(mb, pts, profile, fwd, mat: str) -> None:
    """Труба с произвольным сечением profile [(a, b)]: a — поперёк (fwd × ось), b — вдоль fwd
    (проекция fwd на плоскость сечения). Для обтекателя — хорда по потоку (+Y)."""
    pts = [Vector(p) for p in pts]
    n = len(pts)
    f0 = Vector(fwd)
    rings = []
    for i, p in enumerate(pts):
        t = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized()
        f = (f0 - t * f0.dot(t)).normalized()
        a = t.cross(f).normalized()
        rings.append([p + a * x + f * y for x, y in profile])
    mb.add_grid(rings, mat, flip=False, wrap=True)
    for ring, rev in ((rings[0], False), (rings[-1], True)):
        idx = [mb.add_vert(v) for v in ring]
        mb.add_face(list(reversed(idx)) if rev else idx, mat, smooth=False)


def add_webbing_loop(mb, pts, width: float, mat: str, normal) -> None:
    """Плоская стропа по замкнутой ломаной pts (ширина width поперёк плоскости петли)."""
    mb.add_tube(pts, width * 0.5, mat, sides=4, closed=True, ellipse=(0.08, 1.0),
                up=tuple(Vector(normal).normalized()), smooth=False)


def stadium(c_top, r_top: float, c_bot, r_bot: float, ex, n: int = 20) -> list:
    """Замкнутый контур «стадион» в плоскости (ex, вертикаль c_top−c_bot) вокруг двух окружностей
    (трубы киля сверху и перекладины карабина снизу)."""
    ct, cb = Vector(c_top), Vector(c_bot)
    up = (ct - cb).normalized()
    out = []
    for i in range(n + 1):  # верхняя полуокружность справа → слева
        a = math.pi * i / n
        out.append(ct + ex * (r_top * math.cos(a)) + up * (r_top * math.sin(a)))
    for i in range(n // 2 + 1):  # нижняя
        a = math.pi + math.pi * i / (n // 2)
        out.append(cb + ex * (r_bot * math.cos(a)) + up * (r_bot * math.sin(a)))
    return out


def add_carabiner(mb, top, height: float, width: float, rod_r: float, mat: str,
                  gate_mat: str) -> None:
    """Карабин-«D» в плоскости YZ: верхняя перекладина в top, спинка сзади (−Y), муфта на
    защёлке спереди."""
    t = Vector(top)
    pts = []
    n = 26
    for i in range(n):
        a = 2 * math.pi * i / n
        # D-форма: суперэллипс, спинка прямее
        cy, cz = math.cos(a), math.sin(a)
        y = (abs(cy) ** 0.7) * math.copysign(1, cy) * width * 0.5
        z = (abs(cz) ** 0.8) * math.copysign(1, cz) * height * 0.5
        if cy < 0:
            y *= 1.0 - 0.15 * (1 - abs(cz))
        pts.append(t + Vector((0, y, z - height * 0.5 + rod_r)))
    mb.add_tube(pts, rod_r, mat, sides=6, closed=True)
    # муфта защёлки — толще, на передней стороне сверху
    g = t + Vector((0, width * 0.5 - rod_r * 0.3, -height * 0.3))
    mb.add_tube([g + Vector((0, 0, 0.014)), g - Vector((0, 0, 0.014))], rod_r * 1.8, gate_mat,
                sides=8)
