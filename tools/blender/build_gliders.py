"""Модели трёх крыльев дельтаплана: assets/models/glider_<id>.glb (+ assets/source/*.blend).

Запуск из корня проекта:
    blender --background --python tools/blender/build_gliders.py [-- training kingpost sport]

Параметры формы — tools/blender/glider_params.json, размах и площадь — configs/wings/<id>.json.
Контракт имён (docs/models.md): меши Sail, Frame, ControlFrame; пустышки HangPoint (= начало
координат), BaseBar, InstrumentMount (центр базовой штанги, −Z Godot смотрит на глаза пилота),
VarioMount (на левой стойке), WingTipL, WingTipR. Оси Blender: X вправо, +Y вперёд (нос), Z вверх.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bl_util as U  # noqa: E402
import sail_texture  # noqa: E402

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

    def chord(self, a: float) -> float:
        c = self.p["tip_chord_m"] + (self.p["root_chord_m"] - self.p["tip_chord_m"]) * (1 - a ** 0.85)
        if a > 0.9:  # скруглённая законцовка
            c *= 1.0 - 0.35 * ((a - 0.9) / 0.1) ** 2
        return c

    def le(self, u: float) -> Vector:
        a = abs(u)
        y = self.y_nose - a * self.half / self.tan_ha
        if a > 0.9:
            y -= 0.35 * self.p["tip_chord_m"] * ((a - 0.9) / 0.1) ** 2 * 0.6
        z = self.z0 + a * self.half * self.dih - 0.05 * a ** 3
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


def build_sail(ws: WingShape, mats: dict):
    mb = U.MeshBuilder()
    us = [-1 + 2 * i / (2 * SPAN_STATIONS) for i in range(2 * SPAN_STATIONS + 1)]
    ts = stations(CHORD_STATIONS, True)
    top = [[ws.upper(u, t) for t in ts] for u in us]
    top_uv = [[((u + 1) / 2, t * 0.5) for t in ts] for u in us]
    mb.add_grid(top, "Sail", top_uv, flip=True)
    tls = stations(14, True)
    bot = [[ws.lower(u, tl) for tl in tls] for u in us]
    bot_uv = [[((u + 1) / 2, 0.5 + tl * 0.5) for tl in tls] for u in us]
    mb.add_grid(bot, "Sail", bot_uv, flip=False)
    return mb.build("Sail", mats)


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


def build_frame(ws: WingShape, p: dict, cf: dict, mats: dict):
    mb = U.MeshBuilder()
    kz = cf["keel_z_m"]
    r_le = 0.032
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
            mb.add_tube([top, tg], WIRE_R, "Wire", sides=4, cap=False)
    return mb.build("Frame", mats), tail_y


def build_control_frame(ws: WingShape, p: dict, cf: dict, mats: dict, tail_y: float):
    mb = U.MeshBuilder()
    kz = cf["keel_z_m"]
    apex = Vector((0, cf["apex_forward_m"], kz - 0.05))
    w = p["basebar_width_m"] * 0.5
    y_bb = cf["basebar_forward_m"]
    z_bb = kz - cf["basebar_drop_m"]
    faired = p["faired_uprights"]
    mb.add_box(apex + Vector((0, 0, 0.02)), (0.12, 0.08, 0.07), "Dark")
    corners = []
    for s in (-1, 1):
        top = apex + Vector((s * 0.04, 0, 0))
        c = Vector((s * w, y_bb, z_bb))
        corners.append(c)
        if faired:
            mb.add_tube([top, c + Vector((0, 0, 0.03))], 0.016, "Tube", sides=12,
                        ellipse=(0.9, 2.6), up=(0, 1, 0))
        else:
            mb.add_tube([top, c], 0.019, "Tube", sides=10)
        mb.add_box(c, (0.07, 0.07, 0.07), "Dark")
    # базовая штанга (у спортивного — «спидбар» с изгибом вниз к центру)
    dip = 0.03 if faired else 0.0
    bar = [Vector((-w, y_bb, z_bb)), Vector((-w * 0.45, y_bb, z_bb - dip)),
           Vector((w * 0.45, y_bb, z_bb - dip)), Vector((w, y_bb, z_bb))]
    mb.add_tube(bar, 0.017, "Tube", sides=10)
    if p["wheels"]:
        for s in (-1, 1):
            c = Vector((s * (w + 0.07), y_bb, z_bb))
            mb.add_tube([c - Vector((0.025, 0, 0)), c + Vector((0.025, 0, 0))], 0.1, "Wheel",
                        sides=16, up=(0, 1, 0))
    # нижние тросы: передние к носу, задние к килю, боковые к узлам поперечины
    nose = Vector((0, ws.y_nose - 0.05, kz))
    tail = Vector((0, tail_y + 0.05, kz))
    for s, c in zip((-1, 1), corners):
        ends = [nose, tail, le_tube_point(ws, s * p["crossbar_u"], 0.032)]
        if faired:  # у бескилевых — сдвоенные боковые тросы
            ends.append(le_tube_point(ws, s * (p["crossbar_u"] - 0.04), 0.032))
        for e in ends:
            mb.add_tube([c, e], WIRE_R, "Wire", sides=4, cap=False)
    obj = mb.build("ControlFrame", mats)
    U.empty("BaseBar", (0, y_bb, z_bb - dip), parent=obj)
    eye = Vector(cf["_eye"])
    # планшет — на оси базовой штанги в центре, −Z (Godot) маркера смотрит на глаза пилота
    bar_c = Vector((0, y_bb, z_bb - dip))
    U.empty("InstrumentMount", None, parent=obj, matrix=U.look_matrix(bar_c, eye))
    # вариометр 90-х — на оси левой стойки, тоже экраном к глазам
    pos = (apex + Vector((-0.04, 0, 0))).lerp(Vector((-w, y_bb, z_bb)), cf["vario_on_upright"])
    U.empty("VarioMount", None, parent=obj, matrix=U.look_matrix(pos, eye))
    return obj


def build_wing(key: str, params: dict) -> None:
    p = params["wings"][key]
    cf = dict(params["control_frame"])
    cf["_eye"] = params["pilot_eye"]
    wcfg = U.load_json("configs/wings/%s.json" % p["config"])
    U.reset_scene()
    ws = WingShape(p, cf, float(wcfg["span_m"]))
    tex = sail_texture.make(p, os.path.join(U.SOURCE, p["out"] + "_sail.png"))
    mats = {
        "Sail": U.material("Sail_" + key, (1, 1, 1), rough=0.75, double=True, image=tex),
        "Tube": U.material("Tube_" + key, U.srgb(p["tube_color"]), rough=p["tube_rough"],
                           metal=p["tube_metal"]),
        "Dark": U.material("Fitting", U.srgb((0.1, 0.1, 0.11)), rough=0.5),
        "Wire": U.material("Wire", U.srgb((0.55, 0.56, 0.6)), rough=0.4, metal=0.8),
        "Wheel": U.material("Wheel", U.srgb((0.12, 0.12, 0.12)), rough=0.9),
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
