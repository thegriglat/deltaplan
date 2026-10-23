#!/usr/bin/env python3
"""Ядро и видимый ореол солнца на кадре (карточка HH-11).

    tools/shots/sun_halo_measure.py <кадр.jpg> [--vfov=90] [--radius=0.3] [--f=ПИКСЕЛИ] [--at=X,Y] [--ring=25,30] [--profile]

Печатает:
  halo_px=<диаметр ядра, px>     горизонталь через центр ядра, где МАКСИМАЛЬНЫЙ канал >= 250/255;
  disk_px_geom=<диаметр диска>   по radius (0,3°), vfov (90°) и фактической высоте кадра;
  ratio=<halo_px / disk_px_geom> цель 3-3,5 (допуск 2,8-4,0);
  offset_px=<расстояние>         центр ядра (центроид пикселей >= 250) от центра диска: центр диска — из
                                 <папка>/_aux/<кадр>.sun.txt или рядом («sun_px: X Y», пишет игра при DP_SUN_TINT_LOG — проекция
                                 направления на солнце камерой) или --at=X,Y; нет ни того ни другого — 0 (центр = ядро);
  glow_r_px, glow_r_deg          видимый ореол: радиус, где азимутально усреднённое (медиана по кольцу
                                 радиуса, верхняя полуплоскость — над рельефом) превышение линейной яркости над
                                 фоном падает до 10 % от превышения у края диска; фон — небо той же высоты (строка
                                 кадра) вдали от солнца по азимуту (--bg_deg=35°, медиана): кольцо 25-30° вокруг
                                 солнца у горизонта захватывает естественный градиент неба по высоте; прежний
                                 фон кольцом — --ring=25,30;
  center_not_darker, inner_same_color, monotonic, edge_jump (HH-15, решение 2026-10-23)
                                 абсолютные значения кадра (линейные из sRGB): Y центра диска ≥ Y кольца 1–2 диаметра − 1 %; G/R и B/R кольца 1–2 диаметра
                                 отличаются от диска не больше чем на 0,05 (диск и внутренний ореол одного цвета); профиль Y (кольца 1 px,
                                 до glow_r) не растёт (шум 1 %); edge_jump — макс. перепад Y между соседними пикселями профиля в
                                 0,8–1,5 радиуса диска, доля от центра;
  glow_shift_px                 смещение центроида превышения яркости внутри 2·glow_r от диска (в верхней
                                 полуплоскости; рельеф срезает нижнюю часть — смещение вверх неизбежно).
Фон без засвета (HH-15, доработка 3): если рядом есть кадр того же ракурса и момента без SunGlare
(<папка>/_aux/noglare_<имя без after_>.jpg, съёмка с sun_glare.strength = 0; или --ref=<кадр>), то «превышение над фоном»
в center_not_darker / monotonic / edge_jump / glow_r — это кадр − кадр без засвета по пикселям (вклад засвета);
сам диск (r ≤ 1,6 радиуса) — над небом: кадр − медиана неба без засвета в кольце 1,5–3 диаметра диска.
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


def aux_path(path, suffix):
    """Служебный файл кадра: <папка>/_aux/<имя><suffix> (HH-15), иначе рядом с кадром."""
    p = Path(path)
    a = p.parent / "_aux" / (p.stem + suffix)
    return a if a.exists() else p.with_suffix(suffix)


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
    refd = None
    refp = Path(opts["ref"]) if "ref" in opts else Path(path).parent / "_aux" / (Path(path).stem.replace("after_", "noglare_", 1) + ".jpg")
    if refp.exists() and refp != Path(path):
        rppm = subprocess.run(["convert", str(refp), "-depth", "8", "ppm:-"], capture_output=True, check=True).stdout
        rm_ = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s", rppm)
        if rm_ and (int(rm_.group(1)), int(rm_.group(2))) == (w, h):
            refd = rppm[rm_.end():]
    print("ref_frame=%s" % (refp.name if refd is not None else "нет (фон — небо той же строки вдали от солнца)"))
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
        side = aux_path(path, ".sun.txt")
        if side.exists():
            mm = re.search(r"sun_px:\s*([-\d.]+)\s+([-\d.]+)", side.read_text())
            if mm:
                dcx, dcy = float(mm.group(1)), float(mm.group(2))
    print(f"offset_px={math.hypot(cx - dcx, cy - dcy):.1f} disk_center=({dcx:.1f},{dcy:.1f})")

    # HH-15: диск ярче ореола по каждому каналу, профиль монотонный, нет скачка на краю диска.
    # Профиль канала — медиана линейной яркости по кольцам 1 px вокруг центра диска (верхняя полуплоскость).
    def chan(x, y, c):
        return LIN[d[(y * w + x) * 3 + c]]

    # центр профиля — центроид ядра (>= 250): проекция sun.txt бывает на ~2 px в стороне от нарисованного диска
    # (диск 5–6 px), и профиль вокруг неё «размазан»
    pcx, pcy = (cx, cy) if best >= 2 else (dcx, dcy)
    rprof_max = int(min(max(20 * disk, 40), 300))

    def rchan(x, y, c):
        return LIN[refd[(y * w + x) * 3 + c]]

    # небо без засвета у диска: медиана канала кадра без засвета в кольце 1,5–3 диаметра (верхняя полуплоскость)
    skyref = [0.0, 0.0, 0.0]
    if refd is not None:
        for c in range(3):
            vs = []
            for y in range(max(int(pcy - 3 * disk), 0), min(int(pcy) + 1, h)):
                for x in range(max(int(pcx - 3 * disk), 0), min(int(pcx + 3 * disk) + 1, w)):
                    if 1.5 * disk <= math.hypot(x - pcx, y - pcy) <= 3 * disk:
                        vs.append(rchan(x, y, c))
            skyref[c] = statistics.median(vs) if vs else 0.0

    def val(x, y, c, r):
        """Значение для профиля: без кадра без засвета — канал кадра; с ним — вклад засвета (диск — над небом)."""
        if refd is None:
            return chan(x, y, c)
        return chan(x, y, c) - (skyref[c] if r <= 0.8 * disk else rchan(x, y, c))

    def halo_checks(glow_px):
        """Q6 (а): диск — самая яркая точка по Y и по R (абсолютные значения кадра, линейные из sRGB);
        профиль Y от центра до glow_r не растёт (шум 1 %); edge_jump — по Y."""
        cbins = [{} for _ in range(3)]
        for y in range(max(int(pcy) - rprof_max, 0), min(int(pcy) + 1, h)):
            for x in range(max(int(pcx) - rprof_max, 0), min(int(pcx) + rprof_max + 1, w)):
                r = int(math.hypot(x - pcx, y - pcy))
                r = 0 if r < 2 else r  # кольца r = 0 и 1 — по 1 и ~8 пикселей: объединены в одно
                if r <= rprof_max:
                    for c in range(3):
                        cbins[c].setdefault(r, []).append(chan(x, y, c))
        cprof = [{r: statistics.median(v) for r, v in b.items() if len(v) >= 3} for b in cbins]
        if not all(cp.get(0) is not None or cp.get(1) is not None for cp in cprof):
            return
        ylum = {r: 0.2126 * cprof[0][r] + 0.7152 * cprof[1][r] + 0.0722 * cprof[2][r] for r in cprof[0] if r in cprof[1] and r in cprof[2]}
        r_in = max(int(disk / 2), 1)  # пик внутри диска (кольца до радиуса диска): диск 5–6 px после JPEG размыт у края
        cen = [max([v for r, v in cp.items() if r <= r_in] or [0.0]) for cp in cprof]
        cen_y = max([v for r, v in ylum.items() if r <= r_in] or [0.0])
        # кольцо 1–2 диаметра диска от центра (внутренний ореол)
        lo_r = max(int(round(disk)), 1)
        hi_r2 = max(int(round(2 * disk)), lo_r + 1)
        rv = [v for r, v in ylum.items() if lo_r <= r <= hi_r2]
        ring_y = statistics.mean(rv) if rv else 0.0  # Y кольца — среднее по кольцам 1 px между 1 и 2 диаметрами
        ok = cen_y >= ring_y * 0.99  # допуск шума/JPEG 1 %
        print("center_not_darker=%d center_Y=%.3f ring_Y=%.3f" % (int(ok), cen_y, ring_y))

        def ratios(rs):
            v = [[cprof[c][r] for r in rs if r in cprof[c]] for c in range(3)]
            m = [statistics.mean(x) if x else 0.0 for x in v]
            return m[1] / max(m[0], 1e-6), m[2] / max(m[0], 1e-6)

        dg, db = ratios([r for r in cprof[0] if r <= r_in])
        rg, rb = ratios([r for r in cprof[0] if lo_r <= r <= hi_r2])
        same = abs(rg - dg) <= 0.05 and abs(rb - db) <= 0.05
        print("inner_same_color=%d disk G/R=%.3f B/R=%.3f ring G/R=%.3f B/R=%.3f" % (int(same), dg, db, rg, rb))
        hi_r = max(glow_px, hi_r2 + 1)
        # скользящее среднее по 3 кольцам: диск — 5–6 px, медиана колец из 8–15 пикселей шумит на 2–3 %
        ks = sorted(ylum)
        ylum = {r: sum(ylum[q] for q in ks[max(i - 1, 0):i + 2]) / len(ks[max(i - 1, 0):i + 2]) for i, r in enumerate(ks)}
        tol = 0.01 * max(ylum.get(0, 0.0), 1e-6)
        bad, prev = 0, None
        for r in sorted(ylum):
            if r > hi_r:
                break
            if prev is not None and ylum[r] > prev + tol:
                bad += 1
            prev = ylum[r] if prev is None else min(prev, ylum[r]) if ylum[r] <= prev else ylum[r]
        print("monotonic=%d rises=%d" % (int(bad == 0), bad))
        r_d = disk / 2
        jump = 0.0
        for r in sorted(ylum):
            if 0.8 * r_d <= r <= 1.5 * r_d and (r + 1) in ylum:
                jump = max(jump, abs(ylum[r + 1] - ylum[r]))
        print("edge_jump=%.3f" % (jump / max(cen_y, 1e-6)))

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
    sky_y = 0.2126 * skyref[0] + 0.7152 * skyref[1] + 0.0722 * skyref[2]

    def exc_y(x, y, r, bg):
        """Превышение яркости: с кадром без засвета — кадр − он (диск — над небом), иначе кадр − фон строки."""
        if True:  # фон — небо вдали по строке: рядом с диском кадр без засвета ярче кадра (плато цвета солнца), превышение отрицательно
            return luma(x, y) - bg
        if r <= 0.8 * disk:
            return luma(x, y) - sky_y
        i = (y * w + x) * 3
        return luma(x, y) - (0.2126 * LIN[refd[i]] + 0.7152 * LIN[refd[i + 1]] + 0.0722 * LIN[refd[i + 2]])

    valid = [v for v in row_bg.values() if v is not None]
    if not valid and ring_bg is None and refd is None:
        print("glow_r_px=0 glow_r_deg=0.00 (нет фона)")
        return 0
    bins = {}
    for y in range(y_lo, y_hi):
        bg = ring_bg if ring_bg is not None else row_bg.get(y)
        if bg is None and refd is None:
            continue
        dy = y - dcy
        for x in range(max(int(dcx - rmax), 0), min(int(dcx + rmax) + 1, w)):
            r = math.hypot(x - dcx, dy)
            if r <= rmax:
                bins.setdefault(int(r), []).append(exc_y(x, y, r, bg))
    bg_y = (statistics.median(valid) if valid else 0.0) if ring_bg is None else ring_bg
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
    halo_checks(glow)
    # центроид превышения внутри 2·glow_r (верхняя полуплоскость)
    sx = sy = sw = 0.0
    r2 = 2 * glow
    for y in range(max(int(dcy - r2), 0), min(int(dcy), h)):
        for x in range(max(int(dcx - r2), 0), min(int(dcx + r2) + 1, w)):
            if math.hypot(x - dcx, y - dcy) > r2:
                continue
            bg = ring_bg if ring_bg is not None else row_bg.get(y)
            e = exc_y(x, y, math.hypot(x - dcx, y - dcy), bg if bg is not None else bg_y)
            if e > 0:
                sx += e * x
                sy += e * y
                sw += e
    if sw > 0:
        print("glow_shift_px=%.1f" % math.hypot(sx / sw - dcx, sy / sw - dcy))
    return 0


if __name__ == "__main__":
    sys.exit(main())
