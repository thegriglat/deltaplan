"""Дешёвый поддельный генератор по API S3 для тестов (не физика)."""
import os
import time
import numpy as np
import corpus_io as cio

GENERATOR_VERSION = "fake-1"
TUNABLE = {"shift": (0.0, 100.0, 0.0), "a": (0.0, 1.0, 0.5)}


def generate(corpus_seed, relief_id, theta=None):
    time.sleep(float(os.environ.get("FAKEGEN_SLEEP", "0")))
    rng = np.random.default_rng(np.random.SeedSequence([corpus_seed, relief_id]))
    mix = float(rng.uniform())
    f = np.fft.ifft2(np.fft.fft2(rng.standard_normal((384, 384))) * np.exp(-np.hypot(*np.meshgrid(np.fft.fftfreq(384), np.fft.fftfreq(384))) * 40)).real
    z = 1500 + 800 * f / f.std() + 3 * np.arange(384)[None, :]
    return cio.pb.GenParams(mix=mix, n_compute=384, dx_compute_m=100.0, t_total_yr=1e6, extra=dict({"fake": 1.0}, **{"theta_" + k: v for k, v in (theta or {}).items()})), z + (theta or {}).get("shift", 0.0)
