"""Тесты SWG-6: слитое ядро (fp64/fp32) против `influence.panel_velocity`; far_cluster при θ → 0 = прямой счёт."""
import numpy as np
import pytest

import panels3d as P
from panels3d import influence as inf
import fastq

try:
    import cupy as _cp
    _cp.cuda.runtime.getDeviceCount()
    HAS_GPU = True
except Exception:
    HAS_GPU = False
pytestmark = pytest.mark.skipif(not HAS_GPU, reason="нужен CuPy и GPU")


@pytest.fixture(scope="module")
def case():
    x = np.arange(-3000, 3001, 50.0)
    X, Y = np.meshgrid(x, x)
    z = 150 * np.exp(-(X ** 2 + Y ** 2) / (2 * 500 ** 2)) + 60 * np.exp(-((X - 900) ** 2 + (Y + 400) ** 2) / (2 * 300 ** 2))
    T = P.Terrain3D(x, x, z, smooth_m=20.0, far_m=6000.0)
    pan = P.build_panels(T, focus=[(0.0, 0.0)], ds_min=100.0, focus_r=900.0)
    bg = P.bg_uniform(8.0, (0.8, 0.6))
    sig, _ = P.solve(pan, bg, None, None, backend="cupy")
    rng = np.random.default_rng(1)
    n = 3000
    px, py = rng.uniform(-2000, 2000, n), rng.uniform(-2000, 2000, n)
    pz = T.height(px, py) + rng.uniform(2, 1500, n)
    return pan, sig, np.stack([px, py, pz], 1)


def test_fp64_equals_reference(case):
    pan, sig, pts = case
    ref = inf.panel_velocity(pan, sig, pts, "cupy")
    fq = fastq.FastQuery(pan, np.float64, None, origin=pts.mean(0))
    got = fq.panel_velocity(pan, sig, pts)
    assert np.abs(got - ref).max() < 1e-9 * np.abs(ref).max() + 1e-12


def test_fp32_vs_fp64(case):
    pan, sig, pts = case
    ref = inf.panel_velocity(pan, sig, pts, "cupy")
    got = fastq.FastQuery(pan, np.float32, None, origin=pts.mean(0)).panel_velocity(pan, sig, pts)
    assert np.abs(got - ref).max() < 1e-4 * np.abs(ref).max()


def test_far_cluster_theta_zero_is_direct(case):
    pan, sig, pts = case
    org = pts.mean(0)
    d0 = fastq.FastQuery(pan, np.float64, None, origin=org).panel_velocity(pan, sig, pts)
    f = fastq.FastQuery(pan, np.float64, 1e-12, origin=org)
    g = f.panel_velocity(pan, sig, pts)
    assert f.t["n_cluster"] == 0
    assert np.abs(g - d0).max() < 1e-9 * np.abs(d0).max()


def test_far_cluster_error_monotone(case):
    pan, sig, pts = case
    org = pts.mean(0)
    d0 = fastq.FastQuery(pan, np.float64, None, origin=org).panel_velocity(pan, sig, pts)
    tree = fastq.Tree(pan)
    errs = []
    for th in (0.7, 0.5, 0.3):
        f = fastq.FastQuery(pan, np.float64, th, origin=org, tree=tree)
        g = f.panel_velocity(pan, sig, pts)
        errs.append(np.abs(g - d0).max() / np.abs(d0).max())
        assert f.t["n_cluster"] > 0
    assert errs[0] > errs[1] > errs[2]
    assert errs[1] < 2e-2


def test_horizontal_err_zero():
    u = np.array([1.0, 2.0, np.nan])
    e = fastq.horizontal_err(u, u * 0, u, u * 0)
    assert e["n"] == 2 and e["max_abs_ms"] == 0 and e["frac_game_ok"] == 1


def test_lu_inplace_same_sigma():
    x = np.arange(-1500, 1501, 50.0)
    X, Y = np.meshgrid(x, x)
    T = P.Terrain3D(x, x, 80 * np.exp(-(X ** 2 + Y ** 2) / (2 * 400 ** 2)), far_m=4000.0)
    pan = P.build_panels(T, focus=[(0.0, 0.0)], ds_min=100.0, focus_r=600.0)
    bg = P.bg_uniform(8.0, (0.8, 0.6))
    s0, _ = P.solve(pan, bg, None, P.assemble(pan, "cupy"))
    infl = P.assemble(pan, "cupy")
    fastq.lu_inplace(infl)
    s1, _ = P.solve(pan, bg, None, infl)
    assert np.abs(s1 - s0).max() < 1e-9 * np.abs(s0).max()
