"""Загрузка реальных рельефов игры (data/terrain/<место>/{detail,far}.f32.br) и огрубление.
Формат: brotli-сжатый float32 little-endian, 1601x1601, строки по Z (см. meta.json). Только чтение."""
import json, os
import numpy as np, brotli

ROOT = os.environ.get("DP_TERRAIN", "/home/greg/deltaplan/data/terrain")
PLACES = ["askarovo", "ongudai", "altai", "aushkul"]


def load(place, layer):
    d = os.path.join(ROOT, place)
    meta = json.load(open(os.path.join(d, "meta.json")))
    L = next(l for l in meta["layers"] if l["id"] == layer)
    raw = brotli.decompress(open(os.path.join(d, L["file"]), "rb").read())
    h = np.frombuffer(raw, dtype="<f4").reshape(L["height"], L["width"]).astype(np.float64)
    return h, float(L["spacing_m"]), meta


def coarsen(h, k):
    """Среднее по блокам k x k (обрезая хвост); 1601 -> 1600 // k."""
    n = (h.shape[0] // k) * k
    m = (h.shape[1] // k) * k
    return h[:n, :m].reshape(n // k, k, m // k, k).mean(axis=(1, 3))


def squares(h, dx, size_m=40000.0):
    """Нарезка на неперекрывающиеся квадраты size_m; возвращает список (i, j, массив)."""
    n = int(round(size_m / dx))
    out = []
    for i in range(h.shape[0] // n):
        for j in range(h.shape[1] // n):
            out.append((i, j, h[i * n:(i + 1) * n, j * n:(j + 1) * n]))
    return out
