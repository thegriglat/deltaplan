"""Колесо базовой штанги трапеции: шина (тор со скруглённым профилем и протектором в текстуре),
пластиковый диск-обод с выпуклой ступицей и шестью спицами, стальная ось. Ось колеса — X."""
import math
import os

import numpy as np
from mathutils import Vector

import bl_util as U

R_OUT = 0.1          # внешний радиус шины
HALF_W = 0.025       # половина ширины
TEX = 256


def tire_texture() -> "bpy.types.Image":
    """Общая для всех крыльев текстура шины 256² (u — вдоль окружности ×4 повтора, v — поперёк):
    чёрная резина, косые блоки протектора по центру, мелкая зернистость."""
    path = os.path.join(U.SOURCE, "wheel_tire.png")
    rng = np.random.default_rng(7)
    v, u = np.mgrid[0:TEX, 0:TEX] / TEX
    base = 0.075 + 0.02 * rng.random((TEX, TEX))
    across = np.abs(v - 0.5) * 2                       # 0 в центре, 1 у боковин
    # косые блоки: полосы по (u*8 ± v*3), канавки темнее
    ph = (u * 8 + np.where(v > 0.5, 1, -1) * across * 1.6) % 1.0
    groove = (ph < 0.22) & (across < 0.78)
    base = np.where(groove, base * 0.45, base)
    tread = (across < 0.78) & ~groove
    base = np.where(tread, base * 1.25, base)
    side = across >= 0.8                               # боковина: гладкая, чуть светлее у борта
    base = np.where(side, 0.085 + 0.012 * rng.random((TEX, TEX)) + 0.03 * (across - 0.8), base)
    rgb = np.stack([base, base, base * 1.03], axis=-1)
    return U.image_from_array("wheel_tire", rgb, path)


def add_wheel(mb, c: Vector, x_sign: int, bar_end_x: float) -> None:
    """c — центр колеса; x_sign — сторона (-1 левая, +1 правая); bar_end_x — x конца штанги."""
    X = Vector((1, 0, 0))

    def at(dx, r, ang):  # точка в системе колеса: смещение вдоль оси, радиус, угол в плоскости YZ
        return c + Vector((dx, r * math.sin(ang), r * math.cos(ang)))

    # шина: профиль — суперэллипс, 24 сегмента вокруг оси, 12 точек профиля
    rc, hr = R_OUT - 0.0155, 0.0155
    nprof, nseg = 8, 16
    prof = []
    for k in range(nprof):
        a = 2 * math.pi * k / nprof
        ca, sa = math.cos(a), math.sin(a)
        prof.append((HALF_W * math.copysign(abs(ca) ** 0.55, ca),
                     rc + hr * math.copysign(abs(sa) ** 0.55, sa)))
    rings, uv = [], []
    for j in range(nseg + 1):
        ang = 2 * math.pi * j / nseg
        rings.append([at(dx, r, ang) for dx, r in prof] + [at(*prof[0], ang)])
        uv.append([(4 * j / nseg, k / nprof) for k in range(nprof + 1)])
    mb.add_grid(rings, "Wheel", uv, flip=(x_sign < 0))
    # обод-диск: кольцо у борта (тор Ø) + 6 спиц + ступица
    mb.add_tube([at(0, 0.066, 2 * math.pi * j / 12) for j in range(12)], 0.0075, "WheelRim",
                sides=4, closed=True, up=(1, 0, 0))
    for i in range(5):
        ang = 2 * math.pi * (i + 0.5) / 5
        mb.add_tube([at(0.004, 0.026, ang), at(0.004, 0.066, ang)], 1.0, "WheelRim", sides=4,
                    ellipse=(0.008, 0.006), up=(1, 0, 0))
    hub = x_sign * 0.012                      # выпуклая ступица (сторона наружу)
    mb.add_tube([c + Vector((-0.02, 0, 0)), c + Vector((0.02, 0, 0))], [0.026, 0.026], "WheelRim",
                sides=8)
    mb.add_tube([c + Vector((hub, 0, 0)), c + Vector((x_sign * 0.027, 0, 0))], [0.021, 0.014],
                "WheelRim", sides=8)
    # ось: от конца штанги сквозь ступицу, гайка снаружи
    a0 = Vector((bar_end_x, c.y, c.z))
    mb.add_tube([a0, c + Vector((x_sign * 0.026, 0, 0))], 0.0085, "Steel", sides=6)
    mb.add_tube([c + Vector((x_sign * 0.026, 0, 0)), c + Vector((x_sign * 0.034, 0, 0))], 0.0115,
                "Steel", sides=6)
