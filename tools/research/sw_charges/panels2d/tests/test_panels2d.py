import numpy as np
import pytest
from panels2d import (Terrain, build_panels, bg_uniform, bg_profile,
                                                Vortices, solve, velocity, step, residual)


def flat(zv=0.0):
    return Terrain([-1000.0, 1000.0], [zv, zv])


def agnesi(H=200.0, L=500.0, xr=6000.0):
    x = np.linspace(-xr, xr, 2401)
    return Terrain(x, H / (1 + (x / L) ** 2))


def semicyl(R=200.0):
    x = np.linspace(-2 * R, 2 * R, 4001)
    return Terrain(x, np.sqrt(np.maximum(R * R - x * x, 0.0)))


def test_flat_uniform():
    p = build_panels(flat(), x_focus=0.0, ds_min=25.0)
    bg = bg_uniform(5.0)
    s = solve(p, bg)
    assert np.max(np.abs(s)) < 1e-10
    z = np.array([1.0, 10, 100, 1000])
    u, w = velocity(p, s, bg, np.zeros(4), z)
    assert np.allclose(u, 5.0, atol=1e-10) and np.allclose(w, 0, atol=1e-10)


def test_semicylinder():
    # ds_min = R/20 даёт на высоте 1 м и θ = 20° ошибку 6-15 % (ближнее поле постоянных панелей, косой угол у основания);
    # ±2 % достигается при ds_min = R/160 на всём полукруге (x_focus=None). Вершина (1 м): при R/20 с фокусом -1,24 %, при R/160 ≈ -0,6 %.
    R, U = 200.0, 3.0
    bg = bg_uniform(U)
    p = build_panels(semicyl(R), x_focus=None, ds_min=R / 160)
    s = solve(p, bg)
    u, w = velocity(p, s, bg, np.array([0.0]), np.array([R + 1.0]))
    assert abs(u[0] / (2 * U) - 1) < 0.01
    th = np.radians(np.arange(20, 161, 10))
    r = R + 1.0
    u, w = velocity(p, s, bg, r * np.cos(th), r * np.sin(th))
    ex = U * np.hypot((1 + R * R / r / r) * np.sin(th), (1 - R * R / r / r) * np.cos(th))  # точное для цилиндра в r
    assert np.all(np.abs(np.hypot(u, w) / ex - 1) < 0.02)
    assert np.all(np.abs(np.hypot(u, w) / (2 * U * np.sin(th)) - 1) < 0.025)  # к 2U sinθ, с поправкой 1 м над землёй


def test_residual():
    p = build_panels(agnesi(), x_focus=0.0, ds_min=25.0)
    bg = bg_uniform(7.0)
    s = solve(p, bg)
    assert residual(p, s, bg) <= 1e-8 * 7.0


def test_convergence_agnesi():
    ucrest = []
    for ds in (50.0, 25.0, 12.5):
        t = agnesi()
        p = build_panels(t, x_focus=0.0, ds_min=ds)
        bg = bg_uniform(10.0)
        s = solve(p, bg)
        u, w = velocity(p, s, bg, np.array([0.0]), np.array([200.0 + 10.0]))
        ucrest.append(u[0])
    assert abs(ucrest[2] / ucrest[1] - 1) < 0.01
    assert ucrest[2] > 10.0


def test_underground_nan_and_near_panel_finite():
    t = agnesi()
    p = build_panels(t, x_focus=0.0, ds_min=25.0)
    bg = bg_uniform(10.0)
    s = solve(p, bg)
    u, w = velocity(p, s, bg, np.array([0.0, 300.0]), np.array([100.0, -5.0]))
    assert np.all(np.isnan(u)) and np.all(np.isnan(w))
    # у панели (ближе ds/4), сверху и у узла
    k = np.arange(0, p.n, 7)
    off = 0.2 * p.ds[k] / 4
    for xs, zs in ((p.xc[k] + p.nx[k] * off, p.zc[k] + p.nz[k] * off),
                   (p.x1[k] + p.nx[k] * off, p.z1[k] + p.nz[k] * off)):
        u, w = velocity(p, s, bg, xs, zs)
        assert np.all(np.isfinite(u)) and np.all(np.isfinite(w))


def test_image_velocity():
    p = build_panels(flat(), x_focus=0.0, ds_min=10.0)
    G, h = 1000.0, 100.0
    st = dict(panels=p, bg=bg_uniform(0.0), vortices=Vortices([0.0], [h], [G], [5.0]), t=0.0, shed=[])
    v = G / (4 * np.pi * h)
    dt, n = 1.0, 10
    for _ in range(n):
        step(st, dt)
    vt = st["vortices"]
    assert abs(vt.x[0] / (v * dt * n) - 1) < 0.02
    assert abs(vt.z[0] - h) < 0.02 * h


def test_free_pair():
    p = build_panels(flat(), x_focus=0.0, ds_min=50.0)
    bg = bg_uniform(0.0)
    G, d, h = 500.0, 20.0, 5000.0
    vt = Vortices([-d / 2, d / 2], [h, h], [G, -G], [1.0, 1.0])
    s = solve(p, bg, vt)
    u, w = velocity(p, s, bg, vt.x, vt.z, vt)
    sp = np.hypot(u, w)
    assert np.allclose(sp, G / (2 * np.pi * d), rtol=0.02)


def test_step_agnesi_circulation():
    t = agnesi()
    p = build_panels(t, x_focus=0.0, ds_min=25.0)
    shed = [dict(x_s=100.0, z_s=float(t.height(100.0)) + 12.5, rule="crest")]
    st = dict(panels=p, bg=bg_uniform(10.0), vortices=Vortices(), t=0.0, shed=shed)
    for _ in range(100):
        before = st["vortices"].gamma.sum()
        b0, l0 = st.get("born", 0.0), st.get("lost", 0.0)
        step(st, 0.5)
        vt = st["vortices"]
        assert np.all(np.isfinite(vt.x)) and np.all(np.isfinite(vt.z)) and np.all(np.isfinite(vt.gamma))
        assert abs(vt.gamma.sum() - (before + st["born"] - b0 - (st["lost"] - l0))) < 1e-12 * max(1.0, abs(before))
    assert st["vortices"].n > 0 and st["born"] < 0
    assert abs(st["vortices"].gamma.sum() - (st["born"] - st["lost"])) < 1e-9


def test_bg_profile():
    t = Terrain([-1000.0, 1000.0], [50.0, 50.0])
    bg = bg_profile(8.0, 0.2, 100.0, t)
    zagl = np.array([0.01, 1.0, 10.0, 50.0, 100.0, 500.0])
    u, w = bg(np.zeros(6), 50.0 + zagl)
    ref = 8.0 * (np.clip(zagl, 0.1, 100.0) / 10.0) ** 0.2
    assert np.allclose(u, ref) and np.all(w == 0)
