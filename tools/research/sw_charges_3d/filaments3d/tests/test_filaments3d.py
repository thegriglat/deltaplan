"""Тесты SWD3: инварианты нитей. Запуск: tools/research/sw_charges_3d/py -m pytest -q filaments3d/tests"""
import numpy as np
import pytest

from filaments3d import (Filaments, coarsen, imbalance, induced, line, relabel, ring, self_velocity, shed, step)
from filaments3d.core import _gpu_available

ZERO = lambda x, y, z: (np.zeros_like(x), np.zeros_like(x), np.zeros_like(x))
FLAT = lambda x, y: np.zeros_like(np.asarray(x, float))


def ring_speed(R, G, d):
    # Розенхед — Мур: константа −1 (не −1/2), см. README
    return G / (4 * np.pi * R) * (np.log(8 * R / d) - 1.0)


def impulse(f):
    a, b = f.x[f.seg[:, 0]], f.x[f.seg[:, 1]]
    return 0.5 * (f.gamma[:, None] * np.cross(0.5 * (a + b), b - a)).sum(0)


def test_ring_speed():
    R, G, d = 100.0, 50.0, 5.0
    f = ring(R, G, d, 256)
    v = self_velocity(f)
    assert np.allclose(v[:, :2], 0, atol=1e-12)
    assert abs(v[0, 2] / ring_speed(R, G, d) - 1) < 0.03
    # с константой −1/2 из SWD3 разница ≈ 11 % — расхождение констатируем, а не прячем
    assert abs(v[0, 2] / (G / (4 * np.pi * R) * (np.log(8 * R / d) - 0.5)) - 1) > 0.05


def test_ring_100_steps_shape_and_impulse():
    R, G, d = 100.0, 50.0, 5.0
    f = ring(R, G, d, 128)
    U = ring_speed(R, G, d)
    dt = R / U / 100
    I0 = impulse(f)
    for _ in range(100):
        f = step(f, ZERO, dt, FLAT, {"l_max": 1e9, "l_min": 0.0, "r_rec": 0.0})
    c = f.x.mean(0)
    rr = np.linalg.norm((f.x - c)[:, :2], axis=1)
    assert abs(rr.mean() / R - 1) < 0.01 and rr.std() / R < 0.01
    assert np.ptp(f.x[:, 2]) < 0.01 * R  # плоскостность
    assert c[2] > 0.5 * U * 100 * dt  # ушло вперёд
    assert np.linalg.norm(impulse(f) - I0) / np.linalg.norm(I0) < 0.01
    assert imbalance(f) <= 1e-12


def test_imbalance_topology_ops():
    f = ring(10.0, 5.0, 1.0, 40)
    assert imbalance(f) == 0
    # дробление: ядро велико -> l_max по умолчанию 2·core, отрезки 1.57 м -> принудительно l_max
    g = step(f, ZERO, 0.0, FLAT, {"l_max": 0.5, "l_min": 0.0, "r_rec": 0.0})
    assert g.stats["split"] > 0 and len(g.seg) > len(f.seg) and imbalance(g) <= 1e-12
    # слияние
    h = step(g, ZERO, 0.0, FLAT, {"l_max": 1e9, "l_min": 0.9, "r_rec": 0.0})
    assert h.stats["merge"] > 0 and len(h.seg) < len(g.seg) and imbalance(h) <= 1e-12
    # перезамыкание неравных Γ: два встречных отрезка рядом
    x = np.array([[0, 0, 0], [2, 0, 0], [2, 0.3, 0], [0, 0.3, 0.0]])
    # петля 0->1 (Γ=3), 1->2... строим две петли с разными Γ, касающиеся ребром
    a = ring(3.0, 3.0, 0.5, 24, center=(0, 0, 0))
    b = ring(3.0, 1.0, 0.5, 24, center=(6.2, 0, 0))  # одинаково ориентированные: рядом встречные отрезки
    ab = Filaments(np.vstack([a.x, b.x]), np.vstack([a.seg, b.seg + 24]), np.r_[a.gamma, b.gamma],
                   np.r_[a.core, b.core], np.zeros(48, bool), np.zeros(48, int))
    ab = relabel(ab)
    r = step(ab, ZERO, 0.0, FLAT, {"r_rec": 0.6, "l_max": 1e9, "l_min": 0.0})
    assert r.stats["reconnect"] >= 1 and imbalance(r) <= 1e-12
    assert abs(r.gamma.sum() - ab.gamma.sum()) < 1e-12 * 100  # Γ суммарно сохраняется
    assert r.n_filaments == 1  # две петли -> одна


def test_head_on_rings_reconnect():
    R, G, c = 20.0, 20.0, 2.0
    A = ring(R, G, c, 96, center=(0, 0, 0), normal=(0, 0, 1))
    B = ring(R, G, c, 96, center=(0.3 * R, 0, 10.0), normal=(0, 0, -1))
    f = relabel(Filaments(np.vstack([A.x, B.x]), np.vstack([A.seg, B.seg + 96]), np.r_[A.gamma, B.gamma],
                          np.r_[A.core, B.core], np.zeros(192, bool), np.zeros(192, int)))
    assert f.n_filaments == 2
    counts = {f.n_filaments}
    for _ in range(120):
        f = step(f, ZERO, 0.6, FLAT, None)
        assert imbalance(f) <= 1e-12
        counts.add(f.n_filaments)
    assert f.stats["reconnect"] > 0
    assert len(counts) > 1  # число нитей менялось
    assert np.isfinite(f.x).all()


def test_wall_line_with_image():
    h, G, c = 10.0, 30.0, 2.0
    L = 40 * h
    y = np.arange(-L / 2, L / 2 + 1e-9, c)  # отрезки 2 м = 2·core
    pts = np.stack([np.zeros_like(y), y, np.full_like(y, h)], 1)
    f = line(pts, G, c, anchored_ends=False)
    img = Filaments(pts * [1, 1, -1], f.seg[:, ::-1], f.gamma, f.core, np.zeros(len(y), bool), f.fid)  # −Γ

    def flow(x, y_, z):
        return induced(img, x, y_, z)

    mid = len(y) // 2
    v = np.stack(flow(*(f.x[mid:mid + 1].T)), 1)[0] + self_velocity(f)[mid]
    assert abs(abs(v[0]) / (G / (4 * np.pi * h)) - 1) < 0.02
    assert abs(v[1]) < 1e-9 and abs(v[2]) < 1e-3
    g = step(f, flow, 1e-3, FLAT, {"l_max": 1e9, "l_min": 0.0, "r_rec": 0.0})
    vs = (g.x[mid] - f.x[mid]) / 1e-3
    assert abs(abs(vs[0]) / (G / (4 * np.pi * h)) - 1) < 0.02


def test_shed_line():
    M = 11
    P = np.stack([np.zeros(M), np.linspace(0, 50, M), np.zeros(M)], 1)
    U = np.tile([8.0, 0, 0], (M, 1))
    N = np.tile([0, 0, 1.0], (M, 1))
    dt = 0.1
    s = shed(None, P, U, dt, 1.0, N)
    assert len(s.seg) == M - 1 and np.allclose(s.gamma, 0.5 * 64 * dt)
    assert s.anchored[0] and s.anchored[-1] and not s.anchored[1:-1].any()
    # n × û_t = z × x = +y: вдоль линии (a→b = +y), Γ > 0
    assert imbalance(s) == 0
    # обратный порядок точек — знак Γ меняется
    s2 = shed(None, P[::-1].copy(), U, dt, 1.0, N)
    assert np.allclose(s2.gamma, -0.5 * 64 * dt)
    # неравномерная скорость: ножки к земле, замкнутость сохраняется
    U2 = U * np.linspace(1, 2, M)[:, None]
    s3 = shed(s, P + [5, 0, 0], U2, dt, 1.0, N)
    assert len(s3.seg) > len(s.seg) + M - 1 and imbalance(s3) <= 1e-12 and s3.n_filaments == 2


def test_decay_and_core_growth():
    f = ring(50.0, 10.0, 2.0, 64)
    g = step(f, ZERO, 0.7, FLAT, {"tau_s": 30.0, "nu_t": 0.4, "l_max": 1e9, "l_min": 0.0, "r_rec": 0.0})
    assert np.allclose(g.gamma, 10.0 * np.exp(-0.7 / 30.0), rtol=1e-9)
    assert np.allclose(g.core ** 2, 4.0 + 4 * 0.4 * 0.7, rtol=1e-9)
    h = step(f, ZERO, 0.7, FLAT, {"l_max": 1e9, "l_min": 0.0, "r_rec": 0.0})
    assert np.allclose(h.gamma, 10.0) and np.allclose(h.core, 2.0)


def test_removal_and_ground():
    kw = {"l_max": 1e9, "l_min": 0.0, "r_rec": 0.0}
    # вертикальное кольцо наполовину и глубже под землёй -> удалено
    deep = ring(10.0, 5.0, 1.0, 40, center=(0, 0, -3.0), normal=(1, 0, 0))
    g = step(deep, ZERO, 0.0, FLAT, kw)
    assert len(g.seg) == 0 and g.stats["removed"] == 1
    # меньше половины под землёй -> подняты на ground + core/2
    sh = ring(10.0, 5.0, 1.0, 40, center=(0, 0, 8.0), normal=(1, 0, 0))
    below = int((sh.x[:, 2] < 0).sum())
    g = step(sh, ZERO, 0.0, FLAT, kw)
    assert 0 < below < 20 and len(g.seg) == 40 and g.stats["lifted"] == below
    assert (g.x[:, 2] >= 0.5 - 1e-12).sum() >= below and (g.x[:, 2] >= 0).all()
    assert imbalance(g) <= 1e-12
    # слабая нить
    g = step(ring(10.0, 0.01, 1.0, 40, center=(0, 0, 20.0)), ZERO, 0.0, FLAT, dict(kw, gamma_min=0.1))
    assert len(g.seg) == 0
    # за bounds
    far = ring(5.0, 5.0, 1.0, 40, center=(500, 0, 20.0))
    g = step(far, ZERO, 0.0, FLAT, dict(kw, bounds=(-100, 100, -100, 100, 300)))
    assert len(g.seg) == 0
    g = step(far, ZERO, 0.0, FLAT, dict(kw, bounds=(0, 1000, -100, 100, 300)))
    assert len(g.seg) == 40
    # пустой набор
    e = step(Filaments(), ZERO, 1.0, FLAT, None)
    assert len(e.seg) == 0 and imbalance(e) == 0
    assert all(np.isfinite(g.x).all() for g in (e,))


def test_shed_on_ground_variable_us_survives():
    M = 21
    P = np.stack([np.zeros(M), np.linspace(0, 100, M), np.zeros(M)], 1)
    N = np.tile([0, 0, 1.0], (M, 1))
    wind = lambda x, y, z: (np.full_like(x, 5.0), np.zeros_like(x), np.zeros_like(x))
    for z0 in (0.0, 0.5):
        U = np.tile([8.0, 0, 0], (M, 1)) * np.linspace(1, 1.5, M)[:, None]
        f = shed(None, P + [0, 0, z0], U, 0.5, 1.0, N)
        assert f.anchored.sum() > 2
        for _ in range(50):
            f = step(f, wind, 0.5, FLAT, None)
            assert imbalance(f) <= 1e-12 and np.isfinite(f.x).all()
        assert len(f.seg) > 0 and f.anchored.any()


def test_anchored_projection_and_no_nan():
    hill = lambda x, y: 2.0 * np.exp(-(np.asarray(x) ** 2 + np.asarray(y) ** 2) / 400.0)
    P = np.stack([np.linspace(-20, 20, 21), np.zeros(21), 10.0 * np.ones(21)], 1)
    f = line(P, 5.0, 1.5)
    f.x[[0, -1], 2] = hill(f.x[[0, -1], 0], f.x[[0, -1], 1])
    wind = lambda x, y, z: (np.full_like(x, 3.0), np.zeros_like(x), np.zeros_like(x))
    for _ in range(10):
        f = step(f, wind, 0.5, hill, None)
    a = f.anchored
    assert np.allclose(f.x[a, 2], hill(f.x[a, 0], f.x[a, 1]))
    assert np.isfinite(f.x).all() and imbalance(f) <= 1e-12


@pytest.mark.skipif(not _gpu_available(), reason="нет GPU")
def test_gpu_equals_numpy():
    f = ring(30.0, 5.0, 1.0, 400)
    x = np.random.default_rng(1).uniform(-40, 40, (3, 3000))
    a = induced(f, *x, backend="numpy")
    b = induced(f, *x, backend="cupy")
    for p, q in zip(a, b):
        assert np.allclose(p, q, rtol=1e-9, atol=1e-12)


# ---------- SWD3 v4: t_birth, огрубление по возрасту, потолок узлов ----------
def _shed_model(params, steps, n_pts=110, dx=25.0, U=10.0, dt=3.0, x_cut=6000.0):
    """Модельный сход: линия n_pts точек (шаг dx) на каждом шаге, снос со скоростью U, удаление за x > x_cut;
    скорость слоя вдоль линии меняется (рождаются ножки). → число узлов по шагам, Filaments."""
    y = (np.arange(n_pts) - n_pts / 2) * dx
    pts = np.stack([np.zeros(n_pts), y, np.zeros(n_pts)], 1)
    us = np.stack([U * (1 + 0.3 * np.sin(y / 400.0)), np.zeros(n_pts), np.zeros(n_pts)], 1)
    nrm = np.tile([0.0, 0.0, 1.0], (n_pts, 1))
    f, n = Filaments(), []
    for i in range(steps):
        t = (i + 1) * dt
        f = shed(f, pts, us, dt, 5.0, nrm, t=t)
        f.x[:, 0] += U * dt
        keep = (f.x[f.seg[:, 0], 0] < x_cut) | (f.x[f.seg[:, 1], 0] < x_cut)
        f.seg, f.gamma, f.core, f.fid, f.t_birth = f.seg[keep], f.gamma[keep], f.core[keep], f.fid[keep], f.t_birth[keep]
        f = relabel(f)
        f = coarsen(f, t, params)
        n.append(len(f.x))
    return n, f


def test_t_birth_inherited():
    f = shed(None, [[0, 0, 0], [20, 0, 0], [40, 0, 0]], [[1, 0, 0]] * 3, 1.0, 1.0, [[0, 0, 1]] * 3, t=7.0)
    assert np.all(f.t_birth == 7.0) and len(f.t_birth) == len(f.seg)
    f = step(f, ZERO, 1.0, FLAT, dict(l_max=5.0))                      # дробление наследует t_birth
    assert f.stats["split"] > 0 and np.all(f.t_birth == 7.0) and len(f.t_birth) == len(f.seg)
    assert Filaments().t_birth.shape == (0,) and relabel(f).t_birth.shape == f.t_birth.shape


def test_coarsen_age_ring_invariants():
    f = ring(100.0, 50.0, 1.0, 400)                                    # отрезок 1,6 м
    f.t_birth[:] = 0.0
    g = coarsen(f, 1000.0, dict(l_age=0.01))                           # ½·0,01·1000 = 5 м
    assert len(g.seg) < 0.5 * len(f.seg) and g.stats["coarsen_collapse"] > 0
    assert imbalance(g) <= 1e-12
    assert np.allclose(impulse(g), impulse(f), rtol=0.02)
    P = np.array([[0.0, 0.0, 30.0], [0.0, 0.0, 120.0], [300.0, 0.0, 10.0]])
    a, b = induced(f, *P.T), induced(g, *P.T)
    for p, q in zip(a, b):
        assert np.allclose(p, q, rtol=0.05, atol=1e-3 * np.abs(a[2]).max())
    # молодые нити не трогаются
    h = coarsen(f, 1000.0, dict(l_age=1e-6))
    assert len(h.seg) == len(f.seg)


def test_coarsen_off_by_default_and_pure():
    f = ring(50.0, 5.0, 1.0, 100)
    g = coarsen(f, 100.0, None)
    assert len(g.seg) == len(f.seg) and g is not f and len(f.seg) == 100


def test_coarsen_n_max_ceiling():
    f = line(np.stack([np.linspace(0, 3000, 600), np.zeros(600), np.zeros(600)], 1), 3.0, 2.0)
    f.t_birth = np.linspace(0, 500, len(f.seg))
    g = coarsen(f, 600.0, dict(l_age=0.001, n_max=150))
    assert len(g.x) <= 150 and g.stats["coarsen_rounds"] > 0 and g.stats["coarsen_nmax_unmet"] == 0
    assert imbalance(g) <= 1e-12
    # нельзя сжать дальше (≤ 4 отрезков на нить) — счётчик, не зависание
    h = coarsen(f, 600.0, dict(l_age=0.001, n_max=2))
    assert h.stats["coarsen_nmax_unmet"] == 1 and len(h.x) >= 5


def test_shed_model_bounded():
    prm = dict(l_age=0.2, n_max=20000)
    n, f = _shed_model(prm, 500)
    assert max(n) <= 3e4 and n[-1] < 1.1 * n[-101]
    assert imbalance(f) <= 1e-12
    n0, _ = _shed_model(None, 150)                                      # без ограничителя — рост линейный
    assert n[149] < 0.8 * n0[-1]


def test_step_split_follows_l_age():
    f = line(np.stack([np.linspace(0, 100, 6), np.zeros(6), np.zeros(6)], 1), 1.0, 1.0)
    f.t_birth[:] = 0.0
    a = step(f, ZERO, 1.0, FLAT, dict(l_max=5.0))
    b = step(f, ZERO, 1.0, FLAT, dict(l_max=5.0, l_age=0.5, t=100.0))   # lim = 50 м → дробится меньше
    assert len(b.seg) < len(a.seg)


def test_not_implemented_optional_parts():
    f = ring(10.0, 1.0, 0.5, 20)
    with pytest.raises(NotImplementedError):
        coarsen(f, 1.0, dict(r_amal=1.0))
    with pytest.raises(NotImplementedError):
        induced(f, [0.0], [0.0], [0.0], method="tree")


@pytest.mark.skip(reason="SWD3 v4: слияние отрезков (б) не реализовано (необязательно)")
def test_amalgamation_kirchhoff():
    pass


@pytest.mark.skip(reason="SWD3 v4: дерево Барнса — Хата не реализовано (необязательно)")
def test_tree_vs_direct():
    pass
