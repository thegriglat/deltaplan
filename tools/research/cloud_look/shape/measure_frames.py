#!/usr/bin/env python3
"""Метрики шума облаков по кадрам меню: ступени/полосы (banding) и шум краёв (edge_noise).

    uv run --with numpy --with scipy --with pillow python measure_frames.py --warm=<каталог warm> \
        --nocloud=<каталог кадров без облаков> --before=base --after=after [--nums=09,34] [--json=файл]

Входы: <warm>/<тег>_w40/NN_*.jpg и <warm>/<тег>_w44/NN_*.jpg — один кадр меню (1920x1080) с прогревом 40 и
44 кадра (shots_warm.py): тот же мир и камера, другая фаза дрожания начала луча (IGN, сдвиг frame % 64) —
вторая независимая выборка шума марша; <nocloud>/NN_*.jpg — тот же ракурс без облаков
({"clouds": {"enabled": false}}, README.md). Маска облаков = max по каналам |кадр − кадр без облаков| > 25
(sRGB 8 бит; как tools/shots/cloud_artifacts_measure.py), без пятен меньше 40 px; внутри — маска, сжатая на 6 px.

Зачем так. Ступени и зерно в кадрах меню — ошибка выборки марша: поверхность облака попадала на узел
решётки шагов луча (шаг в десятки метров при пробеге ~11 м), решётка зависит от дрожания, и кадры с разной
фазой дрожания различаются именно там. Статичные текстурные меры (спектр, когерентность, энергия на полосе
частот) на кадрах «до» и «после» не различали: освещение и форма облака дают в них больше, чем зерно.

banding = СКО полосовой части (гаусс σ=2 px − гаусс σ=12 px: полосы и ступени 4–30 px) разности L(w40) − L(w44)
(линейная яркость) внутри маски / СКО L внутри маски. banding_ratio = banding(после) / banding(до).
edge_noise = СКО той же разности (без фильтра) в поясе края: a = clip(max|кадр − без облаков| / 60, 0, 1),
пояс 0,05 < гаусс(a, σ=3) < 0,95; / СКО L внутри маски. edge_noise_ratio = edge_noise(после) / edge_noise(до).
Граница: меры считают шум выборки (между кадрами), а не ровные горизонтальные «полки» самой формы облака — те
убирает форма (mask_sim.py, top_view); при смене формы маска «до» и «после» разная (форма облаков другая).
"""
import glob
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), np.uint8)


def lin_lum(a):
    c = a.astype(np.float32) / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return c @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def diff(frame, nocloud):
    return np.abs(frame.astype(np.int16) - nocloud.astype(np.int16)).max(axis=2)


def cloud_mask(d):
    m = ndimage.binary_opening(d > 25, iterations=1)
    lab, n = ndimage.label(m)
    if n:
        size = ndimage.sum(m, lab, range(1, n + 1))
        m = np.isin(lab, 1 + np.nonzero(size >= 40)[0])
    return m


def noise(f40, f44, nocloud):
    d = diff(f40, nocloud)
    m = cloud_mask(d)
    inner = ndimage.binary_erosion(m, iterations=6)
    L1, L2 = lin_lum(f40), lin_lum(f44)
    e = L1 - L2
    den = float(np.sqrt((L1[inner] ** 2).mean()))
    bp = ndimage.gaussian_filter(e, 2.0) - ndimage.gaussian_filter(e, 12.0)
    a = np.clip(d.astype(np.float32) / 60.0, 0.0, 1.0)
    s3 = ndimage.gaussian_filter(a, 3.0)
    band = (s3 > 0.05) & (s3 < 0.95)
    return {"banding": float(np.sqrt((bp[inner] ** 2).mean())) / den,
            "edge_noise": float(np.sqrt((e[band] ** 2).mean())) / den,
            "mask": float(m.mean())}


def find(d, num):
    g = sorted(glob.glob("%s/%s_*.jpg" % (d, num)) + glob.glob("%s/%s_*.png" % (d, num)))
    return g[0] if g else None


def main():
    o = dict(a.lstrip("-").split("=", 1) for a in sys.argv[1:] if "=" in a)
    warm = o["warm"]
    out = {}
    for n in o.get("nums", "09,34").split(","):
        noc = find(o["nocloud"], n)
        row = {}
        for tag in (o.get("before", "base"), o.get("after", "after")):
            a, b = find("%s/%s_w40" % (warm, tag), n), find("%s/%s_w44" % (warm, tag), n)
            if not (a and b and noc):
                print("нет кадра", n, tag, a, b, noc)
                continue
            row[tag] = noise(load(a), load(b), load(noc))
        if len(row) == 2:
            b, a = row[o.get("before", "base")], row[o.get("after", "after")]
            out["banding_ratio_" + n] = round(a["banding"] / b["banding"], 3)
            out["edge_noise_ratio_" + n] = round(a["edge_noise"] / b["edge_noise"], 3)
            out["detail_" + n] = row
        print(n, json.dumps(row))
    if o.get("json"):
        Path(o["json"]).write_text(json.dumps(out, indent=1, ensure_ascii=False))
    print(json.dumps({k: v for k, v in out.items() if not k.startswith("detail")}))


if __name__ == "__main__":
    main()
