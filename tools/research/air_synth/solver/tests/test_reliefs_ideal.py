"""Идеальные рельефы P1 (docs/contracts/air-phase.md): численный max|∇z| на h100 = s ± 3 %, g400 — блочное среднее."""
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reliefs as R  # noqa: E402

SHAPES = ["hill", "ridge", "step_up", "step_down"]


@pytest.mark.parametrize("shape", SHAPES)
@pytest.mark.parametrize("s", [0.15, 0.3, 0.5, 0.6])
def test_max_gradient(shape, s):
    g100, g400 = R.ideal_relief(shape, s)
    gy, gx = np.gradient(g100, 100.0)
    m = float(np.hypot(gx, gy).max())
    tol = 0.03 if s <= 0.5 else 0.04     # s = 0,6: уступ a = 417 м — центральная разность на 100 м занижает на 3,2 %
    assert abs(m / s - 1) < tol, (shape, s, m)
    assert g100.shape == (384, 384) and g400.shape == (96, 96)
    np.testing.assert_allclose(g400, g100.reshape(96, 4, 96, 4).mean(axis=(1, 3)), rtol=0, atol=1e-9)


def test_heights_and_orientation():
    g, _ = R.ideal_relief("step_up", 0.3)
    assert abs(g[:, 0].max() - 1000.0) < 1 and abs(g[:, -1].min() - 1500.0) < 1   # запад — база, восток — плато
    g, _ = R.ideal_relief("step_down", 0.3)
    assert abs(g[:, 0].min() - 1500.0) < 1 and abs(g[:, -1].max() - 1000.0) < 1
    g, _ = R.ideal_relief("hill", 0.3)
    assert 1495 < g.max() <= 1500 and g.min() >= 1000
    r, _ = R.ideal_relief("ridge", 0.3)   # вытянут по y (север): сечение вдоль y в центре почти постоянно на 20 км
    assert r[192 - 60, 192] > 1490 and r[0, 192] < 1001 and r[:, 0].max() < 1001


def test_load_ideal_names():
    out = R.load_ideal([("hill", 0.3), ("ridge", 0.5, 10000.0), ("ridge", 0.5)])
    assert [o[0] for o in out] == ["hill_s0.30", "ridge_s0.50_L10", "ridge_s0.50"]
    assert all(o[1].shape == (384, 384) and o[2].shape == (96, 96) for o in out)
