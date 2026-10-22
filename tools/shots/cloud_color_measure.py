#!/usr/bin/env python3
"""Цвет освещённых боков облаков в кадре (HH-14): медиана G/R и B/R по ярким облачным пикселям.

    tools/shots/cloud_color_measure.py <кадр.jpg> [--mask=<кадр без облаков.jpg>] [--lit=0.25]

Маска облаков = |кадр - кадр без облаков| > 25 по любому каналу (sRGB 8 бит); без --mask берётся
<кадр>.nocloud.jpg рядом (его пишет tools/shots/haze_humidity_shots.sh, режим clouds). Освещённые
бока = доля --lit (25 %) самых ярких пикселей маски (по среднему линейному RGB). Печатает
g_r=, b_r= (медиана попиксельных отношений линейного RGB к R), r_med= (медиана R, линейный),
mask= (доля кадра), n= (число ярких пикселей). Нужны ImageMagick (convert) и numpy.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np


def load(path):
    w, h = map(int, subprocess.run(["identify", "-format", "%w %h", str(path)], capture_output=True,
                                   text=True, check=True).stdout.split())
    raw = subprocess.run(["convert", str(path), "-alpha", "off", "-depth", "8", "rgb:-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(h, w, 3).astype(float)


def lin(c):
    c = np.asarray(c, float) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    if not args:
        sys.exit(__doc__)
    path = Path(args[0])
    mpath = Path(opts["mask"]) if opts.get("mask") else path.with_suffix(".nocloud.jpg")
    if not mpath.exists():
        sys.exit("нет кадра без облаков: %s (--mask=…)" % mpath)
    a, bg = load(path), load(mpath)
    if a.shape != bg.shape:
        sys.exit("размеры кадров не совпадают: %s и %s" % (a.shape, bg.shape))
    h = a.shape[0]
    mask = np.abs(a - bg).max(2) > 25
    mask[int(h * 0.62):] = False  # низ кадра — рельеф, прибор, руки
    n_mask = int(mask.sum())
    if n_mask < 200:
        sys.exit("облачных пикселей слишком мало: %d" % n_mask)
    px = lin(a[mask])
    lum = px.mean(1)
    sel = px[lum >= np.percentile(lum, 100 * (1 - float(opts.get("lit", 0.25))))]
    r = np.maximum(sel[:, 0], 1e-9)
    print("g_r=%.3f b_r=%.3f r_med=%.3f mask=%.4f n=%d" % (
        np.median(sel[:, 1] / r), np.median(sel[:, 2] / r), np.median(sel[:, 0]), n_mask / mask.size, len(sel)))


main()
