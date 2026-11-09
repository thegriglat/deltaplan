"""Зоны отрыва Хеда (separation3d, SWD2) как диагностика покрытия точек: лежит ли точка (x, y) на линии тока между
точкой отрыва и присоединением (или на 1500 м ниже по ветру от отрыва без присоединения).

Допущение: «покрыта» — расстояние в плане до отрезка отрыв–присоединение ≤ COVER_R (100 м, ≈ 2 шага затравок
линий тока 2·ds_min = 50 м). Порог выбран заранее, не подгонялся; это диагностика, не поправка к скорости.
"""
from __future__ import annotations

import numpy as np

from panels3d import separation3d

COVER_R = 100.0
NO_REATTACH_LEN = 1500.0


def zones(run):
    res = separation3d(run.panels, run.sigma, run.bg, run.z0, lee_only=True)
    pts = res["points"]
    ex, ey = run.wt
    seg = []
    for i in range(len(pts["x"])):
        x0, y0 = float(pts["x"][i]), float(pts["y"][i])
        rea = pts["reattach"][i]
        if rea is None:
            x1, y1 = x0 + NO_REATTACH_LEN * ex, y0 + NO_REATTACH_LEN * ey
        else:
            x1, y1 = rea["x"], rea["y"]
        seg.append((x0, y0, x1, y1, rea is not None))
    return seg, len(res["rejected"]["x"])


def covered(seg, x, y):
    """bool-массив: точка в зоне отрыва; + расстояние вдоль зоны не нужно."""
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    out = np.zeros(x.shape, bool)
    for x0, y0, x1, y1, _ in seg:
        dx, dy = x1 - x0, y1 - y0
        L2 = dx * dx + dy * dy
        t = np.clip(((x - x0) * dx + (y - y0) * dy) / L2, 0.0, 1.0) if L2 > 0 else np.zeros_like(x)
        d = np.hypot(x - (x0 + t * dx), y - (y0 + t * dy))
        out |= d <= COVER_R
    return out
