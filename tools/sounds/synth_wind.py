#!/usr/bin/env python3
"""Процедурные «заготовки» для звука потока воздуха и паруса (FR-28).

Все лупы строятся в частотной области (IFFT шума с заданным спектром) — такой сигнал
строго периодичен, поэтому луп бесшовный БЕЗ кроссфейда. Модуляции (порывы, биения)
тоже периодичны: частоты LFO кратны 1/длина_лупа.

Выход (assets/sounds/airflow/, assets/sounds/sail/):
  wind_rush_loop.ogg     — широкополосный «шум обтекания» с пиком ~ref_peak_hz при V_ref (для pitch_scale ∝ V).
  wind_rumble_loop.ogg   — низкочастотные биения/бафтинг у ушей и шлема (20–250 Гц), сильная AM.
  wires_whistle_loop.ogg — эоловы тоны тросов (узкополосный шум), 4 «троса» при V_ref.
  sail_flutter_synth_loop.ogg — синтетическое трепетание задней кромки (импульсы шума с частотой flutter_hz).
  tools/sounds/preview/airflow_sweep_demo.ogg — демо 20→90→20 км/ч по алгоритму из docs/research/sounds.md.

Запуск: uv run --no-project --with numpy --with scipy python tools/sounds/synth_wind.py [--root .]
"""
import argparse, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audiolib import SR, save_ogg, norm_lufs, loop_seam_report, lufs

RNG = np.random.default_rng(20260927)

# ---- параметры (единицы в имени) ----
LOOP_S = 16.0            # длина лупов, с
V_REF_KMH = 40.0         # скорость, при которой лупы звучат «как есть» (pitch_scale = 1)
RUSH_PEAK_HZ = 450.0     # центр широкой полосы шума обтекания при V_REF
RUSH_LP_HZ = 7000.0      # плавный спад сверху
RUMBLE_LP_HZ = 180.0
WIRE_D_M = [0.0024, 0.0030, 0.0038, 0.0048]   # диаметры тросов/стропы, м (тросы 2.4–3 мм, кингпост, стропы подвески)
STROUHAL = 0.2           # f = St·V/d
WIRE_BW_HZ = 12.0        # ширина полосы тона, Гц


def periodic_noise(n, mag_fn, rng=RNG):
    """Шум длиной n с амплитудным спектром mag_fn(f); периодичен по n."""
    f = np.fft.rfftfreq(n, 1 / SR)
    mag = mag_fn(f)
    ph = rng.uniform(0, 2 * np.pi, len(f))
    spec = mag * np.exp(1j * ph)
    spec[0] = 0
    x = np.fft.irfft(spec, n)
    return (x / np.sqrt(np.mean(x ** 2))).astype(np.float64)


def periodic_lfo(n, f_lo, f_hi, k=8, rng=RNG):
    """Медленная случайная модуляция (сумма синусоид с целым числом периодов на луп), нормирована к [-1,1]."""
    t = np.arange(n) / SR
    L = n / SR
    y = np.zeros(n)
    for _ in range(k):
        cyc = max(1, int(round(rng.uniform(f_lo, f_hi) * L)))
        y += rng.uniform(0.3, 1) * np.sin(2 * np.pi * cyc / L * t + rng.uniform(0, 2 * np.pi))
    return y / np.max(np.abs(y))


def rush_mag(f):
    # широкий «горб»: подъём 12 дБ/окт до ~peak/3, плато, затем спад ~5 дБ/окт и мягкий НЧ-срез
    f = np.maximum(f, 1.0)
    lo = (f / (RUSH_PEAK_HZ / 3)) ** 2 / (1 + (f / (RUSH_PEAK_HZ / 3)) ** 2)
    hi = 1 / (1 + (f / RUSH_PEAK_HZ) ** 2) ** 0.4
    lp = 1 / (1 + (f / RUSH_LP_HZ) ** 4)
    return lo * hi * lp


def rumble_mag(f):
    f = np.maximum(f, 1.0)
    hp = (f / 25) ** 2 / (1 + (f / 25) ** 2)
    return hp / (1 + (f / RUMBLE_LP_HZ) ** 2) / np.sqrt(f)


def stereo_decorrelate(x_fn):
    return np.stack([x_fn(), x_fn()], axis=1)


def make_rush(n):
    def one():
        x = periodic_noise(n, rush_mag)
        am = 1 + 0.25 * periodic_lfo(n, 0.15, 1.5)            # медленная «турбулентность», ±2 дБ
        return x * am
    return stereo_decorrelate(one)


def make_rumble(n):
    def one():
        x = periodic_noise(n, rumble_mag)
        g = periodic_lfo(n, 0.5, 6.0, k=12)
        am = np.exp(1.2 * g)                                  # бафтинг: провалы/всплески ~ ±10 дБ
        return x * am
    return stereo_decorrelate(one)


def make_wires(n, v_ms=V_REF_KMH / 3.6):
    out = np.zeros(n)
    for i, d in enumerate(WIRE_D_M):
        fc = STROUHAL * v_ms / d
        tone = periodic_noise(n, lambda f: np.exp(-0.5 * ((f - fc) / (WIRE_BW_HZ / 2.355)) ** 2))
        # «захват» вихревой дорожки: тон то появляется, то пропадает
        env = np.clip(0.5 + 0.8 * periodic_lfo(n, 0.05, 0.6, k=5), 0, 1) ** 2
        out += tone * env * (0.8 ** i)
    return np.stack([out, out], axis=1)


def make_flutter(n, flutter_hz=9.0):
    """Трепетание паруса: пачки импульсов шума. Частота подаётся в Godot через pitch_scale (∝ V)."""
    t = np.arange(n) / SR
    L = n / SR
    cyc = round(flutter_hz * L)
    phase = (cyc / L * t) % 1.0
    # один «хлопок» на период: быстрая атака, экспоненциальный спад; амплитуда случайна от хлопка к хлопку
    k = np.floor(cyc / L * t).astype(int)
    amp = RNG.uniform(0.35, 1.0, cyc + 1)[k]
    env = amp * np.exp(-phase / 0.12) * (1 - np.exp(-phase / 0.004))
    body = periodic_noise(n, lambda f: np.exp(-0.5 * (np.log(np.maximum(f, 1) / 700) / 0.9) ** 2))
    x = body * env + 0.15 * periodic_noise(n, rush_mag)
    return np.stack([x, x], axis=1)


# ---- демо-рендер алгоритма из docs/research/sounds.md (то, что должен делать Godot) ----
def demo_sweep(rush, rumble, wires, secs=24.0):
    n = int(secs * SR)
    t = np.arange(n) / SR
    v = 20 + 70 * np.sin(np.pi * t / secs) ** 1.2                  # 20→90→20 км/ч
    out = np.zeros((n, 2))
    for loop, pitch_fn, gain_fn in [
        (rush, lambda v: v / V_REF_KMH, lambda v: 50 * np.log10(v / V_REF_KMH)),
        (rumble, lambda v: 0.7 + 0.3 * v / V_REF_KMH, lambda v: -4 + 60 * np.log10(v / V_REF_KMH)),
        (wires, lambda v: v / V_REF_KMH, lambda v: -20 + 60 * np.log10(v / V_REF_KMH) + np.minimum(0, (v - 35) * 1.5)),
    ]:
        p = pitch_fn(v)
        pos = np.cumsum(p) % len(loop)                                 # «воспроизведение с pitch_scale»
        i0 = pos.astype(int); fr = pos - i0; i1 = (i0 + 1) % len(loop)
        y = loop[i0] * (1 - fr)[:, None] + loop[i1] * fr[:, None]
        out += y * (10 ** (gain_fn(v) / 20))[:, None]
    # низкочастотный фильтр, открывающийся со скоростью (как AudioEffectLowPassFilter на шине)
    from scipy.signal import butter, sosfilt
    blk = 1024
    y = np.zeros_like(out); zi = None
    for s in range(0, n, blk):
        fc = min(800 + 60 * v[s], 16000)
        sos = butter(2, fc, "lp", fs=SR, output="sos")
        if zi is None:
            zi = np.zeros((sos.shape[0], 2, 2))
        y[s:s + blk], zi = sosfilt(sos, out[s:s + blk], axis=0, zi=zi)
    return y


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    a = ap.parse_args()
    snd = os.path.join(a.root, "assets", "sounds")
    n = int(LOOP_S * SR)
    rush, rumble, wires = make_rush(n), make_rumble(n), make_wires(n)
    flutter = make_flutter(int(8.0 * SR))
    items = [
        ("airflow/wind_rush_loop.ogg", rush, -20),
        ("airflow/wind_rumble_loop.ogg", rumble, -20),
        ("airflow/wires_whistle_loop.ogg", wires[:, :1], -26),
        ("sail/sail_flutter_synth_loop.ogg", flutter[:, :1], -22),
    ]
    for rel, x, target in items:
        y = norm_lufs(x.astype(np.float32), target)
        save_ogg(os.path.join(snd, rel), y, q=6)
        print(rel, "LUFS/LRA/TP", lufs(y), loop_seam_report(y))
    demo = demo_sweep(norm_lufs(rush.astype(np.float32), -20), norm_lufs(rumble.astype(np.float32), -20),
                      norm_lufs(wires.astype(np.float32), -20))
    demo = norm_lufs(demo.astype(np.float32), -18)
    save_ogg(os.path.join(a.root, "tools", "sounds", "preview", "airflow_sweep_demo.ogg"), demo, q=3)
    print("demo LUFS", lufs(demo))


if __name__ == "__main__":
    main()
