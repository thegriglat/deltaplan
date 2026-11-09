"""Сверка current.py с ручным расчётом по формулам profile.rs. Запуск: python3 test_current.py или pytest."""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import current  # noqa: E402

TOP, R, W0 = 1400.0, 107.0, 3.1


def ss(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def hand(x, z, ring=-1.0):
    """Ручной расчёт: скаляры, ось в (0,0)."""
    if z <= 0 or z >= TOP:
        return 0.0
    xi = min(z / TOP, 1.0)
    r = R * max(0.45, xi ** (1 / 3) * (1 - 0.25 * xi) / 0.75)
    x2 = x * x / (r * r)
    if x * x > R * R * 6.25 or x2 > 6.25:
        return 0.0
    vert = min(1.0, (z / 150.0) ** (1 / 3))
    if TOP - z < 120.0:
        vert *= ss(0.0, 120.0, TOP - z)
    g = math.exp(-x2) * (1 - x2)
    if g < 0:
        g *= 1.6 if ring < 0 else ring
    return W0 * vert * g


def w(x, z, **kw):
    return float(current.current_w(np.array([x, 0.0, z]), src=(0.0, 0.0), top=TOP, R=R, w0=W0, **kw))


def rad(z):
    xi = z / TOP
    return R * max(0.45, xi ** (1 / 3) * (1 - 0.25 * xi) / 0.75)


def close(a, b):
    return abs(a - b) <= 1e-12 + 1e-9 * abs(b)


def test_axis():
    assert close(w(0, 700.0), W0)
    assert close(w(0, 700.0), hand(0, 700.0))


def test_half():
    x = 0.5 * rad(700.0)
    assert close(w(x, 700.0), hand(x, 700.0))
    assert close(w(x, 700.0), W0 * math.exp(-0.25) * 0.75)


def test_ring():
    x = 1.5 * rad(700.0)
    g = math.exp(-2.25) * (1 - 2.25)
    assert close(w(x, 700.0), W0 * 1.6 * g) and w(x, 700.0) < 0
    assert close(w(x, 700.0, ring=0.5), W0 * 0.5 * g)
    assert close(w(x, 700.0, ring=0.5), hand(x, 700.0, 0.5))
    assert close(w(0.9 * rad(700.0), 700.0), hand(0.9 * rad(700.0), 700.0)) and w(0.9 * rad(700.0), 700.0) > 0


def test_cutoff():
    r = rad(700.0)
    assert w(2.5 * r * 1.001, 700.0) == 0.0
    assert w(2.49 * r, 700.0) != 0.0
    assert w(1.0 * r, 700.0) == 0.0 or abs(w(r, 700.0)) < 1e-12


def test_ramp_and_top():
    assert close(w(0, 50.0), W0 * (50 / 150) ** (1 / 3))
    assert close(w(0, 1360.0), hand(0, 1360.0))
    assert close(w(0, 1330.0), hand(0, 1330.0))
    assert w(0, 1399.99) < 1e-3 and w(0, 1400.0) == 0.0
    assert w(0, 0.0) == 0.0 and w(0, -5.0) == 0.0


def test_shape_lean_allen():
    a = current.current_w(np.zeros((3, 4, 3)) + [0, 0, 700.0], src=(0, 0), top=TOP, R=R, w0=W0)
    assert a.shape == (3, 4)
    # наклон 0.1 м/м: на dh = 700 ось сдвинута на 70 м
    wl = float(current.current_w(np.array([70.0, 0.0, 700.0]), src=(0, 0), top=TOP, R=R, w0=W0, lean=(0.1, 0.0)))
    assert close(wl, W0)
    R_, w0_, nA = current.allen_core(2.5, 1400.0)
    assert close(R_, 0.0765 * 1400) and close(w0_, 3.1) and close(nA, 8.5 / 1400**2)


if __name__ == "__main__":
    for k, f in list(globals().items()):
        if k.startswith("test_"):
            f()
            print("ok", k)
