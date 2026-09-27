#!/usr/bin/env python3
"""Проверка готовых звуков: длительность, каналы, громкость (EBU R128), true peak, спектральный центроид,
и для *_loop.ogg — щелчок на стыке лупа (после декодирования Ogg).

  uv run --no-project --with numpy --with scipy python tools/sounds/check_assets.py [--md]

Критерий стыка: click — скачок сэмпла на стыке конец→начало относительно 99-го перцентиля
соседних разностей по файлу. ≤ ~1.5 — щелчка нет (стык не выделяется).
rms_jump_db — разница RMS 50 мс до и после стыка.
"""
import glob, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audiolib import SR, load, lufs, highpass, rms_db

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")


def centroid(x):
    m = x.mean(axis=1)
    n = min(len(m), 1 << 18)
    spec = np.abs(np.fft.rfft(m[:n] * np.hanning(n)))
    f = np.fft.rfftfreq(n, 1 / SR)
    return float((spec * f).sum() / (spec.sum() + 1e-12))


def seam(x):
    """(click, ΔRMS): click = скачок на стыке |x[0]−x[−1]| / 99-й перцентиль |x[n+1]−x[n]| по файлу
    (по худшему каналу). ≤ ~1.5 — стык не отличается от обычного соседства сэмплов."""
    d = np.abs(np.diff(x, axis=0))
    click = float(np.max(np.abs(x[0] - x[-1]) / (np.percentile(d, 99, axis=0) + 1e-12)))
    w = int(0.05 * SR)
    return click, float(abs(rms_db(x[-w:]) - rms_db(x[:w])))


def main():
    md = "--md" in sys.argv
    files = sorted(glob.glob(os.path.join(ROOT, "assets", "sounds", "*", "*.ogg")))
    total = 0
    if md:
        print("| файл | длит., с | кан. | LUFS | LRA | TP, dBFS | центроид, Гц | стык: click / ΔRMS дБ |")
        print("|---|---|---|---|---|---|---|---|")
    bad = []
    for f in files:
        rel = os.path.relpath(f, os.path.join(ROOT, "assets", "sounds"))
        total += os.path.getsize(f)
        x = load(f, mono=False)
        dur = len(x) / SR
        stereo = not np.allclose(x[:, 0], x[:, 1], atol=1e-4)
        i, lra, tp = lufs(x) if dur > 0.4 else (float("nan"), float("nan"), 20 * np.log10(np.abs(x).max()))
        s = ""
        if rel.endswith("_loop.ogg"):
            c, r = seam(x)
            s = f"{c:.2f} / {r:.1f}"
            if c > 1.5:
                bad.append(rel)
        if tp > -0.5:
            bad.append(rel + " (true peak)")
        row = [rel, f"{dur:.2f}", "2" if stereo else "1", f"{i:.1f}", f"{lra:.1f}", f"{tp:.1f}", f"{centroid(x):.0f}", s]
        print(("| " + " | ".join(row) + " |") if md else "  ".join(f"{v:>10}" if k else f"{v:42}" for k, v in enumerate(row)))
    print(f"\nВсего: {len(files)} файлов, {total / 1e6:.1f} МБ. Замечания: {bad or 'нет'}")


if __name__ == "__main__":
    main()
