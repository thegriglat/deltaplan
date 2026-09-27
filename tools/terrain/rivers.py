"""Реки из рельефа: направление стока (priority-flood), площадь водосбора, маска воды.

Нужна потому, что реки — главные ориентиры пилота, а в DEM вода не отмечена.
Считаем сток по самому большому (грубому) слою, чтобы у крупных рек (Катунь) был
водосбор из-за пределов детальной зоны. Ширина реки ~ k·√(площадь водосбора)
(гидравлическая геометрия русла). Центр русла уточняется по детальному слою
(самая низкая точка в радиусе snap_radius_m). Результат — 8-битные PNG-маски
<слой>_water.png той же сетки, что и высоты (255 — вода).
"""

import heapq

import numpy as np


def flow_tree(h: np.ndarray):
    """Priority-flood (Barnes 2014) с эпсилон-заполнением впадин.
    Возвращает parent (куда стекает клетка, −1 — сток за край) и порядок обработки
    (от стоков вверх по течению)."""
    rows, cols = h.shape
    n = rows * cols
    hf = h.ravel().astype(np.float64)
    parent = np.full(n, -1, dtype=np.int64)
    visited = np.zeros(n, dtype=bool)
    heap = []
    for r in range(rows):
        for c in (0, cols - 1):
            i = r * cols + c
            if not visited[i]:
                visited[i] = True
                heap.append((hf[i], i))
    for c in range(cols):
        for r in (0, rows - 1):
            i = r * cols + c
            if not visited[i]:
                visited[i] = True
                heap.append((hf[i], i))
    heapq.heapify(heap)
    order = np.empty(n, dtype=np.int64)
    k = 0
    nbrs = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]
    push = heapq.heappush
    pop = heapq.heappop
    while heap:
        e, i = pop(heap)
        order[k] = i
        k += 1
        r, c = divmod(i, cols)
        for dr, dc in nbrs:
            rr = r + dr
            cc = c + dc
            if 0 <= rr < rows and 0 <= cc < cols:
                j = rr * cols + cc
                if not visited[j]:
                    visited[j] = True
                    parent[j] = i
                    hj = hf[j]
                    push(heap, (hj if hj > e else e + 1e-3, j))
    return parent, order[:k]


def accumulate(parent: np.ndarray, order: np.ndarray, cell_area: float) -> np.ndarray:
    acc = np.full(parent.shape, cell_area, dtype=np.float64)
    for i in order[::-1]:
        p = parent[i]
        if p >= 0:
            acc[p] += acc[i]
    return acc


def snap_to_valley(x: float, z: float, fine_h: np.ndarray, fine: dict, radius_m: float):
    """Сдвинуть точку в самую низкую клетку детального слоя в радиусе (если точка внутри слоя)."""
    s = fine["spacing_m"]
    i = (x - fine["origin_x_m"]) / s
    j = (z - fine["origin_z_m"]) / s
    if i < 0 or j < 0 or i > fine["width"] - 1 or j > fine["height"] - 1:
        return x, z
    rad = int(np.ceil(radius_m / s))
    i0, i1 = max(0, int(i) - rad), min(fine["width"] - 1, int(i) + rad)
    j0, j1 = max(0, int(j) - rad), min(fine["height"] - 1, int(j) + rad)
    win = fine_h[j0:j1 + 1, i0:i1 + 1]
    jj, ii = np.unravel_index(np.argmin(win), win.shape)
    return fine["origin_x_m"] + (i0 + ii) * s, fine["origin_z_m"] + (j0 + jj) * s


def river_segments(h: np.ndarray, info: dict, cfg: dict, fine=None):
    """Отрезки русел [(x0, z0, x1, z1, ширина_м)] по слою h."""
    step = info["spacing_m"]
    parent, order = flow_tree(h)
    acc = accumulate(parent, order, (step / 1000.0) ** 2)
    min_area = float(cfg["min_area_km2"])
    idx = np.nonzero(acc >= min_area)[0]
    cols = info["width"]
    pos = {}

    def xz(i):
        if i not in pos:
            r, c = divmod(int(i), cols)
            x = info["origin_x_m"] + c * step
            z = info["origin_z_m"] + r * step
            if fine is not None:
                x, z = snap_to_valley(x, z, fine[0], fine[1], float(cfg["snap_radius_m"]))
            pos[i] = (x, z)
        return pos[i]

    segs = []
    for i in idx:
        p = parent[i]
        if p < 0:
            continue
        w = float(np.clip(float(cfg["width_k"]) * np.sqrt(acc[i]), cfg["min_width_m"], cfg["max_width_m"]))
        x0, z0 = xz(i)
        x1, z1 = xz(p)
        segs.append((x0, z0, x1, z1, w))
    print(f"  реки: {len(segs)} отрезков, крупнейший водосбор {acc.max():.0f} км²")
    return segs


def rasterize(segs, info: dict) -> np.ndarray:
    """Маска воды 0..255 на сетке слоя (сглаженный край ~1 клетка)."""
    s = info["spacing_m"]
    w, hgt = info["width"], info["height"]
    mask = np.zeros((hgt, w), dtype=np.float32)
    ox, oz = info["origin_x_m"], info["origin_z_m"]
    for x0, z0, x1, z1, width in segs:
        r = width / 2.0
        i0 = int(np.floor((min(x0, x1) - r - s - ox) / s))
        i1 = int(np.ceil((max(x0, x1) + r + s - ox) / s))
        j0 = int(np.floor((min(z0, z1) - r - s - oz) / s))
        j1 = int(np.ceil((max(z0, z1) + r + s - oz) / s))
        i0, j0 = max(i0, 0), max(j0, 0)
        i1, j1 = min(i1, w - 1), min(j1, hgt - 1)
        if i0 > i1 or j0 > j1:
            continue
        gx = ox + np.arange(i0, i1 + 1) * s
        gz = oz + np.arange(j0, j1 + 1) * s
        X, Z = np.meshgrid(gx, gz)
        dx, dz = x1 - x0, z1 - z0
        L2 = dx * dx + dz * dz
        t = np.clip(((X - x0) * dx + (Z - z0) * dz) / L2, 0, 1) if L2 > 0 else 0.0
        d = np.hypot(X - (x0 + t * dx), Z - (z0 + t * dz))
        # узкие ручьи уже клетки: маска = доля воды в клетке
        cov = np.clip((r - d) / s + 0.5, 0, 1) * min(1.0, width / s)
        sub = mask[j0:j1 + 1, i0:i1 + 1]
        np.maximum(sub, cov, out=sub)
    return (mask * 255).astype(np.uint8)
