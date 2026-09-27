"""Процедурная раскраска паруса (1024×1024): нижняя половина картинки (v 0..0.5) — верхняя
обшивка (t от передней кромки к задней), верхняя половина (v 0.5..1) — нижняя обшивка.
u — по размаху от левой законцовки к правой. Латы рисуются линиями.

Узоры (design.pattern): center_v, chevron, sport — нынешние крылья; panels — радиальные цветные
полотнища от носа (1980-е, советские; цвета design.panels по размаху от киля к законцовке,
design.panel_count полотнищ на полукрыло); laminar — светлая передняя кромка, крупные цветные поля
сзади; combat — тёмная кромка, контрастный центр. Надписей и логотипов нет.
"""
import math

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


def _battens(img, a, t, n, color, t0, alpha=0.8, short_t0=None) -> None:
    for k in range(n + 1):
        ak = k / n * 0.97
        w = 0.0035 if k else 0.006
        _paint(img, (np.abs(a - ak) < w) & (t > t0) & (t < 0.985), color, alpha)
    if short_t0 is not None:  # промежуточные короткие латы у задней кромки
        for k in range(n):
            ak = (k + 0.5) / n * 0.97
            _paint(img, (np.abs(a - ak) < 0.003) & (t > short_t0) & (t < 0.985), color, alpha)


def le_band(d: dict, a):
    """Ширина полосы передней кромки (доля хорды) — общая для раскраски и карт шейдера."""
    w = d.get("le_band", 0.28 if d["pattern"] == "sport" else 0.16)
    return w * (1 - 0.35 * a)


def _panel_index(p: dict, span: float, a, t):
    """Номер радиального полотнища (от киля к законцовке) по углу луча из носа в плане крыла."""
    half = span * 0.5
    tan_ha = math.tan(math.radians(p["nose_angle_deg"] * 0.5))
    c = p["tip_chord_m"] + (p["root_chord_m"] - p["tip_chord_m"]) * (1 - a ** 0.85)
    x = a * half
    y = a * half / tan_ha + t * c                   # расстояние за носом
    ang = np.arctan2(x, y) / math.atan(tan_ha)      # 0 — киль, 1 — передняя кромка
    n = int(p["design"].get("panel_count", len(p["design"]["panels"])))
    return np.clip(np.floor(ang * n), 0, n - 1).astype(int), ang * n


def _panels(p: dict, span: float, a, t, img) -> None:
    d = p["design"]
    idx, f = _panel_index(p, span, a, t)
    cols = d["panels"]
    for i in range(int(idx.max()) + 1):
        _paint(img, idx == i, cols[i % len(cols)])
    seam = np.abs(f - np.round(f)) < 0.012 * (1 + f)       # строчка шва между полотнищами
    _paint(img, seam & (np.round(f) > 0), d.get("seam", (0.3, 0.3, 0.3)), 0.35)


def top_design(p: dict, span: float, a, t, img) -> None:
    d = p["design"]
    n_batt = p["battens_per_side"]
    img[:] = _col(d["base"])
    pat = d["pattern"]
    if pat == "panels":
        _panels(p, span, a, t, img)
    elif pat == "laminar":
        edge = 0.42 + 0.25 * a                          # граница светлой кромки и цветных полей
        _paint(img, (t > edge) & (a < 0.5), d["center"])
        _paint(img, (t > edge) & (a >= 0.5) & (a < 0.86), d["accent"])
        _paint(img, np.abs(t - edge) < 0.012, d["te"])
    elif pat == "combat":
        _paint(img, (a < 0.3 + 0.2 * t) & (t > 0.3), d["center"])
        _paint(img, np.abs(a - 0.3 - 0.2 * t) < 0.012, d["te"])
        _paint(img, (a > 0.8) & (a < 0.83), d["accent"])
    elif pat == "center_v":
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
    leb = le_band(d, a)
    _paint(img, t < leb, d["le"])
    _paint(img, t > 0.975, d["te"])
    _battens(img, a, t, n_batt, d["batten"], leb * 0.8, 0.85,
             0.6 if p.get("short_battens") else None)


def bottom_design(p: dict, span: float, a, t, img) -> None:
    d = p["design"]
    n_batt = p["battens_per_side"]
    pat = d["pattern"]
    if "bottom" not in d:  # однообшивочное: карман передней кромки
        img[:] = _col(d["le"])
        return
    cov = p["lower_cover"]
    short = 0.6 / cov if p.get("short_battens") and cov > 0.6 else None
    if d["bottom"] == "panels":  # двухобшивочное 1980-х: те же радиальные полотнища снизу
        _panels(p, span, a, t * cov, img)
        _paint(img, t < 0.06, d["le"])
        _battens(img, a, t, n_batt, d["batten"], 0.1, 0.5, short)
        return
    img[:] = _col(d["bottom"])
    if pat == "laminar":
        _paint(img, (t > 0.45) & (a < 0.55), d["bottom_accent"])
        _paint(img, a > 0.86, d["bottom_tip"])
    elif pat == "combat":
        _paint(img, a < 0.28 + 0.15 * t, d["bottom_accent"])
        _paint(img, np.abs(a - 0.28 - 0.15 * t) < 0.012, d["bottom_tip"])
        _paint(img, a > 0.84, d["bottom_tip"])
    elif pat == "chevron":
        _paint(img, np.abs(a - (0.62 - 0.4 * t)) < 0.07, d["bottom_accent"])
        _paint(img, np.abs(a - (0.85 - 0.4 * t)) < 0.025, d["bottom_accent"])
    else:
        _paint(img, np.abs(a - (0.3 + 0.35 * t)) < 0.05, d["bottom_accent"])
        _paint(img, np.abs(a - (0.62 + 0.25 * t)) < 0.03, d["bottom_accent"])
        _paint(img, a > 0.88, d["bottom_tip"])
    _paint(img, t < 0.06, (0.35, 0.36, 0.38))
    if d.get("scrim"):
        _scrim(img, a, t, 0.12)
    _battens(img, a, t, n_batt, d["batten"], 0.1, 0.5, short)


def make(p: dict, save_path: str, span: float = 10.0):
    half = SIZE // 2
    u = (np.arange(SIZE, dtype=np.float32) + 0.5) / SIZE
    v = (np.arange(half, dtype=np.float32) + 0.5) / half
    uu, vv = np.meshgrid(u, v)
    a = np.abs(uu * 2 - 1)
    img = np.zeros((SIZE, SIZE, 3), dtype=np.float32)
    top = img[:half]
    bot = img[half:]
    top_design(p, span, a, vv, top)
    bottom_design(p, span, a, vv, bot)
    # цвета в sRGB: байтовая картинка хранит sRGB-значения как есть
    return U.image_from_array(p["out"] + "_sail", img, save_path)
