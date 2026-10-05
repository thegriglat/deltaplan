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


# ----------------------------------------------------------------------------- идеальные формы (P1 v1, air-phase)
IDEAL_SHAPES = ("hill", "ridge", "step_up", "step_down")
N100, DX100, X0 = 384, 100.0, -19200.0


def ideal_scale_a(shape, s, h_m=500.0):
    """Масштаб a формы, м: hill/ridge a = h·√2·e^(−1/2)/s (максимум градиента гаусса = s); step a = h/(2s) (tanh)."""
    if shape in ("hill", "ridge"):
        return h_m * np.sqrt(2.0) * np.exp(-0.5) / s
    if shape in ("step_up", "step_down"):
        return h_m / (2.0 * s)
    raise ValueError(f"неизвестная форма {shape!r}; ожидается одна из {IDEAL_SHAPES}")


def ideal_relief(shape, s, h_m=500.0, length_m=20000.0, base_m=1000.0):
    """Идеальный рельеф по формулам P1: (g100 float64 (384, 384), g400 float64 (96, 96)), м над уровнем моря (база + z).
    Узлы g100 — центры клеток x_i = −19200 + 50 + 100·i (i — восток), y_j аналогично (j — север); ветер с запада (к +x).
    hill: z = h·exp(−(x²+y²)/a²); ridge: z = h·exp(−x²/a²)·T(y), T = exp(−max(0, |y| − (L/2 − a))²/a²);
    step_up: z = h(1 + tanh(x/a))/2; step_down: z = h(1 − tanh(x/a))/2. s = max|∇z| (тангенс). g400 = блочное среднее 4 × 4."""
    if s <= 0:
        raise ValueError("s должно быть > 0")
    a = ideal_scale_a(shape, s, h_m)
    c = X0 + DX100 / 2 + DX100 * np.arange(N100)
    x, y = c[None, :], c[:, None]          # [j (север), i (восток)]
    if shape == "hill":
        z = h_m * np.exp(-(x ** 2 + y ** 2) / a ** 2)
    elif shape == "ridge":
        t = np.exp(-np.maximum(0.0, np.abs(y) - (length_m / 2.0 - a)) ** 2 / a ** 2)
        z = h_m * np.exp(-x ** 2 / a ** 2) * t
    elif shape == "step_up":
        z = h_m * (1.0 + np.tanh(x / a)) / 2.0 + 0.0 * y
    else:
        z = h_m * (1.0 - np.tanh(x / a)) / 2.0 + 0.0 * y
    g100 = np.ascontiguousarray(base_m + z, dtype=np.float64)
    return g100, block4(g100)


def ideal_name(shape, s, length_m=20000.0):
    """Имя места P1: `<shape>_s<s:.2f>` (+ `_L<км>` для ridge, если длина не 20 км)."""
    n = f"{shape}_s{s:.2f}"
    if shape == "ridge" and abs(length_m - 20000.0) > 1e-6:
        n += f"_L{length_m / 1000:g}"
    return n


def load_ideal(specs, h_m=500.0, base_m=1000.0):
    """specs — список (shape, s) | (shape, s, length_m) | dict(shape, s, length_m?, h_m?, base_m?).
    → [(имя, g100, g400, scale_m=0.0)] — вид как у load_proto / load_corpus."""
    out = []
    for sp in specs:
        d = dict(zip(("shape", "s", "length_m"), sp)) if not isinstance(sp, dict) else dict(sp)
        L = float(d.get("length_m", 20000.0))
        g100, g400 = ideal_relief(d["shape"], float(d["s"]), float(d.get("h_m", h_m)), L, float(d.get("base_m", base_m)))
        out.append((ideal_name(d["shape"], float(d["s"]), L), g100, g400, 0.0))
    return out
