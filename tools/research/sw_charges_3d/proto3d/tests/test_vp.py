"""Тесты ядер SWD-12: кольцо Кельвина, градиент против конечных разностей, ∇·u = 0."""
import numpy as np
from proto3d import vp, rings


def test_grad_fd():
    rng = np.random.default_rng(1)
    S = rng.normal(size=(30, 3)) * 5
    A = rng.normal(size=(30, 3))
    SG = np.full(30, 2.0)
    X = rng.normal(size=(8, 3)) * 4
    u, G = vp.velocity(X, S, A, SG, grad=True)
    G = G.get()
    h = 1e-5
    for b in range(3):
        e = np.zeros(3); e[b] = h
        up = vp.velocity(X + e, S, A, SG).get()
        um = vp.velocity(X - e, S, A, SG).get()
        fd = (up - um) / (2 * h)
        assert np.allclose(fd, G[:, :, b], atol=1e-7, rtol=1e-6)
    assert np.allclose(G[:, 0, 0] + G[:, 1, 1] + G[:, 2, 2], 0, atol=1e-9)  # ∇·u = 0


def test_kelvin_ring_speed():
    a, gam, core = 10.0, 5.0, 1.0
    S, A, SG = rings.ring_segments(np.zeros(3), np.array([0, 0, 1.0]), a, gam, core, 256)
    u = vp.velocity(np.array([[a, 0, 0.0]]), S, A, SG).get()
    # на кольце самоиндукция: скорость точки на оси кольца
    u0 = vp.velocity(np.array([[0, 0, 0.0]]), S, A, SG).get()[0, 2]
    assert abs(u0 - gam / (2 * a)) / (gam / (2 * a)) < 0.01  # центр: Γ/2a
