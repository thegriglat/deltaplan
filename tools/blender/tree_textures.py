"""Процедурные текстуры деревьев (numpy): карточка хвои/листвы с альфой и кора.

Карточка (512×512 RGBA): «веточка» от низа картинки (v = 0 — у ветки) вверх (v = 1 — кончик).
Кора (256×512 RGB): u — по окружности ствола, v — по высоте (0 — комель, 1 — вершина).
"""
import math

import numpy as np

CARD = 512
BARK = (256, 512)


class Canvas:
    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        self.rgb = np.zeros((h, w, 3), dtype=np.float32)
        self.a = np.zeros((h, w), dtype=np.float32)

    def disk(self, x: float, y: float, r: float, col) -> None:
        x0, x1 = int(max(x - r - 1, 0)), int(min(x + r + 2, self.w))
        y0, y1 = int(max(y - r - 1, 0)), int(min(y + r + 2, self.h))
        if x0 >= x1 or y0 >= y1:
            return
        yy, xx = np.mgrid[y0:y1, x0:x1]
        m = (xx - x) ** 2 + (yy - y) ** 2 <= r * r
        self.rgb[y0:y1, x0:x1][m] = col
        self.a[y0:y1, x0:x1][m] = 1.0

    def line(self, p0, p1, r0: float, r1: float, col) -> None:
        n = max(2, int(math.dist(p0, p1) / max(min(r0, r1) * 0.7, 0.6)))
        for i in range(n + 1):
            t = i / n
            self.disk(p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t,
                      r0 + (r1 - r0) * t, col)

    def ellipse(self, x, y, rx, ry, ang, col) -> None:
        r = max(rx, ry)
        x0, x1 = int(max(x - r - 1, 0)), int(min(x + r + 2, self.w))
        y0, y1 = int(max(y - r - 1, 0)), int(min(y + r + 2, self.h))
        if x0 >= x1 or y0 >= y1:
            return
        yy, xx = np.mgrid[y0:y1, x0:x1]
        c, s = math.cos(ang), math.sin(ang)
        u = (xx - x) * c + (yy - y) * s
        v = -(xx - x) * s + (yy - y) * c
        m = (u / rx) ** 2 + (v / ry) ** 2 <= 1
        self.rgb[y0:y1, x0:x1][m] = col
        self.a[y0:y1, x0:x1][m] = 1.0


def _mix(c1, c2, k, shade=1.0):
    return np.array([(a + (b - a) * k) * shade for a, b in zip(c1, c2)], dtype=np.float32)


def _twigs(rng, n: int):
    """Веточки веером от низа-центра: (старт, конец) в пикселях."""
    out = []
    for i in range(n):
        ang = math.radians(90 + rng.uniform(-38, 38))
        base = (CARD * 0.5 + rng.uniform(-30, 30), CARD * 0.04 + rng.uniform(0, 60))
        length = CARD * rng.uniform(0.55, 0.9)
        end = (base[0] + math.cos(ang) * length, base[1] + math.sin(ang) * length)
        out.append((base, end))
    return out


def foliage(kind: str, c1, c2, seed: int) -> np.ndarray:
    """RGBA-карточка. kind: needles (сосна/кедр/ель), needles_soft (лиственница), leaves (берёза)."""
    rng = np.random.default_rng(seed)
    cv = Canvas(CARD, CARD)
    twig_col = np.array([0.25, 0.18, 0.12], dtype=np.float32)
    twigs = _twigs(rng, 7 if kind != "leaves" else 6)
    for (b, e) in twigs:
        cv.line(b, e, 3.0, 1.2, twig_col)
    for (b, e) in twigs:
        d = (e[0] - b[0], e[1] - b[1])
        ln = math.hypot(*d)
        ux, uy = d[0] / ln, d[1] / ln
        steps = int(ln / (7 if kind == "needles" else 14))
        for i in range(2, steps):
            t = i / steps
            px, py = b[0] + d[0] * t, b[1] + d[1] * t
            shade = 0.6 + 0.5 * t
            if kind == "needles":
                nl = CARD * 0.09 * (1.0 - 0.4 * t)
                for side in (-1, 1):
                    a = math.atan2(uy, ux) + side * math.radians(rng.uniform(35, 60))
                    col = _mix(c1, c2, rng.uniform(0, 1), shade)
                    cv.line((px, py), (px + math.cos(a) * nl, py + math.sin(a) * nl), 2.0, 1.2, col)
            elif kind == "needles_soft":
                if i % 2:
                    continue
                for k in range(9):  # розетка мягких хвоинок
                    a = rng.uniform(0, 2 * math.pi)
                    nl = CARD * rng.uniform(0.03, 0.05)
                    col = _mix(c1, c2, rng.uniform(0, 1), shade)
                    cv.line((px, py), (px + math.cos(a) * nl, py + math.sin(a) * nl), 1.8, 1.0, col)
            else:  # листья на свисающих черешках
                for side in (-1, 1):
                    a = math.atan2(uy, ux) + side * math.radians(rng.uniform(30, 80))
                    ll = CARD * 0.035
                    cx, cy = px + math.cos(a) * ll, py + math.sin(a) * ll
                    col = _mix(c1, c2, rng.uniform(0, 1), shade)
                    cv.ellipse(cx, cy, CARD * 0.028, CARD * 0.018, a, col)
    rgba = np.concatenate([cv.rgb, cv.a[..., None]], axis=2)
    return rgba


def bark(kind: str, col, col_low, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    w, h = BARK
    v = (np.arange(h, dtype=np.float32) + 0.5)[:, None] / h
    u = (np.arange(w, dtype=np.float32) + 0.5)[None, :] / w
    col = np.array(col, dtype=np.float32)
    low = np.array(col_low, dtype=np.float32)
    # вертикальные борозды: сумма синусов по u со случайными фазами
    fur = np.zeros((h, w), dtype=np.float32)
    for k in (5, 9, 17):
        ph = rng.uniform(0, 6.28)
        fur += np.sin(2 * np.pi * k * u + ph + 3 * np.sin(v * 7 + ph)) / k
    fur = 0.5 + 0.5 * fur / 0.4
    if kind == "pine":  # снизу серо-бурые плиты, выше — рыжая тонкая кора
        k = np.clip((v - 0.35) / 0.2, 0, 1)
        base = low[None, None] * (1 - k[..., None]) + col[None, None] * k[..., None]
        img = base * (0.75 + 0.35 * fur[..., None] * (1 - 0.6 * k[..., None]))
    elif kind == "birch":  # белая с чёрными чечевичками, комель тёмный
        img = np.broadcast_to(col, (h, w, 3)).copy() * (0.92 + 0.08 * fur[..., None])
        for _ in range(140):
            y = rng.uniform(0, h)
            x = rng.uniform(0, w)
            ln = rng.uniform(8, 40)
            yy = slice(int(max(y - 1.5, 0)), int(min(y + 1.5, h)))
            xx = slice(int(max(x - ln / 2, 0)), int(min(x + ln / 2, w)))
            img[yy, xx] = low
        base_k = np.clip((0.12 - v) / 0.1, 0, 1)
        img = img * (1 - base_k[..., None]) + low * base_k[..., None]
    else:
        img = (low * (1 - v[..., None]) + col * v[..., None]) * (0.7 + 0.45 * fur[..., None])
    return np.clip(img, 0, 1)
