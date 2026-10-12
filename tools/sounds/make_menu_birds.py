#!/usr/bin/env python3
"""Крики хищных птиц для фона меню (assets/sounds/menu/raptor_NN.ogg), по превью freesound (CC0).

  python3 -I tools/sounds/make_menu_birds.py <каталог с <id>.ogg превью>
Из каждой записи берутся самые громкие кластеры в полосе 1,2–6 кГц (промежуток < 1,2 с — один крик),
вырезаются с запасом, ФВЧ 500 Гц (FFT), fade, пик −6 дБ, моно Ogg q4. Список выбранных — в stdout.
"""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import audiolib as a

SR = a.SR
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "sounds", "menu")
# (префикс, id freesound, сколько клипов, макс длина с)
SRC = [("buzzard", 828438, 2, 4.0), ("buzzard", 818322, 1, 3.5), ("hawk", 616926, 2, 3.5),
       ("kite", 830292, 2, 3.0), ("eagle", 832476, 2, 3.5), ("eagle", 675962, 2, 3.5)]


def hp(x, hz):
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1 / SR)
    X *= 1 / (1 + (hz / np.maximum(f, 1e-3)) ** 4)
    return np.fft.irfft(X, len(x)).astype(np.float32)


def clusters(x, maxlen):
    n, hop = 2048, 2205
    w = np.hanning(n); f = np.fft.rfftfreq(n, 1 / SR); band = (f > 1200) & (f < 6000)
    e = np.array([20 * np.log10(np.abs(np.fft.rfft(x[i:i + n] * w))[band].sum() + 1e-9) for i in range(0, len(x) - n, hop)])
    on = e > np.percentile(e, 60) + 6
    segs, s = [], None
    for i, v in enumerate(list(on) + [False]):
        if v and s is None: s = i
        if not v and s is not None:
            if i - s >= 3: segs.append([s, i, e[s:i].max()])
            s = None
    merged = []
    for g in segs:
        if merged and (g[0] - merged[-1][1]) * 0.05 < 1.2: merged[-1][1] = g[1]; merged[-1][2] = max(merged[-1][2], g[2])
        else: merged.append(g)
    merged.sort(key=lambda g: -g[2])
    return [(g[0] * 0.05, min(g[1] * 0.05, g[0] * 0.05 + maxlen)) for g in merged]


def main():
    cache = sys.argv[1]; cnt = {}
    for pref, sid, k, ml in SRC:
        x = a.load(os.path.join(cache, f"{sid}.ogg"))[:, 0]
        for t0, t1 in clusters(x, ml)[:k]:
            c = x[int(max(0, t0 - 0.25) * SR): int((t1 + 0.6) * SR)]
            c = hp(c, 500)
            c = a.fade(c[:, None], 0.08, 0.35)
            c = a.norm_peak(c, -6.0)
            cnt[pref] = cnt.get(pref, 0) + 1
            name = f"raptor_{pref}_{cnt[pref]:02d}.ogg"
            a.save_ogg(os.path.join(OUT, name), c, q=4)
            print(name, sid, f"{t0:.2f}-{t1:.2f}s", f"{len(c) / SR:.2f}s")


main()
