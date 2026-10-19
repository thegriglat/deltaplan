#!/usr/bin/env python3
"""VM-12: 20 полей болтанки σ 1 м/с (зёрна 7…26, 24 моды) — копия turbulence_modes из tools/research/pendulum/export_reference.py
(как VM-6 sc=turb), без зависимостей от пакета прототипа. → out/vm12/turb_fields.json."""
import json, math, os
import numpy as np


def turbulence_modes(sigma=1.0, n=24, seed=7):
    rng = np.random.default_rng(seed)
    lam = np.exp(np.linspace(math.log(200.0), math.log(4.0), n))
    ks = 2 * math.pi / lam
    L = 40.0
    dk = np.gradient(ks) * -1.0
    E = (ks * L) ** 4 / (1 + (ks * L) ** 2) ** (17.0 / 6.0)
    amp = np.sqrt(np.abs(E * dk))
    dirs = rng.normal(size=(n, 3))
    dirs /= np.linalg.norm(dirs, axis=1, keepdims=True)
    a = rng.normal(size=(n, 3))
    a -= (a * dirs).sum(1, keepdims=True) * dirs
    a /= np.linalg.norm(a, axis=1, keepdims=True)
    A = a * amp[:, None]
    var = (A ** 2).sum(0) / 2.0
    A *= sigma / math.sqrt(var.mean())
    ph = rng.uniform(0, 2 * math.pi, n)
    K = dirs * ks[:, None]
    return {"k": K.tolist(), "a": A.tolist(), "phase": ph.tolist(), "sigma": sigma, "seed": seed}


here = os.path.dirname(os.path.abspath(__file__))
os.makedirs(here + '/out/vm12', exist_ok=True)
json.dump([turbulence_modes(1.0, 24, 7 + k) for k in range(20)], open(here + '/out/vm12/turb_fields.json', 'w'))
print('20 fields')
