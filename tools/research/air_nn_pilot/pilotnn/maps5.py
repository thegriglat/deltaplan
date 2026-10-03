"""Входные карты П2 v5 (контракт docs/contracts/air-nn-p3.md, «Вход v5»): 27 карт 96² в повёрнутой системе.

0–8   — карты v4 (`prep.maps`) без изменений;
9–14  — уклон вдоль / поперёк ветра рельефа, сглаженного на σ = 600, 1600, 4000 м (/0,3);
15–19 — подсеточные из рельефа 25 м (`tiles/v3`): std и p95 ‖∇h₂₅‖, доли круче ∓0,3 вдоль ветра, перепад в клетке;
20–23 — отрыв: σ((−s_L − 0,3)/0,05) для L = 400, 1200, 3200 м и `sep_wake` (след за кромкой выше по ветру);
24–26 — разгон линейной базы (Б1, `base.linear_base`) на 25, 150, 600 м: ln(max(‖V_base‖, ε)/max(Ub, ε)).

Рельеф 25 м (`tile`): массив 1601 × 1601 [j — север, i — восток], узел (800, 800) — центр, шаг 25 м (поле `h` вырезки П6,
`terrain_cut`). Клетка 400 м [j, i] — блок 16 × 16 узлов 32 + 16·i … 47 + 16·i (как `terrain_cut.block_mean_400`), центр
сетки блоков — узел 799,5. Используется квадрат узлов 31 … 1568 (симметричный относительно 799,5: поворот и отражение
образца переводят блоки в блоки точно; один узел запаса даёт центральные разности на краю блоков). Нет рельефа 25 м
(`tile=None`) — h₂₅ = билинейная интерполяция `d400_hc` (центры блоков → узлы 25 м, у края — ближайшая клетка).

Уклон h₂₅ — `np.gradient` повёрнутого квадрата (шаг 25 м); ‖∇h₂₅‖ и пороги берутся по узлам клетки.
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from scipy import ndimage

from . import base as B
from . import prep as P

MAP_NAMES_V5 = P.MAP_NAMES + (
    "slope_along_1k2", "slope_cross_1k2", "slope_along_3k2", "slope_cross_3k2", "slope_along_8k", "slope_cross_8k",
    "sub_slope_std", "sub_slope_p95", "sub_steep_lee", "sub_steep_wind", "sub_relief",
    "sep_400", "sep_1k2", "sep_3k2", "sep_wake", "base_a25", "base_a150", "base_a600")
_NEG = {"y", "slope_cross", "slope_cross_1k2", "slope_cross_3k2", "slope_cross_8k"}
REFLECT_MAP_SIGN_V5 = np.array([-1.0 if n in _NEG else 1.0 for n in MAP_NAMES_V5], np.float32)

# константы карт 9–23 (владелец NN-P11; изменение — один раз, запись в p3/err_by_feature.md и контракте)
SLOPE_SIGMAS_M = (600.0, 1600.0, 4000.0)
NORM_SLOPE = 0.3
NORM_SUB_STD, NORM_SUB_P95, NORM_SUB_RELIEF_M = 0.3, 0.6, 300.0
STEEP = 0.3                      # порог крутизны подклетки и отрыва (м/м, ~17°)
SEP_WIDTH = 0.05
KW = 7.0                         # длина следа в «перепадах кромки»
WAKE_STEP_M, WAKE_MAX_M = 200.0, 6000.0
DROP_STEP_M, DROP_MAX_M = 400.0, 4000.0     # где искать подножие за кромкой для H(q)
H_MIN_M = 25.0                   # пол перепада (не делить на ноль)
EPS_V = 0.1
BASE_AGL = (25, 150, 600)
SP, NB, FB = 25.0, 96, 16        # шаг тайла, клеток области, узлов в клетке
N0, N1 = 31, 1569                # квадрат узлов тайла: 1538 × 1538


def load_tile(loc, data_root=None):
    """Рельеф 25 м места П6 `t_*` (float32 1601²) или None (нет в `tiles/v3`)."""
    import os
    if not loc.startswith("t_"):
        return None
    root = Path(data_root or os.environ.get("AIR_NN_DATA") or "/home/greg/air_nn_data") / "pilot" / "tiles" / "v3" / "cut"
    p = root / f"{loc}.npz"
    if not p.exists():
        return None
    with np.load(p) as z:
        return z["h"]


def _interp_w(n_out, n_in=NB, first=N0, x0_nodes=-20000.0, xc0=-19200.0 + 0.5 * (FB - 1) * SP, dx=400.0):
    """Матрица (n_out, n_in) линейной интерполяции центров блоков → узлы 25 м, у края — ближайший блок."""
    f = (x0_nodes + (first + np.arange(n_out)) * SP - xc0) / dx
    f = np.clip(f, 0, n_in - 1)
    i0 = np.minimum(np.floor(f).astype(int), n_in - 2)
    t = f - i0
    W = np.zeros((n_out, n_in))
    W[np.arange(n_out), i0] = 1 - t
    W[np.arange(n_out), i0 + 1] = t
    return W


def h25_crop(hc, tile):
    """Квадрат узлов 25 м (1538², float64, исходная система) и признак «был тайл»."""
    if tile is not None:
        t = np.asarray(tile)
        assert t.shape == (1601, 1601), t.shape
        return t[N0:N1, N0:N1].astype(np.float64), True
    W = _interp_w(N1 - N0)
    return W @ np.asarray(hc, np.float64) @ W.T, False


def sub_maps(hc, k, r, tile, steep=STEEP):
    """Карты 15–19 (нормированные), float64 (5, 96, 96) в повёрнутой системе."""
    h, _ = h25_crop(hc, tile)
    h = np.ascontiguousarray(P.rot_scalar(h, k))
    gy, gx = np.gradient(h, SP)
    c, s = math.cos(r), math.sin(r)
    sl = np.hypot(gx, gy)[1:-1, 1:-1]
    al = (gx * c + gy * s)[1:-1, 1:-1]
    blk = lambda a: a.reshape(NB, FB, NB, FB).transpose(0, 2, 1, 3).reshape(NB, NB, FB * FB)  # noqa: E731
    sb, ab, hb = blk(sl), blk(al), blk(h[1:-1, 1:-1])
    return np.stack([sb.std(axis=-1) / NORM_SUB_STD, np.percentile(sb, 95, axis=-1) / NORM_SUB_P95,
                     (ab < -steep).mean(axis=-1), (ab > steep).mean(axis=-1),
                     (hb.max(axis=-1) - hb.min(axis=-1)) / NORM_SUB_RELIEF_M])


def sep_of(s_along, thr=STEEP):
    """Маска отрыва σ((−s − 0,3)/0,05), s — уклон вдоль ветра (м/м)."""
    return 1.0 / (1.0 + np.exp(-(-s_along - thr) / SEP_WIDTH))


def _along(a, d_m, jj, ii, c, s, dx):
    """a в точках p + d·ê′ (d < 0 — выше по ветру); вне области — ближайшая клетка, билинейно."""
    return ndimage.map_coordinates(a, [jj + d_m * s / dx, ii + d_m * c / dx], order=1, mode="nearest")


def sep_wake(hr, r, sep400, dx=400.0, kw=KW):
    """След за кромкой: max по q выше по ветру sep_400(q)·exp(−d/(k_w·H(q))), d = 0…6000 м шагом 200;
    H(q) — перепад за кромкой: max(h(q) − min h(q + d·ê′), 25 м), d = 400…4000 м."""
    ny, nx = hr.shape
    jj, ii = np.meshgrid(np.arange(ny, dtype=np.float64), np.arange(nx, dtype=np.float64), indexing="ij")
    c, s = math.cos(r), math.sin(r)
    low = hr.copy()
    for d in np.arange(DROP_STEP_M, DROP_MAX_M + 0.5 * DROP_STEP_M, DROP_STEP_M):
        np.minimum(low, _along(hr, d, jj, ii, c, s, dx), out=low)
    H = np.maximum(hr - low, H_MIN_M)
    best = sep400.copy()                                                  # d = 0
    for d in np.arange(WAKE_STEP_M, WAKE_MAX_M + 0.5 * WAKE_STEP_M, WAKE_STEP_M):
        sq, Hq = _along(sep400, -d, jj, ii, c, s, dx), _along(H, -d, jj, ii, c, s, dx)
        np.maximum(best, sq * np.exp(-d / (kw * Hq)), out=best)
    return best


def terrain_maps(hr, r, dx=400.0):
    """Карты 9–14 и 20–23 по повёрнутому рельефу: float64 (14, ny, nx) в порядке 9–14, 20–23 (без 15–19, 24–26)."""
    sa0, _ = P.slopes(hr, r, dx)
    sl, sep = [], [sep_of(sa0)]
    out = []
    for sg in SLOPE_SIGMAS_M:
        sa, sc = P.slopes(ndimage.gaussian_filter(hr, sg / dx, mode="nearest"), r, dx)
        out += [sa / NORM_SLOPE, sc / NORM_SLOPE]
        sl.append(sa)
    sep += [sep_of(sl[0]), sep_of(sl[1])]
    return out, sep, sep_wake(hr, r, sep[0], dx)


def base_maps(hr, meta, base=None):
    """Карты 24–26 (Б1): ln(max(‖V_base‖, ε)/max(Ub, ε)) на 25, 150, 600 м."""
    ub = P.ubg(P.AGL, meta["alpha"], meta["mp"], meta["U10"])
    if base is None:
        base = B.linear_base(hr, meta["r"], ub)
    vb = np.hypot(base["u"], base["v"])
    return np.stack([np.log(np.maximum(vb[P.AGL.index(a)], EPS_V) / max(ub[P.AGL.index(a)], EPS_V)) for a in BASE_AGL])


def maps_v5(z, meta, row, tile=None, base=None):
    """Карты входа v5 (27, ny, nx) float32. z — поля образца (`d400_hc`, `d400_H`), tile — рельеф 25 м или None,
    base — итог `linear_base` случая (если уже посчитан)."""
    hc = np.asarray(z["d400_hc"], np.float64)
    dx = float((row.get("d400") or {}).get("dx", 400.0))
    k, r = meta["k"], meta["r"]
    hr = np.ascontiguousarray(P.rot_scalar(hc, k))
    sm, sep, wake = terrain_maps(hr, r, dx)
    out = list(P.maps(z, meta, row).astype(np.float64))
    out += sm
    out += list(sub_maps(hc, k, r, tile))
    out += sep + [wake]
    out += list(base_maps(hr, meta, base))
    X = np.stack(out).astype(np.float32)
    assert X.shape[0] == len(MAP_NAMES_V5)
    return X
