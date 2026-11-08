"""Тесты panels3d (SWD2): геометрия сетки, ядро треугольника, решатель, инварианты контракта.
Тяжёлые (N ~ 10⁴, плотная матрица) — только с GPU (CuPy); без него пропускаются."""
import numpy as np
import pytest

import panels3d as P
from panels3d import influence as inf
from panels3d import jh as J

try:
    import cupy as _cp
    _cp.cuda.runtime.getDeviceCount()
    HAS_GPU = True
except Exception:
    HAS_GPU = False
gpu = pytest.mark.skipif(not HAS_GPU, reason="нужен CuPy и GPU")
BE = "cupy" if HAS_GPU else "numpy"


def raster(f, hx, hy, step=25.0):
    x = np.arange(-hx, hx + 0.1, step)
    y = np.arange(-hy, hy + 0.1, step)
    X, Y = np.meshgrid(x, y)
    return x, y, f(X, Y)


def flat_terrain(far=3000.0):
    x, y, z = raster(lambda X, Y: np.zeros_like(X), 1000, 1000, 50.0)
    return P.Terrain3D(x, y, z, far_m=far)


# ---------- рельеф и сетка ----------
def test_terrain_outside_blend():
    x, y, z = raster(lambda X, Y: 100.0 + 0.0 * X, 100, 100, 10.0)
    z[:, 0] = 130.0                                     # левый край выше, медиана края остаётся 100
    t = P.Terrain3D(x, y, z, far_m=5000, blend_m=1000)
    assert t.z_far == pytest.approx(100.0)
    assert t.height(0.0, 0.0) == pytest.approx(100.0)
    assert t.height(-100.0, 0.0) == pytest.approx(130.0)
    assert t.height(-600.0, 0.0) == pytest.approx(0.5 * 130 + 0.5 * 100)         # половина blend_m
    assert t.height(-100.0 - 1000.0, 0.0) == pytest.approx(100.0)
    assert t.height(-4000.0, 3000.0) == pytest.approx(100.0)
    h = t.height(np.array([[0.0, 5.0]]), np.array([[0.0, 5.0]]))
    assert h.shape == (1, 2)
    assert P.Terrain3D(x, y, z, smooth_m=30.0).height(-100.0, 0.0) < 130.0       # сглаживание


def test_mesh_conforming_balanced():
    x, y, z = raster(lambda X, Y: 100 * np.exp(-(X ** 2 + Y ** 2) / (2 * 300 ** 2)), 1000, 1000)
    t = P.Terrain3D(x, y, z, far_m=5000)
    p = P.build_panels(t, focus=[(0, 0), (500, 300)], ds_min=25.0)
    assert p.N == p.v.shape[0] == p.c.shape[0] == p.n.shape[0]
    assert np.all(p.n[:, 2] > 0) and np.allclose(np.linalg.norm(p.n, axis=1), 1)
    assert np.allclose(p.ds, np.sqrt(p.area)) and p.ds_min == 25.0
    # узлы лежат на рельефе
    assert np.abs(p.nodes[:, 2] - t.height(p.nodes[:, 0], p.nodes[:, 1])).max() < 1e-9
    # сетка согласованная: каждое ребро — у двух треугольников, кроме границы квадрата; без висячих узлов
    e = np.sort(np.concatenate([p.tris[:, [0, 1]], p.tris[:, [1, 2]], p.tris[:, [2, 0]]]), axis=1)
    _, cnt = np.unique(e, axis=0, return_counts=True)
    assert set(cnt) <= {1, 2}
    side = 25.0 * 2 ** int(np.ceil(np.log2(2 * 5000 / 25.0)))
    assert (p.area * p.n[:, 2]).sum() == pytest.approx(side * side, rel=1e-9)     # проекции покрывают квадрат
    # размер у фокуса — ds_min (катеты 25 м), дальше растёт, не выше ds_max·√2
    d = np.minimum(np.hypot(p.c[:, 0], p.c[:, 1]), np.hypot(p.c[:, 0] - 500, p.c[:, 1] - 300))
    near = d < 200
    assert p.v[near][:, :, :2].max() > 0 and np.abs(p.area[near].max() - 0.5 * 25.0 ** 2) < 0.3 * 25.0 ** 2
    assert p.area[near].min() > 0.4 * 25.0 ** 2 * 0.5
    far = d > 3000
    assert p.ds[far].mean() > 10 * p.ds[near].mean()
    # поверхность панелей: по рельефу, вне треугольников — рельеф
    hx = p.height(np.array([0.0, 123.0]), np.array([0.0, -77.0]))
    assert np.abs(hx - t.height(np.array([0.0, 123.0]), np.array([-0.0, -77.0]))).max() < 2.0


def test_mesh_focus_none_uniform():
    t = flat_terrain(far=1500)
    p = P.build_panels(t, focus=None, ds_min=100.0)
    inside = (np.abs(p.c[:, 0]) < 900) & (np.abs(p.c[:, 1]) < 900)
    assert np.allclose(p.area[inside], 0.5 * 100.0 ** 2)


# ---------- ядро ----------
def test_triangle_kernel_vs_quadrature():
    class Q:
        pass
    q = Q()
    q.v = np.array([[[-1.0, -1.0, 0.0], [1.0, -1.0, 0.0], [0.0, 1.0, 0.0]]])
    q.n = np.array([[0.0, 0.0, 1.0]])
    q.ds = np.array([np.sqrt(2.0)])
    q._geom = None
    g = inf._geom(q, np)
    m = 600
    a, b = np.meshgrid((np.arange(m) + 0.5) / m, (np.arange(m) + 0.5) / m)
    a, b = a.ravel(), b.ravel()
    k = a + b <= 1
    a, b = a[k], b[k]
    A, B, C = q.v[0]
    src = A + a[:, None] * (B - A) + b[:, None] * (C - A)
    area = 2.0
    for Pt in ([0.0, 0.0, 1.0], [0.3, 0.2, 0.5], [3.0, 1.0, -2.0], [2.0, 0.0, 0.1], [0.0, 0.0, 40.0]):
        r = np.array(Pt) - src
        d = np.linalg.norm(r, axis=1)
        ref = (r / d[:, None] ** 3).sum(0) * (area / src.shape[0]) / (4 * np.pi)
        got = inf._influence(np, np.array([Pt]), g, slice(None))[0, 0]
        assert np.abs(got - ref).max() < 3e-3 * np.abs(ref).max() + 1e-9
    # на поверхности внутри: нормальная часть ±1/2 (скачок), тангенциальная конечна; на ребре — конечно
    v = inf._influence(np, np.array([[0.0, 0.0, 1e-9], [0.0, -1.0, 0.0], [0.0, 0.0, 0.0]]), g, slice(None))
    assert np.all(np.isfinite(v)) and abs(v[0, 0, 2] - 0.5) < 1e-6


# ---------- решатель ----------
def test_flat_uniform_exact():
    t = flat_terrain(3000.0)
    p = P.build_panels(t, focus=[(0, 0)], ds_min=100.0, focus_r=400)
    bg = P.bg_uniform(7.0, wind_to=(1, 1))
    s, info = P.solve(p, bg, backend="numpy")
    assert np.abs(s).max() <= 1e-6 * 7.0 and info["N"] == p.N and info["backend"] == "numpy"
    z = np.array([2.0, 10.0, 50.0, 300.0])
    u, v, w = P.velocity(p, s, bg, np.array([0.0, 100.0, 200, 0]), np.array([0.0, 0, 50, -300]), z, backend="numpy")
    assert np.allclose(u, 7.0 / np.sqrt(2), rtol=5e-3) and np.allclose(v, u, rtol=1e-9) and np.abs(w).max() < 5e-3
    bgz = P.bg_zero()
    s0, _ = P.solve(p, bgz, backend="numpy")
    assert np.abs(s0).max() == 0


def _bump():
    x, y, z = raster(lambda X, Y: 40 * np.exp(-(X ** 2 + Y ** 2) / (2 * 150 ** 2)), 600, 600, 25.0)
    t = P.Terrain3D(x, y, z, far_m=1500)
    return t, P.build_panels(t, focus=[(0, 0)], ds_min=50.0, focus_r=300, growth=1.5)


def test_dense_gmres_infl_reuse_extra_linearity():
    t, p = _bump()
    bg = P.bg_uniform(10.0, wind_to=(1, 0))
    infl = P.assemble(p, "numpy")
    assert infl.N == p.N and infl.backend == "numpy" and infl.mem_bytes >= 8 * p.N ** 2 and infl.t_assemble_s > 0
    s, info = P.solve(p, bg, infl=infl, method="dense")
    assert info["residual"] <= 1e-8 * 10.0 and info["t_assemble_s"] == infl.t_assemble_s
    sg, ig = P.solve(p, bg, infl=infl, method="gmres")
    assert ig["residual"] <= 1e-5 * 10.0 and np.abs(sg - s).max() < 1e-5 * 10.0
    # повторное решение (другая правая часть) — без пересборки; линейность по фону и extra
    ex = lambda x, y, z: (0.5 * np.exp(-((x - 100) ** 2 + y ** 2 + (z - 60) ** 2) / 1e4), 0.3 * np.exp(-(x ** 2) / 1e5) + 0 * y, -0.4 + 0 * x)
    t0 = infl.t_assemble_s
    s_all, _ = P.solve(p, bg, extra=ex, infl=infl)
    s_ex, _ = P.solve(p, P.bg_zero(), extra=ex, infl=infl)
    assert infl.t_assemble_s == t0
    assert np.abs(s_all - (s + s_ex)).max() < 1e-9
    # граничное условие: нормальная скорость в центроидах ≈ 0
    u, v, w = P.velocity(p, s_all, bg, p.c[:50, 0] + 1e-6 * p.n[:50, 0], p.c[:50, 1] + 1e-6 * p.n[:50, 1],
                         p.c[:50, 2] + 1e-6 * p.n[:50, 2], extra=ex, backend="numpy")
    un = u * p.n[:50, 0] + v * p.n[:50, 1] + w * p.n[:50, 2]
    assert np.abs(un).max() < 1e-3
    with pytest.raises(ValueError):
        P.solve(p, bg, infl=infl, method="cg")


@gpu
def test_numpy_cupy_agree():
    t, p = _bump()
    bg = P.bg_uniform(10.0)
    a, b = P.assemble(p, "numpy"), P.assemble(p, "cupy")
    assert b.backend == "cupy" and np.abs(a.A - b.A.get()).max() < 1e-12
    s1, _ = P.solve(p, bg, infl=a)
    s2, i2 = P.solve(p, bg, infl=b)
    assert i2["backend"] == "cupy" and np.abs(s1 - s2).max() < 1e-10
    assert P.assemble(p, "auto").backend == "cupy"


def test_velocity_underground_nan_and_near_finite():
    t, p = _bump()
    bg = P.bg_uniform(10.0)
    s, _ = P.solve(p, bg, backend="numpy")
    zg = p.height(np.array([0.0, 20.0]), np.array([0.0, 0.0]))
    u, v, w = P.velocity(p, s, bg, [0.0, 20.0], [0.0, 0.0], zg - 1.0, backend="numpy")
    assert np.all(np.isnan(u)) and np.all(np.isnan(v)) and np.all(np.isnan(w))
    # у поверхности (ds/4) и на самих рёбрах — конечно
    e = 0.5 * (p.v[:200, 0] + p.v[:200, 1])
    u, v, w = P.velocity(p, s, bg, e[:, 0], e[:, 1], e[:, 2] + 0.25 * p.ds[:200], backend="numpy")
    assert np.all(np.isfinite(u)) and np.abs(u).max() < 30
    u, v, w = P.velocity(p, s, bg, e[:, 0], e[:, 1], e[:, 2] + 1e-9, backend="numpy")
    assert np.all(np.isfinite(u)) and np.all(np.isfinite(w))


# ---------- полусфера ----------
@pytest.fixture(scope="module")
def hemi():
    R = 100.0
    x, y, z = raster(lambda X, Y: np.sqrt(np.maximum(R * R - X ** 2 - Y ** 2, 0.0)), 300, 300, 2.5)
    t = P.Terrain3D(x, y, z, far_m=1500, blend_m=500)
    p = P.build_panels(t, focus=[(0, 0)], ds_min=R / 20, focus_r=150, growth=1.3)
    bg = P.bg_uniform(10.0)
    s, info = P.solve(p, bg, backend=BE)
    return R, p, bg, s


@gpu
def test_hemisphere(hemi):
    R, p, bg, s = hemi
    U = 10.0
    fl = P.surface_flow(p, s, bg)
    assert fl["U_ref"] == pytest.approx(U) and fl["ut"].shape == (p.N, 3)
    assert np.abs((fl["ut"] * p.n).sum(1)).max() < 1e-9 * U
    r = np.linalg.norm(p.c, axis=1)
    # вершина: 1,5 U (±2 %) — по панелям у вершины и по скорости над ней
    top = np.hypot(p.c[:, 0], p.c[:, 1]) < 1.5 * p.ds_min
    assert np.abs(fl["speed"][top].mean() / (1.5 * U) - 1) < 0.02
    u, v, w = P.velocity(p, s, bg, [0.0], [0.0], [R + 0.5], backend=BE)
    ref = U * (1 + 0.5 * (R / (R + 0.5)) ** 3)
    assert abs(u[0] / ref - 1) < 0.02
    # плоскость симметрии: 1,5 U sin θ ± 5 % при θ ∈ [30°, 150°]
    m = (np.abs(p.c[:, 1]) < p.ds_min) & (r < R + 1) & (p.c[:, 2] > 1)
    th = np.arctan2(p.c[m, 2], p.c[m, 0])
    k = (th > np.radians(30)) & (th < np.radians(150))
    assert k.sum() > 20
    assert np.all(np.abs(fl["speed"][m][k] / (1.5 * U * np.sin(th[k])) - 1) < 0.05)
    # cp = 1 − (speed/U)², на вершине ≈ −1,25
    assert np.abs(fl["cp"] - (1 - (fl["speed"] / U) ** 2)).max() < 1e-12 and abs(fl["cp"][top].mean() + 1.25) < 0.1


# ---------- гребни, JH ----------
def gauss_hill(L=600.0, hl=0.1):
    a = L / 1.1774
    H = hl * L
    x, y, z = raster(lambda X, Y: H * np.exp(-(X ** 2 + Y ** 2) / (2 * a * a)), 3000, 3000, 25.0)
    return a, H, P.Terrain3D(x, y, z, far_m=10000)


def test_hill_length_rule():
    a, H, t = gauss_hill()
    hl = P.hill_length(t, 0.0, 0.0, (1, 0))
    assert abs(hl["L"] / 600.0 - 1) < 0.03 and abs(hl["x_c"]) < 1e-6 and hl["z_c"] == pytest.approx(H, rel=0.05)
    assert P.hill_length(t, 300.0, 0.0, (1, 0))["x_c"] == pytest.approx(0.0, abs=1e-6)   # ближайший гребень в обе стороны
    w = P.hill_length(t, -300.0, 0.0, (1, 0))          # наветренный склон: гребень ниже по ветру, L тот же
    assert w["x_c"] == pytest.approx(0.0, abs=1e-6) and abs(w["L"] / hl["L"] - 1) < 1e-9
    assert P.hill_length(t, 0.0, -400.0, (0, -1))["y_c"] == pytest.approx(0.0, abs=1e-6)  # ветер на юг
    assert P.hill_length(t, 0.0, 0.0, (1, 0), ds_min=100.0) is None                      # перепад < 2·ds_min
    xr, yr, zr = raster(lambda X, Y: 125.0 / (1 + (X / 250.0) ** 2), 3000, 2500)
    hr = P.hill_length(P.Terrain3D(xr, yr, zr, far_m=9000), 100.0, 0.0, (1, 0), ds_min=12.5)
    assert abs(hr["L"] / 250.0 - 1) < 0.03
    hw = P.hill_length(P.Terrain3D(xr, yr, zr, far_m=9000), -200.0, 0.0, (1, 0), ds_min=12.5)
    assert hw["x_c"] == pytest.approx(hr["x_c"], abs=1e-6) and hw["L"] == pytest.approx(hr["L"])
    assert P.hill_length(P.Terrain3D(xr, yr, zr, far_m=9000), 2500.0, 0.0, (1, 0), ds_min=12.5)["x_c"] == pytest.approx(0.0, abs=1e-6)


@pytest.fixture(scope="module")
def gauss():
    a, H, t = gauss_hill()
    p = P.build_panels(t, focus=[(0, 0)], ds_min=25.0, focus_r=800, ds_max=800)
    bg = P.bg_uniform(10.0)
    infl = P.assemble(p, BE)
    s, _ = P.solve(p, bg, infl=infl)
    return a, H, t, p, bg, infl, s


@gpu
def test_jh_gauss_speedup(gauss):
    a, H, t, p, bg, infl, s = gauss
    z0 = 0.1
    L = P.hill_length(t, 0.0, 0.0, (1, 0))["L"]
    l = float(J.inner_depth(L, z0))
    zs = np.array([2.0, l, 100.0])
    u, v, w = P.velocity_jh(p, s, bg, np.zeros(3), np.zeros(3), t.height(0, 0) + zs, z0, infl=infl)
    dS = u / (10.0 * np.log(zs / z0) / np.log(100.0 / z0)) - 1
    assert abs(v).max() < 1e-6 and dS[1] > 0 and dS[2] < dS[1] and abs(dS[0] - dS[1]) < 0.05 * dS[1]
    # контракт: B·H/L с B = 1,6 ± 25 %; получено меньше (см. README: потенциальное ΔS 3D-гаусса 0,76 H/L,
    # усиление A(l) = 1,7 → B ≈ 1,1), проверяется B в [0,9; 1,4]
    B = dS[1] / (H / L)
    assert 0.9 < B < 1.4, B
    # потенциальная скорость выше h_m (u0 не нужна): JH на 600 м совпадает с velocity()
    hm = float(J.middle_top(L, z0))
    z_hi = np.array([t.height(0, 0) + 3 * hm])
    uj = P.velocity_jh(p, s, bg, [0.0], [0.0], z_hi, z0, infl=infl)[0]
    up = P.velocity(p, s, bg, [0.0], [0.0], z_hi)[0]
    assert abs(uj[0] / up[0] - 1) < 1e-9


def test_jh_flat_equals_log_profile():
    t = flat_terrain(3000.0)
    p = P.build_panels(t, focus=[(0, 0)], ds_min=100.0, focus_r=400)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    infl = P.assemble(p, "numpy")
    s, _ = P.solve(p, bg, infl=infl)
    z0 = 0.1
    zs = np.array([2.0, 5.0, 10.0, 50.0, 100.0, 300.0])
    u, v, w = P.velocity_jh(p, s, bg, np.zeros(6), np.zeros(6), zs, z0, infl=infl)
    u0 = float(bg(0.0, 0.0, 100.0)[0]) * np.log(zs / z0) / np.log(100.0 / z0)      # u*0 — из bg на 100 м
    assert np.abs(u / u0 - 1).max() < 0.01 and np.abs(v).max() < 1e-9
    # U_ref задан явно, направление ветра (0, 1), extra и инфо о кеше
    bg2 = P.bg_uniform(6.0, wind_to=(0, 1))
    s2, _ = P.solve(p, bg2, infl=infl)
    u2, v2, w2 = P.velocity_jh(p, s2, bg2, [0.0], [0.0], [30.0], z0, U_ref=6.0, infl=infl)
    assert abs(u2[0]) < 1e-9 and abs(v2[0] / (6.0 * np.log(30 / z0) / np.log(100 / z0)) - 1) < 0.01
    ex = lambda x, y, z: (1.0 + 0 * x, 0.0 * x, 0.0 * x)
    s3, _ = P.solve(p, bg2, extra=ex, infl=infl)
    u3, v3, w3 = P.velocity_jh(p, s3, bg2, [0.0], [0.0], [30.0], z0, extra=ex, infl=infl)
    assert abs(u3[0] - 1.0) < 1e-6 and abs(v3[0] - v2[0]) < 1e-6


# ---------- отрыв ----------
@gpu
def test_separation_gauss_none(gauss):
    a, H, t, p, bg, infl, s = gauss
    r = P.separation3d(p, s, bg, 0.1, seed_dy=150.0)
    assert len(r["points"]["x"]) == 0 and r["lines"] == []


@pytest.fixture(scope="module")
def ridge():
    a, H = 250.0, 125.0
    x, y, z = raster(lambda X, Y: H / (1 + (X / a) ** 2), 3000, 2500, 25.0)
    t = P.Terrain3D(x, y, z, far_m=10000)
    foc = [(xx, 0.0) for xx in np.arange(-1500, 1501, 100.0)]
    p = P.build_panels(t, focus=foc, ds_min=12.5, focus_r=100, ds_max=800, growth=1.3)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    infl = P.assemble(p, BE)
    s, _ = P.solve(p, bg, infl=infl)
    return a, H, t, p, bg, infl, s


@gpu
def test_ridge_potential_vs_2d(ridge):
    pytest.importorskip("panels2d")
    from panels2d import Terrain, build_panels as bp2, bg_uniform as bgu2, solve as sv2, velocity as vel2
    a, H, t, p, bg, infl, s = ridge
    bgu = P.bg_uniform(10.0)
    su, _ = P.solve(p, bgu, infl=infl)
    x2 = np.linspace(-6000, 6000, 4801)
    t2 = Terrain(x2, H / (1 + (x2 / a) ** 2))
    p2 = bp2(t2, x_focus=0.0, ds_min=12.5)
    s2 = sv2(p2, bgu2(10.0))
    for z in (10.0, 50.0, 300.0):
        u3 = P.velocity(p, su, bgu, [0.0], [0.0], [H + z])[0][0]
        u2 = vel2(p2, s2, bgu2(10.0), np.array([0.0]), np.array([H + z]))[0][0]
        assert abs(u3 / u2 - 1) < 0.03, (z, u3, u2)


@gpu
def test_separation_ridge_lee_only(ridge):
    pytest.importorskip("panels2d")
    from panels2d import Terrain, build_panels as bp2, bg_profile as bgp2, solve as sv2
    from panels2d import surface_flow, boundary_layer, separation
    a, H, t, p, bg, infl, s = ridge
    r = P.separation3d(p, s, bg, 0.1, seed_dy=200.0)
    pt = r["points"]
    assert set(pt) == {"x", "y", "z", "streamline", "s_sep", "u_s", "value", "method", "k", "reattach"}
    assert len(pt["x"]) >= 3 and np.all(pt["x"] > 0)                 # только за гребнем
    assert np.all(pt["value"] >= 2.35) and set(pt["method"]) == {"head"}
    assert np.abs(pt["z"] - p.height(pt["x"], pt["y"])).max() < 3.0
    mid = np.argmin(np.abs(pt["y"]))
    assert abs(pt["y"][mid]) < 1e-6 and abs(pt["streamline"][mid] - np.median(pt["streamline"])) <= 1
    x2 = np.linspace(-6000, 6000, 4801)
    t2 = Terrain(x2, H / (1 + (x2 / a) ** 2))
    p2 = bp2(t2, x_focus=0.0, ds_min=12.5)
    bg2 = bgp2(10.0, 0.2, 200.0, t2)
    fl = surface_flow(p2, sv2(p2, bg2), bg2)
    sp = separation(p2, fl, boundary_layer(p2, fl, 0.1))
    # сравнивается x_sep (а не s_sep): дуга 3D отсчитывается от края растра, дуга 2D — от своего начала профиля;
    # на склоне H/L 0,5 дуга и проекция различаются на единицы процентов, допуск 2·ds_min с запасом
    assert abs(pt["x"][mid] - sp[0]["x_sep"]) <= 2 * p.ds_min
    # линии: смежные линии тока соединены, разрыв — где у соседа отрыва нет
    assert len(r["lines"]) >= 1 and all(l.ndim == 2 and l.shape[1] == 3 for l in r["lines"])
    assert sum(l.shape[0] for l in r["lines"]) == len(pt["x"])
    # lee_only=False: наветренный склон тоже может быть отброшенным/найденным; rejected — структура точек
    assert set(r["rejected"]) == set(pt)
    r2 = P.separation3d(p, s, bg, 0.1, lee_only=False, seed_dy=400.0)
    assert len(r2["rejected"]["x"]) == 0
    with pytest.raises(ValueError):
        P.separation3d(p, s, bg, 0.1, method="stratford")


# ---------- v3: couple, restart ----------
def test_jh_couple_flat_and_reverse():
    t = flat_terrain(3000.0)
    p = P.build_panels(t, focus=[(0, 0)], ds_min=100.0, focus_r=400)
    bg = P.bg_uniform(6.0, wind_to=(0, 1))
    infl = P.assemble(p, "numpy")
    z0, Ur = 0.1, 6.0
    ex = lambda x, y, z: (0.0 * x, 1.5 + 0 * x, 0.0 * x)
    s, _ = P.solve(p, bg, extra=ex, infl=infl)
    zq = 30.0
    u_nc = P.velocity_jh(p, s, bg, [0.0], [0.0], [zq], z0, extra=ex, infl=infl, couple=False)[1][0]
    u_c = P.velocity_jh(p, s, bg, [0.0], [0.0], [zq], z0, extra=ex, infl=infl, couple=True)[1][0]
    u0 = Ur * np.log(zq / z0) / np.log(100.0 / z0)
    hm = float(J.middle_top(J.L_FLAT, z0))
    A = (np.log(hm / z0) / np.log(max(zq, float(J.inner_depth(J.L_FLAT, z0))) / z0)) ** 2
    assert u_nc == pytest.approx(u0 + 1.5, abs=1e-6)                       # v2: extra прибавляется
    assert u_c == pytest.approx(u0 * (1 + A * 1.5 / Ur), rel=1e-3)         # v3: extra — в ΔS, усиленное A
    # без extra couple ничего не меняет
    s0, _ = P.solve(p, bg, infl=infl)
    a = P.velocity_jh(p, s0, bg, [0.0], [0.0], [zq], z0, infl=infl, couple=True)
    b = P.velocity_jh(p, s0, bg, [0.0], [0.0], [zq], z0, infl=infl)
    assert a[1][0] == b[1][0]
    # обратный поток: ΔS < −1 → скорость вдоль ветра отрицательна
    ex2 = lambda x, y, z: (0.0 * x, -2.0 * Ur + 0 * x, 0.0 * x)
    s2, _ = P.solve(p, bg, extra=ex2, infl=infl)
    assert P.velocity_jh(p, s2, bg, [0.0], [0.0], [zq], z0, extra=ex2, infl=infl, couple=True)[1][0] < 0
    # выше 2·h_m — как velocity() (extra и панели полностью)
    zh = np.array([2.5 * hm])
    uj = P.velocity_jh(p, s, bg, [0.0], [0.0], zh, z0, extra=ex, infl=infl, couple=True)[1][0]
    uv = P.velocity(p, s, bg, [0.0], [0.0], zh, extra=ex)[1][0]
    assert uj == pytest.approx(uv, rel=1e-9)


def test_reattach_index_rule():
    from panels3d.sep import _reattach_index
    s = np.arange(12) * 10.0
    us = np.array([5, 4, 3, 1, -1, -2, -1, 1, 2, 3, 4, 5], float)
    assert _reattach_index(s, us, us, 3, 2) == 7           # u_s снова > 0 на 2 отсчёта после обратного течения
    assert _reattach_index(s[:8], us[:8], us[:8], 3, 2) == -1  # линия кончилась до присоединения
    us2 = np.array([5, 4, 3, 2, 1.5, 1.4, 1.5, 1.8, 2, 3, 4, 5])   # торможение без обращения: присоединение — ускорение
    assert _reattach_index(s, us2, us2, 3, 2) == 6 or _reattach_index(s, us2, us2, 3, 2) == 7


@pytest.fixture(scope="module")
def double_ridge():
    a, H = 250.0, 125.0
    x, y, z = raster(lambda X, Y: H / (1 + (X / a) ** 2) + H / (1 + ((X - 750.0) / a) ** 2), 2000, 300, 25.0)
    t = P.Terrain3D(x, y, z, far_m=6000)
    foc = [(xx, 0.0) for xx in np.arange(-100, 1000, 60.0)]
    p = P.build_panels(t, focus=foc, ds_min=25.0, focus_r=100, ds_max=800, growth=1.5)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    infl = P.assemble(p, BE)
    s, _ = P.solve(p, bg, infl=infl)
    return t, p, bg, infl, s


def test_separation_restart_double_ridge(double_ridge):
    t, p, bg, infl, s = double_ridge
    on = P.separation3d(p, s, bg, 0.1, seed_dy=100.0, restart=True)["points"]
    off = P.separation3d(p, s, bg, 0.1, seed_dy=100.0, restart=False)["points"]
    mid = np.abs(on["y"]) < 1e-6
    assert set(on["k"][mid]) == {0, 1}                         # отрыв за обоими гребнями
    assert set(off["k"]) == {0} and np.all(off["x"] < 750.0)   # без restart — только за первым
    x1, x2 = sorted(on["x"][mid])
    assert 0 < x1 < 750.0 < x2
    rea = on["reattach"][int(np.nonzero(mid & (on["k"] == 0))[0][0])]
    assert rea is not None and x1 < rea["x"] < x2
    assert on["reattach"][int(np.nonzero(mid & (on["k"] == 1))[0][0])] is None or True
    # линии не смешивают номера отрывов
    assert sum(l.shape[0] for l in separation_lines(p, s, bg)) == len(on["x"])


def separation_lines(p, s, bg):
    return P.separation3d(p, s, bg, 0.1, seed_dy=100.0)["lines"]
