"""Источники рельефа для замера H7 (параметр --source): proto (4 рельефа прототипа Fastscape, proto_reliefs.npz) и
corpus (корпус S1 через corpus_io.py SY-1). Возвращает [(имя, g100 float64 (384, 384), g400 float64 (96, 96) | None, scale_m)]."""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent


def block4(z):
    n = z.shape[0]
    return z.reshape(n // 4, 4, n // 4, 4).mean(axis=(1, 3))


def load_proto(npz=None):
    z = np.load(npz or HERE / "proto_reliefs.npz")
    out = []
    for name, g in zip(z["names"], z["z100"]):
        g = g.astype(np.float64)
        out.append((str(name), g, block4(g), 0.0))   # g400 прототипа = блочное среднее (как z400 fastscape_gen)
    return out


def load_corpus(corpus_dir, ids, corpus_io_dir=None):
    """Корпус S1 v3 (HDF5, docs/contracts/air-synth.md): файлы corpus.h5 или part-*.h5 в каталоге; наборы relief/id,
    relief/h100, relief/h400 (int16), атрибуты offset_m, scale_m: h = offset_m + scale_m * q. Читает h5py напрямую
    (corpus_io не нужен; corpus_io_dir игнорируется). ids — номера рельефов. Не проверено на настоящем корпусе (его ещё нет)."""
    import h5py
    d = Path(corpus_dir)
    files = [d / "corpus.h5"] if (d / "corpus.h5").exists() else sorted(d.glob("part-*.h5"))
    want = [int(x) for x in ids]
    found = {}
    for f in files:
        with h5py.File(f, "r") as h:
            rid = h["relief/id"][:]
            for w in want:
                k = np.nonzero(rid == w)[0]
                if len(k) and w not in found:
                    a1, a4 = h["relief/h100"], h["relief/h400"]
                    g100 = float(a1.attrs["offset_m"]) + float(a1.attrs["scale_m"]) * a1[int(k[0])].astype(np.float64)
                    g400 = float(a4.attrs["offset_m"]) + float(a4.attrs["scale_m"]) * a4[int(k[0])].astype(np.float64)
                    found[w] = (f"c_{w:05d}", g100, g400, float(a4.attrs["scale_m"]))
    miss = [w for w in want if w not in found]
    if miss:
        raise KeyError(f"рельефы {miss} не найдены в {d}")
    return [found[w] for w in want]
