#!/usr/bin/env python3
"""Цветность ядра диска солнца в кадре (HH-13): проверка, что тонмаппинг не выбеливает HDR-диск.

    tools/shots/sun_color_measure.py <кадр.jpg> [--expected=G_R,B_R] [--at=X,Y] [--win=R] [--core=R]

Центр солнца — --at=X,Y, или <кадр>.sun.txt (проекция направления на солнце камерой), иначе самое яркое пятно (ненадёжно); усредняет RGB ядра диска (радиус --core=2 px) в линейном
виде (из sRGB) и печатает g_r=, b_r= (отношения к R), expected= и within=1|0 (±0,1 по обоим).
Ожидаемое — --expected или строка «sun_tint: … g_r=… b_r=…» из <кадр>.tint.txt (пишет
haze_humidity_shots.sh; SkyEnvironment печатает её при DP_SUN_TINT_LOG). Нужен ImageMagick (convert).
"""
import re
import subprocess
import sys
from pathlib import Path

TOL = 0.1


def lin(v):
    c = v / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    if not args:
        sys.exit(__doc__)
    path = Path(args[0])
    ppm = subprocess.run(["convert", str(path), "-depth", "8", "ppm:-"], capture_output=True, check=True).stdout
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s", ppm)
    w, h = int(m.group(1)), int(m.group(2))
    d = ppm[m.end():]
    # центр солнца — максимум яркости над локальным средним (окно 41x41) в окне поиска вокруг
    # центра кадра (камера смотрит на солнце, --win=радиус, по умолчанию 220 px); иначе — по всему кадру
    win = int(opts.get("win", 220))
    x0, x1 = max(w // 2 - win, 0), min(w // 2 + win, w)
    y0, y1 = max(h // 2 - win, 0), min(h // 2 + 30, h)  # ниже — прибор и руки
    ww, hh = x1 - x0, y1 - y0
    lum = [[d[((y0 + j) * w + x0 + i) * 3] + d[((y0 + j) * w + x0 + i) * 3 + 1] + d[((y0 + j) * w + x0 + i) * 3 + 2]
            for i in range(ww)] for j in range(hh)]
    integ = [[0] * (ww + 1) for _ in range(hh + 1)]
    for j in range(hh):
        run = 0
        for i in range(ww):
            run += lum[j][i]
            integ[j + 1][i + 1] = integ[j][i + 1] + run
    k = 20
    best, bx, by = -1e9, 0, 0
    for j in range(k, hh - k):
        for i in range(k, ww - k):
            sm = integ[j + k + 1][i + k + 1] - integ[j - k][i + k + 1] - integ[j + k + 1][i - k] + integ[j - k][i - k]
            sc = lum[j][i] - sm / float((2 * k + 1) ** 2)
            if sc > best:
                best, bx, by = sc, i, j
    cx, cy = x0 + bx, y0 + by
    if opts.get("at"):  # центр диска известен (по кадру) — не искать
        cx, cy = map(float, opts["at"].split(","))
    else:  # центр диска по проекции камерой — <кадр>.sun.txt («sun_px: X Y», пишет игра при DP_SUN_TINT_LOG)
        sun_txt = path.with_suffix(".sun.txt")
        if sun_txt.exists():
            mm = re.search(r"sun_px:\s*([-\d.]+)\s+([-\d.]+)", sun_txt.read_text())
            if mm:
                cx, cy = float(mm.group(1)), float(mm.group(2))
    rad = int(opts.get("core", 2))
    acc = [0.0, 0.0, 0.0]
    cnt = 0
    for y in range(max(int(cy) - rad, 0), min(int(cy) + rad + 1, h)):
        for x in range(max(int(cx) - rad, 0), min(int(cx) + rad + 1, w)):
            if (x - cx) ** 2 + (y - cy) ** 2 <= rad * rad:
                i = (y * w + x) * 3
                for k in range(3):
                    acc[k] += lin(d[i + k])
                cnt += 1
    r, g, b = (a / cnt for a in acc)
    g_r, b_r = g / max(r, 1e-9), b / max(r, 1e-9)
    print("centre=%.0f,%.0f core_rgb_lin=%.3f,%.3f,%.3f" % (cx, cy, r, g, b))
    print("g_r=%.3f b_r=%.3f" % (g_r, b_r))
    exp = opts.get("expected")
    if exp:
        eg, eb = map(float, exp.split(","))
    else:
        side = path.with_suffix(".tint.txt")
        if not side.exists():
            print("expected=? (нет --expected и %s)" % side.name)
            print("within=0")
            return
        mm = re.search(r"g_r=([\d.]+) b_r=([\d.]+)", side.read_text())
        eg, eb = float(mm.group(1)), float(mm.group(2))
    print("expected g_r=%.3f b_r=%.3f" % (eg, eb))
    print("within=%d" % (1 if abs(g_r - eg) <= TOL and abs(b_r - eb) <= TOL else 0))


main()
