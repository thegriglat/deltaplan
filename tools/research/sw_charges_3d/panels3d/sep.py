"""Отрыв по поверхностным линиям тока (SWD2): интегральный турбулентный слой (Карман + вовлечение Хеда, как SW6 v3,
panels2d.bl) вдоль каждой линии тока квазидвумерно по u_s(s); отрыв — первая точка торможения с H ≥ 2,4 или cf ≤ 0.
Head 1958 ARC R&M 3152; Thwaites/Head — формулы формы H1(H) и F(H1) как в panels2d.bl."""
import numpy as np
from . import influence as _inf
from .terrain import wind_of, u_ref_of
from .jh import crests_profile, lee_mask_profile

KAPPA = 0.4
GATE = 0.01          # возмущение u_e, с которого слой считается по Хеду (1 % от u_e на входе)
H_SEP = 2.4          # критерий отрыва Хеда
H1_SPLIT = 5.3
DELTA0_Z0 = 500.0    # δ0 = 500·z0 — глубина слоя ровной земли
H_EDGE = 50.0        # высота над поверхностью, где берётся фон для u_e


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


def _cf2(delta, z0):
    return (KAPPA / np.log(max(delta, 3.0 * z0) / z0)) ** 2


def _equilibrium(z0):
    d0 = DELTA0_Z0 * z0
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


def march_layer(s, ue, du, z0, uref, sep_ok=None):
    """Слой вдоль линии: s (n), u_e, du_e/ds → dict(theta, delta, H, cf, i_sep). Отрыв в i_sep, если задан sep_ok —
    только где sep_ok[i]."""
    n = s.size
    th0, H10, H0 = _equilibrium(z0)
    H = np.full(n, np.nan)
    cf = np.full(n, np.nan)
    theta = np.full(n, np.nan)
    umin = 1e-3 * max(uref, 1e-9)

    def rhs(th, H1, u, dudx):
        u = max(u, umin)
        Hh = _H_of_H1(H1)
        d = th * (H1 + Hh)
        c2 = _cf2(d, z0)
        dth = c2 - (Hh + 2.0) * th * dudx / u
        dH1 = (_F(H1) - H1 * dth - th * H1 * dudx / u) / th
        return dth, dH1

    th, H1 = th0, H10
    i_sep = -1
    free = False
    for i in range(n):
        if not free and abs(ue[i] / ue[0] - 1.0) > GATE:
            free = True
        if i > 0 and free:
            nsub = max(1, int(np.ceil((s[i] - s[i - 1]) / (15.0 * th0))))
            for k in range(nsub):
                a0, a1 = k / nsub, (k + 1) / nsub
                ds = (s[i] - s[i - 1]) / nsub
                ua, ub = ue[i - 1] + a0 * (ue[i] - ue[i - 1]), ue[i - 1] + a1 * (ue[i] - ue[i - 1])
                da, db = du[i - 1] + a0 * (du[i] - du[i - 1]), du[i - 1] + a1 * (du[i] - du[i - 1])
                k1 = rhs(th, H1, ua, da)
                k2 = rhs(th + 0.5 * ds * k1[0], H1 + 0.5 * ds * k1[1], 0.5 * (ua + ub), 0.5 * (da + db))
                th = max(th + ds * k2[0], 1e-3 * th0)
                H1 = min(max(H1 + ds * k2[1], 3.3 + 1e-3), 80.0)
        Hh = _H_of_H1(H1)
        d = th * (H1 + Hh)
        theta[i], H[i], cf[i] = th, Hh, 2 * _cf2(d, z0)
        if (((Hh >= H_SEP and du[i] < 0) or cf[i] <= 0 or ue[i] <= 0)
                and (sep_ok is None or sep_ok[i])):
            i_sep = i
            break
    return dict(theta=theta, H=H, cf=cf, i_sep=i_sep)


def _nodal_field(panels, ut):
    """Узловые значения (area-взвешенное среднее по смежным панелям)."""
    K = panels.nodes.shape[0]
    w = np.zeros(K)
    acc = np.zeros((K, 3))
    for k in range(3):
        np.add.at(w, panels.tris[:, k], panels.area)
        np.add.at(acc, panels.tris[:, k], panels.area[:, None] * ut)
    return acc / w[:, None]


def _trace(panels, ut_node, seeds, wind, rect, ucut, max_steps, aux_node=None):
    """Линии тока из seeds (M, 2) по полю ut_node; возвращает массивы (x, y, z, s, speed, ax, ay, az) по линиям,
    (ax, ay, az) — вектор aux_node (по умолчанию то же поле) в точке."""
    if aux_node is None:
        aux_node = ut_node
    M = seeds.shape[0]
    pos = seeds.copy()
    act = np.ones(M, bool)
    recs = [[] for _ in range(M)]
    s_acc = np.zeros(M)
    prev = None

    aux = [None]

    def field(p):
        t, l1, l2, l3 = panels.locate(p[:, 0], p[:, 1])
        tt = np.maximum(t, 0)
        tr = panels.tris[tt]
        f = l1[:, None] * ut_node[tr[:, 0]] + l2[:, None] * ut_node[tr[:, 1]] + l3[:, None] * ut_node[tr[:, 2]]
        fa = l1[:, None] * aux_node[tr[:, 0]] + l2[:, None] * aux_node[tr[:, 1]] + l3[:, None] * aux_node[tr[:, 2]]
        aux[0] = fa
        z = l1 * panels.v[tt, 0, 2] + l2 * panels.v[tt, 1, 2] + l3 * panels.v[tt, 2, 2]
        return t, f, z

    x0, y0, x1, y1 = rect
    for it in range(max_steps):
        idx = np.nonzero(act)[0]
        if idx.size == 0:
            break
        p = pos[idx]
        t, f, z = field(p)
        fa0 = aux[0]
        inside = (t >= 0) & (p[:, 0] >= x0) & (p[:, 0] <= x1) & (p[:, 1] >= y0) & (p[:, 1] <= y1)
        sp = np.linalg.norm(f, axis=1)
        for q, i in enumerate(idx):
            if inside[q]:
                recs[i].append((p[q, 0], p[q, 1], z[q], s_acc[i], sp[q], fa0[q, 0], fa0[q, 1], fa0[q, 2]))
        stop = ~inside | (sp < ucut)
        h = 0.5 * panels.ds[np.maximum(t, 0)]
        tau = f / np.maximum(sp, 1e-300)[:, None]
        pm = p + 0.5 * h[:, None] * tau[:, :2]
        t2, f2, z2 = field(pm)
        sp2 = np.linalg.norm(f2, axis=1)
        ok2 = (t2 >= 0) & (sp2 >= ucut)
        tau2 = np.where(ok2[:, None], f2 / np.maximum(sp2, 1e-300)[:, None], tau)
        pn = p + h[:, None] * tau2[:, :2]
        zn = panels.height(pn[:, 0], pn[:, 1])
        dl = np.sqrt(np.sum((pn - p) ** 2, axis=1) + (zn - z) ** 2)
        tiny = h * np.hypot(tau2[:, 0], tau2[:, 1]) < 1e-3 * panels.ds_min
        stop |= tiny
        keep = ~stop
        s_acc[idx[keep]] += dl[keep]
        pos[idx[keep]] = pn[keep]
        act[idx[stop]] = False
    return [np.array(r) if len(r) else np.zeros((0, 8)) for r in recs]


def _sigma_bg(panels, bg):
    """σ для одного bg (без extra): `Influence` берётся из panels._infl_obj (кладёт sim3d или первый вызов)."""
    infl = getattr(panels, "_infl_obj", None)
    if infl is None:
        infl = panels._infl_obj = _inf.assemble(panels, "auto")
    if ("bg", bg) not in infl._cache:
        from .api import solve
        infl._cache[("bg", bg)] = solve(panels, bg, None, infl)[0]
    return infl._cache[("bg", bg)]


def _reattach_index(s, us, ue, i, n2):
    """Присоединение после отрыва в i: первая точка j > i, где u_s > 0 на ≥ n2 отсчётов подряд, после того как u_s
    было ≤ 0 (обратное течение); если u_s не менялось на ≤ 0 — первая точка, где u_s растёт на ≥ n2 отсчётов подряд
    (ускорение, неблагоприятного градиента нет). −1 — линия кончилась."""
    n = s.size
    neg = np.nonzero(us[i:] <= 0)[0]
    if neg.size:
        j0 = i + int(neg[0])
        ok = us > 0
    else:
        j0 = i
        ok = np.concatenate([[False], np.diff(us) > 0])
    for j in range(j0 + 1, n - n2 + 1):
        if ok[j:j + n2].all():
            return j
    return -1


def separation3d(panels, sigma, bg, z0, extra=None, method="head", lee_only=True, seed_dy=None, restart=True,
                 streamlines_from="bg"):
    """Линии отрыва по поверхностным линиям тока (контракт SWD2 v3). → {points, lines, rejected}.
    `streamlines_from="bg"` — линии тока по решению для одного bg (σ_bg), u_s — полная касательная скорость (с extra)
    вдоль линии со знаком; `"full"` — линии по полному решению (v2). `restart` — после отрыва слой стартует заново
    с присоединения (`_reattach_index`), возможны несколько отрывов на линии."""
    if method != "head":
        raise ValueError("method='head'")
    if streamlines_from not in ("bg", "full"):
        raise ValueError("streamlines_from: bg | full")
    terrain = panels.terrain
    dsm = panels.ds_min
    if seed_dy is None:
        seed_dy = 2.0 * dsm
    ex, ey = wind_of(bg, terrain)
    U_ref, _ = u_ref_of(bg, terrain)
    ut = _inf.tangent_velocity(panels, sigma, bg, extra)
    ut_node = _nodal_field(panels, ut)
    if streamlines_from == "bg" and extra is not None:
        ut_tr = _nodal_field(panels, _inf.tangent_velocity(panels, _sigma_bg(panels, bg), bg, None))
    else:
        ut_tr = ut_node
    x0, x1, y0, y1 = terrain.x[0], terrain.x[-1], terrain.y[0], terrain.y[-1]
    rect = (x0, y0, x1, y1)
    px, py = -ey, ex
    cx, cy = terrain.cx, terrain.cy
    # затравки: на поперечной линии через центр, проекция на наветренный край растра
    corners = np.array([[x0, y0], [x1, y0], [x0, y1], [x1, y1]])
    qs = (corners[:, 0] - cx) * px + (corners[:, 1] - cy) * py
    nq = int(np.floor(max(abs(qs.min()), abs(qs.max())) / seed_dy))
    qv = seed_dy * np.arange(-nq, nq + 1)
    seeds, sq = [], []
    for q in qv:
        # луч x = c + q·p − t·w; наибольшее t внутри прямоугольника — вход
        lo, hi = -np.inf, np.inf
        for c0, a0, a1, d in ((cx + q * px, x0, x1, -ex), (cy + q * py, y0, y1, -ey)):
            if abs(d) > 1e-12:
                t1, t2 = (a0 - c0) / d, (a1 - c0) / d
                lo, hi = max(lo, min(t1, t2)), min(hi, max(t1, t2))
            elif not (a0 <= c0 <= a1):
                lo, hi = 1.0, 0.0
        if hi > lo and hi > 0:
            e = 1e-6 * (x1 - x0)
            t = hi - e
            seeds.append((cx + q * px - t * ex, cy + q * py - t * ey))
            sq.append(q)
    seeds = np.array(seeds)
    diag = float(np.hypot(x1 - x0, y1 - y0))
    max_steps = int(2.0 * diag / (0.5 * float(panels.ds.min()))) + 100
    recs = _trace(panels, ut_tr, seeds, (ex, ey), rect, 0.02 * max(U_ref, 1e-9), max_steps, ut_node)

    keys = ("x", "y", "z", "streamline", "s_sep", "u_s", "value", "method", "k", "reattach")
    pts = {k: [] for k in keys}
    rej = {k: [] for k in keys}

    def put(d, k, kk, s, xx, yy, zz, us, Hv, rea=None):
        for key, val in zip(keys, (xx, yy, zz, k, s, us, Hv, "head", kk, rea)):
            d[key].append(val)

    for k, r in enumerate(recs):
        if r.shape[0] < 4:
            continue
        # дублирующиеся точки убрать, равномерный ряд по s с шагом ds_min
        s_raw = r[:, 3]
        good = np.concatenate([[True], np.diff(s_raw) > 1e-9])
        r = r[good]
        s_raw = r[:, 3]
        n = max(int(s_raw[-1] / dsm), 3)
        s = np.linspace(0.0, s_raw[-1], n + 1)
        X = np.interp(s, s_raw, r[:, 0])
        Y = np.interp(s, s_raw, r[:, 1])
        Z = np.interp(s, s_raw, r[:, 2])
        tx = np.gradient(X, s)
        ty = np.gradient(Y, s)
        tz = np.gradient(Z, s)
        tn = np.sqrt(tx * tx + ty * ty + tz * tz)
        tx, ty, tz = tx / tn, ty / tn, tz / tn
        # u_s: касательная скорость полного решения вдоль линии (со знаком; при "full" и extra=None — |ut|)
        A3 = np.stack([np.interp(s, s_raw, r[:, 5 + c]) for c in range(3)], 1)
        us = A3[:, 0] * tx + A3[:, 1] * ty + A3[:, 2] * tz
        tt, l1, l2, l3 = panels.locate(X, Y)
        nn = panels.n[np.maximum(tt, 0)]
        b0 = bg(X, Y, Z)
        b1 = bg(X + nn[:, 0] * H_EDGE, Y + nn[:, 1] * H_EDGE, Z + nn[:, 2] * H_EDGE)
        d0 = b0[0] * tx + b0[1] * ty + b0[2] * tz
        d1 = b1[0] * tx + b1[1] * ty + b1[2] * tz
        ue = us + (d1 - d0)
        du = np.gradient(ue, s)
        dp = np.concatenate([[du[0]], du, [du[-1]]])
        du = (dp[:-2] + dp[1:-1] + dp[2:]) / 3.0
        sep_ok = None
        if lee_only:
            zsm, cr = crests_profile(s, Z, dsm)
            sep_ok = lee_mask_profile(s, zsm, cr)
        n2 = max(2, int(np.ceil(2.0 * dsm / max(float(s[1] - s[0]), 1e-9))))
        i0, kk = 0, 0
        while i0 < s.size - 3:
            sl = slice(i0, None)
            ok_sl = None if sep_ok is None else sep_ok[sl]
            bl = march_layer(s[sl], ue[sl], du[sl], z0, U_ref, None)
            i = bl["i_sep"]
            if i >= 0 and ok_sl is not None and not ok_sl[i]:
                put(rej, k, kk, *_where(s[sl], X[sl], Y[sl], Z[sl], us[sl], bl, i))
                bl = march_layer(s[sl], ue[sl], du[sl], z0, U_ref, ok_sl)
                i = bl["i_sep"]
            if i < 0:
                break
            w = _where(s[sl], X[sl], Y[sl], Z[sl], us[sl], bl, i)
            ig = i0 + i
            j = _reattach_index(s, us, ue, ig, n2) if restart else -1
            rea = None if j < 0 else dict(x=float(X[j]), y=float(Y[j]), z=float(Z[j]))
            put(pts, k, kk, *w, rea)
            kk += 1
            if j < 0:
                break
            i0 = j
    lines = []
    sk, kv = np.array(pts["streamline"], int), np.array(pts["k"], int)
    xyz = np.array([pts["x"], pts["y"], pts["z"]]).T
    for level in sorted(set(kv.tolist())):
        sel = np.nonzero(kv == level)[0]
        sel = sel[np.argsort(sk[sel])]
        run = []
        for q in sel:
            if run and sk[q] != sk[run[-1]] + 1:
                lines.append(xyz[run])
                run = []
            run.append(q)
        if run:
            lines.append(xyz[run])
    def pack(d):
        return {k: (np.array(v) if k not in ("method", "reattach") else list(v)) for k, v in d.items()}
    return dict(points=pack(pts), lines=lines, rejected=pack(rej))


def _where(s, X, Y, Z, us, bl, i):
    """(s_sep, x, y, z, u_s, H) в точке отрыва с интерполяцией по H = H_SEP между i−1 и i."""
    H = bl["H"]
    if i > 0 and np.isfinite(H[i - 1]) and H[i] >= H_SEP > H[i - 1]:
        a = (H_SEP - H[i - 1]) / (H[i] - H[i - 1])
    else:
        a = 1.0
    i0 = max(i - 1, 0)
    f = lambda v: float(v[i0] + a * (v[i] - v[i0]))
    return f(s), f(X), f(Y), f(Z), f(us), float(H[i])
