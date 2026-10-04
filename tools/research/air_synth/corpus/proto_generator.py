"""Прототипный генератор по API S3 — обёртка terrain_stats/fastscape_gen.py (типы askarovo/ongudai, mix — непрерывная
смесь между ними). Для замера времени запуска корпуса до готовности generator.py (SY-2). Не для массовой генерации."""
import hashlib
import os
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TS = os.path.join(HERE, "..", "terrain_stats")
sys.path.insert(0, HERE)
sys.path.insert(0, TS)
import corpus_io as cio  # noqa: E402
import fastscape_gen as fg  # noqa: E402

pb = cio.pb
SC = float(np.tan(np.radians(35)))
BASE = dict(n=512, dx=100.0, m=0.45, n_exp=1.0, T=4e6, dt=5e4, Sc=SC, D=0.03, K_logsd=0.7, K_beta=2.0, U_floor=0.1, noise=2.0)
TYPES = {  # как terrain_stats/run_fastscape.py
    "askarovo": dict(BASE, U0=2e-4, K=4e-6, n_ridges=2, strike_deg=170, strike_spread_deg=10, ridge_H=(0.5, 1), ridge_L_km=(15, 30),
                     ridge_sigma_km=(4, 8), n_blobs=6, blob_sigma_km=(1.5, 4), blob_H=(0.1, 0.4), fourier_amp=0.3),
    "ongudai": dict(BASE, U0=7e-4, K=8e-6, n_ridges=3, strike_deg=70, strike_spread_deg=40, ridge_H=(0.5, 1), ridge_L_km=(10, 25),
                    ridge_sigma_km=(3, 6), n_blobs=12, blob_sigma_km=(1.5, 4), blob_H=(0.1, 0.5), fourier_amp=0.4),
}
GENERATOR_VERSION = "proto-" + hashlib.sha1(open(os.path.abspath(__file__), "rb").read()).hexdigest()[:7]
# имена theta (поля GenParams) -> ключи прототипа
THETA_MAP = dict(uplift_max_m_per_yr="U0", k0="K", diffusion_m2_per_yr="D", m_exp="m", k_logsd="K_logsd", fourier_amp="fourier_amp",
                 t_total_yr="T", tan_crit="Sc")
TUNABLE = {k: (0.0, float("inf"), None) for k in THETA_MAP}
_INT = ("n_ridges", "n_blobs")


def _mix_params(mix):
    a, o = TYPES["askarovo"], TYPES["ongudai"]
    p = {}
    for k in a:
        va, vo = a[k], o[k]
        if isinstance(va, tuple):
            p[k] = tuple((1 - mix) * x + mix * y for x, y in zip(va, vo))
        elif isinstance(va, (int, float)) and k not in ("n",):
            p[k] = (1 - mix) * va + mix * vo
        else:
            p[k] = va
    for k in _INT:
        p[k] = int(round(p[k]))
    return p


def generate(corpus_seed, relief_id, theta=None):
    ss = np.random.SeedSequence([corpus_seed, relief_id])
    mix = float(np.random.default_rng(ss.spawn(1)[0]).uniform())
    p = _mix_params(mix)
    for k, v in (theta or {}).items():
        if k not in THETA_MAP:
            raise KeyError(f"неизвестный параметр theta: {k}")
        p[THETA_MAP[k]] = float(v)
    r = fg.gen(p, np.random.default_rng(ss))  # gen() вызывает default_rng(Generator) -> тот же генератор
    named = dict(n_compute=p["n"], dx_compute_m=p["dx"], uplift_max_m_per_yr=p["U0"], uplift_floor=p["U_floor"],
                 fourier_amp=p["fourier_amp"], fourier_beta=p.get("fourier_beta", 2.0), strike_rad=float(np.radians(p["strike_deg"])),
                 k0=p["K"], k_logsd=p["K_logsd"], k_beta=p["K_beta"], m_exp=p["m"], n_exp=p["n_exp"], diffusion_m2_per_yr=p["D"],
                 tan_crit=p["Sc"], thermal_passes=5, t_total_yr=p["T"], dt_yr=p["dt"], noise_m=p["noise"], base_elevation_m=0.0)
    extra = {}
    for k, v in p.items():
        if k in ("n_ridges", "n_blobs", "strike_spread_deg", "pos_spread_km"):
            extra[k] = float(v)
        elif isinstance(v, tuple):
            extra[k + "_lo"], extra[k + "_hi"] = float(v[0]), float(v[1])
    for k, v in (theta or {}).items():
        extra["theta_" + k] = float(v)
    params = pb.GenParams(mix=mix, extra=extra, **named)
    return params, r["z100"]
