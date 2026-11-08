"""Гребни, масштаб холма и внутренний слой Jackson–Hunt поверх потенциального решения (SWD2, как panels2d v4).
Jackson & Hunt 1975 QJRMS 101:929; Hunt, Leibovich & Richards 1988 QJRMS 114:1435; Taylor & Lee 1984 (3D-холм)."""
import numpy as np
from scipy.ndimage import gaussian_filter1d
from . import influence as _inf
from .terrain import bg_uniform, wind_of, u_ref_of

KAPPA = 0.4
L_FLAT = 1.0e4  # масштаб длины там, где гребня нет (ровная земля), м


def crests_profile(s, z, ds_min, smooth_m=None):
    """Гребни профиля z(s) на равномерной сетке s: локальные максимумы сглаженного (σ = smooth_m, по умолчанию
    2·ds_min) профиля с перепадом ≥ 2·ds_min над обоими соседними минимумами; L — наветренная полуширина на половине
    высоты над наветренным минимумом. → (zs, список {i, s_c, z_c, L})."""
    h = float(s[1] - s[0])
    sm = 2.0 * ds_min if smooth_m is None else float(smooth_m)
    zs = gaussian_filter1d(z, sm / h, mode="nearest") if sm > 0 else np.asarray(z, float)
    n = zs.size
    d = np.diff(zs)
    nzi = np.nonzero(d)[0]
    sg = np.sign(d[nzi])
    mx = sorted({int(nzi[k]) + 1 for k in range(len(nzi) - 1) if sg[k] > 0 > sg[k + 1]})
    out = []
    thr = 2.0 * ds_min
    for k, im in enumerate(mx):
        lo = mx[k - 1] if k > 0 else 0
        hi = mx[k + 1] if k + 1 < len(mx) else n - 1
        zl = float(zs[lo:im + 1].min())
        zr = float(zs[im:hi + 1].min())
        zc = float(zs[im])
        if zc - max(zl, zr) < thr:
            continue
        zh = zl + 0.5 * (zc - zl)
        seg = zs[lo:im + 1]
        below = np.nonzero(seg < zh)[0]
        if below.size == 0:
            xw = s[lo]
        else:
            b = below[-1]
            a = (zh - seg[b]) / (seg[b + 1] - seg[b])
            xw = s[lo + b] + a * (s[lo + b + 1] - s[lo + b])
        out.append(dict(i=im, s_c=float(s[im]), z_c=zc, L=float(s[im] - xw)))
    return zs, out


def lee_mask_profile(s, zs, crest_list):
    """Отсчёты между гребнем и следующим (по s) минимумом сглаженного профиля."""
    m = np.zeros(s.size, bool)
    for c in crest_list:
        j = c["i"]
        while j < s.size - 1 and zs[j + 1] <= zs[j]:
            j += 1
        m[c["i"]:j + 1] = True
    return m


def _line_profile(terrain, x, y, ex, ey, step):
    """Профиль земли вдоль луча через (x, y): s кратно step, в пределах растра (и точки s = 0)."""
    lo, hi = -np.inf, np.inf
    for p0, d, a0, a1 in ((x, ex, terrain.x[0], terrain.x[-1]), (y, ey, terrain.y[0], terrain.y[-1])):
        if abs(d) > 1e-12:
            t1, t2 = (a0 - p0) / d, (a1 - p0) / d
            lo, hi = max(lo, min(t1, t2)), min(hi, max(t1, t2))
    lo, hi = min(lo, 0.0), max(hi, 0.0)
    k0, k1 = int(np.ceil(lo / step)), int(np.floor(hi / step))
    s = step * np.arange(k0, k1 + 1)
    return s, terrain.height(x + s * ex, y + s * ey)


def hill_length(terrain, x, y, wind_to, smooth_m=None, ds_min=25.0):
    """Ближайший (в любую сторону, v2) гребень по профилю земли вдоль wind_to через (x, y):
    {x_c, y_c, z_c, L} или None. Правило гребней — panels2d.crests (SW6 v4)."""
    w = np.asarray(wind_to, float)
    ex, ey = w / np.hypot(w[0], w[1])
    sm = 2.0 * ds_min if smooth_m is None else float(smooth_m)
    step = min(ds_min, terrain.dx, terrain.dy, sm / 4.0) if sm > 0 else min(ds_min, terrain.dx, terrain.dy)
    s, z = _line_profile(terrain, float(x), float(y), ex, ey, step)
    if s.size < 3:
        return None
    zs, cr = crests_profile(s, z, ds_min, smooth_m)
    if not cr:
        return None
    c = min(cr, key=lambda q: abs(q["s_c"]))
    return dict(x_c=float(x + c["s_c"] * ex), y_c=float(y + c["s_c"] * ey), z_c=c["z_c"], L=c["L"])


def inner_depth(L, z0):
    """l: l·ln(l/z0) = 2κ²·L (Jackson & Hunt 1975), бисекция."""
    L = np.asarray(L, float)
    rhs = 2 * KAPPA ** 2 * L
    lo = np.full(L.shape, z0 * 1.0000001)
    hi = np.maximum(rhs, 10 * z0) + 10 * z0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        f = mid * np.log(mid / z0) - rhs
        lo = np.where(f < 0, mid, lo)
        hi = np.where(f < 0, hi, mid)
    return 0.5 * (lo + hi)


def middle_top(L, z0):
    """h_m = L/√ln(L/z0) (допущение, как panels2d v4)."""
    L = np.asarray(L, float)
    return L / np.sqrt(np.log(np.maximum(L, 3 * z0) / z0))


def velocity_jh(panels, sigma, bg, x, y, z, z0, U_ref=None, extra=None, infl=None):
    """Внутренний слой Jackson–Hunt (контракт SWD2). → (u, v, w)."""
    terrain = panels.terrain
    ex, ey = wind_of(bg, terrain)
    if U_ref is None:
        U_ref, _ = u_ref_of(bg, terrain)
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    z = np.asarray(z, float)
    shp = np.broadcast(x, y, z).shape
    xf, yf, zf = (np.broadcast_to(a, shp).ravel() for a in (x, y, z))
    from .api import solve
    if infl is None:
        infl = _inf.assemble(panels, "auto")
    be = infl.backend
    if extra is None:
        sig_bg, sig_ex = sigma, None
    else:
        sig_bg, _ = solve(panels, bg, None, infl)
        sig_ex = sigma - sig_bg
    key = ("uniform", float(U_ref), round(ex, 12), round(ey, 12))
    if key not in infl._cache:
        infl._cache[key] = solve(panels, bg_uniform(U_ref, (ex, ey)), None, infl)[0]
    sig_u = infl._cache[key]
    bgu = bg_uniform(U_ref, (ex, ey))

    zg = panels.height(xf, yf)
    zagl = zf - zg
    # масштаб холма по колонкам (x, y)
    q = np.round(np.stack([xf, yf], 1), 6)
    uq, inv = np.unique(q, axis=0, return_inverse=True)
    Lq = np.empty(uq.shape[0])
    for i, (qx, qy) in enumerate(uq):
        hl = hill_length(terrain, qx, qy, (ex, ey), ds_min=panels.ds_min)
        Lq[i] = L_FLAT if hl is None else hl["L"]
    L = Lq[inv.ravel()]
    l = inner_depth(L, z0)
    hm = middle_top(L, z0)

    uv, vv, wv = _inf.velocity(panels, sig_bg, bg, xf, yf, zf, None, be)   # потенциал + фон (без extra)
    ok = np.isfinite(uv)
    zz = np.where(ok, np.maximum(zagl, z0), z0)
    ze = np.maximum(zz, l)
    up, vp, _ = _inf.velocity(panels, sig_u, bgu, xf, yf, np.where(ok, zg + ze, zg + 1.0), None, be)
    sp = np.hypot(up, vp)
    dx_ = np.where(sp > 1e-9, up / np.maximum(sp, 1e-12), ex)
    dy_ = np.where(sp > 1e-9, vp / np.maximum(sp, 1e-12), ey)
    dS = sp / U_ref - 1.0
    lnh = np.log(np.maximum(hm, 1.01 * z0) / z0)
    A = np.where(ze < hm, (lnh / np.log(np.maximum(ze, 1.0001 * z0) / z0)) ** 2, 1.0)
    u0 = U_ref * np.log(zz / z0) / np.log(100.0 / z0)
    uin = u0 * (1.0 + A * dS)
    t = np.clip(np.log(zz / hm) / np.log(2.0), 0.0, 1.0)
    uh_in = uin * 1.0
    uh_out = np.hypot(uv, vv)
    # направление вне слоя — потенциальное у точки
    spo = np.maximum(uh_out, 1e-12)
    ox = np.where(uh_out > 1e-9, uv / spo, dx_)
    oy = np.where(uh_out > 1e-9, vv / spo, dy_)
    U = (1 - t) * uh_in * dx_ + t * uh_out * ox
    V = (1 - t) * uh_in * dy_ + t * uh_out * oy
    U = np.where(ok, U, np.nan)
    V = np.where(ok, V, np.nan)
    W = np.where(ok, wv, np.nan)
    if extra is not None:
        P = np.stack([xf, yf, zf], 1)
        eu, ev, ew = _inf.horizontal_extra(extra, P)
        pe = _inf.panel_velocity(panels, sig_ex, P, be)
        U = U + eu + pe[:, 0]
        V = V + ev + pe[:, 1]
        W = W + ew + pe[:, 2]
    return U.reshape(shp), V.reshape(shp), W.reshape(shp)
