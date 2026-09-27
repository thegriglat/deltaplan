"""Бесшовные 3D-текстуры шума для облаков (Perlin-Worley, как в Horizon Zero Dawn / Nubis).

Запуск: uv run --with numpy python tools/atmosphere/gen_cloud_noise.py
Результат: assets/textures/clouds/cloud_shape.png, cloud_detail.png — атласы срезов, которые
импортёр Godot (.import: importer="3d_texture") превращает в Texture3D с мипами.

Шейдер берёт канал R и считает клубы как 1 − R, поэтому сохраняем «перевёрнутую» плотность:
малое значение — центр клуба.
"""
import os

import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "textures", "clouds")


def worley(n: int, cells: int, rng: np.random.Generator) -> np.ndarray:
    """F1 Уорли, бесшовный: точки в клетках решётки cells³, расстояние с переносом."""
    pts = rng.random((cells, cells, cells, 3))
    ax = (np.arange(n) + 0.5) / n * cells
    x, y, z = np.meshgrid(ax, ax, ax, indexing="ij")
    ix, iy, iz = np.floor(x).astype(int), np.floor(y).astype(int), np.floor(z).astype(int)
    best = np.full(x.shape, 1e9, dtype=np.float32)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                cx, cy, cz = ix + dx, iy + dy, iz + dz
                p = pts[cx % cells, cy % cells, cz % cells]
                d = (cx + p[..., 0] - x) ** 2 + (cy + p[..., 1] - y) ** 2 + (cz + p[..., 2] - z) ** 2
                best = np.minimum(best, d)
    return np.sqrt(best)


def perlin(n: int, cells: int, rng: np.random.Generator) -> np.ndarray:
    """Градиентный шум Перлина, бесшовный с периодом cells."""
    g = rng.normal(size=(cells, cells, cells, 3))
    g /= np.linalg.norm(g, axis=-1, keepdims=True)
    ax = (np.arange(n) + 0.5) / n * cells
    x, y, z = np.meshgrid(ax, ax, ax, indexing="ij")
    i0, j0, k0 = np.floor(x).astype(int), np.floor(y).astype(int), np.floor(z).astype(int)
    fx, fy, fz = x - i0, y - j0, z - k0

    def fade(t):
        return t * t * t * (t * (t * 6 - 15) + 10)

    u, v, w = fade(fx), fade(fy), fade(fz)
    out = 0.0
    for di in (0, 1):
        for dj in (0, 1):
            for dk in (0, 1):
                gr = g[(i0 + di) % cells, (j0 + dj) % cells, (k0 + dk) % cells]
                dot = gr[..., 0] * (fx - di) + gr[..., 1] * (fy - dj) + gr[..., 2] * (fz - dk)
                wx = u if di else 1 - u
                wy = v if dj else 1 - v
                wz = w if dk else 1 - w
                out = out + dot * wx * wy * wz
    return out


def fbm(fn, n, cells, octaves, rng, gain=0.5):
    total, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        total = total + fn(n, cells * 2 ** o, rng) * amp
        norm += amp
        amp *= gain
    return total / norm


def remap(v, lo, hi, nlo, nhi):
    return nlo + (v - lo) * (nhi - nlo) / (hi - lo)


def save(name: str, vol: np.ndarray, cols: int) -> None:
    """Срезы по z в атлас PNG (cols по горизонтали) + .import для импортёра 3D-текстур Godot."""
    from PIL import Image

    v = np.clip(vol, 0.0, 1.0)
    n = v.shape[0]
    rows = n // cols
    atlas = np.zeros((rows * n, cols * n), dtype=np.uint8)
    for z in range(n):
        r, c = divmod(z, cols)
        atlas[r * n:(r + 1) * n, c * n:(c + 1) * n] = (v[:, :, z].T * 255.0 + 0.5).astype(np.uint8)
    path = os.path.join(OUT, name + ".png")
    Image.fromarray(atlas, "L").save(path, optimize=True)
    with open(path + ".import", "w", encoding="utf-8") as f:
        f.write("[remap]\n\nimporter=\"3d_texture\"\ntype=\"CompressedTexture3D\"\n\n"
                "[params]\n\ncompress/mode=0\nmipmaps/generate=true\nmipmaps/limit=-1\n"
                f"slices/horizontal={cols}\nslices/vertical={rows}\n")
    print(name, v.shape, "min/mean/max", float(v.min()), float(v.mean()), float(v.max()))


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(20260927)
    n = 128
    # Крупные клубы: Perlin-Worley. Уорли инвертирован (1 − F1): высокий в центрах клубов.
    w = 1.0 - np.clip(fbm(worley, n, 4, 3, rng, 0.5) / 0.9, 0.0, 1.0)
    p = fbm(perlin, n, 4, 4, rng, 0.5) * 0.5 + 0.5
    pw = np.clip(remap(p, w - 1.0, 1.0, 0.0, 1.0), 0.0, 1.0)
    shape = 0.35 * pw + 0.65 * w
    shape = (shape - shape.min()) / (shape.max() - shape.min())
    save("cloud_shape", 1.0 - shape, 16)
    # Мелкий шум краёв: Уорли 3 октавы, чаще.
    nd = 64
    wd = 1.0 - np.clip(fbm(worley, nd, 6, 3, rng, 0.55) / 0.9, 0.0, 1.0)
    wd = (wd - wd.min()) / (wd.max() - wd.min())
    save("cloud_detail", 1.0 - wd, 8)


main()
