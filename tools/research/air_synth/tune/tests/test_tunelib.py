"""Восстановление известных θ по синтетической функции: наблюдаемые = квадратичная функция u + шум."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tunelib as T  # noqa: E402


def make(n_obs=12, dim=6, seed=1):
    rng = np.random.default_rng(seed)
    A = rng.normal(size=(n_obs, dim)); Q = rng.normal(size=(n_obs, dim)) * 0.3; c = rng.normal(size=n_obs)
    return lambda u: c + A @ u + Q @ (u ** 2)


def test_space_roundtrip():
    sp = T.Space({"a": (1.0, 100.0, 10.0), "b": (-1.0, 3.0, 0.0)})
    assert sp.log.tolist() == [True, False]
    u = np.array([-0.3, 0.7])
    assert np.allclose(sp.to_u(sp.from_u(u)), u)
    assert np.allclose(sp.from_u([-1, 1]), [1.0, 3.0])


def test_lhs_stratified():
    U = T.lhs(5, 40, seed=3)
    assert U.shape == (40, 5) and U.min() >= -1 and U.max() <= 1
    for k in range(5):
        assert len(set(np.floor((U[:, k] + 1) / 2 * 40).astype(int))) == 40


def test_recover_theta():
    dim = 6
    f = make(dim=dim)
    rng = np.random.default_rng(0)
    U = T.lhs(dim, 100, seed=0)
    sig = 0.02
    Y = np.array([f(u) + rng.normal(0, sig, 12) for u in U])
    sur = T.Surrogate(U, Y, 2)
    for t in range(5):
        u_true = rng.uniform(-0.8, 0.8, dim)
        y_ref = f(u_true) + rng.normal(0, sig, 12)
        u, chi2, res, ndf = T.fit_one(sur, y_ref, np.full(12, sig), dim)
        assert np.abs(u - u_true).max() < 0.15
        assert chi2 < 5 * ndf


def test_unreachable_flag_via_chi2():
    dim = 4
    f = make(dim=dim, n_obs=10)
    U = T.lhs(dim, 60, seed=1)
    sur = T.Surrogate(U, np.array([f(u) for u in U]), 2)
    y = f(np.zeros(dim)).copy(); y[3] += 50.0   # недостижимая наблюдаемая
    u, chi2, res, ndf = T.fit_one(sur, y, np.full(10, 0.05), dim)
    assert abs(res[3]) > 100
