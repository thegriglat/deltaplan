"""Геометрия крыла: полосы (strip theory), распределение массы, моменты инерции.

Системы координат:
- «от носа» N: x — назад вдоль киля от носового узла, y — вправо, z — вниз; начало — нос на киле;
- связанная B (авиационная): x — вперёд по килю, y — вправо, z — вниз; начало — ЦМ крыла.
Перевод N→B: (x, y, z) → (x_cg − x, y, z − z_cg).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from .params import Params


@dataclass
class Strips:
    r_n: np.ndarray  # (n,3) точка приложения сил полосы, система N
    chord: np.ndarray  # (n,)
    width: np.ndarray  # (n,) ширина по размаху (проекция), м
    twist: np.ndarray  # (n,) рад, геометрическая крутка (− на концах)
    s_b: np.ndarray  # (n,3) направление размаха (наружу), B
    c_b: np.ndarray  # (n,3) хордовое направление (вперёд, ⊥ размаху), B
    n_b: np.ndarray  # (n,3) нормаль панели (вниз), B: наклонена на поперечное V
    side: np.ndarray  # (n,) +1 правая, −1 левая


def chord_scale(p: Params) -> float:
    return p.area / (0.5 * (p.root_chord + p.tip_chord) * p.span)


def make_strips(p: Params) -> Strips:
    n_side = p.n_strips // 2
    half = 0.5 * p.span
    k = chord_scale(p)
    t = math.tan(p.sweep)
    ys = (np.arange(n_side) + 0.5) * half / n_side
    w = np.full(n_side, half / n_side)
    c = k * (p.root_chord + (p.tip_chord - p.root_chord) * ys / half)
    x = ys * t + p.cp_chord * c
    z = -ys * math.tan(p.dihedral)
    tw = -p.washout * ys / half
    sl, cl = math.sin(p.sweep), math.cos(p.sweep)
    r, ch, wd, twi, sb, cb, sd, nb = [], [], [], [], [], [], [], []
    sg, cg_ = math.sin(p.dihedral), math.cos(p.dihedral)
    for s in (1.0, -1.0):
        r.append(np.stack([x, s * ys, z], 1))
        ch.append(c)
        wd.append(w)
        twi.append(tw)
        s_vec = np.array([-sl, s * cl * cg_, -cl * sg])  # размах наружу, с поперечным V
        n_vec = np.array([0.0, s * sg, cg_])
        c_vec = np.cross(s_vec, n_vec)
        c_vec = c_vec * (1.0 if c_vec[0] > 0 else -1.0)  # вперёд
        sb.append(np.tile(s_vec, (n_side, 1)))
        cb.append(np.tile(c_vec / np.linalg.norm(c_vec), (n_side, 1)))
        sd.append(np.full(n_side, s))
        nb.append(np.tile([0.0, s * sg, cg_], (n_side, 1)))
    return Strips(
        np.concatenate(r), np.concatenate(ch), np.concatenate(wd), np.concatenate(twi),
        np.concatenate(sb), np.concatenate(cb), np.concatenate(nb), np.concatenate(sd),
    )


def _segment(a, b, mass, n=24):
    a, b = np.asarray(a, float), np.asarray(b, float)
    t = (np.arange(n) + 0.5) / n
    pts = a[None] + (b - a)[None] * t[:, None]
    return pts, np.full(n, mass / n)


@dataclass
class MassModel:
    cg_n: np.ndarray  # ЦМ крыла в системе N
    inertia_b: np.ndarray  # 3×3 тензор инерции около ЦМ, оси B (без присоединённой массы)
    parts: dict  # масса частей, кг


def mass_model(p: Params, x_hang: float) -> MassModel:
    """Оценка распределения массы крыла (EST): трубы — погонные массы из glider_params.json
    (control_frame.mass_model, «оценка»), остаток до паспортной массы — парус с лат-
    тами, равномерно по площади. Трапеция под подвеской (вершина у точки подвески)."""
    mm = p.extra["mass_model"]
    half = 0.5 * p.span
    t = math.tan(p.sweep)
    le_tip = np.array([half * t, half, -half * math.tan(p.dihedral)])
    le_len = float(np.linalg.norm(le_tip))
    pts, ms, parts = [], [], {}

    def add(name, a, b, lin):
        length = float(np.linalg.norm(np.asarray(b) - np.asarray(a)))
        q, m = _segment(a, b, lin * length)
        pts.append(q)
        ms.append(m)
        parts[name] = parts.get(name, 0.0) + lin * length

    add("keel", [0, 0, 0], [p.keel_len, 0, 0], mm["keel"])
    for s in (1, -1):
        tip = le_tip * np.array([1, s, 1])
        add("leading_edge", [0, 0, 0], tip, mm["leading_edge"])
        u = p.extra["crossbar_u"]
        add("crossbar", [p.crossbar_from_nose, 0, 0], tip * u, mm["crossbar"])
        apex = np.array([x_hang, 0.05 * s, 0.06])
        bottom = np.array([
            x_hang - p.upright_len * math.sin(p.upright_tilt), 0.7 * s,
            0.06 + p.upright_len * math.cos(p.upright_tilt),
        ])
        add("uprights", apex, bottom, mm["upright"])
    zb = 0.06 + p.upright_len * math.cos(p.upright_tilt)
    xb = x_hang - p.upright_len * math.sin(p.upright_tilt)
    add("basebar", [xb, -0.7, zb], [xb, 0.7, zb], mm["basebar"])
    if p.kingpost > 0:
        add("kingpost", [x_hang, 0, 0], [x_hang, 0, -p.kingpost], mm["kingpost"])
    tubes = sum(parts.values())
    sail = max(p.m_wing - tubes, 0.0)
    parts["sail_rest"] = sail
    # парус: сетка по плану крыла
    k = chord_scale(p)
    ny, nx = 40, 12
    ys = (np.arange(ny) + 0.5) / ny * half
    sp, sm = [], []
    for y in ys:
        c = k * (p.root_chord + (p.tip_chord - p.root_chord) * y / half)
        xs = y * t + (np.arange(nx) + 0.5) / nx * c
        for s in (1, -1):
            sp.append(np.stack([xs, np.full(nx, s * y), np.full(nx, -y * math.tan(p.dihedral))], 1))
            sm.append(np.full(nx, c))
    sp = np.concatenate(sp)
    sm = np.concatenate(sm)
    sm = sm / sm.sum() * sail
    pts.append(sp)
    ms.append(sm)
    P = np.concatenate(pts)
    M = np.concatenate(ms)
    scale = p.m_wing / M.sum()  # точно паспортная масса (если трубы тяжелее паспорта)
    M = M * scale
    cg = (P * M[:, None]).sum(0) / M.sum()
    # в оси B около ЦМ
    d = P - cg
    d[:, 0] *= -1.0
    I = np.zeros((3, 3))
    for i in range(3):
        for j in range(3):
            I[i, j] = -(M * d[:, i] * d[:, j]).sum()
    tr = (M * (d * d).sum(1)).sum()
    I += np.eye(3) * tr
    return MassModel(cg, I, {k: v * scale for k, v in parts.items()})


def apparent_roll_inertia(p: Params) -> float:
    """Присоединённая масса воздуха по крену: пластина, π/4·ρ·c² на метр размаха → π/48·ρ·c²·b³
    (как GroundRun.roll_inertia в игре)."""
    c = p.area / p.span
    return math.pi / 48.0 * p.rho * c * c * p.span ** 3
