"""PT-1: поле air3d (CuPy) -> снимок R4 v2 (`picard-rs-state`, dtype f32) и запись пары R1 (.json + .bin).

Раскладка массивов air3d совпадает с R1/R4: (NZ, NY, NX) с ореолом, индекс (k*NY + j)*NX + i, поэтому перевод —
только приведение к float32 little-endian. Запись — через временные файлы и переименование (JSON последним).
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
STATE_KEYS = ("u", "v", "w", "th", "thd", "p")


def git_rev():
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def G(a):
    return a.get() if hasattr(a, "get") else np.asarray(a)


class Pack:
    """Массивы подряд в float32 LE; arrays: {имя: [смещение, длина]} в числах float32 (формат R1)."""

    def __init__(self):
        self.parts, self.arrays, self.off = [], {}, 0

    def add(self, name, a):
        a = np.ascontiguousarray(np.asarray(a, np.float64)).astype("<f4").ravel()
        self.arrays[name] = [self.off, int(a.size)]
        self.parts.append(a)
        self.off += a.size

    def write(self, base, meta):
        """base — путь без расширения; meta — словарь JSON без `arrays`."""
        base = str(base)
        os.makedirs(os.path.dirname(base), exist_ok=True)
        tb, tj = base + ".bin.tmp", base + ".json.tmp"
        np.concatenate(self.parts).tofile(tb)
        Path(tj).write_text(json.dumps(dict(meta, arrays=self.arrays), ensure_ascii=False, indent=1))
        os.replace(tb, base + ".bin")
        os.replace(tj, base + ".json")


def write_state(base, S, case_name, input_path, residuals=None):
    """Снимок R4 v2 из решателя air3d `S` (после finalize): u, v, w, th, thd, p."""
    nx, ny, nz = S.shape[2], S.shape[1], S.shape[0]
    P = Pack()
    for k in STATE_KEYS:
        P.add(k, G(getattr(S, k)))
    meta = dict(format="picard-rs-state", version=2, case=case_name, input=str(input_path), it=int(S.outer),
                dims=[nx, ny, nz], halo=1, nx=nx - 2, ny=ny - 2, nz=nz - 2, dtype="f32", residuals=residuals,
                host={"git": git_rev(), "solver": "air3d", "dtype": "f64"})
    P.write(base, meta)
    return P
