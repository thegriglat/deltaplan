"""Модели трёх крыльев дельтаплана: assets/models/glider_<id>.glb (+ assets/source/*.blend).

Запуск из корня проекта:
    blender --background --python tools/blender/build_gliders.py [-- training laminar sport]

Параметры формы — tools/blender/glider_params.json, размах и площадь — configs/wings/<id>.json
(нет конфига — span_m/area_m2 из самой записи glider_params: модель можно строить до конфига).
Контракт имён (docs/models.md): меши Sail, Frame, ControlFrame; пустышки HangPoint (= начало
координат), BaseBar, InstrumentMount (центр базовой штанги, −Z Godot смотрит на глаза пилота),
VarioMount (на базовой штанге слева от планшета), WingTipL, WingTipR. Оси Blender: X вправо, +Y вперёд (нос), Z вверх.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import sail_maps  # noqa: E402
import sail_texture  # noqa: E402
import frame_parts as F  # noqa: E402

SPAN_STATIONS = 44       # на полуразмах
CHORD_STATIONS = 22
WIRE_R = 0.0045


class WingShape:
    """Геометрия паруса: u ∈ [−1, 1] по размаху (− слева), t ∈ [0, 1] от передней кромки."""

    def __init__(self, p: dict, cf: dict, span: float):
        self.p = p
        self.half = span * 0.5
        self.tan_ha = math.tan(math.radians(p["nose_angle_deg"] * 0.5))
        self.y_nose = p["nose_forward_m"]
        self.z0 = cf["keel_z_m"] + 0.035
        self.dih = math.tan(math.radians(p["dihedral_deg"]))
        self.wash = math.radians(p["washout_deg"])
        self.tip_round = p.get("tip_round", True)   # False — «рубленая» законцовка 1980-х

    def chord(self, a: float) -> float:
        c = self.p["tip_chord_m"] + (self.p["root_chord_m"] - self.p["tip_chord_m"]) * (1 - a ** 0.85)
        if a > 0.9 and self.tip_round:  # скруглённая законцовка
            c *= 1.0 - 0.35 * ((a - 0.9) / 0.1) ** 2
        return c

    def le(self, u: float) -> Vector:
        a = abs(u)
        y = self.y_nose - a * self.half / self.tan_ha
        if a > 0.9 and self.tip_round:
            y -= 0.35 * self.p["tip_chord_m"] * ((a - 0.9) / 0.1) ** 2 * 0.6
        # dihedral_deg — поперечное V в полёте (кромки уже изогнуты нагрузкой); прямая линия
        z = self.z0 + a * self.half * self.dih
        return Vector((u * self.half, y, z))

    def camber(self, a: float) -> float:
        c0, c1, c2 = self.p["camber"]
        if a < 0.4:
            return c0 + (c1 - c0) * math.sin(a / 0.4 * math.pi / 2)
        return c1 + (c2 - c1) * ((a - 0.4) / 0.6) ** 1.5

    def thickness(self, a: float) -> float:
        return self.p["le_thickness"] * (1 - 0.45 * a) * (1 - a ** 8)

    @staticmethod
    def naca(t: float) -> float:
        t = max(t, 0.0)
        return 10 * (0.2969 * math.sqrt(t) - 0.126 * t - 0.3516 * t ** 2 + 0.2843 * t ** 3
                     - 0.1015 * t ** 4)

    def mean(self, u: float, t: float) -> Vector:
        a = abs(u)
        le = self.le(u)
        c = self.chord(a)
        th = self.wash * a ** 1.3
        f = math.sin(math.pi * t ** 0.75)
        # немного «пузыря» у задней кромки между латами не моделируем
        return Vector((le.x, le.y - t * c * math.cos(th),
                       le.z + c * (self.camber(a) * f + t * math.sin(th))))

    def upper(self, u: float, t: float) -> Vector:
        p = self.mean(u, t)
        if self.p["double_surface"]:
            p.z += 0.25 * self.thickness(abs(u)) * self.chord(abs(u)) * self.naca(t)
        return p

    def lower(self, u: float, tl: float) -> Vector:
        """tl ∈ [0, 1] — доля нижней обшивки (0 — кромка, 1 — где она сходится с верхней)."""
        cov = self.p["lower_cover"]
        t = tl * cov
        p = self.upper(u, t)
        w = 1 - tl ** 3
        k = 1.0 if self.p["double_surface"] else 0.6
        p.z -= k * self.thickness(abs(u)) * self.chord(abs(u)) * self.naca(t) * w
        return p


def stations(n: int, cos_spacing: bool) -> list:
    if cos_spacing:
        return [(1 - math.cos(math.pi * i / n)) / 2 for i in range(n + 1)]
    return [i / n for i in range(n + 1)]


def span_stations(n_batt: int) -> list:
    """Станции по полуразмаху a ∈ [0, 1], совпадающие с латами (a_k = k/n·0.97): между
    соседними латами — несколько станций, чтобы парус мог «дышать» между ними.
    Возвращает [(a, вес_пролёта)]: вес 0 на лате, 1 — посередине между латами."""
    seg = max(3, round(SPAN_STATIONS / n_batt))
    out = []
    for k in range(n_batt):
        a0, a1 = k / n_batt * 0.97, (k + 1) / n_batt * 0.97
        for q in range(seg):
            f = q / seg
            out.append((a0 + (a1 - a0) * f, math.sin(math.pi * f)))
    out += [(0.97, 0.0), (0.985, 0.0), (1.0, 0.0)]
    return out


def build_sail(ws: WingShape, mats: dict):
    """Парус. Вторая UV (UV2 в Godot) — маска для шейдера паруса (assets/shaders/sail/):
    UV2.x — вес пролёта между латами (0 на лате, 1 посередине), UV2.y — доля хорды t
    (0 — передняя кромка, 1 — задняя); у нижней обшивки к UV2.y прибавлено 2."""
    mb = U.MeshBuilder()
    half = span_stations(ws.p["battens_per_side"])
    st = [(-a, w) for a, w in reversed(half)] + half[1:]
    us = [u for u, _ in st]
    ts = stations(CHORD_STATIONS, True)
    top = [[ws.upper(u, t) for t in ts] for u in us]
    top_uv = [[((u + 1) / 2, t * 0.5) for t in ts] for u in us]
    top_col = [[(w, t) for t in ts] for _, w in st]
    mb.add_grid(top, "Sail", top_uv, flip=True, colors=top_col)
    tls = stations(14, True)
    cov = ws.p["lower_cover"]
    bot = [[ws.lower(u, tl) for tl in tls] for u in us]
    bot_uv = [[((u + 1) / 2, 0.5 + tl * 0.5) for tl in tls] for u in us]
    bot_col = [[(w, 2.0 + tl * cov) for tl in tls] for _, w in st]
    mb.add_grid(bot, "Sail", bot_uv, flip=False, colors=bot_col)
    if ws.p.get("keel_pocket_m", 0.0) > 0:
        add_keel_pocket(ws, mb)
    return mb.build("Sail", mats)


def root_underside_z(ws: WingShape, t: float) -> float:
    """Высота нижней стороны паруса над килем (u = 0) на доле корневой хорды t."""
    cov = ws.p["lower_cover"]
    if t < cov:
        return ws.lower(0.0, t / cov).z
    return ws.upper(0.0, t).z


def keel_pocket_depth(ws: WingShape, y: float, y_te: float) -> float:
    """Глубина килевого кармана под килем, м: невысокий клин впереди, вырез у узла трапеции
    и точки подвеса (y ∈ [−0,15; 0,5]), глубже всего (keel_pocket_m) у хвоста, срез к задней кромке."""
    d = ws.p["keel_pocket_m"]
    if y > 0.5:
        return 0.3 * d * math.sin(math.pi * (ws.y_nose - y) / (ws.y_nose - 0.5))
    if y > -0.15:
        return 0.0
    s = (-0.15 - y) / (-0.15 - y_te)
    return d * min(1.0, s / 0.8) ** 0.7 * (1 - 0.65 * max(0.0, (s - 0.85) / 0.15))


def add_keel_pocket(ws: WingShape, mb) -> None:
    """Высокий килевой карман: «плавник» из паруса под килем (плоскость x = 0), от носа к
    задней кромке корня. Текстура — корень верхней обшивки (чуть в стороне от центральной латы),
    UV2: вес пролёта 0 (не колышется), верхний ряд идёт за парусом (доля хорды), нижний — 0."""
    kz = ws.z0 - 0.035
    root = ws.chord(0.0)
    y_te = ws.y_nose - root
    n = 40
    pts, uv, col = [], [], []
    for i in range(n + 1):
        t = i / n
        y = ws.y_nose - t * root
        top = root_underside_z(ws, t)
        dep = keel_pocket_depth(ws, y, y_te)
        bot = min(top, kz) - dep
        pts.append([Vector((0, y, top)), Vector((0, y, (top + bot) * 0.5)), Vector((0, y, bot))])
        uv.append([(0.52, t * 0.5)] * 3)
        col.append([(0.0, t), (0.0, 0.0), (0.0, 0.0)])
    mb.add_grid(pts, "Sail", uv, flip=False, colors=col)


def le_tube_point(ws: WingShape, u: float, r: float) -> Vector:
    """Центр трубы передней кромки — внутри кармана кромки."""
    t = 0.025
    up = ws.upper(u, t)
    if ws.p["double_surface"]:
        return (up + ws.lower(u, t / ws.p["lower_cover"])) * 0.5
    return up - Vector((0, 0, r * 1.1))


def inside_sail(ws: WingShape, p: Vector, margin: float = 0.04) -> Vector:
    """Опустить/поднять точку трубы так, чтобы она была под парусом (однообшивочное)
    или между обшивками (двухобшивочное)."""
    u = max(-1.0, min(1.0, p.x / ws.half))
    le = ws.le(u)
    t = max(0.0, min(1.0, (le.y - p.y) / ws.chord(abs(u))))
    up = ws.upper(u, t).z
    cov = ws.p["lower_cover"]
    if ws.p["double_surface"] and t < cov:
        return Vector((p.x, p.y, (up + ws.lower(u, t / cov).z) * 0.5))
    return Vector((p.x, p.y, min(p.z, up - margin)))


def sail_underside_z(ws: WingShape, u: float, t: float) -> float:
    """Высота нижней стороны паруса в точке (u, t): нижняя обшивка, за ней — верхняя."""
    cov = ws.p["lower_cover"]
    if t < cov:
        return ws.lower(u, t / cov).z
    return ws.upper(u, t).z


def add_antidive_tube(ws: WingShape, s: int, spec: dict, r_le: float, mb) -> None:
    """Антипикирующая трубка «Апогея» (со слов пилота): от законцовки передней кромки (a0)
    назад-внутрь под ~45° к задней кромке, пересекает последнюю полную лату и кончается на
    доле хорды t1 у станции a1. Идёт под парусом, снизу его подпирает; крепится к кромке."""
    r = spec.get("r_m", 0.01)
    p0 = le_tube_point(ws, s * spec["a0"], r_le)
    le1 = ws.le(s * spec["a1"])
    p1 = Vector((le1.x, le1.y - spec["t1"] * ws.chord(spec["a1"]), 0.0))
    pts = []
    for i in range(9):
        q = p0.lerp(p1, i / 8)
        u = q.x / ws.half
        t = max(0.0, min(1.0, (ws.le(u).y - q.y) / ws.chord(abs(u))))
        q.z = sail_underside_z(ws, u, t) - r - 0.006
        pts.append(q)
    pts[0] = p0 - Vector((0, 0, r_le * 0.6))
    mb.add_tube(pts, r, "Tube", sides=8)


def build_frame(ws: WingShape, p: dict, cf: dict, mats: dict):
    mb = U.MeshBuilder()
    kz = cf["keel_z_m"]
    r_le = 0.032
    wire_r = p.get("wire_r_m", WIRE_R)
    # передние кромки
    for s in (-1, 1):
        pts = [le_tube_point(ws, s * a, r_le) for a in [i / 30 * 0.97 for i in range(31)]]
        pts[0] = Vector((0, ws.y_nose - 0.03, kz + 0.02))
        mb.add_tube(pts, [r_le * (1 - 0.35 * i / 30) for i in range(31)], "Tube", sides=10)
    # киль
    tail_y = ws.y_nose - p["root_chord_m"] - p["keel_extra_m"]
    mb.add_tube([(0, ws.y_nose, kz), (0, tail_y, kz)], 0.025, "Tube", sides=10)
    mb.add_ellipsoid((0, ws.y_nose + 0.01, kz + 0.02), (0.06, 0.09, 0.05), "Dark", 10, 6)
    # поперечина
    cb_center = Vector((0, 0.08, kz + 0.04))
    for s in (-1, 1):
        j = le_tube_point(ws, s * p["crossbar_u"], r_le)
        c = cb_center + Vector((s * 0.03, 0, 0))
        pts = [inside_sail(ws, j.lerp(c, i / 12)) for i in range(13)]
        pts[0] = j
        mb.add_tube(pts, 0.03, "Tube", sides=10)
    # законцовки
    for s in (-1, 1):
        mb.add_ellipsoid(le_tube_point(ws, s * 0.975, r_le), (0.03, 0.05, 0.03), "Dark", 8, 5)
    if p.get("antidive_tube"):
        for s in (-1, 1):
            add_antidive_tube(ws, s, p["antidive_tube"], r_le, mb)
    top = None
    if p["kingpost_m"] > 0:
        apex_y = cf["apex_forward_m"]
        top = Vector((0, apex_y, kz + p["kingpost_m"]))
        mb.add_tube([(0, apex_y, kz), top], 0.022, "Tube", sides=8)
        mb.add_ellipsoid(top, (0.03, 0.03, 0.04), "Dark", 8, 5)
        targets = [Vector((0, ws.y_nose, kz + 0.03)), Vector((0, tail_y, kz + 0.02))]
        for s in (-1, 1):
            targets.append(le_tube_point(ws, s * p["crossbar_u"], r_le))
            for a in p["luff_lines"]:
                targets.append(ws.upper(s * a, 1.0))
        for tg in targets:
            mb.add_tube([top, tg], wire_r, "Wire", sides=6, cap=False)
    return mb.build("Frame", mats), tail_y


def convex_hull(pts) -> list:
    """Выпуклая оболочка точек 2D (против часовой)."""
    pts = sorted(set(pts))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, hi = [], []
    for q in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], q) <= 0:
            lo.pop()
        lo.append(q)
    for q in reversed(pts):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], q) <= 0:
            hi.pop()
        hi.append(q)
    return lo[:-1] + hi[:-1]


def add_apex(mb, kz: float, apex_y: float, top_x: float, top_z: float, r_up: float) -> None:
    """Узел стоек под килем: две щеки по бокам киля на болту через киль, снизу — ось стоек
    (болт поперёк) с наконечниками стоек снаружи щёк."""
    ex, ey = Vector((0, 1, 0)), Vector((0, 0, 1))
    cheek = F.rounded_outline([(-0.065, kz + 0.02), (0.065, kz + 0.02), (0.045, top_z - 0.022),
                               (-0.045, top_z - 0.022)], 0.012, 3)
    for s in (-1, 1):
        F.add_prism(mb, cheek, Vector((s * 0.03, apex_y, 0)), ex, ey, 0.005, "Dark")
    F.add_bolt(mb, (0, apex_y, kz), (1, 0, 0), 0.075, 0.004, "Steel")
    F.add_bolt(mb, (0, apex_y, top_z), (1, 0, 0), 2 * top_x + 2 * r_up + 0.012, 0.005, "Steel")


def add_hang(mb, kz: float) -> None:
    """Подвеска на киле у HangPoint: основная стропа-петля вокруг киля, карабин (верх — в петле,
    фал пилота — в начале координат внутри карабина) и страховочная петля подлиннее."""
    xa = Vector((1, 0, 0))
    F.add_webbing_loop(mb, F.stadium((0, 0.0, kz), 0.028, (0, 0.0, 0.016), 0.007, xa),
                       0.025, "Webbing", (0, 1, 0))
    F.add_webbing_loop(mb, F.stadium((0, -0.03, kz), 0.029, (0, -0.03, -0.055), 0.009, xa),
                       0.02, "WebbingBackup", (0, 1, 0))
    mb.add_tube([(0, -0.045, kz), (0, 0.02, kz)], 0.0275, "Webbing", sides=12)  # накладка на киле
    F.add_carabiner(mb, (0, 0.0, 0.018), 0.105, 0.058, 0.0055, "Steel", "Dark")


def add_corner(mb, c: Vector, top: Vector, s: int, r_up: float, r_bar: float) -> tuple:
    """Угол трапеции: две пластины в плоскости «стойка — штанга», болты стойки, штанги и тросов.
    Возвращает (точка болта тросов, ось болта)."""
    u = (top - c).normalized()
    e1 = Vector((s, 0, 0))
    n = u.cross(e1).normalized()
    e2 = n.cross(e1).normalized()
    if e2.z < 0:
        e2, n = -e2, -n
    u2 = (u.dot(e1), u.dot(e2))
    p2 = (-u2[1], u2[0])
    pts = [(-0.08, -0.024), (-0.08, 0.024), (0.03, -0.03), (0.03, 0.02), (0.005, -0.045)]
    for k in (0.1, 0.02):
        for q in (-1, 1):
            pts.append((u2[0] * k + p2[0] * q * 0.026, u2[1] * k + p2[1] * q * 0.026))
    outline = F.rounded_outline(convex_hull([(round(x, 5), round(y, 5)) for x, y in pts]),
                                0.01, 2)
    off = max(r_up, r_bar) + 0.004
    for q in (-1, 1):
        F.add_prism(mb, outline, c + n * (q * off), e1, e2, 0.004, "Dark")
    blen = 2 * off + 0.014
    for x, y in ((-0.058, 0.0), (u2[0] * 0.075, u2[1] * 0.075)):
        F.add_bolt(mb, c + e1 * x + e2 * y, n, blen, 0.004, "Steel")
    wa = c + e1 * 0.012 - e2 * 0.028
    F.add_bolt(mb, wa, n, blen, 0.0045, "Steel")
    return wa, n


def build_control_frame(ws: WingShape, p: dict, cf: dict, mats: dict, tail_y: float):
    mb = U.MeshBuilder()
    kz = cf["keel_z_m"]
    apex_y = cf["apex_forward_m"]
    top_x, top_z = cf["upright_top_x_m"], cf["upright_top_z_m"]
    w = p["basebar_width_m"] * 0.5
    y_bb = cf["basebar_forward_m"]
    z_bb = kz - cf["basebar_drop_m"]
    faired = p["faired_uprights"]
    r_up, r_bar = cf["upright_r_m"], cf["basebar_r_m"]
    wire_r = p.get("wire_r_m", WIRE_R)
    add_apex(mb, kz, apex_y, top_x, top_z, r_up)
    add_hang(mb, kz)
    bend = p.get("upright_bend", {})
    corners, anchors = [], []
    for s in (-1, 1):
        top = Vector((s * top_x, apex_y, top_z))
        c = Vector((s * w, y_bb, z_bb))
        dn = (c - top).normalized()  # наконечник стойки (втулка-«вилка») на оси узла
        mb.add_tube([top - dn * 0.016, top + dn * 0.055], r_up * 1.12, "Dark", sides=12)
        corners.append(c)
        # ось стойки: прямая или с изгибом в нижней части (bend: t0 — доля длины от верха, где
        # начинается изгиб, fwd_m — наибольший вынос вперёд, out_m — наружу)
        d = c - top
        fwd = Vector((0, 1, 0))
        fwd_perp = (fwd - d.normalized() * fwd.dot(d.normalized())).normalized()

        def point(t: float, top=top, d=d, fwd_perp=fwd_perp, s=s) -> Vector:
            q = top + d * t
            if bend and t > bend["t0"]:
                k = math.sin(math.pi * (t - bend["t0"]) / (1 - bend["t0"])) ** 1.5
                q += fwd_perp * (bend.get("fwd_m", 0.0) * k) + Vector((s, 0, 0)) * (bend.get("out_m", 0.0) * k)
            return q
        ts = [i / 10 for i in range(11)] if bend else [0.0, 1.0]
        axis = [point(t) for t in ts]
        if faired:
            # обтекатель от наконечника до ~7 см над углом; концы — круглая труба
            f0, f1 = 0.05 / d.length, 1 - 0.07 / d.length
            fa = [point(f0)] + [point(t) for t in ts if f0 < t < f1] + [point(f1)]
            prof = F.airfoil_ring(16, cf["fairing_chord_m"], cf["fairing_thick_m"], 0.3)
            F.add_profile_tube(mb, fa, prof, (0, 1, 0), "Tube")
            mb.add_tube([point(0.0), point(f0 + 0.01)], r_up * 0.95, "Tube", sides=12)
            mb.add_tube([point(f1 - 0.01), point(0.97), c], r_up, "Tube", sides=12)
        else:
            mb.add_tube(axis, r_up, "Tube", sides=16)
        wa, bax = add_corner(mb, c, point(0.9), s, r_up, r_bar)
        anchors.append((wa, bax))
    # базовая штанга (у безмачтовых — «спидбар»: ровная середина ниже, плавные изгибы к углам)
    dip = cf["speedbar_dip_m"] if faired else 0.0
    flat = cf["speedbar_flat_half_m"]
    left = [-(w + 0.035)] + [-w + (w - flat) * i / 6 for i in range(7)]
    xs = left + [-flat + 2 * flat * i / 4 for i in range(1, 4)] + [-x for x in reversed(left)]

    def bar_z(x: float) -> float:
        a = abs(x)
        if a <= flat:
            return z_bb - dip
        k = min(1.0, (a - flat) / (w - flat))
        return z_bb - dip * (1 - (3 * k * k - 2 * k ** 3))
    bar = [Vector((x, y_bb, bar_z(x))) for x in xs]
    mb.add_tube(bar, r_bar, "Tube", sides=14)
    for s in (-1, 1):  # заглушки концов штанги
        e = Vector((s * (w + 0.035), y_bb, z_bb))
        mb.add_tube([e, e + Vector((s * 0.012, 0, 0))], r_bar * 1.08, "Dark", sides=12)
    if p.get("bar_grips", True):  # резиновые накладки под руками
        g0, g1 = cf["bar_grip_x_m"]
        for s in (-1, 1):
            mb.add_tube([Vector((s * g0, y_bb, bar_z(g0))), Vector((s * g1, y_bb, bar_z(g1)))],
                        r_bar + 0.0025, "Grip", sides=16)
    if p["wheels"]:
        for s in (-1, 1):
            c = Vector((s * (w + 0.07), y_bb, z_bb))
            mb.add_tube([c - Vector((0.025, 0, 0)), c + Vector((0.025, 0, 0))], 0.1, "Wheel",
                        sides=16, up=(0, 1, 0))
    # нижние тросы: передние к носу, задние к килю, боковые к узлам поперечины; у угла —
    # наконечник (ушко + коуш + втулка), сам трос — материал Wire (по нему ленточка ищет трос)
    nose = Vector((0, ws.y_nose - 0.05, kz))
    tail = Vector((0, tail_y + 0.05, kz))
    for s, (wa, bax) in zip((-1, 1), anchors):
        ends = [nose, tail, le_tube_point(ws, s * p["crossbar_u"], 0.032)]
        if faired:  # у бескилевых — сдвоенные боковые тросы
            ends.append(le_tube_point(ws, s * (p["crossbar_u"] - 0.04), 0.032))
        for e in ends:
            w0 = F.add_wire_end(mb, wa, e, bax, wire_r, "Steel")
            mb.add_tube([w0, e], wire_r, "Wire", sides=8, cap=False)
    obj = mb.build("ControlFrame", mats)
    U.empty("BaseBar", (0, y_bb, z_bb - dip), parent=obj)
    eye = Vector(cf["_eye"])
    # планшет — на оси базовой штанги в центре, −Z (Godot) маркера смотрит на глаза пилота
    bar_c = Vector((0, y_bb, z_bb - dip))
    U.empty("InstrumentMount", None, parent=obj, matrix=U.look_matrix(bar_c, eye))
    # вариометр 90-х — на оси базовой штанги слева от планшета (между ним и левой рукой), тоже
    # экраном к глазам: при взгляде вниз (0°, −60°) в кадре штанга только между кулаками
    # (±0,35 м) — угол трапеции и стойки вне кадра при любой высоте на стойке
    xv = -cf["vario_bar_offset_m"]
    zv = bar_z(xv)
    # горизонталь циферблата — вдоль штанги (иначе в кадре сбоку от оси взгляда он «завален»)
    pv = Vector((xv, y_bb, zv))
    to_eye = (eye - pv).normalized()
    side = (Vector((-1, 0, 0)) + to_eye * to_eye.x).normalized()
    U.empty("VarioMount", None, parent=obj, matrix=U.look_matrix(pv, eye, up=side.cross(to_eye)))
    return obj


def build_wing(key: str, params: dict) -> None:
    p = params["wings"][key]
    cf = dict(params["control_frame"])
    cf["_eye"] = params["pilot_eye"]
    cfg_path = "configs/wings/%s.json" % p["config"]
    if os.path.exists(os.path.join(U.ROOT, cfg_path)):
        span = float(U.load_json(cfg_path)["span_m"])
    else:  # конфига крыла ещё нет — размах из glider_params
        span = float(p["span_m"])
    U.reset_scene()
    ws = WingShape(p, cf, span)
    tex = sail_texture.make(p, os.path.join(U.SOURCE, p["out"] + "_sail.png"), span)
    sail_maps.make(p)  # карта нормалей и просвечивания для шейдера паруса
    mats = {
        "Sail": U.material("Sail_" + key, (1, 1, 1), rough=p.get("sail_rough", 0.75), double=True, image=tex),
        "Tube": U.material("Tube_" + key, U.srgb(p["tube_color"]), rough=p["tube_rough"],
                           metal=p["tube_metal"]),
        "Dark": U.material("Fitting", U.srgb((0.1, 0.1, 0.11)), rough=0.5),
        "Wire": U.material("Wire", U.srgb((0.55, 0.56, 0.6)), rough=0.4, metal=0.8),
        "Wheel": U.material("Wheel", U.srgb((0.12, 0.12, 0.12)), rough=0.9),
        "Steel": U.material("Steel", U.srgb((0.62, 0.63, 0.66)), rough=0.3, metal=0.9),
        "Grip": U.material("Grip", U.srgb((0.07, 0.07, 0.075)), rough=0.85),
        "Webbing": U.material("Webbing", U.srgb(p.get("strap_color", (0.12, 0.16, 0.3))), rough=0.9),
        "WebbingBackup": U.material("WebbingBackup", U.srgb((0.62, 0.1, 0.07)), rough=0.9),
    }
    build_sail(ws, mats)
    _, tail_y = build_frame(ws, p, cf, mats)
    build_control_frame(ws, p, cf, mats, tail_y)
    U.empty("HangPoint", (0, 0, 0))
    U.empty("WingTipL", ws.le(-1.0))
    U.empty("WingTipR", ws.le(1.0))
    U.export(p["out"])


def main() -> None:
    params = U.load_json("tools/blender/glider_params.json")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for key in argv or list(params["wings"].keys()):
        build_wing(key, params)


if __name__ == "__main__":
    main()
