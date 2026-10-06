"""AP-10: bubble.py — fr_local по невозмущённому профилю притока; сечение через наибольший подветренный уклон
(окно при косом ветре не содержит центр формы)."""
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import bubble as B  # noqa: E402

AGL = np.array([25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000], float)


def _step_field(x0, y0, dx, nx, ny, e, L, H, U, a=500.0, h=500.0):
    """Уступ вниз по x (tanh), обратная полоса 0 < x < L ниже H: u = −2·e, иначе U·e."""
    xs = x0 + dx / 2 + dx * np.arange(nx)
    ys = y0 + dx / 2 + dx * np.arange(ny)
    X, _ = np.meshgrid(xs, ys)
    ground = 1000 + h * (1 - np.tanh(X / a)) / 2
    f = np.zeros((4, AGL.size, ny, nx), np.float32)
    for k, z in enumerate(AGL):
        rev = (X > 0) & (X < L) & (z < H)
        sp = np.where(rev, -2.0, U)
        f[0, k], f[1, k] = sp * e[0], sp * e[1]
    return f, ground


def test_fr_local_inflow_profile():
    """fr_local = U(h)/(N·h) по профилю притока: выше z_sat — U_sat, ниже — степенной закон."""
    alpha, mp, us, n = 0.24, 2.341, 1.5, 0.01
    f, g = _step_field(-5000.0, -2000.0, 100.0, 200, 40, (1.0, 0.0), 2000.0, 160.0, us)
    b = B.bubble(f, AGL, -5000.0, -2000.0, 100.0, g, (1.0, 0.0), 500.0, us, n, inflow=(alpha, mp))
    assert b["fr_local"] == pytest.approx(us / (n * 500.0), rel=1e-6)          # Fr = 0,3, не 0,6
    z_sat = 10 * mp ** (1 / alpha)
    b2 = B.bubble(f, AGL, -5000.0, -2000.0, 100.0, g, (1.0, 0.0), 100.0, us, n, inflow=(alpha, mp))
    assert b2["fr_local"] == pytest.approx(us * (100 / z_sat) ** alpha / (n * 100.0), rel=1e-6)
    # возмущённая колонна (выброс у губки) больше не влияет, если задан inflow
    up = (AGL, np.full(AGL.size, 3.0), 1000.0)
    b3 = B.bubble(f, AGL, -5000.0, -2000.0, 100.0, g, (1.0, 0.0), 500.0, us, n, up_profile=up, inflow=(alpha, mp))
    assert b3["fr_local"] == pytest.approx(b["fr_local"])
    b4 = B.bubble(f, AGL, -5000.0, -2000.0, 100.0, g, (1.0, 0.0), 500.0, us, n, up_profile=up)
    assert b4["fr_local"] == pytest.approx(3.0 / (n * 500.0))                   # старое определение — как было


def test_oblique_window_off_center():
    """Окно 100 м у конца хребта при ветре 300°: (0, 0) вне окна. center=(0, 0) — сечение мимо уступа (старая ошибка),
    center=None — через наибольший подветренный уклон: пузырь найден, длина по ветру ≈ L/cos 30°."""
    phi = np.radians(300.0)
    e = (-np.sin(phi), -np.cos(phi))
    x0, y0, dx, nx, ny = -4400.0, -16700.0, 100.0, 152, 136
    L, H, U = 2000.0, 160.0, 15.0
    f, g = _step_field(x0, y0, dx, nx, ny, e, L, H, U)
    old = B.bubble(f, AGL, x0, y0, dx, g, e, 500.0, U, 0.01, center=(0.0, 0.0))
    assert old["has_reverse"] == 0 and old["slope_lee"] < 1e-3
    b = B.bubble(f, AGL, x0, y0, dx, g, e, 500.0, U, 0.01, center=None)
    assert b["has_reverse"] == 1
    assert b["slope_lee"] == pytest.approx(0.5 * np.cos(np.radians(30)), rel=0.05)
    xb = -0.66 * 500.0                                   # бровка tanh-уступа (наибольшая выпуклость), по x
    assert b["L_over_h"] * 500.0 == pytest.approx((L - xb) / np.cos(np.radians(30)), rel=0.08)
    assert b["urev_over_U"] == pytest.approx(-2.0 / U, rel=1e-3)


def test_steepest_lee_point_tie_center():
    """Однородный по y уступ: из равных выбирается строка, ближайшая к центру сетки."""
    x0, y0, dx, nx, ny = -3000.0, -4100.0, 100.0, 120, 88
    f, g = _step_field(x0, y0, dx, nx, ny, (1.0, 0.0), 1000.0, 100.0, 10.0)
    x, y = B.steepest_lee_point(g, x0, y0, dx, (1.0, 0.0))
    ys = y0 + dx / 2 + dx * np.arange(ny)
    assert abs(x) <= dx and abs(y - ys.mean()) <= dx / 2 + 1e-6
