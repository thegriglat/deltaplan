"""«Обшивка на каркасе»: статичные деформации паруса поверх гладкой формы WingShape.

Парус натянут, поэтому без симуляции ткани — только смещения вершин сетки паруса:
- провис между латами (sail_sag): мембрана верхней обшивки чуть проседает внутрь (к нижней),
  глубина ∝ вес пролёта w · ширина пролёта; на латах 0, у передней кромки и у киля сходит на нет;
- фестоны задней кромки (te_scallop): между концами лат кромка уходит к носу, концы лат на месте;
- рукав передней кромки (le_sleeve_m): ткань облегает трубу — наплыв с перетяжкой-швом за ним;
- карман поперечины (crossbar_bulge_m): у двухобшивочных поперечина проступает сквозь нижнюю
  обшивку валиком.
UV не трогаем (нарисованные латы остаются на рёбрах), у фестонов сдвигается доля хорды t вдоль
поверхности, а текстура остаётся по исходному t — лента задней кромки идёт по фестону.
Параметры — блок "skin" крыла в glider_params.json (нет блока или 0 — выключено).
"""
import math

from mathutils import Vector


def active(p: dict, preview: bool) -> dict:
    """Блок skin крыла, если он действует в этой сборке (preview_only — только для превью)."""
    sk = p.get("skin")
    if not sk or (sk.get("preview_only", True) and not preview):
        return {}
    return sk


def _smooth(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def bay_width(ws) -> float:
    return 0.97 / ws.p["battens_per_side"] * ws.half


def span_weight(n_batt: int, a: float) -> float:
    """Вес пролёта в точке a полуразмаха (как у span_stations)."""
    if a >= 0.97:
        return 0.0
    f = (a / (0.97 / n_batt)) % 1.0
    return math.sin(math.pi * f)


def upper_normal(ws, u: float, t: float) -> Vector:
    """Внешняя нормаль гладкой верхней обшивки (вверх)."""
    e = 1e-3
    du = ws.upper(min(1.0, u + e), t) - ws.upper(max(-1.0, u - e), t)
    dt = ws.upper(u, min(1.0, t + e)) - ws.upper(u, max(0.0, t - e))
    n = du.cross(dt)
    if n.length < 1e-9:
        return Vector((0, 0, 1))
    n.normalize()
    return n if n.z >= 0 else -n


def _te_shift(ws, sk: dict, a: float, t: float, w: float) -> float:
    """Сдвиг доли хорды к носу у задней кромки (фестон)."""
    t0 = sk.get("te_scallop_t0", 0.85)
    sc = sk.get("te_scallop", 0.0)
    if sc <= 0 or t <= t0:
        return 0.0
    ds = sc * bay_width(ws) * w / ws.chord(a)
    return ds * ((t - t0) / (1 - t0)) ** 2


def _sleeve(sk: dict, t: float) -> float:
    """Наплыв рукава передней кромки наружу (м): горб над трубой, шов-перетяжка на краю рукава."""
    h = sk.get("le_sleeve_m", 0.0)
    if h <= 0:
        return 0.0
    ts = sk.get("le_sleeve_t", 0.07)
    bump = math.sin(math.pi * min(t, ts) / ts) ** 2 if t < ts else 0.0
    seam = math.exp(-((t - ts) / 0.012) ** 2)
    return h * (bump - 0.5 * seam)


def _upper_disp(ws, sk: dict, u: float, t: float, w: float) -> Vector:
    """Смещение верхней обшивки в точке (u, t) без фестона: провис + рукав."""
    a = abs(u)
    n = upper_normal(ws, u, t)
    sag = sk.get("sail_sag", 0.0) * bay_width(ws) * w
    sag *= _smooth(t / sk.get("sag_le_fade_t", 0.15))
    sag *= _smooth(a / sk.get("sag_keel_fade", 0.08))
    return n * (_sleeve(sk, t) - sag)


def upper(ws, sk: dict, u: float, t: float, w: float) -> Vector:
    t2 = t - _te_shift(ws, sk, abs(u), t, w)
    return ws.upper(u, t2) + _upper_disp(ws, sk, u, t2, w)


def _seg_dist(p, a, b) -> float:
    ax, ay = b[0] - a[0], b[1] - a[1]
    k = max(0.0, min(1.0, ((p[0] - a[0]) * ax + (p[1] - a[1]) * ay) / (ax * ax + ay * ay)))
    return math.hypot(p[0] - a[0] - ax * k, p[1] - a[1] - ay * k)


def lower(ws, sk: dict, u: float, tl: float, w: float) -> Vector:
    """Нижняя обшивка: рукав и карман поперечины наружу (вниз); к стыку с верхней (tl → 1)
    перенимает смещение верхней, чтобы шов не разошёлся."""
    t = tl * ws.p["lower_cover"]
    p = ws.lower(u, tl)
    n = upper_normal(ws, u, t)
    d = -n * _sleeve(sk, t)
    cb = sk.get("crossbar_bulge_m", 0.0)
    if cb > 0 and ws.p["double_surface"]:
        s = 1 if u >= 0 else -1
        j = sk["_cb_joint"][s]  # узел поперечины на кромке (build_sail), ось — к центру
        path = ((j.x, j.y), (s * 0.03, 0.08))
        dist = _seg_dist((p.x, p.y), *path)
        width = sk.get("crossbar_bulge_w_m", 0.09)
        d += Vector((0, 0, -cb * max(0.0, 1 - (dist / width) ** 2) ** 2))
    b = tl ** 4
    return p + d * (1 - b) + _upper_disp(ws, sk, u, t, w) * b
