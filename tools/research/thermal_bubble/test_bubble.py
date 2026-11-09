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
    # w на оси шлейфа против MTT w_p(z + z_v): внешнее решение из стоков занижает на 4–15 % (README), не больше
    src, st = _plume_state()
    st = dataclasses.replace(st, U=0.0, Uh=0.0)
    for z, tol in ((200.0, 0.08), (300.0, 0.12)):
        w = bm.velocity(np.array([[st.xc, st.yc, z]]), [st], ENV, ground=False, lid=False)[0, 2]
        assert abs(w / bm.plume_w(src.F0, z + bm._zv(src.b0)) - 1) < tol, z


def test_axis_vertical_and_drift():
    env = bm.Env(wind=(3.0, -1.0), zi=1400.0)
    src = bm.from_game(100, 50, 10, 2.5, 1400, env)
    for tp in (30.0, 300.0, 900.0, 1500.0):
        s = bm.state(src, env, src.t0 + tp)
        assert s.xs == s.xc and s.ys == s.yc
        assert abs(s.xc - (src.x + 3.0 * tp)) < 1e-9 and abs(s.yc - (src.y - tp)) < 1e-9
    # поле симметрично вокруг вертикальной оси: v(x0 + dx, y0, z) и v(x0 − dx, y0, z) — зеркальные
    s = bm.state(src, env, src.t0 + 400.0)
    a = bm.velocity(np.array([[s.xc + 120.0, s.yc, 600.0]]), [s], env)[0]
    c = bm.velocity(np.array([[s.xc, s.yc + 120.0, 600.0]]), [s], env)[0]
    assert abs(a[0] - c[1]) < 1e-9 and abs(a[2] - c[2]) < 1e-9 and abs(a[1]) < 1e-9


def test_virtual_source_finite_near_ground():
    src, st = _plume_state()
    zv = bm._zv(src.b0)
    assert abs(zv - 5 * src.b0 / (6 * bm.PARAMS["alpha_plume"]["value"])) < 1e-9
    assert abs(1.2 * bm.PARAMS["alpha_plume"]["value"] * zv - src.b0) < 1e-9  # b(0) = b0
    z = np.linspace(0.5, 100.0, 30)
    P = np.stack([np.full_like(z, st.xc), np.full_like(z, st.yc), z], -1)
    w = bm.velocity(P, [st], ENV)[:, 2]
    assert np.all(np.isfinite(w)) and np.max(np.abs(w)) <= 2.0 * 2.5
    assert abs(bm.velocity(np.array([[st.xc, st.yc, 0.0]]), [st], ENV)[0, 2]) < 1e-9


def test_time_continuity_around_transitions():
    env = bm.Env(wind=(3.0, 0.0), zi=1400.0)
    src = bm.from_game(0, 0, 0, 2.5, 1400, env)
    t_end = bm._traj(src, env).t_end
    gx = np.arange(-600.0, 601.0, 60.0)
    gz = np.arange(1.0, 1400.0, 60.0)
    GX, GZ = np.meshgrid(gx, gz, indexing="ij")
    vmax, jump = 0.0, 0.0
    for t0, t1 in ((2, 40), (src.tau - 40, src.tau + 80), (900, 960), (t_end - 60, t_end - 2)):
        prev = None
        for t in np.arange(t0, t1 + 1e-9, 2.0):
            s = bm.state(src, env, t)
            v = bm.velocity(np.stack([GX + 3.0 * t, np.zeros_like(GX), GZ], -1), [s], env)
            vmax = max(vmax, float(np.max(np.linalg.norm(v, axis=-1))))
            if prev is not None:
                jump = max(jump, float(np.max(np.linalg.norm(v - prev, axis=-1))))
            prev = v
    assert jump <= 0.25 * vmax, (jump, vmax)
    assert bm.state(src, env, t_end + 1.0) is None


def test_similarity_after_detach():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    sts = [bm.state(src, BIG, src.tau * f) for f in (1.5, 3.0, 6.0)]
    a = bm.PARAMS["alpha_thermal"]["value"]
    for s in sts:  # R = α(z + z_h) (v3, измеренный рост ядра), U (z + z_h) = const (Скорер)
        assert abs(s.R - a * (s.zc + src.zh)) < 1e-9
    k = [s.U * (s.zc + src.zh) for s in sts]
    assert max(k) / min(k) - 1 < 1e-9


def test_U_continuous_at_detach():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    a, b = bm.state(src, BIG, src.tau - 1e-3), bm.state(src, BIG, src.tau + 1e-3)
    assert abs(a.U - b.U) < 1e-3 and abs(a.R - b.R) < 1e-2


def test_plume_dies_when_caught():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    s = bm.state(src, BIG, 3 * src.tau)
    assert s.F0 == 0.0 and s.Q == 0.0 and s.zb <= s.zc - s.R + 1e-9


def test_lid_stop_and_end():
    src = bm.from_game(0, 0, 0, 2.5, 1400, ENV)
    s = bm.state(src, ENV, src.tau * 2.0)
    assert s.U < 0.05 and s.zc + s.R < ENV.zi          # остановка плавная, крышку не пересекает
    assert s.Uh > s.U                                   # вихрь головы ещё живёт, гаснет по t_decay
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


def test_hill_shell_smooth_and_continuous():
    # v3: ψ-смешение — скорость непрерывна, излом убран (Δ²w/h·R/U ≤ 0,5 на экваторе и оси), ∇·v = 0 в оболочке
    st = head()
    h = 0.005 * st.R
    x = np.arange(-2 * st.R, 2 * st.R + 1e-9, h)
    for line in (np.stack([x, 0 * x, 0 * x + 700], -1), np.stack([0 * x, 0 * x, 700 + x], -1)):
        w = bm.velocity(line, [st], BIG, ground=False, lid=False)[:, 2]
        assert np.max(np.abs(w[2:] - 2 * w[1:-1] + w[:-2])) / h * st.R / st.U <= 0.5
    rng = np.random.default_rng(5)
    d = rng.normal(size=(300, 3)); d /= np.linalg.norm(d, axis=1, keepdims=True)
    P = np.array([0, 0, 700.0]) + d * st.R * rng.uniform(0.7, 1.3, (300, 1))
    hh = 1e-3 * st.R
    div = 0
    for k in range(3):
        e = np.zeros(3); e[k] = hh
        div = div + (bm.velocity(P + e, [st], BIG, ground=False, lid=False)[:, k]
                     - bm.velocity(P - e, [st], BIG, ground=False, lid=False)[:, k]) / (2 * hh)
    assert np.max(np.abs(div)) * st.R / st.U < 1e-3
    # вне оболочки — чистый Хилл
    st2 = head()
    far = bm.velocity(np.array([[1.4 * st.R, 0, 700.0]]), [st2], BIG, ground=False, lid=False)[0]
    assert abs(far[2] - (-0.5 * st.U / 1.4 ** 3)) < 1e-12


def test_core_radius_matches_lenschow_stephens():
    # радиус смены знака w при R = α(z + z_h): совпадает с r_LS(ζ) = 0,08 ζ^⅓(1 − 0,25ζ) z_i с точностью подгонки (≤ 8 %, ζ 0,2–0,8; линейная подгонка ζ^⅓)
    a = bm.PARAMS["alpha_thermal"]["value"]
    zh = bm._ZH_FRAC * 1400.0
    for zeta in (0.2, 0.5, 0.8):
        R = a * (zeta * 1400.0 + zh)
        r_ref = 0.08 * zeta ** (1 / 3) * (1 - 0.25 * zeta) * 1400.0
        assert abs(bm._SIGN_OVER_R * R / r_ref - 1) < 0.08, zeta


def test_from_strength_hits_w0():
    for w0 in (1.5, 3.0):
        src = bm.from_strength(0, 0, 0, w0, 1400.0, 690.0, ENV)
        assert abs(bm._axis_wmax(src, ENV) / w0 - 1) < 0.02


def test_kbar_positive_and_scales():
    kb = bm.kbar(1400.0, 690.0, ENV)
    assert 100.0 < kb < 1e5
    assert bm.kbar(1400.0, 690.0, bm.Env(wind=(3.0, 1.0), zi=1400.0)) == kb     # ветер не влияет
