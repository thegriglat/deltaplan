"""Процедурная раскраска паруса (1024×1024): нижняя половина картинки (v 0..0.5) — верхняя
обшивка (t от передней кромки к задней), верхняя половина (v 0.5..1) — нижняя обшивка.
u — по размаху от левой законцовки к правой. Латы рисуются линиями.
"""
import numpy as np

import bl_util as U

SIZE = 1024


def _col(c) -> np.ndarray:
    return np.array(c, dtype=np.float32)


def _paint(img, mask, color, alpha=1.0) -> None:
    img[mask] = img[mask] * (1 - alpha) + _col(color) * alpha


def _scrim(img, a, t, alpha=0.18) -> None:
    """Сетка армирующих нитей ламината (X-ply) — тонкие диагонали."""
    x = a * 60.0
    y = t * 24.0
    grid = (np.abs(((x + y) % 1.0) - 0.5) > 0.46) | (np.abs(((x - y) % 1.0) - 0.5) > 0.46)
    img[grid] = img[grid] * (1 - alpha)


def _battens(img, a, t, n, color, t0, alpha=0.8) -> None:
    for k in range(n + 1):
        ak = k / n * 0.97
        w = 0.0035 if k else 0.006
        _paint(img, (np.abs(a - ak) < w) & (t > t0) & (t < 0.985), color, alpha)


def top_design(d: dict, n_batt: int, a, t, img) -> None:
    img[:] = _col(d["base"])
    pat = d["pattern"]
    if pat == "center_v":
        _paint(img, a < 0.1 + 0.3 * t, d["center"])
        _paint(img, (np.abs(a - 0.1 - 0.3 * t) < 0.018), d["accent"])
        _paint(img, (a > 0.8) & (a < 0.86), d["accent"])
    elif pat == "chevron":
        for off, col, wd in ((0.55, d["center"], 0.06), (0.35, d["accent"], 0.03),
                             (0.75, d["center"], 0.025)):
            _paint(img, np.abs(a - (off - 0.55 * t)) < wd, col)
    else:  # sport
        _paint(img, (a > 0.22) & (a < 0.5) & (t > 0.3), d["center"])
        _paint(img, (a > 0.5) & (a < 0.53) & (t > 0.3), d["te"])
        _paint(img, a > 0.9, d["te"])
    if d.get("scrim"):
        _scrim(img, a, t)
    le_band = (0.28 if pat == "sport" else 0.16) * (1 - 0.35 * a)
    _paint(img, t < le_band, d["le"])
    _paint(img, t > 0.975, d["te"])
    _battens(img, a, t, n_batt, d["batten"], le_band * 0.8, 0.85)


def bottom_design(d: dict, n_batt: int, a, t, img) -> None:
    pat = d["pattern"]
    if pat == "center_v":  # однообшивочное: карман передней кромки
        img[:] = _col(d["le"])
        return
    img[:] = _col(d["bottom"])
    if pat == "chevron":
        _paint(img, np.abs(a - (0.62 - 0.4 * t)) < 0.07, d["bottom_accent"])
        _paint(img, np.abs(a - (0.85 - 0.4 * t)) < 0.025, d["bottom_accent"])
    else:
        _paint(img, np.abs(a - (0.3 + 0.35 * t)) < 0.05, d["bottom_accent"])
        _paint(img, np.abs(a - (0.62 + 0.25 * t)) < 0.03, d["bottom_accent"])
        _paint(img, a > 0.88, d["bottom_tip"])
    _paint(img, t < 0.06, (0.35, 0.36, 0.38))
    if d.get("scrim"):
        _scrim(img, a, t, 0.12)
    _battens(img, a, t, n_batt, d["batten"], 0.1, 0.5)


def make(p: dict, save_path: str):
    d = p["design"]
    half = SIZE // 2
    u = (np.arange(SIZE, dtype=np.float32) + 0.5) / SIZE
    v = (np.arange(half, dtype=np.float32) + 0.5) / half
    uu, vv = np.meshgrid(u, v)
    a = np.abs(uu * 2 - 1)
    img = np.zeros((SIZE, SIZE, 3), dtype=np.float32)
    top = img[:half]
    bot = img[half:]
    top_design(d, p["battens_per_side"], a, vv, top)
    bottom_design(d, p["battens_per_side"], a, vv, bot)
    # цвета в sRGB: байтовая картинка хранит sRGB-значения как есть
    return U.image_from_array(p["out"] + "_sail", img, save_path)
