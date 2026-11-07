import numpy as np
import pytest
from panels2d import (Terrain, build_panels, bg_uniform, bg_profile,
                                                Vortices, solve, velocity, step, residual,
                                                surface_flow, boundary_layer, separation, velocity_bl)


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
    # инвариант SW6 v2: ds_min = R/20, x_focus=None; у основания (угол 90° открытой линии источников) ошибка 1-го порядка
    R, U = 200.0, 3.0
    bg = bg_uniform(U)
    p = build_panels(semicyl(R), x_focus=None, ds_min=R / 20)
    s = solve(p, bg)
    u, w = velocity(p, s, bg, np.array([0.0]), np.array([R + 1.0]))
    assert abs(u[0] / (2 * U) - 1) < 0.01
    # точки коллокации (на 1e-3 м над серединой панели) на полукруге: |V| = 2U sinθ
    inside = (np.abs(p.xc) < R - 1) & (p.zc > 1e-6)
    th = np.arctan2(p.zc[inside], p.xc[inside])
    k = (th > np.radians(30)) & (th < np.radians(150))
    xs, zs = p.xc[inside][k] + 1e-3 * p.nx[inside][k], p.zc[inside][k] + 1e-3 * p.nz[inside][k]
    u, w = velocity(p, s, bg, xs, zs)
    assert k.sum() > 10
    assert np.all(np.abs(np.hypot(u, w) / (2 * U * np.sin(th[k])) - 1) < 0.03)


def test_no_slivers_and_core():
    for ds, xf in ((25.0, 0.0), (12.5, 0.0), (7.3, 100.0), (25.0, None)):
        p = build_panels(agnesi(), x_focus=xf, ds_min=ds)
        assert p.ds_min == ds and p.ds.min() >= 0.5 * ds - 1e-9
        assert abs(p.x2[:-1] - p.x1[1:]).max() == 0.0
    t = agnesi()
    p = build_panels(t, x_focus=0.0, ds_min=12.5)
    st = dict(panels=p, bg=bg_uniform(10.0), vortices=Vortices(), t=0.0,
              shed=[dict(x_s=100.0, z_s=float(t.height(100.0)) + 6.0, rule="crest")])
    step(st, 0.5)
    assert np.allclose(st["vortices"].core, 6.25)


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


# ---- v3: пограничный слой, отрыв, скорость у стенки ----
def _bl(terrain, bg, ds=25.0, z0=0.1, xf=0.0):
    p = build_panels(terrain, x_focus=xf, ds_min=ds)
    s = solve(p, bg)
    fl = surface_flow(p, s, bg)
    return p, s, fl, boundary_layer(p, fl, z0)


def test_flat_bl_profile():
    t = flat()
    bg = bg_profile(8.0, 0.2, 200.0, t)
    p, s, fl, bl = _bl(t, bg)
    assert np.all(np.diff(bl["theta"]) >= -1e-12) and np.all(np.isfinite(bl["theta"]))
    assert np.all(bl["H"] < 2.4) and bl["i_sep"] == -1
    for m in ("head", "stratford"):
        assert separation(p, fl, bl, m) == []
    z = np.array([10.0, 15, 20, 30, 50, 100, 200, 300])
    u, w = velocity_bl(p, s, bg, np.zeros(z.size), z, bl)
    ub, _ = bg(np.zeros(z.size), z)
    assert np.all(np.abs(u / ub - 1) < 0.03) and np.allclose(w, 0, atol=1e-9)


def test_equilibrium_layer():
    from panels2d.bl import _equilibrium, _H1_of_H, _H_of_H1, _F, _cf2
    th0, H10, H0 = _equilibrium(0.1)
    assert abs(float(_H1_of_H(H0)) - H10) < 1e-9 and abs(_H_of_H1(H10) - H0) < 1e-6
    assert abs(H10 * _cf2(th0 * (H10 + H0), 0.1) - _F(H10)) < 1e-6  # вовлечение уравновешено трением
    assert 1.3 < H0 < 2.0


def test_surface_flow_semicylinder():
    R, U = 200.0, 3.0
    bg = bg_uniform(U)
    p = build_panels(semicyl(R), x_focus=None, ds_min=R / 20)
    fl = surface_flow(p, solve(p, bg), bg)
    assert fl["U_ref"] == U and np.all(np.diff(fl["s"]) > 0)
    m = (np.abs(p.xc) < R - 1) & (p.zc > 1e-6)
    th = np.arctan2(p.zc[m], p.xc[m])
    k = (th > np.radians(30)) & (th < np.radians(150))
    ex = 2 * U * np.sin(th[k])
    assert k.sum() > 10 and np.all(np.abs(fl["u_s"][m][k] / ex - 1) < 0.03)
    assert np.allclose(fl["cp"][m][k], 1 - (fl["u_s"][m][k] / U) ** 2)
    assert np.all(np.abs(fl["cp"][m][k] - (1 - ex ** 2 / U ** 2)) < 0.3)  # cp = 1 − 4 sin²θ


def test_agnesi_gentle_no_separation():
    for hl in (0.1, 0.3):
        p, s, fl, bl = _bl(agnesi(H=hl * 500.0), bg_uniform(10.0))
        assert bl["i_sep"] == -1 and np.nanmax(bl["H"]) < 2.4
        for m in ("head", "stratford"):
            assert separation(p, fl, bl, m) == []


def test_agnesi_steep_separation_head():
    # H/L = 0.7: отрыв Хеда на подветренном склоне; ниже точки — NaN; рост H с равновесного 1,66 до 2,4
    t = agnesi(H=350.0)
    p, s, fl, bl = _bl(t, bg_uniform(10.0))
    sp = separation(p, fl, bl, "head")
    assert len(sp) == 1 and sp[0]["method"] == "head" and sp[0]["x_sep"] > 0 and abs(sp[0]["z_sep"] - t.height(sp[0]["x_sep"])) < 5
    assert 2.35 < sp[0]["value"] < 3.5
    j = bl["i_sep"]
    assert np.all(np.isfinite(bl["theta"][:j + 1])) and np.all(np.isnan(bl["theta"][j + 1:]))
    # профиль ветра, H/L = 0.5: отрыв Хеда тоже есть (слой подкрепляется сдвигом фона)
    t = agnesi(H=250.0)
    p, s, fl, bl = _bl(t, bg_profile(10.0, 0.2, 200.0, t))
    assert separation(p, fl, bl, "head")[0]["x_sep"] > 0


def test_stratford():
    # Агнези даже при H/L = 1 — потенциальное торможение пологое: Стратфорд отрыва не даёт (граница метода)
    p, s, fl, bl = _bl(agnesi(H=500.0), bg_uniform(10.0))
    assert separation(p, fl, bl, "stratford") == []
    # полуцилиндр: торможение за вершиной резкое — отрыв на подветренной стороне (θ ≈ 54°)
    R = 200.0
    p = build_panels(semicyl(R), x_focus=None, ds_min=R / 20)
    bg = bg_uniform(3.0)
    fl = surface_flow(p, solve(p, bg), bg)
    sp = separation(p, fl, boundary_layer(p, fl, 0.1), "stratford")
    assert len(sp) == 1 and sp[0]["method"] == "stratford" and 0 < sp[0]["x_sep"] < R
    assert 30 < np.degrees(np.arctan2(sp[0]["z_sep"], sp[0]["x_sep"])) < 80 and sp[0]["value"] >= 0.39


def test_velocity_bl_loglaw():
    t = flat()
    bg = bg_uniform(6.0)
    p, s, fl, bl = _bl(t, bg)
    d = float(bl["delta"][p.n // 2])
    assert abs(d - 50.0) < 1e-9
    x = np.full(4, 3.0)
    u, w = velocity_bl(p, s, bg, x, np.array([0.1, 5.0, d - 1e-6, d + 1e-6]), bl)
    assert abs(u[0]) < 1e-12 and abs(u[2] - u[3]) < 1e-4 and abs(u[3] - 6.0) < 1e-9
    assert abs(u[1] - 6.0 * np.log(5.0 / 0.1) / np.log(d / 0.1)) < 1e-9
    # над склоном (профиль): вблизи земли скорость меньше потенциальной, нормальная составляющая — потенциальная
    t = agnesi(H=100.0)
    p, s, fl, bl = _bl(t, bg_uniform(10.0))
    xs = np.array([-100.0]); zs = t.height(xs) + 5.0
    ub, wb = velocity(p, s, bg_uniform(10.0), xs, zs)
    ul, wl = velocity_bl(p, s, bg_uniform(10.0), xs, zs, bl)
    assert ul[0] < ub[0] and ul[0] > 0


def test_step_auto_shed():
    t = agnesi(H=350.0)
    p = build_panels(t, x_focus=0.0, ds_min=25.0)
    st = dict(panels=p, bg=bg_uniform(10.0), vortices=Vortices(), t=0.0, shed="auto")
    for _ in range(60):
        before = st["vortices"].gamma.sum()
        b0, l0 = st.get("born", 0.0), st.get("lost", 0.0)
        step(st, 0.5)
        vt = st["vortices"]
        assert abs(vt.gamma.sum() - (before + st["born"] - b0 - (st["lost"] - l0))) < 1e-12 * max(1.0, abs(before))
    vt = st["vortices"]
    assert vt.n > 0 and st["born"] < 0 and np.all(np.isfinite(vt.x))
    # рождение только на подветренной стороне; без отрыва (пологий холм) — нет рождения
    assert np.all(vt.x > -50)
    t = agnesi(H=50.0)
    st = dict(panels=build_panels(t, x_focus=0.0, ds_min=25.0), bg=bg_uniform(10.0), vortices=Vortices(), t=0.0, shed="auto")
    for _ in range(5):
        step(st, 0.5)
    assert st["vortices"].n == 0
