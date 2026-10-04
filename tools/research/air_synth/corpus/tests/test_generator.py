import os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import generator as G


def test_bitwise_repeat_and_shape():
    p1, z1 = G.generate(3, 5)
    p2, z2 = G.generate(3, 5)
    assert z1.shape == (384, 384) and z1.dtype == np.float64
    assert np.isfinite(z1).all()
    assert np.array_equal(z1, z2)
    assert p1.SerializeToString(deterministic=True) == p2.SerializeToString(deterministic=True)
    assert G.GENERATOR_VERSION.startswith("fs1-")


def test_params_filled_and_mix():
    for rid in range(6):
        p = G.sample_params(np.random.default_rng(np.random.SeedSequence([1, rid])))
        assert 0.0 <= p.mix <= 1.0
        assert p.uplift_max_m_per_yr > 0 and p.k0 > 0 and p.diffusion_m2_per_yr > 0
        assert p.t_total_yr == G.T_TOTAL and p.base_elevation_m > 0 and len(p.forms) >= 3
        assert p.extra["stretch"] >= 1.0


def test_theta_tunable():
    assert all(lo < d < hi or lo <= d <= hi for lo, hi, d in G.TUNABLE.values())
    p, z = G.generate(3, 5, theta={"k0": 1e-5, "anisotropy": 0.0})
    p0, _ = G.generate(3, 5)
    assert p.k0 == 1e-5 and p.extra["stretch"] == 1.0
    assert p.mix == p0.mix and [f.x_m for f in p.forms] == [f.x_m for f in p0.forms]
    assert np.isfinite(z).all()
