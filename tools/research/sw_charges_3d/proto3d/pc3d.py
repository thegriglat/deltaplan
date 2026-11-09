"""Прототип C в 3D: кольца-пары болтанки (3D-аналог пары вихрей прототипа C 2D), порог рождения по Ri, экранировка.

Закон (как C 2D, 'Общая основа' unified-scales.md): ℓ = κ z, диаметр кольца d = ℓ (R_r = ℓ/2), ΔU = S ℓ, Γ = ΔU ℓ,
ядро c = c_over_R·R_r; скорость кольца U_r = Γ/(4π R_r)(ln(8R_r/c) − ¼) (Сэффмен, равномерная завихрённость в ядре),
энергия E = ½ Γ² R_r (ln(8R_r/c) − 7/4); время жизни τ = d/U_r; интенсивность рождения λ = ε F(Ri)/E на м³/с,
ε = ℓ² S³ (в логарифмическом слое S = u*/κz → u*³/κz, как в 2D); F(Ri) = clip(1 − 4Ri, 0, 1) (порог Майлса — Ховарда),
F ≡ 1 — «без порога». Курс кольца (ось = направление движения): ±45° к вертикали в плоскости ветра, 50/50
(выброс: вверх-против ветра; вторжение: вниз-по ветру). Земля: зеркальное кольцо (ω_x,ω_y → −ω_x,−ω_y; z → −z).
Кольца невзаимодействующие (суперпозиция Био — Савара; нет аннигиляции/перезамыкания) — граница модели."""
import numpy as np
import cupy as cp
from . import vp, rings

KAPPA = 0.4


def ring_props(ell, S, c_over_R=0.35, Rfac=0.5):
    Rr = Rfac * ell
    c = c_over_R * Rr
    gam = S * ell * ell
    Ur = gam / (4 * np.pi * Rr) * (np.log(8 * Rr / c) - 0.25)
    E = 0.5 * gam ** 2 * Rr * (np.log(8 * Rr / c) - 1.75)
    tau = (2 * Rr) / Ur
    return Rr, c, gam, Ur, E, tau


def F_ri(Ri, kind="step"):
    if kind == "none":
        return np.ones_like(Ri)
    return np.clip(1 - 4 * Ri, 0, 1)


class Params:
    def __init__(self, c_over_R=0.35, Rfac=0.5, phi_deg=45.0, nseg=12, fkind="step"):
        self.c_over_R, self.Rfac, self.phi, self.nseg, self.fkind = c_over_R, Rfac, np.radians(phi_deg), nseg, fkind


def snapshot(rng, zlo, zhi, Lbox, Sfun, N2fun, P, dz_bin=None, kappa_z0=0.0):
    """Мгновенный ансамбль колец в коробке Lbox×Lbox×[zlo, zhi] (периодика по x, y). Sfun(z), N2fun(z) — средний сдвиг (1/с)
    и N² (1/с²). Возврат: dict(S (n·nseg,3), A, SG, n_rings, Ri_mean_birth, per-bin данные)."""
    dzb = dz_bin or max(1.0, 0.05 * zlo)
    edges = np.arange(zlo, zhi + dzb, dzb)
    Ss, As, Gs = [], [], []
    nr = 0
    for z0, z1 in zip(edges[:-1], edges[1:]):
        zm = 0.5 * (z0 + z1)
        S = float(Sfun(zm)); N2 = float(N2fun(zm))
        Ri = N2 / (S * S) if S > 0 else np.inf
        f = float(F_ri(np.array([Ri]), P.fkind)[0])
        if f <= 0 or S <= 0:
            continue
        ell = KAPPA * zm
        Rr, c, gam, Ur, E, tau = ring_props(ell, S, P.c_over_R, P.Rfac)
        eps = ell * ell * S ** 3 * f
        lam = eps / E
        mean = lam * tau * Lbox * Lbox * (z1 - z0)
        n = rng.poisson(mean)
        if n == 0:
            continue
        # дальше — позиции и курс; кольцо ниже земли (центр ниже R_r) отбрасывается отражением по высоте z
        zc = rng.uniform(z0, z1, n)
        xc = rng.uniform(0, Lbox, n); yc = rng.uniform(0, Lbox, n)
        sgn = rng.choice([-1.0, 1.0], n)
        sp, cp_ = np.sin(P.phi), np.cos(P.phi)
        # выброс: вверх (+z) и против ветра (−x); вторжение: вниз и по ветру. ось = направление движения
        ax = np.stack([-sgn * sp, np.zeros(n), sgn * cp_], 1)
        pos, al, sg = rings.ring_batch(np.stack([xc, yc, zc], 1), ax, Rr, gam, c, P.nseg)
        Ss.append(pos); As.append(al); Gs.append(sg)
        nr += n
    if not Ss:
        return dict(S=np.zeros((0, 3)), A=np.zeros((0, 3)), SG=np.zeros(0), n_rings=0)
    return dict(S=np.vstack(Ss), A=np.vstack(As), SG=np.concatenate(Gs), n_rings=nr)


def image_of(S, A, SG):
    """Зеркало земли z = 0: положение (x, y, −z), α → (−α_x, −α_y, +α_z)."""
    return S * np.array([1.0, 1.0, -1.0]), A * np.array([-1.0, -1.0, 1.0]), SG


def field(ens, X, Lbox, images=True):
    sh = np.array([[i * Lbox, j * Lbox, 0.0] for i in (-1, 0, 1) for j in (-1, 0, 1)])
    S, A, SG = ens["S"], ens["A"], ens["SG"]
    if images:
        S2, A2, G2 = image_of(S, A, SG)
        S, A, SG = np.vstack([S, S2]), np.vstack([A, A2]), np.concatenate([SG, G2])
    return vp.velocity(X, S, A, SG, shifts=sh).get()


def stats_at_level(rng, zp, Sfun, N2fun, P, win=4.0, Lfac=12.0, nprobe=1500, nlines=6, nline_pts=96, seeds=1):
    """Статистика на высоте zp: σ_w, σ_u, ⟨u'w'⟩, L_w (интеграл автокорреляции вдоль x до нуля × 2)."""
    ell = KAPPA * zp
    Lbox = Lfac * ell
    ws, us, uws, Lw_list, nrs = [], [], [], [], []
    for _ in range(seeds):
        ens = snapshot(rng, max(zp / win, 0.5), zp * win, Lbox, Sfun, N2fun, P)
        nrs.append(ens["n_rings"])
        if ens["n_rings"] == 0:
            ws.append(0.0); us.append(0.0); uws.append(0.0); Lw_list.append(np.nan)
            continue
        X = np.stack([rng.uniform(0, Lbox, nprobe), rng.uniform(0, Lbox, nprobe), np.full(nprobe, zp)], 1)
        u = field(ens, X, Lbox)
        ws.append(float(np.sqrt(np.mean(u[:, 2] ** 2)))); us.append(float(np.sqrt(np.mean(u[:, 0] ** 2))))
        uws.append(float(np.mean(u[:, 0] * u[:, 2])))
        # L_w по линиям вдоль x
        dx = Lbox / nline_pts
        xs = np.arange(nline_pts) * dx
        wl = []
        for _l in range(nlines):
            y0 = rng.uniform(0, Lbox)
            Xl = np.stack([xs, np.full(nline_pts, y0), np.full(nline_pts, zp)], 1)
            wl.append(field(ens, Xl, Lbox)[:, 2])
        wl = np.array(wl)
        wl -= wl.mean()
        var = (wl ** 2).mean()
        rho = [np.mean(wl[:, :nline_pts - k] * wl[:, k:]) / var for k in range(nline_pts // 2)]
        rho = np.array(rho)
        z0i = np.where(rho <= 0)[0]
        kz = z0i[0] if len(z0i) else len(rho) - 1
        Lw_list.append(float(2 * dx * (rho[:kz].sum() - 0.5 * rho[0])))
    return dict(z=zp, sigma_w=float(np.mean(ws)), sigma_u=float(np.mean(us)), uw=float(np.mean(uws)),
                L_w=float(np.nanmean(Lw_list)), n_rings=int(np.mean(nrs)), sigma_w_all=ws)
