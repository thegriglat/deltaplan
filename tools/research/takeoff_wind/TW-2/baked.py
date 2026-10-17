"""Чтение запечённого поля dp-air-baked (TI-К3 v3) в numpy: load(base) -> [ (grid, meta, {name: array}) ].
Массивы 3D — (nz, ny, nx); 2D — (ny, nx); раскладка как WindField (k — вверх, j — север, i — восток)."""
import json, sys
import numpy as np, zstandard

def load(base):
    h = json.load(open(base + ".json"))
    raw = zstandard.ZstdDecompressor().decompress(open(base + ".bin", "rb").read(), max_output_size=h["raw_bytes"])
    out = []
    for L in h["levels"]:
        g = L["grid"]; a = {}
        for name, (off, n, t) in L["arrays"].items():
            dt = np.float16 if t == "f16" else np.float32
            x = np.frombuffer(raw, dtype=dt, count=n // np.dtype(dt).itemsize, offset=off).astype(np.float64)
            if x.size == g["nx"] * g["ny"] * g["nz"]:
                x = x.reshape(g["nz"], g["ny"], g["nx"])
            elif x.size == g["nx"] * g["ny"]:
                x = x.reshape(g["ny"], g["nx"])
            a[name] = x
        out.append((g, L["meta"], a))
    return h, out

if __name__ == "__main__":
    h, lv = load(sys.argv[1])
    for g, m, a in lv:
        print(g, {k: v.shape for k, v in a.items()})
