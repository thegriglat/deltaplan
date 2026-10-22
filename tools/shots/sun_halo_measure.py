#!/usr/bin/env python3
"""Размер пересвета вокруг солнца на кадре (карточка HH-11).

tools/shots/sun_halo_measure.py <кадр.jpg> [vfov_deg] [radius_deg]
Находит самое широкое по горизонтали пятно насыщения (все каналы >= 250/255) и печатает:
  halo_px=<его ширина, px>  — видимое яркое пятно через центр;
  disk_px_geom=<геометрический диаметр диска, px> по radius_deg (0,3°) и vfov (90°) для высоты кадра.
Нужен ImageMagick (convert), без PIL/numpy.
"""
import math
import subprocess
import sys


def main() -> int:
    path = sys.argv[1]
    vfov = float(sys.argv[2]) if len(sys.argv) > 2 else 90.0
    radius = float(sys.argv[3]) if len(sys.argv) > 3 else 0.3
    ident = subprocess.run(["identify", "-format", "%w %h", path], capture_output=True, text=True, check=True)
    w, h = map(int, ident.stdout.split())
    raw = subprocess.run(["convert", path, "-depth", "8", "rgb:-"], capture_output=True, check=True).stdout
    best, best_row, best_x = 0, -1, 0
    thr = 250
    for y in range(h):
        row = raw[y * w * 3:(y + 1) * w * 3]
        run = 0
        for x in range(w):
            i = x * 3
            if row[i] >= thr and row[i + 1] >= thr and row[i + 2] >= thr:
                run += 1
                if run > best:
                    best, best_row, best_x = run, y, x - run // 2
            else:
                run = 0
    # геометрический диаметр: плоская проекция, tan(угла) * (h/2)/tan(vfov/2)
    f = (h / 2) / math.tan(math.radians(vfov) / 2)
    disk = 2 * f * math.tan(math.radians(radius))
    print(f"halo_px={best} center=({best_x},{best_row}) disk_px_geom={disk:.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
