"""Карты для шейдера паруса (assets/shaders/sail/): нормали и просвечивание, 1024×1024.

Раскладка UV — как у раскраски (sail_texture.py): v 0..0.5 — верхняя обшивка (t от передней
кромки), v 0.5..1 — нижняя обшивка (доля от кромки до места схождения), u — по размаху.
  <wing>_normal.png — касательная карта нормалей (OpenGL, Y+): карманы лат, швы панелей, кромка
                      майлара, подгиб задней кромки, у ламината — сетка армирующих нитей;
  <wing>_trans.png  — сколько света проходит насквозь (1 — одна обшивка, меньше — кромка,
                      латы, швы, двойная обшивка).
"""
import os

import numpy as np

import bl_util as U
from sail_texture import le_band as _le_band

SIZE = 1024
OUT = os.path.join(U.ROOT, "assets", "shaders", "sail")
SEAMS_T = (0.33, 0.58, 0.8)     # швы панелей поперёк хорды (доля хорды)


def _ridge(d: np.ndarray, width: float) -> np.ndarray:
    return np.exp(-(d / width) ** 2)


def _height_and_trans(p: dict, a, t, lower: bool):
    n = p["battens_per_side"]
    ds = p["double_surface"]
    h = np.zeros_like(a)
    tr = np.ones_like(a)
    # латы: ближайшая к a лата a_k = k/n·0.97
    step = 0.97 / n
    k = np.clip(np.round(a / step), 0, n)
    da = np.abs(a - k * step)
    bay = np.clip(da / (step * 0.5), 0, 1)           # 0 на лате, 1 посередине
    bat = _ridge(da, 0.004) * (t > 0.06) * (t < 0.985) * (a < 0.975)
    if p.get("short_battens"):      # промежуточные короткие латы: от 0,6 хорды к задней кромке
        ds_ = np.abs(a - (np.floor(a / step) + 0.5) * step)
        tt = t if not lower else t * p["lower_cover"]
        bat = np.maximum(bat, _ridge(ds_, 0.0035) * (tt > 0.6) * (tt < 0.985) * (a < 0.975))
    if not lower:
        h += 0.35 * np.sin(np.pi * 0.5 * bay) * (t > 0.2)   # парус чуть «пузырится» между латами
        h += 1.0 * bat
        tr *= 1 - 0.65 * bat
        for ts in SEAMS_T:                                   # швы: уступ + строчка
            d = t - ts
            h += 0.25 * (d > 0) * _ridge(d, 0.02) + 0.2 * _ridge(d, 0.002)
            tr *= 1 - 0.3 * _ridge(d, 0.003)
        le_band = _le_band(p["design"], a)
        h += 0.5 * _ridge(t - le_band, 0.003)
        tr = np.where(t < le_band, 0.22, tr)                 # майлар/дакрон + труба кромки
        te = t > 0.975
        h += 0.4 * te
        tr = np.where(te, tr * 0.55, tr)
        if ds:
            tr = np.where(t < p["lower_cover"], tr * 0.75, tr)   # под ней нижняя обшивка
    else:
        h += 0.6 * bat * (t > 0.1)
        tr *= 0.8 * (1 - 0.5 * bat)
        tr = np.where(t < 0.08, 0.2, tr)
        if not ds:
            tr[:] = 0.22                                     # карман кромки однообшивочного
    if p["design"].get("scrim"):                             # X-ply ламинат
        x, y = a * 60.0, t * 24.0
        g = np.maximum(_ridge(((x + y) % 1.0) - 0.5, 0.03), _ridge(((x - y) % 1.0) - 0.5, 0.03))
        h += 0.15 * g
    return h, tr


def make(p: dict) -> None:
    os.makedirs(OUT, exist_ok=True)
    half = SIZE // 2
    u = (np.arange(SIZE, dtype=np.float32) + 0.5) / SIZE
    v = (np.arange(half, dtype=np.float32) + 0.5) / half
    uu, vv = np.meshgrid(u, v)
    a = np.abs(uu * 2 - 1)
    h_top, t_top = _height_and_trans(p, a, vv, False)
    h_bot, t_bot = _height_and_trans(p, a, vv, True)
    h = np.concatenate([h_top, h_bot], axis=0)
    tr = np.concatenate([t_top, t_bot], axis=0)
    strength = 2.5
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5 * strength
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5 * strength
    nrm = np.stack([-dx, -dy, np.ones_like(h)], axis=2)
    nrm /= np.linalg.norm(nrm, axis=2, keepdims=True)
    U.image_from_array(p["out"] + "_normal", nrm * 0.5 + 0.5,
                       os.path.join(OUT, p["out"] + "_normal.png"))
    U.image_from_array(p["out"] + "_trans", np.repeat(np.clip(tr, 0, 1)[..., None], 3, axis=2),
                       os.path.join(OUT, p["out"] + "_trans.png"))
