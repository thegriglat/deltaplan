"""Генератор рельефа «поле поднятия + речная эрозия (SPL, неявная схема Braun & Willett 2013, fastscapelib)
+ линейная диффузия склонов (ADI) + тепловая эрозия до предельного уклона». Расчёт на 100 м, огрубление до 400 м.
Использование: gen(params, seed) -> dict(z100 (384x384), z400 (96x96), info)."""
import time
import numpy as np
from numba import njit
import fastscapelib as fs


@njit(cache=True)
def thermal(z, dx, Sc, npass, fixed_border):
    """Тепловая эрозия: пока уклон между соседями > Sc, четверть избытка переносится вниз (сохранение массы)."""
    n, m = z.shape
    for _ in range(npass):
        for i in range(n):
            for j in range(m):
                for di in (-1, 0, 1):
                    for dj in (-1, 0, 1):
                        if di == 0 and dj == 0:
                            continue
                        ii = i + di; jj = j + dj
                        if ii < 0 or jj < 0 or ii >= n or jj >= m:
                            continue
                        d = dx * (1.41421356 if (di != 0 and dj != 0) else 1.0)
                        ex = z[i, j] - z[ii, jj] - Sc * d
                        if ex > 0:
                            t = 0.125 * ex
                            if not (fixed_border and (i == 0 or j == 0 or i == n - 1 or j == m - 1)):
                                z[i, j] -= t
                            if not (fixed_border and (ii == 0 or jj == 0 or ii == n - 1 or jj == m - 1)):
                                z[ii, jj] += t


def fourier_field(n, beta, rng, kmin_cells=1.0):
    """Гауссово поле со спектром мощности профиля ~ k^-beta (2D-плотность ~ k^-(beta+1)), нормировано std=1."""
    k = np.fft.fftfreq(n)
    KX, KY = np.meshgrid(k, k)
    K = np.hypot(KX, KY); K[0, 0] = 1
    amp = K ** (-(beta + 1) / 2.0); amp[0, 0] = 0
    f = np.fft.ifft2(amp * np.fft.fft2(rng.standard_normal((n, n)))).real
    return (f - f.mean()) / f.std()


def uplift_field(n, dx, p, rng):
    """Поле поднятия (безразмерное, max=1): сумма гребней/пупырей (формы плана) и/или Фурье-составляющая."""
    import forms
    y, x = np.mgrid[0:n, 0:n] * dx / 1000.0
    ext = n * dx / 1000.0
    z = np.zeros((n, n))
    c = 0.5 * ext
    for _ in range(p.get("n_ridges", 0)):
        th = rng.normal(np.radians(p.get("strike_deg", 0.0)), np.radians(p.get("strike_spread_deg", 15.0)))
        Hr = rng.uniform(*p.get("ridge_H", (0.4, 1.0)))
        pr = [c + rng.normal(0, p.get("pos_spread_km", 8.0)), c + rng.normal(0, p.get("pos_spread_km", 8.0)), th, Hr,
              np.log(rng.uniform(*p.get("ridge_sigma_km", (3, 7)))), np.log(rng.uniform(*p.get("ridge_L_km", (10, 25)))),
              np.log(rng.uniform(1.5, 4.0)), rng.uniform(-0.3, 0.3)]
        z += forms.ridge(pr, x, y)
    for _ in range(p.get("n_blobs", 0)):
        s = rng.uniform(*p.get("blob_sigma_km", (2, 6)))
        pb = [c + rng.normal(0, p.get("pos_spread_km", 8.0)), c + rng.normal(0, p.get("pos_spread_km", 8.0)), rng.uniform(0, np.pi),
              rng.uniform(*p.get("blob_H", (0.2, 0.8))), np.log(s), np.log(s * rng.uniform(0.6, 1.0))]
        z += forms.blob(pb, x, y)
    if p.get("fourier_amp", 0) > 0:
        z = z + p["fourier_amp"] * fourier_field(n, p.get("fourier_beta", 2.0), rng)
    z = z - z.min()
    return z / z.max() if z.max() > 0 else z + 1.0


def gen(p, seed=0, verbose=False):
    """p: n (узлов, по умолч. 512), dx (м, 100), U0 (м/год, максимум поднятия), K, m, n_exp, D (м²/год), Sc (тангенс предела),
    T (лет), dt (лет), noise (м), + параметры uplift_field. Возвращает z100 (центральные 384²), z400 (96²), время."""
    rng = np.random.default_rng(seed)
    n = p.get("n", 512); dx = p.get("dx", 100.0)
    U = p["U0"] * (p.get("U_floor", 0.1) + (1 - p.get("U_floor", 0.1)) * uplift_field(n, dx, p, rng))
    z = rng.uniform(0, p.get("noise", 2.0), (n, n))
    grid = fs.RasterGrid([n, n], [dx, dx], fs.NodeStatus.FIXED_VALUE)
    graph = fs.FlowGraph(grid, [fs.SingleFlowRouter(), fs.MSTSinkResolver()])
    K = p["K"]
    if p.get("K_logsd", 0) > 0:          # неоднородность пород: лог-нормальный K с гауссовым полем (спектр k^-K_beta)
        K = p["K"] * np.exp(p["K_logsd"] * fourier_field(n, p.get("K_beta", 2.0), rng))
    spl = fs.SPLEroder(graph, K, p.get("m", 0.45), p.get("n_exp", 1.0), 1e-5)
    diff = fs.DiffusionADIEroder(grid, p["D"])
    dt, T = p.get("dt", 2e4), p["T"]
    steps = int(T / dt)
    t0 = time.time()
    z[0, :] = z[-1, :] = z[:, 0] = z[:, -1] = 0.0
    hist = []
    for s in range(steps):
        z0 = z.copy()
        graph.update_routes(z)
        A = graph.accumulate(1.0) if False else graph.accumulate(np.full((n, n), dx * dx)) if False else graph.accumulate(1.0)
        er = spl.erode(z, A, dt)
        z_new = z + U * dt - er
        z_new -= diff.erode(z_new, dt)
        z_new[0, :] = z_new[-1, :] = z_new[:, 0] = z_new[:, -1] = 0.0
        z = np.ascontiguousarray(z_new)
        if p.get("Sc") is not None:
            thermal(z, dx, p["Sc"], p.get("thermal_passes", 5), True)
        if s % 10 == 0 or s == steps - 1:
            hist.append((s * dt, float(z[64:-64, 64:-64].max()), float(np.abs(z - z0)[64:-64, 64:-64].mean() / dt)))
        if verbose and s % 25 == 0:
            print(s, hist[-1], flush=True)
    sec = time.time() - t0
    c0 = (n - 384) // 2
    z100 = z[c0:c0 + 384, c0:c0 + 384].copy()
    z400 = z100.reshape(96, 4, 96, 4).mean(axis=(1, 3))
    return dict(z100=z100, z400=z400, seconds=sec, hist=hist, steps=steps)
