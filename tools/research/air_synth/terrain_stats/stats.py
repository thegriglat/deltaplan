"""Статистики рельефа: вершины/седловины/prominence (дерево слияния), спектр, уклоны, анизотропия, дренаж.
Все функции принимают массив высот h (м) и шаг dx (м). Только NumPy/SciPy/numba."""
import heapq
import numpy as np
from numba import njit

# ---------- дерево слияния: вершины, ключевые седловины, prominence ----------
@njit(cache=True)
def _find(p, a):
    while p[a] != a:
        p[a] = p[p[a]]
        a = p[a]
    return a


@njit(cache=True)
def _merge_tree(h, order):
    """Обход клеток по убыванию высоты (8 соседей). Компонента рождается в локальном максимуме
    (нет уже обработанных соседей); при слиянии низшая по вершине компонента «умирает»:
    prominence = высота её вершины - высота клетки слияния (ключевая седловина).
    Возвращает по индексам вершин: клетка вершины, клетка седловины, клетка вершины-родителя."""
    n, m = h.shape
    N = n * m
    parent = np.full(N, -1, np.int64)      # -1: ещё не обработана
    peak = np.full(N, -1, np.int64)        # для корня компоненты — клетка вершины
    pk_cell = np.empty(N, np.int64); sd_cell = np.empty(N, np.int64); par_cell = np.empty(N, np.int64)
    npk = 0
    for t in range(N):
        c = order[t]
        i = c // m; j = c % m
        parent[c] = c
        peak[c] = c
        root = c
        born = True
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                if di == 0 and dj == 0:
                    continue
                ii = i + di; jj = j + dj
                if ii < 0 or jj < 0 or ii >= n or jj >= m:
                    continue
                d = ii * m + jj
                if parent[d] < 0:
                    continue
                r2 = _find(parent, d)
                if born:                      # первый обработанный сосед: клетка просто присоединяется
                    born = False
                    parent[c] = r2
                    root = r2
                    continue
                r1 = _find(parent, root)
                if r1 == r2:
                    continue
                p1 = peak[r1]; p2 = peak[r2]
                # выживает компонента с более высокой вершиной
                if h[p1 // m, p1 % m] >= h[p2 // m, p2 % m]:
                    win, lose, pw, pl = r1, r2, p1, p2
                else:
                    win, lose, pw, pl = r2, r1, p2, p1
                parent[lose] = win
                peak[win] = pw
                pk_cell[npk] = pl; sd_cell[npk] = c; par_cell[npk] = pw
                npk += 1
                root = win
        if born:
            pass
    # главный максимум: выживший
    r = _find(parent, order[0])
    pk_cell[npk] = peak[r]; sd_cell[npk] = -1; par_cell[npk] = -1
    npk += 1
    return pk_cell[:npk], sd_cell[:npk], par_cell[:npk]


def peaks(h, dx):
    """Таблица вершин: y,x (м), высота, prominence, высота ключевой седловины, расстояние до родителя и до седловины.
    Последняя (главный максимум области) имеет prominence = h - min(h) (нижняя оценка)."""
    n, m = h.shape
    hh = h + np.arange(n * m).reshape(n, m) * 1e-9          # разрыв равенств по индексу
    order = np.argsort(-hh.ravel(), kind="stable").astype(np.int64)
    pk, sd, par = _merge_tree(hh, order)
    pi, pj = pk // m, pk % m
    ph = h[pi, pj]
    has = sd >= 0
    sh = np.where(has, h.ravel()[np.where(has, sd, 0)], h.min())
    prom = ph - sh
    qi, qj = np.where(has, par // m, pi), np.where(has, par % m, pj)
    si, sj = np.where(has, sd // m, pi), np.where(has, sd % m, pj)
    return dict(y=pi * dx, x=pj * dx, h=ph, prom=prom, saddle_h=sh,
                d_parent=np.hypot(pi - qi, pj - qj) * dx, d_saddle=np.hypot(pi - si, pj - sj) * dx,
                sy=si * dx, sx=sj * dx)


def critical_counts(h):
    """Критические точки (Банчофф) на триангуляции сетки (6 соседей: (-1,0),(-1,1),(0,1),(1,0),(1,-1),(0,-1)):
    максимумы, минимумы, седловины (с k чередованиями «выше/ниже» считается k/2-1 раз). Для связной области без краёв
    #max - #saddle + #min = 1 (формула Эйлера для сферы-диска; на краях отклонения)."""
    c = h[1:-1, 1:-1]
    ring = [h[:-2, 1:-1], h[:-2, 2:], h[1:-1, 2:], h[2:, 1:-1], h[2:, :-2], h[1:-1, :-2]]
    s = np.stack([(r > c) for r in ring])
    ch = (s != np.roll(s, 1, axis=0)).sum(axis=0) // 2
    up = s.sum(axis=0)
    return int((up == 0).sum()), int((up == 6).sum()), int(np.where(ch >= 2, ch - 1, 0).sum())


def peak_density(P, thresholds, area_km2):
    return {int(t): float((P["prom"] >= t).sum() / area_km2) for t in thresholds}


def ccdf_exponent(prom, lo, hi):
    """Наклон b в N(>=P) ~ P^-b по log-log МНК на [lo,hi] (м) между точками уникальных значений."""
    p = np.sort(prom[prom > 0])[::-1]
    N = np.arange(1, len(p) + 1)
    sel = (p >= lo) & (p <= hi)
    if sel.sum() < 5:
        return float("nan")
    return float(-np.polyfit(np.log(p[sel]), np.log(N[sel]), 1)[0])


# ---------- уклоны и анизотропия ----------
def gradient(h, dx):
    gy, gx = np.gradient(h, dx)
    return gy, gx


def slope_stats(h, dx):
    gy, gx = gradient(h, dx)
    s = np.degrees(np.arctan(np.hypot(gx, gy)))
    return dict(mean=float(s.mean()), median=float(np.median(s)), p90=float(np.percentile(s, 90)),
                p99=float(np.percentile(s, 99)), frac_gt30=float((s > 30).mean()), frac_gt20=float((s > 20).mean()))


def orientation(h, dx):
    """Тензор структуры градиента: доминирующее направление ХРЕБТОВ (простирание, град от +x, 0..180 против часовой
    при оси y вверх по массиву строк) и анизотропия a = 1 - λmin/λmax (0 — изотропно, 1 — параллельные хребты)."""
    gy, gx = gradient(h - np.mean(h), dx)
    Jxx, Jyy, Jxy = (gx * gx).mean(), (gy * gy).mean(), (gx * gy).mean()
    w, v = np.linalg.eigh(np.array([[Jxx, Jxy], [Jxy, Jyy]]))
    gdir = v[:, 1]                                          # направление наибольшего градиента (поперёк хребтов)
    strike = (np.degrees(np.arctan2(gdir[0], gdir[1])) + 90.0) % 180.0
    return dict(strike_deg=float(strike), anisotropy=float(1 - w[0] / w[1]))


def slope_asymmetry(h, dx):
    """Асимметрия склонов: среднее |склон| на склонах, смотрящих в одну сторону поперёк хребтов / в другую (≥1)."""
    o = orientation(h, dx)
    gy, gx = gradient(h, dx)
    th = np.radians(o["strike_deg"] + 90.0)
    gn = gx * np.cos(th) + gy * np.sin(th)                  # производная поперёк хребтов
    a = np.abs(gn[gn > 0]).mean(); b = np.abs(gn[gn < 0]).mean()
    return float(max(a, b) / min(a, b))


# ---------- спектр ----------
def profile_psd(h, dx):
    """1D PSD вдоль строк и столбцов (окно Ханна, вычитание линейного тренда), усреднённая; возвращает k (1/м), P."""
    out = []
    for arr in (h, h.T):
        n = arr.shape[1]
        x = np.arange(n)
        A = arr - arr.mean(axis=1, keepdims=True)
        # линейный тренд
        t = x - x.mean()
        A = A - np.outer((A @ t) / (t @ t), t)
        w = np.hanning(n)
        F = np.fft.rfft(A * w, axis=1)
        P = (np.abs(F) ** 2).mean(axis=0) * dx / (w ** 2).sum()
        out.append(P)
    k = np.fft.rfftfreq(h.shape[1], dx)
    return k[1:], 0.5 * (out[0] + out[1])[1:], out[0][1:], out[1][1:]


def beta_bands(k, P, bands_m):
    """Наклон beta (P ~ k^-beta) по полосам длин волн [lo,hi) м, логарифмически равномерные бины."""
    res = {}
    for lo, hi in bands_m:
        sel = (1 / k >= lo) & (1 / k < hi)
        if sel.sum() < 3:
            res[f"{lo}-{hi}"] = float("nan"); continue
        res[f"{lo}-{hi}"] = float(-np.polyfit(np.log(k[sel]), np.log(P[sel]), 1)[0])
    return res


# ---------- дренаж (заполнение впадин + D8 + накопление) ----------
@njit(cache=True)
def _flood_fill(h):
    """Priority-flood (Barnes 2014, упрощённо кучей): заполняет впадины, края — стоки; возвращает заполненную h."""
    n, m = h.shape
    f = h.copy()
    closed = np.zeros((n, m), np.bool_)
    heap = [(0.0, 0, 0)]
    heap.pop()
    for i in range(n):
        for j in range(m):
            if i == 0 or j == 0 or i == n - 1 or j == m - 1:
                heapq.heappush(heap, (f[i, j], i, j)); closed[i, j] = True
    while len(heap) > 0:
        z, i, j = heapq.heappop(heap)
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                ii = i + di; jj = j + dj
                if ii < 0 or jj < 0 or ii >= n or jj >= m or closed[ii, jj]:
                    continue
                closed[ii, jj] = True
                if f[ii, jj] < z:
                    f[ii, jj] = z + 1e-4
                heapq.heappush(heap, (f[ii, jj], ii, jj))
    return f


@njit(cache=True)
def _d8_accum(f, dx):
    n, m = f.shape
    N = n * m
    recv = np.arange(N)
    for i in range(n):
        for j in range(m):
            best = 0.0; b = i * m + j
            for di in (-1, 0, 1):
                for dj in (-1, 0, 1):
                    if di == 0 and dj == 0:
                        continue
                    ii = i + di; jj = j + dj
                    if ii < 0 or jj < 0 or ii >= n or jj >= m:
                        continue
                    d = np.sqrt(float(di * di + dj * dj))
                    s = (f[i, j] - f[ii, jj]) / d
                    if s > best:
                        best = s; b = ii * m + jj
            recv[i * m + j] = b
    order = np.argsort(-f.ravel())
    A = np.ones(N) * dx * dx
    for t in range(N):
        c = order[t]
        if recv[c] != c:
            A[recv[c]] += A[c]
    return recv, A.reshape(n, m)


def drainage(h, dx, areas_km2=(0.25, 1.0, 4.0)):
    """Плотность русел Dd (км/км²) при пороге площади водосбора; ср. расстояние хребет–долина ≈ 1/(2 Dd) (км)."""
    f = _flood_fill(h)
    recv, A = _d8_accum(f, dx)
    n, m = h.shape
    ri, rj = recv // m, recv % m
    L = np.hypot(ri - np.arange(n * m) // m, rj - np.arange(n * m) % m).reshape(n, m) * dx
    area_km2 = n * m * dx * dx / 1e6
    out = {}
    for a in areas_km2:
        ch = A >= a * 1e6
        Dd = L[ch].sum() / 1e3 / area_km2
        out[str(a)] = dict(Dd_km_per_km2=float(Dd), half_spacing_m=float(500.0 / Dd) if Dd > 0 else float("nan"))
    # закон Хака: длина главного русла ~ A^h по крупнейшим водосборам (по точкам русел: A vs путь до водораздела не считаем)
    return out


def hypsometric(h):
    return dict(HI=float((h.mean() - h.min()) / (h.max() - h.min())), relief=float(h.max() - h.min()),
                std=float(h.std()))


def local_relief(h, dx, r_m=2500.0):
    from scipy.ndimage import maximum_filter, minimum_filter
    k = int(2 * r_m / dx) | 1
    return float((maximum_filter(h, k) - minimum_filter(h, k)).mean())
