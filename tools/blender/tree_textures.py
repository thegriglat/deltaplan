"""Процедурные текстуры деревьев (numpy): карточка хвои/листвы с альфой и кора.

Карточка (512×512 RGBA): ветка от низа картинки (v = 0 — у ветки) вверх (v = 1 — кончик).
Не «перо»-веер (читалось как лист пальмы): у сосны/кедра — кисти хвои на концах побегов с
просветами, у ели — сплошная лапа ёлочкой, у лиственницы — розетки на провисающих побегах,
у берёзы — плакучие прутья с мелкими листьями.
Кора (256×512 RGB): u — по окружности ствола, v — по высоте (0 — комель, 1 — вершина).
"""
import math
import random

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


def _needle_tuft(cv: Canvas, rng, x: float, y: float, r: float, n: int, c1, c2, shade: float,
                 aim: float = None, spread: float = math.pi, w: float = 1.7) -> None:
    """Пучок хвоинок из точки: сначала длинные тёмные (глубина пучка), сверху короче и светлее."""
    ls = sorted((rng.uniform(0.35, 1.0) for _ in range(n)), reverse=True)
    for ln in ls:
        a = rng.uniform(0, 2 * math.pi) if aim is None else aim + rng.uniform(-spread, spread)
        k = 0.7 + 0.45 * (1 - ln)  # короткие (ближе к оси пучка) — светлее, «торчат» к зрителю
        col = _mix(c1, c2, rng.uniform(0, 1), shade * k)
        cv.line((x, y), (x + math.cos(a) * r * ln, y + math.sin(a) * r * ln), w, w * 0.55, col)


def _branchlet(cv: Canvas, p0, p1, w0: float, col) -> None:
    cv.line(p0, p1, w0, max(w0 * 0.4, 0.8), col)


def _pine(cv: Canvas, rng, c1, c2, n_tufts: int, r_tuft: tuple, dens: int, spread_px: float) -> None:
    """Сосна/кедр: ветка ветвится к концу, на концах побегов — шапки длинной хвои (кисти).
    Между кистями просветы: крона «клочьями», а не сплошное перо."""
    twig = np.array([0.3, 0.2, 0.13], dtype=np.float32)
    base = (CARD * 0.5, CARD * 0.03)
    tips = []
    for i in range(n_tufts):
        ang = math.radians(90 + rng.uniform(-1, 1) * spread_px)
        ln = CARD * rng.uniform(0.55, 0.84)
        tips.append((base[0] + math.cos(ang) * ln * 0.75, base[1] + math.sin(ang) * ln))
    tips.sort(key=lambda t: t[1])
    fork = (base[0] + rng.uniform(-10, 10), CARD * 0.22)
    _branchlet(cv, base, fork, 5.0, twig)
    for t in tips:
        _branchlet(cv, fork, t, 3.0, twig)
    for i, (tx, ty) in enumerate(tips):
        r = CARD * rng.uniform(*r_tuft)
        aim = math.atan2(ty - fork[1], tx - fork[0])
        shade = 0.72 + 0.35 * ty / CARD
        # кисть: хвоя растёт вокруг побега и вперёд по нему
        for s in range(3):
            cx = tx - math.cos(aim) * r * 0.35 * (2 - s)
            cy = ty - math.sin(aim) * r * 0.35 * (2 - s)
            _needle_tuft(cv, rng, cx, cy, r * (0.8 + 0.1 * s), dens // 3, c1, c2,
                         shade * (0.85 + 0.08 * s), aim, math.radians(125), 2.0)


def _spruce(cv: Canvas, rng, c1, c2, needle_px: float) -> None:
    """Ель: плоская «лапа» — ось, боковые веточки ёлочкой, сплошь в короткой хвое. Контур —
    округлый треугольник (ширина к середине, острый конец); без просветов-перьев."""
    twig = np.array([0.28, 0.2, 0.14], dtype=np.float32)
    x0 = CARD * 0.5
    axis = [(x0 + 14 * math.sin(3 * t) * t, CARD * (0.02 + 0.95 * t))
            for t in np.linspace(0, 1, 24)]
    for a, b in zip(axis[:-1], axis[1:]):
        _branchlet(cv, a, b, 3.5, twig)
    side = []
    for i, (ax, ay) in enumerate(axis[2:-1]):
        t = (ay / CARD)
        half = CARD * 0.47 * math.sin(math.pi * min(0.2 + 0.9 * t, 1.0)) ** 0.8 * (1 - 0.35 * t)
        for sgn in (-1, 1):
            ang = math.radians(90 - sgn * rng.uniform(42, 62))
            ln = min(half / max(abs(math.cos(ang)), 0.35), half * 1.4) * rng.uniform(0.8, 1.05)
            e = (ax + math.cos(ang) * ln, ay + math.sin(ang) * ln)
            side.append(((ax, ay), e, t))
    for (a, e, t) in side:
        _branchlet(cv, a, e, 1.8, twig)
    # хвоя: сначала тёмный подшёрсток, сверху светлее — объём лапы
    for layer, (k, dens) in enumerate(((0.62, 5), (0.95, 4))):
        for (a, e, t) in side:
            d = (e[0] - a[0], e[1] - a[1])
            ln = math.hypot(*d)
            ux, uy = d[0] / ln, d[1] / ln
            for i in range(int(ln / dens)):
                s = i / max(ln / dens, 1)
                px, py = a[0] + d[0] * s, a[1] + d[1] * s
                for sgn in (-1, 1):
                    ang = math.atan2(uy, ux) + sgn * math.radians(rng.uniform(30, 75))
                    nl = needle_px * rng.uniform(0.7, 1.1) * (1 - 0.3 * s)
                    col = _mix(c1, c2, rng.uniform(0, 1), k * (0.8 + 0.3 * s))
                    cv.line((px, py), (px + math.cos(ang) * nl, py + math.sin(ang) * nl),
                            1.8, 1.0, col)


def _larch(cv: Canvas, rng, c1, c2) -> None:
    """Лиственница: ажурная ветка — тонкие свисающие побеги с розетками мягкой хвои (пучки
    на укороченных побегах), много просветов."""
    twig = np.array([0.4, 0.27, 0.18], dtype=np.float32)
    x0 = CARD * 0.5
    axis = [(x0 + 18 * math.sin(2.5 * t), CARD * (0.02 + 0.95 * t)) for t in np.linspace(0, 1, 16)]
    for a, b in zip(axis[:-1], axis[1:]):
        _branchlet(cv, a, b, 3.0, twig)
    shoots = [(axis[-1], None)]
    for i, (ax, ay) in enumerate(axis[3:-1]):
        t = ay / CARD
        for sgn in (-1, 1):
            ang = math.radians(90 - sgn * rng.uniform(45, 70))
            ln = CARD * rng.uniform(0.2, 0.4) * (1.15 - 0.5 * t)
            # побег «провисает» (в плоскости карточки — изгибается к основанию)
            m = (ax + math.cos(ang) * ln * 0.6, ay + math.sin(ang) * ln * 0.6)
            e = (ax + math.cos(ang) * ln, ay + math.sin(ang) * ln - ln * 0.25)
            _branchlet(cv, (ax, ay), m, 1.6, twig)
            _branchlet(cv, m, e, 1.2, twig)
            shoots.append(((ax, ay), e))
    for (a, e) in shoots[1:]:
        for s in np.linspace(0.2, 1.0, 5):
            px, py = a[0] + (e[0] - a[0]) * s, a[1] + (e[1] - a[1]) * s - 0.1 * s * s
            _needle_tuft(cv, rng, px, py, CARD * rng.uniform(0.04, 0.058), 22, c1, c2,
                         0.8 + 0.25 * s, None, math.pi, 1.5)
    for s in np.linspace(0.15, 1.0, 8):  # пучки и по оси
        px, py = axis[int(s * 15)]
        _needle_tuft(cv, rng, px + rng.uniform(-6, 6), py, CARD * 0.05, 20, c1, c2, 0.9,
                     None, math.pi, 1.5)


def _birch(cv: Canvas, rng, c1, c2) -> None:
    """Берёза повислая: тонкие плакучие прутья (от основания карточки — вниз по дереву),
    по ним мелкие треугольно-ромбические листья вразнобой, гуще к концам; округлый контур."""
    twig = np.array([0.32, 0.24, 0.2], dtype=np.float32)
    base = (CARD * 0.5, CARD * 0.03)
    strands = []
    for i in range(9):
        ang = math.radians(90 + rng.uniform(-30, 30))
        ln = CARD * rng.uniform(0.5, 0.92)
        bend = rng.uniform(-0.25, 0.25)
        pts = []
        for t in np.linspace(0, 1, 8):
            a = ang + bend * t
            pts.append((base[0] + math.cos(a) * ln * t, base[1] + math.sin(a) * ln * t))
        strands.append(pts)
    for pts in strands:
        for a, b in zip(pts[:-1], pts[1:]):
            _branchlet(cv, a, b, 1.3, twig)
    for pass_k in (0.72, 1.0):  # нижний слой листьев темнее — глубина
        for pts in strands:
            for j, (px, py) in enumerate(pts[1:], 1):
                t = j / (len(pts) - 1)
                for _ in range(int(6 + 14 * t)):
                    ox, oy = rng.normal(0, 12 + 20 * t), rng.normal(0, 12)
                    a = math.radians(90 + rng.uniform(-60, 60))
                    col = _mix(c1, c2, rng.uniform(0, 1), pass_k * rng.uniform(0.82, 1.08))
                    sz = CARD * rng.uniform(0.009, 0.014)
                    cv.ellipse(px + ox, py + oy, sz * 1.35, sz, a, col)


def foliage(kind: str, c1, c2, seed: int) -> np.ndarray:
    """RGBA-карточка (низ картинки — у ветки, верх — конец ветки).
    kind: pine, cedar, spruce, larch, birch."""
    rng = np.random.default_rng(seed)
    rs = random.Random(seed)
    cv = Canvas(CARD, CARD)
    if kind == "pine":
        _pine(cv, rs, c1, c2, 5, (0.13, 0.17), 330, 34)
    elif kind == "cedar":
        _pine(cv, rs, c1, c2, 7, (0.15, 0.19), 420, 40)
    elif kind == "spruce":
        _spruce(cv, rs, c1, c2, CARD * 0.032)
    elif kind == "larch":
        _larch(cv, rs, c1, c2)
    else:
        _birch(cv, rng, c1, c2)
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
