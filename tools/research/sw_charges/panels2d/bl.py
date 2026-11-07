"""panels2d v3 (SW6): скорость и давление на поверхности, интегральный турбулентный пограничный слой (Хед 1958),
отрыв (Хед; Стратфорд 1959), скорость у стенки с log-законом. Только NumPy."""
import numpy as np
from .core import _pair, velocity

KAPPA = 0.4
NU = 1.5e-5          # кинематическая вязкость воздуха, м²/с
GATE = 0.01          # возмущение u_e, с которого слой считается по Хеду (1 % от u_e на входе)
H_SEP = 2.4          # критерий отрыва Хеда
H1_SPLIT = 5.3       # H1(H=1,6) — граница двух ветвей H1(H)
H_EQ = 1.35          # форм-фактор равновесного слоя ровной земли
DELTA0_Z0 = 500.0    # δ0 = 500·z0 (50 м при z0 = 0,1) — глубина слоя ровной земли
H_EDGE = 50.0        # высота (м) над поверхностью, где берётся фон для u_e (≈ δ0)
STRAT_C = 0.39       # турбулентный Стратфорд: Cp·(x dCp/dx)^½·(1e-6 Re)^-0,1 = 0,39


def _H1_of_H(H):
    H = np.asarray(H, float)
    return np.where(H <= 1.6, 0.8234 * np.maximum(H - 1.1, 1e-6) ** -1.287 + 3.3,
                    1.5501 * np.maximum(H - 0.6778, 1e-6) ** -3.064 + 3.3)


def _H_of_H1(H1):
    H1 = max(float(H1), 3.3 + 1e-6)
    if H1 >= H1_SPLIT:
        return 1.1 + ((H1 - 3.3) / 0.8234) ** (-1 / 1.287)
    return 0.6778 + ((H1 - 3.3) / 1.5501) ** (-1 / 3.064)


def _F(H1):
    return 0.0306 * max(H1 - 3.0, 1e-6) ** -0.6169


def _cf2(delta, z0):  # cf/2 шероховатой стенки
    return (KAPPA / np.log(max(delta, 3.0 * z0) / z0)) ** 2


def _tangent_matrix(p):
    n = p.n
    T = np.empty((n, n))
    step_ = max(1, 2_000_000 // n)
    for i in range(0, n, step_):
        sl = slice(i, i + step_)
        pu, pw = _pair(p, p.xc[sl], p.zc[sl])
        T[sl] = pu * p.nz[sl, None] + pw * (-p.nx[sl, None])
    T[np.arange(n), np.arange(n)] = 0.0  # собственный вклад панели в касательную — 0
    return T


def surface_flow(panels, sigma, bg, vortices=None, h_edge=H_EDGE):
    """s, u_s, cp, U_ref (контракт SW6 v3) + u_e — касательная скорость на кромке слоя (фон на h_edge над поверхностью +
    наведённая часть на стенке; при однородном фоне u_e = u_s), du_e (сглаженная du_e/ds)."""
    from .core import _vort_vel
    p = panels
    tx, tz = p.nz, -p.nx
    s = np.concatenate([[0.0], np.cumsum(p.ds)])
    s = 0.5 * (s[:-1] + s[1:])
    u0, w0 = bg(p.xc, p.zc)
    vu, vw = _vort_vel(vortices, p.xc, p.zc)
    ind = _tangent_matrix(p) @ sigma
    bgt0 = u0 * tx + w0 * tz
    u_s = bgt0 + vu * tx + vw * tz + ind
    uh, wh = bg(p.xc + p.nx * h_edge, p.zc + p.nz * h_edge)
    u_e = u_s + (uh * tx + wh * tz - bgt0)
    ur, wr = bg(np.array([p.x1[0]]), np.array([p.z1[0] + 100.0]))
    U_ref = float(np.hypot(ur[0], wr[0]))
    d = np.gradient(u_e, s)
    dp = np.concatenate([[d[0]], d, [d[-1]]])
    d = (dp[:-2] + dp[1:-1] + dp[2:]) / 3.0  # сглаживание на 3 панели
    return dict(s=s, u_s=u_s, cp=1.0 - (u_s / U_ref) ** 2, U_ref=U_ref, u_e=u_e, du_e=d)


def _equilibrium(z0, delta0=None):
    """Слой ровной земли — решение уравнений Хеда с постоянными H и δ на ровной земле: вовлечение при dH1/ds = 0
    даёт H1·cf/2 = F(H1) (dθ/ds = cf/2 → θ растёт, форма сохраняется). Для шероховатой стенки при δ0/z0 = 500 корень
    H0 ищется бисекцией; θ0 = δ0/(H1 + H0). Рост θ на ровной земле уравновешен АПС (крупномасштабное давление) и в
    модель не входит: слой держится (θ0, H0) до первого возмущения давления рельефом (см. boundary_layer)."""
    d0 = DELTA0_Z0 * z0 if delta0 is None else delta0
    c2 = _cf2(d0, z0)
    g = lambda H: _F(float(_H1_of_H(H))) - float(_H1_of_H(H)) * c2
    lo, hi = 1.15, 2.3
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        if g(lo) * g(mid) <= 0:
            hi = mid
        else:
            lo = mid
    H0 = 0.5 * (lo + hi)
    H10 = float(_H1_of_H(H0))
    return d0 / (H10 + H0), H10, H0


def boundary_layer(panels, flow, z0, method="head"):
    if method != "head":
        raise ValueError("method='head'")
    s, ue, du = flow["s"], flow["u_e"], flow["du_e"]
    n = s.size
    uref = max(flow["U_ref"], 1e-9)
    th0, H10, H0 = _equilibrium(z0)
    theta = np.full(n, np.nan); H = np.full(n, np.nan); delta = np.full(n, np.nan)
    cf = np.full(n, np.nan); ustar = np.full(n, np.nan)
    umin = 1e-3 * uref

    def rhs(sv, th, H1, u, dudx):
        u = max(u, umin)
        Hh = _H_of_H1(H1)
        d = th * (H1 + Hh)
        c2 = _cf2(d, z0)
        dth = c2 - (Hh + 2.0) * th * dudx / u
        dH1 = (_F(H1) - H1 * dth - th * H1 * dudx / u) / th
        return dth, dH1

    th, H1 = th0, H10
    i_sep = -1
    free = False  # слой ровной земли удерживается, пока кромочная скорость в пределах GATE от скорости на входе
    for i in range(n):
        if not free and abs(ue[i] / ue[0] - 1.0) > GATE:
            free = True
        if i > 0 and free:
            # подшаги: жёсткость (рост H1 ~ 0,07 м⁻¹·θ0/θ) — шаг не больше 15·θ0
            nsub = max(1, int(np.ceil((s[i] - s[i - 1]) / (15.0 * th0))))
            for k in range(nsub):
                a0, a1 = k / nsub, (k + 1) / nsub
                ds = (s[i] - s[i - 1]) / nsub
                ua, ub = ue[i - 1] + a0 * (ue[i] - ue[i - 1]), ue[i - 1] + a1 * (ue[i] - ue[i - 1])
                da, db = du[i - 1] + a0 * (du[i] - du[i - 1]), du[i - 1] + a1 * (du[i] - du[i - 1])
                k1 = rhs(0, th, H1, ua, da)
                k2 = rhs(0, th + 0.5 * ds * k1[0], H1 + 0.5 * ds * k1[1], 0.5 * (ua + ub), 0.5 * (da + db))
                th = max(th + ds * k2[0], 1e-3 * th0)
                H1 = min(max(H1 + ds * k2[1], 3.3 + 1e-3), 80.0)
        Hh = _H_of_H1(H1)
        d = th * (H1 + Hh)
        c2 = _cf2(d, z0)
        theta[i], H[i], delta[i], cf[i] = th, Hh, d, 2 * c2
        ustar[i] = max(ue[i], 0.0) * np.sqrt(c2)
        if (Hh >= H_SEP and du[i] < 0) or ue[i] <= 0:
            i_sep = i
            break
    return dict(theta=theta, delta=delta, H=H, u_star=ustar, cf=cf, i_sep=i_sep, z0=float(z0))


def _pt(p, s, i0, i1, a):
    return (p.xc[i0] + a * (p.xc[i1] - p.xc[i0]), p.zc[i0] + a * (p.zc[i1] - p.zc[i0]))


def separation(panels, flow, bl, method="head"):
    p = panels
    out = []
    s = flow["s"]
    if method == "head":
        i = bl["i_sep"]
        if i >= 0:
            if i > 0 and np.isfinite(bl["H"][i - 1]) and bl["H"][i] >= H_SEP > bl["H"][i - 1]:
                a = (H_SEP - bl["H"][i - 1]) / (bl["H"][i] - bl["H"][i - 1])
            else:
                a = 1.0
            i0 = max(i - 1, 0)
            x, z = _pt(p, s, i0, i, a)
            out.append(dict(s_sep=float(s[i0] + a * (s[i] - s[i0])), x_sep=float(x), z_sep=float(z),
                            method="head", value=float(bl["H"][i])))
        return out
    if method != "stratford":
        raise ValueError("method: head | stratford")
    u, du = flow["u_e"], flow["du_e"]
    n = s.size
    i = 1
    while i < n - 1:
        # начало торможения — локальный максимум скорости (минимум давления)
        if du[i] < 0 <= du[i - 1] and u[i] > 0:
            im = i - 1 if u[i - 1] > u[i] else i
            umax = u[im]
            ref = u[:im + 1]
            ia = int(np.nonzero(ref <= ref.min() + 0.01 * abs(ref.min()))[0][-1])
            L = max(s[im] - s[ia], p.ds_min or float(p.ds.min()))
            Re = umax * L / NU
            fac = (1e-6 * Re) ** 0.1
            j = im + 1
            while j < n and du[j] < 0:
                x = s[j] - s[im]
                cp = 1.0 - (u[j] / umax) ** 2
                dcp = -2.0 * u[j] * du[j] / umax ** 2
                val = cp * np.sqrt(max(x * dcp, 0.0)) / fac
                if val >= STRAT_C:
                    j0 = j - 1
                    out.append(dict(s_sep=float(s[j]), x_sep=float(p.xc[j]), z_sep=float(p.zc[j]),
                                    method="stratford", value=float(val)))
                    break
                j += 1
            i = j
        i += 1
    return out


def velocity_bl(panels, sigma, bg, x, z, bl, vortices=None):
    x = np.asarray(x, float)
    z = np.asarray(z, float)
    u, w = velocity(panels, sigma, bg, x, z, vortices)
    p = panels
    xf, zf = x.ravel(), z.ravel()
    uf, wf = u.ravel().copy(), w.ravel().copy()
    j = np.clip(np.searchsorted(p.x1, xf, side="right") - 1, 0, p.n - 1)
    zg = p.ground(xf)
    zagl = zf - zg
    d = bl["delta"][j]
    z0 = bl["z0"]
    sel = np.isfinite(d) & np.isfinite(uf) & (zagl < d)
    if np.any(sel):
        idx = np.nonzero(sel)[0]
        ue_, we_ = velocity(p, sigma, bg, xf[idx], zg[idx] + d[idx], vortices)
        tx, tz, nx, nz = p.nz[j[idx]], -p.nx[j[idx]], p.nx[j[idx]], p.nz[j[idx]]
        vt_edge = ue_ * tx + we_ * tz
        vt = uf[idx] * tx + wf[idx] * tz
        vn = uf[idx] * nx + wf[idx] * nz
        lg = np.log(np.maximum(zagl[idx], z0) / z0) / np.log(d[idx] / z0)
        vt = vt_edge * lg
        uf[idx] = vt * tx + vn * nx
        wf[idx] = vt * tz + vn * nz
    return uf.reshape(x.shape), wf.reshape(x.shape)
