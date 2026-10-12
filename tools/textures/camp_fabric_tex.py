#!/usr/bin/env python3
"""Процедурная нормаль ткани лагеря (рипстоп): assets/textures/camp/fabric_normal.png, 512², бесшовная.
Плетение 64x64 нитей на плитку, каждая 8-я нить утолщена (рипстоп). Без лицензий (наш генератор).
Запуск: python3 tools/textures/camp_fabric_tex.py"""
import struct
import sys
import zlib

import numpy as np

N = 512
THREADS = 64
RIP = 8
STRENGTH = 2.2


def write_png(path, rgb):
    h, w, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/textures/camp/fabric_normal.png"
    rng = np.random.default_rng(11)
    cell = N // THREADS
    y, x = np.mgrid[0:N, 0:N]
    ci, cj = x // cell, y // cell
    fx = (x % cell + 0.5) / cell
    fy = (y % cell + 0.5) / cell
    s = lambda t: np.sin(np.pi * t) ** 0.8
    up = ((ci + cj) % 2 == 0)
    h = np.where(up, s(fx) * 0.75 + 0.25 * s(fy), s(fy) * 0.75 + 0.25 * s(fx))
    rip = ((ci % RIP == 0) | (cj % RIP == 0)).astype(float)
    h = h * (1.0 + 0.45 * rip)
    noise = rng.standard_normal((N // 4, N // 4))
    noise = np.kron(noise, np.ones((4, 4)))
    h = h + 0.05 * noise
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    nx, ny, nz = -gx * STRENGTH, -gy * STRENGTH, np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    img = np.stack([nx / ln, ny / ln, nz / ln], -1) * 0.5 + 0.5
    write_png(out, np.clip(img * 255 + 0.5, 0, 255).astype(np.uint8))


if __name__ == "__main__":
    main()
