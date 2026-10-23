#!/usr/bin/env python3
"""Размеры отдельных кучевых по кадрам «вид сверху» (top_view.sh): p10/p50/p90 ширины, p90/p10.

    uv run --with numpy --with scipy --with pillow python sizes_top.py --dir=<каталог кадров> \
        --tag=after [--nocloud=nocloud] [--json=out.json]

Кадр <dir>/<tag>_<i>.png и тот же кадр без облаков <dir>/<nocloud>_<i>.png (камера, мир, час те же).
Маска облаков — пиксели, ставшие ярче без облаков на > 20 (верх кучевого даёт +35…55, перистые — до +10) (яркость sRGB 0…255, Y = 0,2126R + 0,7152G + 0,0722B):
верх облака белый на тёмной земле. Площадь пикселя на плоскости — H²·p² / (f² cos³θ), H — высота камеры
над серединой слоя (из <tag>_field.json), f — фокус в пикселях, θ — угол от надира; берётся круг θ < 38°
(дальше растяжение сильное). Ширина облака = 2·√(A/π) по связной области маски; области, касающиеся
края круга, и уже 200 м не считаются. «Облако» здесь — связная область верха облаков с вида сверху:
слитые верха соседних облаков — одна область (граница метода; то же для «до» и «после»).
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

THETA_MAX = math.radians(38.0)
MIN_W = 200.0
THR = 20.0  # верх кучевого на видимой с высоты дымке: +35…55 к кадру без облаков; перистые — до +10


def luma(p):
    a = np.asarray(Image.open(p).convert("RGB"), np.float32)
    return a @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def analyse(d, tag, noc):
    info = json.loads((d / ("%s_field.json" % tag)).read_text())
    fov = math.radians(info["fov_deg"])
    widths = []
    cover_px = valid_px = 0
    for i, fr in enumerate(info["frames"]):
        F = luma(d / ("%s_%d.png" % (tag, i)))
        N = luma(d / ("%s_%d.png" % (noc, i)))
        h, w = F.shape
        f = (h / 2.0) / math.tan(fov / 2.0)
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        rx, ry = xx + 0.5 - w / 2.0, yy + 0.5 - h / 2.0
        r = np.hypot(rx, ry)
        theta = np.arctan(r / f)
        valid = theta < THETA_MAX
        H = fr["cam_height_above_mid_layer_m"]
        dA = (H ** 2) / (f ** 2 * np.cos(theta) ** 3)
        mask = ((F - N) > THR) & valid
        mask = ndimage.binary_opening(mask, iterations=1)
        lab, k = ndimage.label(mask)
        idx = np.arange(1, k + 1)
        area = ndimage.sum(dA, lab, idx)
        ring = valid & ~ndimage.binary_erosion(valid)
        touch = set(np.unique(lab[ring]).tolist())
        for j, a in zip(idx, area):
            if j in touch:
                continue
            wd = 2.0 * math.sqrt(a / math.pi)
            if wd >= MIN_W:
                widths.append(wd)
        cover_px += float((dA * mask).sum())
        valid_px += float((dA * valid).sum())
    w = np.array(widths)
    out = {"tag": tag, "n_clouds": int(len(w)), "frames": len(info["frames"]), "mask_area_fraction": round(cover_px / valid_px, 4),
           "field_cover_mean": info["cover_mean"], "base_msl": info["base_msl"], "depth_max_m": info["depth_max_m"]}
    if len(w) >= 5:
        p = np.percentile(w, [10, 50, 90])
        out.update({"w_p10_m": round(float(p[0])), "w_p50_m": round(float(p[1])), "w_p90_m": round(float(p[2])), "size_p90_p10": round(float(p[2] / p[0]), 2)})
    return out


if __name__ == "__main__":
    o = dict(a.lstrip("-").split("=", 1) for a in sys.argv[1:] if "=" in a)
    r = analyse(Path(o["dir"]), o["tag"], o.get("nocloud", "nocloud"))
    print(json.dumps(r, ensure_ascii=False))
    if o.get("json"):
        Path(o["json"]).write_text(json.dumps(r, indent=1, ensure_ascii=False))
