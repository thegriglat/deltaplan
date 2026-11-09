"""Проверки шаблона пузыря сверх контрактного теста."""
import dataclasses

import numpy as np

import bubble as bm

ENV = bm.Env(wind=(0.0, 0.0), zi=1400.0)
BIG = bm.Env(zi=1e6)


def head(U=2.0, R=100.0, zc=700.0):
    return bm.State(xs=0, ys=0, xc=0, yc=0, zc=zc, R=R, U=U, Q=0.0, F0=0.0, zb=zc)


def v1(p, st, **kw):
    return bm.velocity(np.array([p], float), [st], BIG, ground=False, lid=False, **kw)[0]


def test_hill_center():
    st = head()
    assert abs(v1([0, 0, 700], st)[2] - 2.5 * st.U) < 1e-12


def test_hill_continuity_at_R():
    st = head()
    for d in ([1, 0, 0], [0, 0, 1], [0.6, 0.0, 0.8], [0.3, 0.4, -0.866]):
        d = np.array(d) / np.linalg.norm(d)
        a = v1(np.array([0, 0, 700]) + d * st.R * (1 - 1e-9), st)
        b = v1(np.array([0, 0, 700]) + d * st.R * (1 + 1e-9), st)
        assert np.max(np.abs(a - b)) < 1e-6 * st.U


def test_hill_top_speed_is_U():
    st = head()
    assert abs(v1([0, 0, 700 + 100], st)[2] - st.U) < 1e-9


def _plume_state():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    return src, bm.state(src, ENV, 0.5 * src.tau)


def test_inflow_toward_axis_near_ground():
    _, st = _plume_state()
    for d in (60.0, 150.0):
        v = bm.velocity(np.array([[d, 0, 5.0], [-d, 0, 5.0], [0, d, 5.0]]), [st], ENV)
        assert v[0, 0] < 0 and v[1, 0] > 0 and v[2, 1] < 0


def test_plume_flux_5_3():
    F = 2000.0
    assert abs(bm.plume_Q(F, 400.0) / bm.plume_Q(F, 200.0) - 2 ** (5 / 3)) < 1e-12
    assert abs(bm.plume_w(F, 400.0) / bm.plume_w(F, 200.0) - 2 ** (-1 / 3)) < 1e-12


def test_plume_interior_w_matches_mtt():
    src, st = _plume_state()
    s = 300.0
    # точка на оси плюма на расстоянии s; ветра нет — ось вертикальна
    p = np.array([[0.0, 0.0, s]])
    w = bm.velocity(p, [dataclasses.replace(st, U=0.0)], ENV, ground=False, lid=False)[0, 2]
    assert abs(w / bm.plume_w(src.F0, s) - 1) < 1e-2


def test_similarity_after_detach():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    sts = [bm.state(src, BIG, src.tau * f) for f in (1.5, 3.0, 6.0)]
    zv = sts[0].zc - sts[0].R / bm.PARAMS["alpha_thermal"]["value"]
    for s in sts:  # R ∝ (z − zv), U (z − zv) = const
        assert abs(s.R / (s.zc - zv) - 0.25) < 1e-9
    k = [s.U * (s.zc - zv) for s in sts]
    assert max(k) / min(k) - 1 < 1e-9


def test_U_continuous_at_detach():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    a, b = bm.state(src, BIG, src.tau - 1e-3), bm.state(src, BIG, src.tau + 1e-3)
    assert abs(a.U - b.U) < 1e-3 and abs(a.R - b.R) < 1e-2


def test_plume_dies_when_caught():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    s = bm.state(src, BIG, 3 * src.tau)
    assert s.F0 == 0.0 and s.Q == 0.0 and s.zb == s.zc


def test_lid_stop_and_end():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    s = bm.state(src, ENV, src.tau * 1.1)
    assert s.U == 0.0 and s.zc + s.R <= ENV.zi + 1e-6
    assert bm.state(src, ENV, src.tau * 20) is None


def test_two_bubbles_divergence_and_ground():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    a = bm.state(src, ENV, 0.4 * src.tau)
    b = dataclasses.replace(a, xs=500.0, xc=a.xc + 500.0, yc=200.0, ys=200.0)
    rng = np.random.default_rng(3)
    P = np.stack([rng.uniform(-200, 800, 800), rng.uniform(-200, 400, 800), rng.uniform(5, 1395, 800)], -1)
    h = 1e-3 * a.R
    div = 0
    for k in range(3):
        e = np.zeros(3); e[k] = h
        div = div + (bm.velocity(P + e, [a, b], ENV)[:, k] - bm.velocity(P - e, [a, b], ENV)[:, k]) / (2 * h)
    assert np.percentile(np.abs(div), 99) * a.R / a.U < 1e-3
    g = P.copy(); g[:, 2] = 0.0
    assert np.max(np.abs(bm.velocity(g, [a, b], ENV)[:, 2])) < 1e-3 * np.max(np.abs(bm.velocity(P, [a, b], ENV)[:, 2]))
