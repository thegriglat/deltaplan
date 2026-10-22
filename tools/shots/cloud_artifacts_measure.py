#!/usr/bin/env python3
"""Артефакты облаков в кадре (HH-16): «светлячки» внутри облаков и «лестница» на их краях.

    tools/shots/cloud_artifacts_measure.py <кадр.jpg> [--mask=<кадр без облаков.jpg>] [--day=<дневной кадр.jpg>]

Маска облаков = |кадр - кадр без облаков| > 25 по любому каналу (sRGB 8 бит, как в
tools/research/haze_humidity/sunset_color/ablation_stats.py); кадр без облаков по умолчанию —
build/cloudart/<имя кадра>.nocloud.jpg копии (его пишет tools/shots/haze_humidity_shots.sh, режим
cloudart; вне папки пользователя), затем <кадр>.nocloud.jpg рядом. Дневной кадр по умолчанию —
<префикс>_day.jpg рядом (после_cloudart_2deg_side.jpg -> after_cloudart_day.jpg).

Печатает:
  fireflies=<число>  изолированных пикселей внутри маски (>= 2 px от края маски), ярче медианы
                     5x5 соседей на > 0,25 линейной яркости (светлые точки внутри облаков);
  edge_step=<число>  по краю маски (пиксель маски с соседом вне маски, 4-связность): доля перепада
                     яркости на шаге 1 px от полного перепада на пяти пикселях поперёк края
                     (|L(p) - L(q)| / (|L(p-2n) - L(q+2n)|), n - ориентация края по осям;
                     гладкий край ~0,25-0,4, лестница/зубцы -> 1), среднее по краю;
  edge_step_ratio=<число>  edge_step кадра / edge_step дневного кадра (контроль; лестница на краях ↑);
  mask=<доля кадра>, edge_px=<число пикселей края>.
Нужны ImageMagick (convert) и numpy.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]


def load(path):
    w, h = map(int, subprocess.run(["identify", "-format", "%w %h", str(path)], capture_output=True,
                                   text=True, check=True).stdout.split())
    raw = subprocess.run(["convert", str(path), "-alpha", "off", "-depth", "8", "rgb:-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(h, w, 3)


def lin_lum(a):
    c = a.astype(np.float32) / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return c @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def shifted(a, dy, dx, fill):
    out = np.full_like(a, fill)
    h, w = a.shape
    ys, yd = (slice(dy, h), slice(0, h - dy)) if dy >= 0 else (slice(0, h + dy), slice(-dy, h))
    xs, xd = (slice(dx, w), slice(0, w - dx)) if dx >= 0 else (slice(0, w + dx), slice(-dx, w))
    out[yd, xd] = a[ys, xs]
    return out


def median5(l):
    h = l.shape[0]
    out = np.empty_like(l)
    pad = np.pad(l, 2, mode="edge")
    for y0 in range(0, h, 120):
        y1 = min(h, y0 + 120)
        st = np.stack([pad[y0 + dy:y1 + dy, dx:dx + l.shape[1]] for dy in range(5) for dx in range(5)])
        out[y0:y1] = np.median(st, axis=0)
    return out


def erode(m, n):
    r = m.copy()
    for _ in range(n):
        r = r & shifted(r, 1, 0, False) & shifted(r, -1, 0, False) & shifted(r, 0, 1, False) & shifted(r, 0, -1, False)
    return r


def edge_step(l, mask):
    """Среднее по краю маски: перепад на шаге 1 px / перепад на 5 px поперёк края (по оси)."""
    vals = []
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nb = shifted(mask, dy, dx, False)  # сосед в сторону (dy, dx)
        e = mask & ~nb
        e[:2, :] = e[-2:, :] = False
        e[:, :2] = e[:, -2:] = False
        if not e.any():
            continue
        p = l
        q = shifted(l, dy, dx, 0.0)
        a = shifted(l, -2 * dy, -2 * dx, 0.0)
        b = shifted(l, 3 * dy, 3 * dx, 0.0)
        step = np.abs(p - q)[e]
        span = np.abs(a - b)[e]
        ok = span > 0.02
        vals.append(np.clip(step[ok] / span[ok], 0.0, 1.0))
    v = np.concatenate(vals) if vals else np.zeros(1)
    return float(v.mean()), int(v.size)


def analyze(path, mpath):
    a = load(path)
    bg = load(mpath)
    mask = np.abs(a.astype(np.int16) - bg.astype(np.int16)).max(2) > 25
    l = lin_lum(a)
    return l, mask


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    if not args:
        sys.exit(__doc__)
    path = Path(args[0])

    def nocloud(p):
        for c in (ROOT / "build" / "cloudart" / (p.stem + ".nocloud.jpg"), p.with_suffix(".nocloud.jpg")):
            if c.exists():
                return c
        sys.exit("нет кадра без облаков для %s (--mask=…)" % p)

    mpath = Path(opts["mask"]) if opts.get("mask") else nocloud(path)
    l, mask = analyze(path, mpath)
    inner = erode(mask, 2)
    med = median5(l)
    ff = int((inner & ((l - med) > 0.25)).sum())
    step, edge_px = edge_step(l, mask)
    out = {"fireflies": ff, "edge_step": round(step, 4), "mask": round(float(mask.mean()), 4), "edge_px": edge_px}
    dpath = Path(opts["day"]) if opts.get("day") else None
    if dpath is None:
        name = path.name
        for tag in ("_2deg_side", "_2deg_sun", "_1deg_side", "_1deg_sun"):
            if tag in name:
                dpath = path.with_name(name.replace(tag, "_day"))
    ratio = None
    if dpath is not None and dpath.exists():
        ld, md = analyze(dpath, nocloud(dpath) if not opts.get("daymask") else Path(opts["daymask"]))
        sd, _ = edge_step(ld, md)
        if sd > 1e-6:
            ratio = step / sd
    print("fireflies=%d" % ff)
    print("edge_step=%.4f" % step)
    if ratio is not None:
        print("edge_step_ratio=%.3f" % ratio)
    print("mask=%.4f edge_px=%d" % (out["mask"], edge_px))


if __name__ == "__main__":
    main()
