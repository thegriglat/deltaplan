#!/usr/bin/env python3
"""Реплика маски отдельных кучевых слоя поля (cf_mask / cf_excess / cf_dome в cloud_common.gdshaderinc)
на CPU: сечение на высоте основания + 200 м, размеры облаков (связные области), высота/ширина.
Константы формы читаются из шейдера (CF_*), текстура — assets/textures/clouds/cloud_shape.png (RGB:
G — маска, B — её крупная часть; трилинейная выборка с переносом, как sampler3D repeat_enable; мипы не
учитываются), квантили — как cloud_layer.gd (свёртка гистограммы G, последний — 1 − 1e-5).

    uv run --with numpy --with scipy --with pillow python mask_sim.py [--cover=0.2,0.35] [--depth=2500]

Не реплика ли полного расчёта плотности: без клубов, мелкого шума, стадий; размеры — по маске и пределу
высоты (top > 200 м над основанием); реальный вид сверху — sizes_top.py по кадрам top_view.sh.
"""
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[4]
SHADER = ROOT / "scripts/atmosphere/cloud_common.gdshaderinc"
PERIOD_M = 8000.0


def const(name):
    m = re.search(r"const float %s = ([-0-9.]+);" % name, SHADER.read_text(encoding="utf-8"))
    return float(m.group(1))


def const_vec3(name):
    m = re.search(r"const vec3 %s = vec3\(([^)]*)\);" % name, SHADER.read_text(encoding="utf-8"))
    return np.array([float(x) for x in m.group(1).split(",")], np.float32)


def load_vol():
    a = np.asarray(Image.open(ROOT / "assets/textures/clouds/cloud_shape.png"), np.float32) / 255.0
    n, cols = 128, 16
    vol = np.zeros((n, n, n, 3), np.float32)  # [x, y, z, канал]
    for z in range(n):
        r, c = divmod(z, cols)
        vol[:, :, z, :] = np.swapaxes(a[r * n:(r + 1) * n, c * n:(c + 1) * n, :], 0, 1)
    return vol


def tex(vol, q, ch):
    n = vol.shape[0]
    return ndimage.map_coordinates(vol[..., ch], q * n - 0.5, order=1, mode="grid-wrap")


def quantiles(vol):
    """16 квантилей суммы двух выборок G — как noise_quantiles в cloud_layer.gd."""
    h = np.bincount(np.round(vol[..., 1] * 255).astype(int).ravel(), minlength=256).astype(np.float64)
    conv = np.convolve(h, h)
    cum = np.cumsum(conv) / conv.sum()
    q = np.zeros(16)
    for k in range(1, 16):
        t = k / 15.0 if k < 15 else 1.0 - 1e-5
        q[k] = np.searchsorted(cum, t - 1e-9) / 255.0
    q[0] = np.nonzero(conv)[0][0] / 255.0
    return q


def threshold(qs, c):
    x = np.clip(1.0 - c, 0, 1) * 15.0
    i = min(int(x), 14)
    return qs[i] + (qs[i + 1] - qs[i]) * (x - i)


def field(vol, qs, cover, depth_m, y_m=200.0, extent_m=48000.0, step_m=40.0, seed=0):
    """Превышение порога e и высота облака top (м) на сетке сечения y_m над основанием."""
    k, o = const("CF_MASK_K"), const_vec3("CF_MASK_O").reshape(3, 1, 1)
    n = int(extent_m / step_m)
    g = (np.arange(n) + 0.5) * step_m + seed * 7919.0
    x, z = np.meshgrid(g, g, indexing="ij")
    q = np.stack([x.astype(np.float32), np.full(x.shape, y_m * 0.3 + seed * 37.0, np.float32), z.astype(np.float32)]) / PERIOD_M
    q2 = (q * k + o) % 1.0
    q = q % 1.0
    s = tex(vol, q, 1) + tex(vol, q2, 1)
    c = tex(vol, q, 2) + tex(vol, q2, 2)
    thr = threshold(qs, cover)
    e = (s - thr) / max(qs[15] - qs[8], 1e-3)
    xi = np.clip(((c - const("CF_XI_MU")) / const("CF_XI_SD") - const("CF_XI_LO")) / (const("CF_XI_HI") - const("CF_XI_LO")), 0, 1)
    dm = np.asarray(depth_m, np.float32)
    lim = np.minimum(dm, const("CF_ASPECT") * np.maximum(1.0, dm / const("CF_D_REF")) * const("CF_W_MIN") * (const("CF_W_MAX") / const("CF_W_MIN")) ** xi)
    xx = np.clip(e / const("CF_DOME_E"), 0, 1)
    top = lim * np.sqrt(xx * (2 - xx))
    return e, top, step_m


def field_legacy(vol, cover, depth_m, y_m=200.0, extent_m=48000.0, step_m=40.0, seed=0):
    """Прежняя модель (до CLK-2): маска 1 − R одной выборкой, верх = depth·√min(e/0,8; 1), плато и стенка."""
    h = np.bincount(np.round(vol[..., 0] * 255).astype(int).ravel(), minlength=256)[::-1].astype(np.float64)  # 1 − R
    cum = np.cumsum(h) / h.sum()
    qs = np.array([np.searchsorted(cum, k / 15.0 - 1e-9) / 255.0 for k in range(16)])
    n = int(extent_m / step_m)
    g = (np.arange(n) + 0.5) * step_m + seed * 7919.0
    x, z = np.meshgrid(g, g, indexing="ij")
    q = np.stack([x.astype(np.float32), np.full(x.shape, y_m * 0.3 + seed * 37.0, np.float32), z.astype(np.float32)]) / PERIOD_M
    m = 1.0 - tex(vol, q % 1.0, 0)
    thr = threshold(qs, cover)
    e = (m - thr) / max(1.0 - thr, 1e-3)
    return e, depth_m * np.sqrt(np.clip(e / 0.8, 0, 1)), step_m


def sizes(cover, depth_m=2500.0, min_w=200.0, seeds=(0, 1, 2), legacy=False):
    vol = load_vol()
    qs = quantiles(vol)
    W, H, AS, ca, cb = [], [], [], [], []
    for sd in seeds:
        e, top, step = field_legacy(vol, cover, depth_m, seed=sd) if legacy else field(vol, qs, cover, depth_m, seed=sd)
        inside = (e > 0) & (top > 200.0)
        lab, k = ndimage.label(inside)
        idx = np.arange(1, k + 1)
        area = ndimage.sum(inside, lab, idx) * step ** 2
        w = 2 * np.sqrt(area / np.pi)
        hmax = ndimage.maximum(top, lab, idx)
        edge = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]])).tolist())
        keep = np.array([i not in edge for i in idx]) & (w >= min_w)
        W.append(w[keep]); ca.append(inside.mean()); cb.append((e > 0).mean())
        # высота/ширина — по основанию (e > 0): ширина по площади основания, высота — наибольший верх облака
        lb, kb = ndimage.label(e > 0)
        ib = np.arange(1, kb + 1)
        wb = 2 * np.sqrt(ndimage.sum(e > 0, lb, ib) * step ** 2 / np.pi)
        hb = ndimage.maximum(top, lb, ib)
        eb = set(np.unique(np.concatenate([lb[0], lb[-1], lb[:, 0], lb[:, -1]])).tolist())
        kb_ = np.array([i not in eb for i in ib]) & (wb >= min_w)
        H.append(hb[kb_]); AS.append(hb[kb_] / wb[kb_])
    w, h, a = np.concatenate(W), np.concatenate(H), np.concatenate(AS)
    pc = lambda v, ps: [round(float(np.percentile(v, p)), 2) for p in ps]
    return {"model": "до (R, одна выборка)" if legacy else "после (G+B, две выборки)", "cover": cover, "depth_m": depth_m, "area_e_pos": round(float(np.mean(cb)), 4), "area_at_200m": round(float(np.mean(ca)), 4),
            "n": int(len(w)), "w_p10_p50_p90": pc(w, (10, 50, 90)), "p90_p10": round(float(np.percentile(w, 90) / np.percentile(w, 10)), 2),
            "h_p10_p50_p90": pc(h, (10, 50, 90)), "h_p90_p10": round(float(np.percentile(h, 90) / max(np.percentile(h, 10), 1.0)), 2), "aspect_base_p10_p50_p90": pc(a, (10, 50, 90))}


if __name__ == "__main__":
    covers = [0.2, 0.35]
    depth = 2500.0
    for a in sys.argv[1:]:
        if a.startswith("--cover="):
            covers = [float(x) for x in a.split("=")[1].split(",")]
        if a.startswith("--depth="):
            depth = float(a.split("=")[1])
    for c in covers:
        print(sizes(c, depth, legacy=True))
        print(sizes(c, depth))


def top_to_depth_max(field_json, y_m=200.0, extent_half_m=15000.0, step_m=50.0):
    """Наибольшее по клеткам отношение вершины облака над основанием к мощности клетки (поле сильного дня из
    <тег>_field.json top_view_shot.gd: cover, depth; билинейно, как cf_sample). Маска — реплика (сдвиг ветром
    не учтён: максимум по позициям от него не зависит). Клетки с покрытием < 0,05 и мощностью < 300 м не берутся."""
    import json
    f = json.loads(Path(field_json).read_text())["field"]
    nx, ny, dx = f["nx"], f["ny"], f["dx"]
    cover = np.array(f["cover"], np.float32).reshape(ny, nx)
    depth = np.array(f["depth"], np.float32).reshape(ny, nx)
    vol = load_vol()
    qs = quantiles(vol)
    best = 0.0
    n = int(2 * extent_half_m / step_m)
    g = (np.arange(n) + 0.5) * step_m - extent_half_m
    x, z = np.meshgrid(g, g, indexing="ij")
    # строка массива j — север (z = -(y0 + (j+0.5)dx)); берём клетки в окне вокруг центра сетки
    ci, cj = nx // 2, ny // 2
    u = np.clip((x / dx) + ci, 0, nx - 1.001)
    v = np.clip((-z / dx) + cj, 0, ny - 1.001)
    from scipy.ndimage import map_coordinates
    cv = map_coordinates(cover, [v, u], order=1)
    dp = map_coordinates(depth, [v, u], order=1)
    # превышение для переменного покрытия: порог по квантилю каждого пикселя
    k, o = const("CF_MASK_K"), const_vec3("CF_MASK_O").reshape(3, 1, 1)
    q = np.stack([x.astype(np.float32), np.full(x.shape, y_m * 0.3, np.float32), z.astype(np.float32)]) / PERIOD_M
    q2 = (q * k + o) % 1.0
    q = q % 1.0
    sm = tex(vol, q, 1) + tex(vol, q2, 1)
    c = tex(vol, q, 2) + tex(vol, q2, 2)
    xs = np.clip(1.0 - cv, 0, 1) * 15.0
    i0 = np.minimum(xs.astype(int), 14)
    thr = qs[i0] + (qs[i0 + 1] - qs[i0]) * (xs - i0)
    e = (sm - thr) / max(qs[15] - qs[8], 1e-3)
    xi = np.clip(((c - const("CF_XI_MU")) / const("CF_XI_SD") - const("CF_XI_LO")) / (const("CF_XI_HI") - const("CF_XI_LO")), 0, 1)
    lim = np.minimum(dp, const("CF_ASPECT") * np.maximum(1.0, dp / const("CF_D_REF")) * const("CF_W_MIN") * (const("CF_W_MAX") / const("CF_W_MIN")) ** xi)
    xx = np.clip(e / const("CF_DOME_E"), 0, 1)
    top = lim * np.sqrt(xx * (2 - xx))
    ok = (cv >= 0.05) & (dp >= 300.0) & (e > 0)
    ratio = np.where(ok, top / np.maximum(dp, 1.0), 0.0)
    # по клеткам: максимум по пикселям клетки
    ci_ = np.floor(u).astype(int) * 100000 + np.floor(v).astype(int)
    per = {}
    for key, r in zip(ci_[ok], ratio[ok]):
        if r > per.get(key, 0.0):
            per[key] = r
    vals = np.array(list(per.values())) if per else np.zeros(1)
    return {"cells": int(len(per)), "top_to_depth_max": round(float(vals.max()), 3), "p90_cells": round(float(np.percentile(vals, 90)), 3)}
