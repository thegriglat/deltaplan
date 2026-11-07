"""Прототип C: общие функции. Диполь Лэмба — Чаплыгина (LC), профиль ветра, константы."""
import numpy as np
from scipy.special import j0, j1

KA = 3.8317059702075125          # первый нуль J1
J0KA = j0(KA)                    # = -0.4028
KAPPA = 0.4
G_OVER_T0 = 9.81 / 300.0
Z0 = 0.1


def lc_velocity(dx, dz, nx, nz, U, a):
    """Скорость лабораторной системы (u, w) диполя ЛЧ: центр в (0,0), курс (nx,nz) единичный,
    скорость диполя U, радиус a. dx, dz — массивы (точка минус центр). Внутри — J1, снаружи — U a^2/r."""
    X = dx * nx + dz * nz            # вдоль курса
    Y = -dx * nz + dz * nx           # поперёк (левая тройка: Y = n_perp)
    r = np.sqrt(X * X + Y * Y)
    rs = np.maximum(r, 1e-9)
    s2 = (Y / rs) ** 2
    c2 = (X / rs) ** 2
    sc = (X / rs) * (Y / rs)
    k = KA / a
    inside = r < a
    # f(r) и f'(r)
    f_in = -2.0 * U * j1(k * rs) / (k * J0KA) + U * rs
    fp_in = -2.0 * U * j0(k * rs) / J0KA * 1.0 + U      # d/dr[-2U J1(kr)/(k J0)] = -2U J1'(kr)/J0 ; J1' = J0 - J1/x
    fp_in = -2.0 * U * (j0(k * rs) - j1(k * rs) / (k * rs)) / J0KA + U
    f_out = U * a * a / rs
    fp_out = -U * a * a / rs ** 2
    f = np.where(inside, f_in, f_out)
    fp = np.where(inside, fp_in, fp_out)
    # центр: f/r -> U(1 - 1/J0KA), f' -> то же
    small = r < 1e-6 * a
    fr = np.where(small, U * (1.0 - 1.0 / J0KA), f / rs)
    fp = np.where(small, U * (1.0 - 1.0 / J0KA), fp)
    uX = fp * s2 + fr * c2
    uY = -(fp - fr) * sc
    # назад в (x, z): e_X = (nx, nz), e_Y = (-nz, nx)
    u = uX * nx - uY * nz
    w = uX * nz + uY * nx
    return u, w


def wind_profile(z, ustar=0.4, zcap=100.0):
    """Гладкое U(z): логарифм до zcap, выше постоянное."""
    zz = np.clip(z, Z0 * 1.01, zcap)
    return ustar / KAPPA * np.log(zz / Z0)


def theta_env(z, gam_ml=0.5e-3, zi=1500.0, gam_up=5e-3):
    z = np.asarray(z, float)
    return np.where(z < zi, gam_ml * z, gam_ml * zi + gam_up * (z - zi))


def lc_energy_coeff():
    """E/(U^2 a^2) для единичной плотности: 1/2 ∫|u|^2 dA, численно по полярной сетке."""
    a = 1.0
    nr, nt = 2000, 360
    # r от 0 до 400a, неравномерная
    rr = np.concatenate([np.linspace(1e-4, a, nr), a + np.expm1(np.linspace(0, np.log(400), nr)) * a / 1.0])
    rm = 0.5 * (rr[1:] + rr[:-1]); dr = np.diff(rr)
    th = (np.arange(nt) + 0.5) * 2 * np.pi / nt
    R, T = np.meshgrid(rm, th, indexing="ij")
    u, w = lc_velocity(R * np.cos(T), R * np.sin(T), 1.0, 0.0, 1.0, a)
    e = 0.5 * np.sum((u * u + w * w) * R * dr[:, None]) * (2 * np.pi / nt)
    return e
