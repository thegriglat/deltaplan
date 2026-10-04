"""Дешёвый поддельный генератор по API S3 для тестов (не физика)."""
import os
import time
import numpy as np

GENERATOR_VERSION = "fake-1"
PARAM_NAMES = ("mix", "t_total_yr", "shift", "a")
TUNABLE = {"shift": (0.0, 100.0, 0.0), "a": (0.0, 1.0, 0.5)}


def generate(corpus_seed, relief_id, theta=None):
    time.sleep(float(os.environ.get("FAKEGEN_SLEEP", "0")))
    rng = np.random.default_rng(np.random.SeedSequence([corpus_seed, relief_id]))
    mix = float(rng.uniform())
    f = np.fft.ifft2(np.fft.fft2(rng.standard_normal((384, 384))) * np.exp(-np.hypot(*np.meshgrid(np.fft.fftfreq(384), np.fft.fftfreq(384))) * 40)).real
    z = 1500 + 800 * f / f.std() + 3 * np.arange(384)[None, :]
    th = theta or {}
    if str(relief_id) in os.environ.get("FAKEGEN_BAD_IDS", "").split(",") and corpus_seed < 10 ** 9:
        th = dict(th, shift=th.get("shift", 0.0) + 9000.0)     # вне диапазона int16 на первой попытке
    return {"mix": mix, "t_total_yr": 1e6, "shift": th.get("shift", 0.0), "a": th.get("a", 0.5)}, z + th.get("shift", 0.0)
