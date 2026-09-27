#!/usr/bin/env python3
"""Объективное сравнение сгенерированных кандидатов с текущими ассетами.

  uv run --no-project --with numpy --with scipy python tools/sounds/gen/evaluate.py [--png DIR]
Метрики: полоса (частота, выше которой < −60 дБ от пика спектра), центроид, спектральная плоскостность
(шум → 1, тональность/музыка → 0), тональные пики (сколько узких пиков > 15 дБ над медианой — признак «музыкальности»),
LRA и std кратковременной громкости (стационарность для лупов), DC/клиппинг.
"""
import glob, json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from audiolib import SR, load, lufs

ROOT = os.path.join(HERE, "..", "..", "..")
REF = {  # категория генерации → текущий ассет для сравнения
    "airflow_30": "airflow/wind_ears_loop.ogg", "airflow_50": "airflow/wind_rush_loop.ogg",
    "airflow_80": "airflow/air_rush_fast_loop.ogg", "sail_rustle": "sail/wing_under_wind_loop.ogg",
    "sail_flap": "sail/sail_luff_loop.ogg", "trailing_edge": "sail/sail_flutter_synth_loop.ogg",
    "frame_creak": "frame/creak_01.ogg", "meadow_wind_grass": "ambient/grass_wind_loop.ogg",
    "meadow_birds": "ambient/birds_alpine_loop.ogg", "cowbells": "ambient/cowbells_distant_loop.ogg",
}


def metrics(path):
    x = load(path, mono=False)
    m = x.mean(axis=1)
    n = 8192
    fr = np.lib.stride_tricks.sliding_window_view(m, n)[:: n // 2] * np.hanning(n)
    P = (np.abs(np.fft.rfft(fr, axis=1)) ** 2).mean(axis=0) + 1e-20
    f = np.fft.rfftfreq(n, 1 / SR)
    db = 10 * np.log10(P / P.max())
    sm = np.convolve(db, np.ones(9) / 9, "same")
    bw = f[np.where(sm > -60)[0][-1]]
    cen = float((P * f).sum() / P.sum())
    band = (f > 50) & (f < min(bw, 16000))
    flat = float(np.exp(np.mean(np.log(P[band]))) / np.mean(P[band]))
    from scipy.ndimage import median_filter
    med = median_filter(db, 101)
    peaks = int(((db - med) > 15)[band].sum())
    hop = int(0.4 * SR)
    st = np.array([10 * np.log10(np.mean(m[i:i + int(3 * SR)] ** 2) + 1e-12) for i in range(0, max(1, len(m) - int(3 * SR)), hop)])
    I, lra, tp = lufs(x) if len(x) > SR else (np.nan, np.nan, np.nan)
    return dict(dur=round(len(x) / SR, 1), bw_hz=int(bw), centroid=int(cen), flatness=round(flat, 3), tonal_peaks=peaks,
                st_std_db=round(float(st.std()), 1), lufs=I, lra=lra, tp=tp)


def main():
    rows = []
    for key, ref in REF.items():
        rows.append(("ref", key, ref, metrics(os.path.join(ROOT, "assets", "sounds", ref))))
        for model in ("sao", "ldm2l", "audiogen"):
            for f in sorted(glob.glob(os.path.join(HERE, "out", model, f"{key}_s*.wav"))):
                rows.append((model, key, os.path.basename(f), metrics(f)))
    json.dump(rows, open(os.path.join(HERE, "out", "eval.json"), "w"), indent=1, default=float)
    for r in rows:
        print(f"{r[0]:8} {r[1]:18} {r[2]:34}", " ".join(f"{k}={v}" for k, v in r[3].items()))


if __name__ == "__main__":
    main()
