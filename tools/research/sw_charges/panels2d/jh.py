"""panels2d v4 (SW6): гребни рельефа и внутренний слой Jackson–Hunt. Только NumPy.
Jackson & Hunt 1975 QJRMS 101:929; Hunt, Leibovich & Richards 1988 QJRMS 114:1435; Taylor, Mason & Bradley 1987 BLM 39:107."""
import numpy as np
from .core import _gauss, bg_uniform, solve, velocity

KAPPA = 0.4
L_FLAT = 1.0e4  # допущение: масштаб длины там, где гребней нет (ровная земля), м


def _ground_line(p):
    return np.append(p.x1, p.x2[-1]), np.append(p.z1, p.z2[-1])


def _extrema(p, smooth_m):
    xn, zn = _ground_line(p)
    sm = 2.0 * p.ds_min if smooth_m is None else float(smooth_m)
    if sm > 0:
        xs, zs = _gauss(xn, zn, sm)
    else:
        xs, zs = xn, zn
    return xs, zs


def crests(panels, smooth_m=None):
    """Гребни: локальные максимумы земли, сглаженной гауссом σ = smooth_m (по умолчанию 2·ds_min), с перепадом
    ≥ 2·ds_min над обоими соседними минимумами (минимум z между соседними максимумами или до края области).
    L — наветренная полуширина на половине высоты над наветренным минимумом. → список {x_c, z_c, L}."""
    p = panels
    xs, zs = _extrema(p, smooth_m)
    n = zs.size
    d = np.diff(zs)
    # максимумы: подъём, затем не подъём (плато — левый край)
    nz = np.nonzero(d)[0]  # индексы ненулевых приращений (плато пропускаются)
    sg = np.sign(d[nz])
    mx = [int(nz[k]) + 1 for k in range(len(nz) - 1) if sg[k] > 0 > sg[k + 1]]
    mx = sorted(set(mx))
    out = []
    thr = 2.0 * p.ds_min
    for k, im in enumerate(mx):
        lo = mx[k - 1] if k > 0 else 0
        hi = mx[k + 1] if k + 1 < len(mx) else n - 1
        zl = float(zs[lo:im + 1].min())
        zr = float(zs[im:hi + 1].min())
        zc = float(zs[im])
        if zc - max(zl, zr) < thr:
            continue
        zh = zl + 0.5 * (zc - zl)
        # последняя точка слева от гребня на уровне ниже половины высоты → линейная интерполяция
        seg = zs[lo:im + 1]
        below = np.nonzero(seg < zh)[0]
        if below.size == 0:
            xw = xs[lo]
        else:
            b = below[-1]
            a = (zh - seg[b]) / (seg[b + 1] - seg[b])
            xw = xs[lo + b] + a * (xs[lo + b + 1] - xs[lo + b])
        out.append(dict(x_c=float(xs[im]), z_c=zc, L=float(xs[im] - xw)))
    return out


def lee_mask(panels, crest_list, smooth_m=None):
    """Панели (по xc) между гребнем и следующим минимумом по ветру (или краем области) — где отрыв допустим."""
    p = panels
    xs, zs = _extrema(p, smooth_m)
    m = np.zeros(p.n, bool)
    for c in crest_list:
        i0 = int(np.searchsorted(xs, c["x_c"]))
        j = i0
        while j < xs.size - 1 and zs[j + 1] <= zs[j]:
            j += 1
        m |= (p.xc >= c["x_c"]) & (p.xc <= xs[j])
    return m


def inner_depth(L, z0):
    """l: l·ln(l/z0) = 2κ²·L (Jackson & Hunt 1975), бисекция."""
    L = np.asarray(L, float)
    rhs = 2 * KAPPA ** 2 * L
    lo = np.full(L.shape, z0 * 1.0000001)
    hi = np.maximum(rhs, 10 * z0) + 10 * z0  # l·ln(l/z0) ≥ l при l ≥ e·z0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        f = mid * np.log(mid / z0) - rhs
        lo = np.where(f < 0, mid, lo)
        hi = np.where(f < 0, hi, mid)
    return 0.5 * (lo + hi)


def middle_top(L, z0):
    """h_m = L/√ln(L/z0) (допущение, README: упрощение h_m ln(h_m/z0)^½ ~ L Hunt et al. 1988)."""
    L = np.asarray(L, float)
    return L / np.sqrt(np.log(np.maximum(L, 3 * z0) / z0))


def _uniform_sigma(p, U):
    c = getattr(p, "_jh_cache", None)
    if c is None or c[0] != U:
        c = (U, solve(p, bg_uniform(U)))
        p._jh_cache = c
    return c[1]


def velocity_jh(panels, sigma, bg, x, z, z0, U_ref=None):
    """Внутренний слой Jackson–Hunt поверх потенциального разгона (контракт SW6 v4).
    ΔS(x, z) = A(z_e)·(u_pot(x, z_e)/U_ref − 1), z_e = max(z_agl, l); A = (ln(h_m/z0)/ln(z_e/z0))² при z_e < h_m, иначе 1
    (допущение: u0·Δu ≈ const в среднем слое — давление не зависит от z); u = u0(z_agl)·(1 + ΔS); на [h_m, 2h_m] —
    линейная по ln z сшивка к velocity(bg); выше — velocity(bg). w — потенциальная (velocity)."""
    p = panels
    x = np.asarray(x, float)
    z = np.asarray(z, float)
    shp = x.shape
    xf, zf = x.ravel(), z.ravel()
    if U_ref is None:
        ur, wr = bg(np.array([p.x1[0]]), np.array([p.z1[0] + 100.0]))
        U_ref = float(np.hypot(ur[0], wr[0]))
    uv, wv = velocity(p, sigma, bg, xf, zf)
    zg = p.ground(xf)
    zagl = zf - zg
    cr = crests(p)
    if cr:
        xc = np.array([c["x_c"] for c in cr])
        Lc = np.array([c["L"] for c in cr])
        L = Lc[np.argmin(np.abs(xf[:, None] - xc[None]), axis=1)]
    else:
        L = np.full(xf.shape, L_FLAT)
    l = inner_depth(L, z0)
    hm = middle_top(L, z0)
    ok = np.isfinite(uv)
    zz = np.where(ok, np.maximum(zagl, z0), z0)
    ze = np.maximum(zz, l)
    sg = _uniform_sigma(p, U_ref)
    up, _ = velocity(p, sg, bg_uniform(U_ref), xf, np.where(ok, zg + ze, zg + 1.0))
    ds_pot = up / U_ref - 1.0
    lnh = np.log(np.maximum(hm, 1.01 * z0) / z0)
    A = np.where(ze < hm, (lnh / np.log(np.maximum(ze, 1.0001 * z0) / z0)) ** 2, 1.0)
    u0 = U_ref * np.log(zz / z0) / np.log(100.0 / z0)
    uin = u0 * (1.0 + A * ds_pot)
    t = np.clip(np.log(zz / hm) / np.log(2.0), 0.0, 1.0)
    u = np.where(ok, (1 - t) * uin + t * uv, np.nan)
    return u.reshape(shp), wv.reshape(shp)
