#!/usr/bin/env python3
"""Обработка выбранных звуков → assets/sounds/<категория>/*.ogg (FR-28, FR-29).

  1) python3 tools/sounds/fetch_candidates.py <cache_dir>          # HQ-превью freesound (без логина)
  2) (Kenney) curl -L <url> -o kenney_impact.zip && unzip в <cache_dir>/kenney_impact  (см. KENNEY_URL)
  3) uv run --no-project --with numpy --with scipy python tools/sounds/process_assets.py <cache_dir>
  4) uv run --no-project --with numpy --with scipy python tools/sounds/synth_wind.py
  5) uv run --no-project --with numpy --with scipy python tools/sounds/check_assets.py

Что делается: вырезка фрагмента, ФВЧ (убрать гул/ветер в микрофоне), моно/стерео, бесшовный луп
(равномощный кроссфейд, audiolib.make_loop), нормализация (лупы — по LUFS, one-shot — набор по общему пику),
fade in/out у one-shot, Ogg Vorbis q4. Источники и лицензии — в assets/sounds/LICENSES.md.
"""
import json, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audiolib import SR, load, save_ogg, norm_lufs, norm_peak, fade, highpass, lowpass, make_loop, lufs, peak_db

KENNEY_URL = "https://kenney.nl/media/pages/assets/impact-sounds/87b4ddecda-1677589768/kenney_impact-sounds.zip"
LOOP_Q = 6   # Vorbis q6 для лупов: при q4 шум квантования даёт заметный скачок на стыке (см. sounds.md)
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
OUT = os.path.join(ROOT, "assets", "sounds")

# Лупы: (выход, id freesound, начало_с, длина_лупа_с, кроссфейд_с, стерео, ФВЧ_Гц, LUFS)
LOOPS = [
    ("airflow/wind_ears_loop.ogg",        611197, 2.0, 20.0, 2.0, True, 30, -20),
    ("airflow/air_rush_fast_loop.ogg",     20108, 1.0, 14.0, 2.0, True, 60, -20),
    ("sail/wing_under_wind_loop.ogg",     836086, 5.0, 20.0, 2.5, True, 60, -22),
    ("sail/sail_luff_loop.ogg",           154794, 5.0, 20.0, 2.0, True, 80, -22),
    ("ambient/launch_meadow_loop.ogg",    454841, 2.0, 60.0, 4.0, True, 40, -26),
    ("ambient/birds_alpine_loop.ogg",     855955, 1.0, 30.0, 3.0, True, 150, -28),
    ("ambient/cowbells_distant_loop.ogg", 437147, 2.0, 60.0, 4.0, True, 80, -30),
    ("ambient/wind_launch_gusts_loop.ogg", 454092, 20.0, 60.0, 4.0, True, 30, -24),
    ("ambient/grass_wind_loop.ogg",       146436, 10.0, 40.0, 3.0, True, 60, -26),
    ("run/breath_run_loop.ogg",           609482, 2.0, 9.35, 0.02, False, 80, -22),  # границы — паузы между вдохами
]

# One-shot наборы: (префикс, id, t0, t1, сколько, мин_интервал_с, макс_длина_с, изоляция_дБ, pitch, ФВЧ, пик_дБ)
HITS = [
    ("run/step_grass",     556042, 20.7, 30.5, 8, 0.25, 0.30, 10, 1.0, 60, -3),
    ("run/step_gravel",    556002, 13.4, 18.0, 8, 0.20, 0.20, None, 1.0, 60, -3),
    ("sail/sail_snap",      57280, 0.0, 37.0, 6, 0.60, 0.45, 8, 0.75, 60, -3),
    ("frame/creak",        862995, 0.0, 47.0, 6, 0.80, 1.2, None, 1.0, 120, -6),
]

# Отдельные one-shot: (выход, id, t0, t1, стерео, ФВЧ, пик_дБ)
SINGLES = [
    ("landing/land_soft_grass.ogg", 73583, 1.55, 3.3, False, 40, -3),
    ("landing/land_hard_dirt.ogg",  504626, 0.0, 1.63, False, 30, -1),
    ("landing/frame_hit_alu.ogg",   352775, 0.0, 3.0, False, 60, -3),
    ("run/breath_pant_after.ogg",   609482, 20.0, 30.0, False, 80, -6),
    ("frame/carabiner_clip.ogg",    399926, 0.0, 2.2, False, 100, -6),
]


def src(cache, sid, stereo=True):
    meta = json.load(open(os.path.join(cache, "meta.json")))
    cat = meta[str(sid)]["category"]
    return load(os.path.join(cache, cat, f"{sid}.ogg"), mono=not stereo)


def extract_hits(x, t0, t1, n, gap_s, maxlen_s, iso_db=None, pre_s=0.015, floor_db=30):
    """Найти n самых громких ударов в [t0,t1]. iso_db: отбрасывать удар, если в хвосте (после 120 мс)
    есть событие громче «пик − iso_db» (чтобы не захватить следующий шаг/удар)."""
    seg = x[int(t0 * SR): int(t1 * SR)]
    hop = int(0.005 * SR)
    m = np.abs(seg).max(axis=1)
    nf = len(m) // hop
    env = m[: nf * hop].reshape(nf, hop).max(axis=1)
    order = np.argsort(env)[::-1]
    picked = []
    for i in order:
        if len(picked) >= n or env[i] < env[order[0]] * 10 ** (-24 / 20):
            break
        if iso_db is not None:
            tail = env[i + int(0.12 * SR / hop): i + int(maxlen_s * SR / hop)]
            head = env[max(0, i - int(0.15 * SR / hop)): max(0, i - int(0.03 * SR / hop))]
            if (len(tail) and tail.max() > env[i] * 10 ** (-iso_db / 20)) or \
               (len(head) and head.max() > env[i] * 10 ** (-iso_db / 20)):
                continue
        if all(abs(i - j) * hop / SR >= gap_s for j in picked):
            picked.append(i)
    picked.sort()
    clips = []
    for k, i in enumerate(picked):
        # начало: откат назад к началу атаки (до −20 дБ от пика), не дальше 30 мс, плюс pre_s
        s = i
        while s > 0 and env[s - 1] > env[i] * 10 ** (-20 / 20) and (i - s) * hop / SR < 0.03:
            s -= 1
        a = max(0, s * hop - int(pre_s * SR))
        lim = picked[k + 1] * hop - int(pre_s * SR) if k + 1 < len(picked) else len(seg)
        b = min(a + int(maxlen_s * SR), lim)
        c = seg[a:b]
        # обрезать хвост ниже floor_db от пика
        e = np.abs(c).max(axis=1)
        above = np.where(e > e.max() * 10 ** (-floor_db / 20))[0]
        c = c[: above[-1] + int(0.02 * SR)] if len(above) else c
        clips.append((t0 + a / SR, c))
    return clips


def resample(x, factor):
    """pitch < 1 — ниже и длиннее (простая интерполяция; достаточно для шумовых звуков)."""
    if factor == 1.0:
        return x
    n = int(len(x) / factor)
    t = np.arange(n) * factor
    return np.stack([np.interp(t, np.arange(len(x)), x[:, c]) for c in range(x.shape[1])], axis=1).astype(np.float32)


def main():
    cache = sys.argv[1]
    report = []
    for rel, sid, t0, L, xf, st, hp, target in LOOPS:
        x = src(cache, sid, st)
        need = int((L + xf) * SR)
        seg = x[int(t0 * SR): int(t0 * SR) + need]
        assert len(seg) == need, (rel, len(x) / SR)
        seg = highpass(seg, hp)
        y = norm_lufs(make_loop(seg, xf), target)
        save_ogg(os.path.join(OUT, rel), y, q=LOOP_Q)
        report.append((rel, sid, f"{t0:.2f}-{t0 + L + xf:.2f}s", lufs(y)))
    for pref, sid, t0, t1, n, gap, ml, iso, pitch, hp, pk in HITS:
        x = src(cache, sid, False)
        clips = extract_hits(x, t0, t1, n, gap, ml, iso, floor_db=40 if iso is None else 30)
        clips = [(t, fade(resample(highpass(c, hp), pitch), 0.002, min(0.08, 0.4 * len(c) / SR))) for t, c in clips]
        g = pk - max(peak_db(c) for _, c in clips)        # общий множитель — сохраняем естественный разброс
        for k, (t, c) in enumerate(clips, 1):
            rel = f"{pref}_{k:02d}.ogg"
            save_ogg(os.path.join(OUT, rel), c * 10 ** (g / 20))
            report.append((rel, sid, f"{t:.2f}s", f"{len(c) / SR:.2f}s"))
    for rel, sid, t0, t1, st, hp, pk in SINGLES:
        x = src(cache, sid, st)
        c = fade(highpass(x[int(t0 * SR): int(t1 * SR)], hp), 0.003, 0.08)
        save_ogg(os.path.join(OUT, rel), norm_peak(c, pk))
        report.append((rel, sid, f"{t0:.2f}-{t1:.2f}s", f"{len(c) / SR:.2f}s"))
    # Kenney Impact Sounds (CC0): лёгкие металлические стуки каркаса + мягкие удары
    kdir = os.path.join(cache, "kenney_impact", "Audio")
    for name in ["impactMetal_light_000", "impactMetal_light_002", "impactSoft_heavy_000", "impactSoft_heavy_002"]:
        x = load(os.path.join(kdir, name + ".ogg"))
        rel = f"landing/kenney_{name}.ogg"
        save_ogg(os.path.join(OUT, rel), norm_peak(x, -3))
        report.append((rel, "kenney", name, f"{len(x) / SR:.2f}s"))
    json.dump(report, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "process_report.json"), "w"),
              indent=1, ensure_ascii=False, default=str)
    for r in report:
        print(*r)


if __name__ == "__main__":
    main()
