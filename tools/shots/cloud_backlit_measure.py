#!/usr/bin/env python3
"""Тела облаков против солнца (HH-15): яркость и цвет тёмной половины облачных пикселей против неба позади.

    tools/shots/cloud_backlit_measure.py <кадр.jpg> [--mask=<кадр без облаков.jpg>] [--body=0.5]

Маска облаков = |кадр − кадр без облаков| > 25 по любому каналу (sRGB 8 бит); без --mask — <папка>/_aux/<кадр>.nocloud.jpg.
Тело = доля --body (50 %) самых тёмных пикселей маски (по линейной светлоте Y). Небо рядом = те же пиксели на кадре
без облаков (небо позади облака, с дымкой). Печатает body_y, sky_y (средняя линейная светлота), ratio = body_y / sky_y,
body_g_r, body_b_r, sky_g_r, sky_b_r (медианы отношений к R), mask= (доля кадра). Нужны ImageMagick (convert) и numpy.
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
    mpath = Path(opts["mask"]) if opts.get("mask") else path.parent / "_aux" / (path.stem + ".nocloud.jpg")
    if not mpath.exists():
        sys.exit("нет кадра без облаков: %s" % mpath)
    a, b = load(path), load(mpath)
    mask = (np.abs(a - b).max(axis=2) > 25)
    if mask.sum() < 50:
        print("mask=0 (облаков в кадре нет)")
        return
    la, lb = lin(a), lin(b)
    y = la @ np.array([0.2126, 0.7152, 0.0722])
    yb = lb @ np.array([0.2126, 0.7152, 0.0722])
    idx = np.argwhere(mask)
    yy = y[mask]
    k = max(int(len(yy) * float(opts.get("body", 0.5))), 1)
    order = np.argsort(yy)[:k]
    sel = idx[order]
    body = la[sel[:, 0], sel[:, 1]]
    sky = lb[sel[:, 0], sel[:, 1]]
    wv = np.array([0.2126, 0.7152, 0.0722])
    by, sy = (body @ wv).mean(), (sky @ wv).mean()
    print("body_y=%.4f sky_y=%.4f ratio=%.3f" % (by, sy, by / max(sy, 1e-9)))
    for name, v in (("body", body), ("sky", sky)):
        print("%s_g_r=%.3f %s_b_r=%.3f" % (name, np.median(v[:, 1] / np.maximum(v[:, 0], 1e-6)), name, np.median(v[:, 2] / np.maximum(v[:, 0], 1e-6))))
    print("mask=%.4f n=%d" % (mask.mean(), k))


main()
