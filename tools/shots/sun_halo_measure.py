#!/usr/bin/env python3
"""Ядро и видимый ореол солнца на кадре (карточка HH-11).

    tools/shots/sun_halo_measure.py <кадр.jpg> [--vfov=90] [--radius=0.3] [--f=ПИКСЕЛИ] [--at=X,Y] [--ring=25,30] [--profile]

Печатает:
  halo_px=<диаметр ядра, px>     горизонталь через центр ядра, где МАКСИМАЛЬНЫЙ канал >= 250/255;
  disk_px_geom=<диаметр диска>   по radius (0,3°), vfov (90°) и фактической высоте кадра;
  ratio=<halo_px / disk_px_geom> цель 3-3,5 (допуск 2,8-4,0);
  offset_px=<расстояние>         центр ядра (центроид пикселей >= 250) от центра диска: центр диска — из
                                 <кадр>.sun.txt («sun_px: X Y», пишет игра при DP_SUN_TINT_LOG — проекция
                                 направления на солнце камерой) или --at=X,Y; нет ни того ни другого — 0 (центр = ядро);
  glow_r_px, glow_r_deg          видимый ореол: радиус, где азимутально усреднённое (медиана по кольцу
                                 радиуса, верхняя полуплоскость — над рельефом) превышение линейной яркости над
                                 фоном падает до 10 % от превышения у края диска; фон — небо той же высоты (строка
                                 кадра) вдали от солнца по азимуту (--bg_deg=35°, медиана): кольцо 25-30° вокруг
                                 солнца у горизонта захватывает естественный градиент неба по высоте; прежний
                                 фон кольцом — --ring=25,30;
  glow_offset_px                 смещение центроида превышения яркости внутри 2·glow_r от диска (в верхней
                                 полуплоскости; рельеф срезает нижнюю часть — смещение вверх неизбежно).
Фото (не кадр игры): --f=<фокусное в px> (27 мм экв. → горизонтальный угол ≈ 67°, f = ширина/2/tan(33,5°)),
--radius=0.27 (Солнце). Нужен ImageMagick (convert), без PIL/numpy.
"""
import math
import re
import statistics
import subprocess
import sys
from pathlib import Path


def lin(v):
    c = v / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


LIN = [lin(i) for i in range(256)]


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    if not args:
        sys.exit(__doc__)
    path = Path(args[0])
    vfov = float(opts.get("vfov", 90.0))
    radius = float(opts.get("radius", 0.3))
    ppm = subprocess.run(["convert", str(path), "-depth", "8", "ppm:-"], capture_output=True, check=True).stdout
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s", ppm)
    w, h = int(m.group(1)), int(m.group(2))
    d = ppm[m.end():]
    f = float(opts["f"]) if "f" in opts else (h / 2) / math.tan(math.radians(vfov) / 2)
    disk = 2 * f * math.tan(math.radians(radius))

    def mx(x, y):
        i = (y * w + x) * 3
        return max(d[i], d[i + 1], d[i + 2])

    def luma(x, y):
        i = (y * w + x) * 3
        return 0.2126 * LIN[d[i]] + 0.7152 * LIN[d[i + 1]] + 0.0722 * LIN[d[i + 2]]

    # центр ядра: самая плотная клетка 16x16 пикселей >= 250, дальше центроид в окне 80 px
    cell = 16
    dens = {}
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            if mx(x, y) >= 250:
                k = (x // cell, y // cell)
                dens[k] = dens.get(k, 0) + 1
    if not dens:
        print("halo_px=0 center=(-1,-1) disk_px_geom=%.1f" % disk)
        print("ratio=0.00")
        print("offset_px=999")
        print("glow_r_px=0 glow_r_deg=0.00")
        return 0
    kx, ky = max(dens, key=dens.get)
    cx, cy = kx * cell + cell / 2, ky * cell + cell / 2
    for _ in range(3):
        sx = sy = n = 0
        for y in range(max(int(cy) - 80, 0), min(int(cy) + 81, h)):
            for x in range(max(int(cx) - 80, 0), min(int(cx) + 81, w)):
                if mx(x, y) >= 250:
                    sx += x
                    sy += y
                    n += 1
        cx, cy = sx / n, sy / n
    # диаметр ядра по горизонтали через центр: серия подряд идущих пикселей >= 250 в ряду центра
    best = 0
    for y in range(max(int(round(cy)) - 2, 0), min(int(round(cy)) + 3, h)):
        x = int(cx)
        if mx(x, y) < 250:
            continue
        a = b = x
        while a > 0 and mx(a - 1, y) >= 250:
            a -= 1
        while b < w - 1 and mx(b + 1, y) >= 250:
            b += 1
        best = max(best, b - a + 1)
    print(f"halo_px={best} center=({cx:.1f},{cy:.1f}) disk_px_geom={disk:.1f}")
    print(f"ratio={best / disk:.2f}")

    # центр диска по проекции камерой (sun.txt) или --at
    dcx, dcy = cx, cy
    if opts.get("at"):
        dcx, dcy = map(float, opts["at"].split(","))
    else:
        side = path.with_suffix(".sun.txt")
        if side.exists():
            mm = re.search(r"sun_px:\s*([-\d.]+)\s+([-\d.]+)", side.read_text())
            if mm:
                dcx, dcy = float(mm.group(1)), float(mm.group(2))
    print(f"offset_px={math.hypot(cx - dcx, cy - dcy):.1f} disk_center=({dcx:.1f},{dcy:.1f})")

    # видимый ореол: профиль превышения яркости по радиусу от центра диска, верхняя полуплоскость.
    # Фон — небо той же высоты (строки кадра) вдали от солнца по азимуту (|x − x_солнца| от --bg_deg=35°):
    # у горизонта небо ярче к низу и без солнца, кольцо вокруг солнца (25-30°) захватывало бы естественный
    # градиент неба по высоте и принимало его за ореол; --ring=25,30 — прежний фон кольцом (медиана).
    bg_deg = float(opts.get("bg_deg", 35.0))
    rmax = int(f * math.tan(math.radians(30.0))) + 1
    y_lo, y_hi = max(int(dcy - rmax), 0), min(int(dcy), h)
    gap = f * math.tan(math.radians(bg_deg))
    row_bg = {}
    for y in range(y_lo, y_hi):
        vs = [luma(x, y) for x in range(w) if abs(x - dcx) >= gap]
        row_bg[y] = statistics.median(vs) if len(vs) >= 20 else None
    ring_bg = None
    if "ring" in opts:
        ring_lo, ring_hi = map(float, opts["ring"].split(","))
        r_lo, r_hi = f * math.tan(math.radians(ring_lo)), f * math.tan(math.radians(ring_hi))
        vs = []
        for y in range(y_lo, y_hi):
            for x in range(max(int(dcx - r_hi), 0), min(int(dcx + r_hi) + 1, w)):
                if r_lo <= math.hypot(x - dcx, y - dcy) <= r_hi:
                    vs.append(luma(x, y))
        ring_bg = statistics.median(vs) if vs else None
    valid = [v for v in row_bg.values() if v is not None]
    if not valid and ring_bg is None:
        print("glow_r_px=0 glow_r_deg=0.00 (нет фона)")
        return 0
    bins = {}
    for y in range(y_lo, y_hi):
        bg = ring_bg if ring_bg is not None else row_bg.get(y)
        if bg is None:
            continue
        dy = y - dcy
        for x in range(max(int(dcx - rmax), 0), min(int(dcx + rmax) + 1, w)):
            r = math.hypot(x - dcx, dy)
            if r <= rmax:
                bins.setdefault(int(r), []).append(luma(x, y) - bg)
    bg_y = statistics.median(valid) if ring_bg is None else ring_bg
    prof = {r: statistics.median(vs) for r, vs in bins.items() if len(vs) >= 5}
    r_edge = max(int(round(disk / 2)), 1)
    near = [v for r, v in prof.items() if r <= r_edge + 1]
    edge = max(near) if near else max(prof.values())
    if "profile" in opts or "--profile" in sys.argv:
        for deg in (0.3, 0.6, 1, 1.5, 2, 3, 4, 5, 7, 10, 14, 18, 25):
            r = int(round(f * math.tan(math.radians(deg))))
            print("  profile %5.1f deg r=%3d px: excess %.3f" % (deg, r, prof.get(r, float("nan"))))
    thr = 0.1 * edge
    glow = 0
    for r in sorted(prof):
        if r < r_edge:
            continue
        if prof[r] >= thr:
            glow = r
        elif r > glow + 3:
            break
    deg = math.degrees(math.atan(glow / f))
    print(f"bg_lin={bg_y:.3f} edge_excess={edge:.3f} glow_r_px={glow} glow_r_deg={deg:.2f}")
    # центроид превышения внутри 2·glow_r (верхняя полуплоскость)
    sx = sy = sw = 0.0
    r2 = 2 * glow
    for y in range(max(int(dcy - r2), 0), min(int(dcy), h)):
        for x in range(max(int(dcx - r2), 0), min(int(dcx + r2) + 1, w)):
            if math.hypot(x - dcx, y - dcy) > r2:
                continue
            bg = ring_bg if ring_bg is not None else row_bg.get(y)
            e = luma(x, y) - (bg if bg is not None else bg_y)
            if e > 0:
                sx += e * x
                sy += e * y
                sw += e
    if sw > 0:
        print("glow_offset_px=%.1f" % math.hypot(sx / sw - dcx, sy / sw - dcy))
    return 0


if __name__ == "__main__":
    sys.exit(main())
