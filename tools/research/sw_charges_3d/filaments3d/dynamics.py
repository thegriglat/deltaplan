"""Шаг нитей: RK2, растяжение, дробление/слияние, перезамыкание, ядро, затухание, земля; сход (shed)."""
from __future__ import annotations

import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree

from .core import Filaments, induced

DEFAULTS = dict(l_max=None, l_min=None, r_rec=None, nu_t=0.0, tau_s=None, gamma_min=0.0, bounds=None, l_age=None, t=0.0, bs_method="direct", theta=0.5)
COS_REC = -0.5
MAX_SPLIT_PASSES = 10
MIN_SEGS_PER_FILAMENT = 4  # слияние не сжимает нить меньше этого числа отрезков


def _ground_fn(ground):
    if ground is None:
        return lambda x, y: np.zeros_like(np.asarray(x, float))
    return lambda x, y: np.broadcast_to(np.asarray(ground(x, y), float), np.shape(x)).copy()


def _flow_vel(flow, X):
    u, v, w = flow(X[:, 0], X[:, 1], X[:, 2])
    n = len(X)
    return np.stack([np.broadcast_to(np.asarray(c, float), (n,)) for c in (u, v, w)], 1)


def _ground_normal(g, x, y, h=0.5):
    gx = (g(x + h, y) - g(x - h, y)) / (2 * h)
    gy = (g(x, y + h) - g(x, y - h)) / (2 * h)
    n = np.stack([-gx, -gy, np.ones_like(gx)], 1)
    return n / np.linalg.norm(n, axis=1)[:, None]


def _velocity(f, X, flow, g, method="direct", theta=0.5):
    ff = Filaments(X, f.seg, f.gamma, f.core, f.anchored, f.fid)
    V = _flow_vel(flow, X) + np.stack(induced(ff, X[:, 0], X[:, 1], X[:, 2], method=method, theta=theta), 1)
    if f.anchored.any():
        a = f.anchored
        n = _ground_normal(g, X[a, 0], X[a, 1])
        V[a] -= (V[a] * n).sum(1)[:, None] * n
    return V


def _snap(X, anchored, g):
    if anchored.any():
        X[anchored, 2] = g(X[anchored, 0], X[anchored, 1])
    return X


def relabel(f):
    """fid — связные компоненты графа; убирает узлы без отрезков."""
    if len(f.seg) == 0:
        return Filaments(np.zeros((0, 3)), np.zeros((0, 2), int), [], [], np.zeros(0, bool), [], f.stats)
    used = np.unique(f.seg)
    remap = np.full(len(f.x), -1)
    remap[used] = np.arange(len(used))
    seg = remap[f.seg]
    m = len(used)
    G = coo_matrix((np.ones(len(seg)), (seg[:, 0], seg[:, 1])), shape=(m, m))
    _, lab = connected_components(G, directed=False)
    _, fid = np.unique(lab[seg[:, 0]], return_inverse=True)
    return Filaments(f.x[used], seg, f.gamma, f.core, f.anchored[used], fid, f.stats, f.t_birth)


# ---------- топология ----------
def _split(f, l_max, l_age=None, t=0.0):
    for _ in range(MAX_SPLIT_PASSES):
        d = f.x[f.seg[:, 1]] - f.x[f.seg[:, 0]]
        L = np.linalg.norm(d, axis=1)
        lim = (2 * f.core) if l_max is None else np.full(len(L), float(l_max))
        if l_age:
            lim = np.maximum(lim, l_age * (t - f.t_birth))
        idx = np.nonzero(L > lim)[0]
        if len(idx) == 0:
            break
        m0 = len(f.x)
        mid = 0.5 * (f.x[f.seg[idx, 0]] + f.x[f.seg[idx, 1]])
        newn = m0 + np.arange(len(idx))
        b_old = f.seg[idx, 1].copy()
        f.x = np.vstack([f.x, mid])
        f.anchored = np.concatenate([f.anchored, np.zeros(len(idx), bool)])
        f.seg[idx, 1] = newn
        f.seg = np.vstack([f.seg, np.stack([newn, b_old], 1)])
        f.gamma = np.concatenate([f.gamma, f.gamma[idx]])
        f.core = np.concatenate([f.core, f.core[idx]])
        f.fid = np.concatenate([f.fid, f.fid[idx]])
        f.t_birth = np.concatenate([f.t_birth, f.t_birth[idx]])
        f.stats["split"] += len(idx)
    return f


def _merge(f, l_min, lim=None):
    d = f.x[f.seg[:, 1]] - f.x[f.seg[:, 0]]
    L = np.linalg.norm(d, axis=1)
    if lim is None:
        lim = (0.5 * f.core) if l_min is None else np.full(len(L), float(l_min))
    cand = np.nonzero(L < lim)[0]
    if len(cand) == 0:
        return f
    cand = cand[np.argsort(L[cand])]
    count = np.bincount(f.fid)
    touched = np.zeros(len(f.x), bool)
    drop = np.zeros(len(f.seg), bool)
    X = f.x.copy()
    rep = np.arange(len(f.x))  # b -> a
    for i in cand:
        a, b = f.seg[i]
        if touched[a] or touched[b] or a == b:
            continue
        if f.anchored[a] and f.anchored[b]:
            continue
        if count[f.fid[i]] <= MIN_SEGS_PER_FILAMENT:
            continue
        if f.anchored[b]:
            a, b = b, a  # остаётся якорный
        elif not f.anchored[a]:
            X[a] = 0.5 * (X[a] + X[b])
        touched[a] = touched[b] = True
        rep[b] = a
        drop[i] = True
        count[f.fid[i]] -= 1
        f.stats["merge"] += 1
    if not drop.any():
        return f
    seg = rep[f.seg]
    drop |= seg[:, 0] == seg[:, 1]
    keep = ~drop
    f.x, f.seg = X, seg[keep]
    f.gamma, f.core, f.fid, f.t_birth = f.gamma[keep], f.core[keep], f.fid[keep], f.t_birth[keep]
    return f


def _reconnect(f, r_rec):
    k = len(f.seg)
    if k < 2:
        return f
    # единая ориентация: Γ > 0 (разворот отрезка с отрицательной Γ не меняет физику)
    neg = f.gamma < 0
    f.seg[neg] = f.seg[neg][:, ::-1]
    f.gamma = np.abs(f.gamma)
    a, b = f.x[f.seg[:, 0]], f.x[f.seg[:, 1]]
    d = b - a
    L = np.linalg.norm(d, axis=1)
    t = d / np.maximum(L, 1e-300)[:, None]
    mid = 0.5 * (a + b)
    rmax = (f.core.max() if r_rec is None else float(r_rec))
    pairs = cKDTree(mid).query_pairs(rmax, output_type="ndarray")
    if len(pairs) == 0:
        return f
    i, j = pairs[:, 0], pairs[:, 1]
    dist = np.linalg.norm(mid[i] - mid[j], axis=1)
    lim = (0.5 * (f.core[i] + f.core[j])) if r_rec is None else np.full(len(i), float(r_rec))
    cosang = (t[i] * t[j]).sum(1)
    si, sj = f.seg[i], f.seg[j]
    share = (si[:, :, None] == sj[:, None, :]).any(axis=(1, 2))
    ok = (dist < lim) & (cosang < COS_REC) & ~share & (f.gamma[i] > 0) & (f.gamma[j] > 0) & (L[i] > 0) & (L[j] > 0)
    ci = np.nonzero(ok)[0]
    if len(ci) == 0:
        return f
    ci = ci[np.argsort(dist[ci])]
    used = np.zeros(k, bool)
    new_seg, new_g, new_c, new_f, new_t = [], [], [], [], []
    for p in ci:
        s1, s2 = i[p], j[p]
        if used[s1] or used[s2]:
            continue
        used[s1] = used[s2] = True
        a1, b1 = f.seg[s1]
        a2, b2 = f.seg[s2]
        g1, g2 = f.gamma[s1], f.gamma[s2]
        if g1 > g2:      # s1 делится: остаток (a1→b1) и часть g2, которая обменивается
            f.gamma[s1] = g1 - g2
            new_seg.append((a1, b2)); new_g.append(g2); new_c.append(f.core[s1]); new_f.append(f.fid[s1]); new_t.append(min(f.t_birth[s1], f.t_birth[s2]))
            f.seg[s2] = (a2, b1)
        elif g2 > g1:
            f.gamma[s2] = g2 - g1
            new_seg.append((a2, b1)); new_g.append(g1); new_c.append(f.core[s2]); new_f.append(f.fid[s2]); new_t.append(min(f.t_birth[s1], f.t_birth[s2]))
            f.seg[s1] = (a1, b2)
        else:
            f.seg[s1] = (a1, b2)
            f.seg[s2] = (a2, b1)
        f.stats["reconnect"] += 1
    if new_seg:
        f.seg = np.vstack([f.seg, np.array(new_seg, int)])
        f.gamma = np.concatenate([f.gamma, new_g])
        f.core = np.concatenate([f.core, new_c])
        f.fid = np.concatenate([f.fid, new_f])
        f.t_birth = np.concatenate([f.t_birth, new_t])
    return f


def _ground_and_removal(f, g, gamma_min, bounds):
    f = relabel(f)
    if len(f.seg) == 0:
        return f
    nf = f.fid.max() + 1
    node_fid = np.zeros(len(f.x), int)
    node_fid[f.seg[:, 0]] = f.fid
    node_fid[f.seg[:, 1]] = f.fid
    zg = g(f.x[:, 0], f.x[:, 1])
    below = (f.x[:, 2] < zg - 1e-9) & ~f.anchored
    frac = np.bincount(node_fid, below, nf) / np.bincount(node_fid, minlength=nf)
    kill = frac > 0.5
    gmax = np.zeros(nf)
    np.maximum.at(gmax, f.fid, np.abs(f.gamma))
    if gamma_min:
        kill |= gmax < gamma_min
    if bounds is not None:
        xmin, xmax, ymin, ymax, zmax = bounds
        out = ((f.x[:, 0] < xmin) | (f.x[:, 0] > xmax) | (f.x[:, 1] < ymin) | (f.x[:, 1] > ymax) | (f.x[:, 2] > zmax))
        kill |= np.bincount(node_fid, out, nf) == np.bincount(node_fid, minlength=nf)
    if kill.any():
        f.stats["removed"] += int(kill.sum())
        keep = ~kill[f.fid]
        f.seg, f.gamma, f.core, f.fid, f.t_birth = f.seg[keep], f.gamma[keep], f.core[keep], f.fid[keep], f.t_birth[keep]
        f = relabel(f)
        if len(f.seg) == 0:
            return f
        zg = g(f.x[:, 0], f.x[:, 1])
    low = (f.x[:, 2] < zg + 0.0) & ~f.anchored
    # поднимаем неякорные узлы под землёй (и ниже ground + core/2 — только под землёй)
    cn = np.zeros(len(f.x))
    cn[f.seg[:, 0]] = f.core
    cn[f.seg[:, 1]] = f.core
    sub = (f.x[:, 2] < zg) & ~f.anchored
    f.x[sub, 2] = zg[sub] + 0.5 * cn[sub]
    f.stats["lifted"] += int(sub.sum())
    return f


def step(f, flow, dt, ground, params=None):
    """Шаг dt: RK2 по flow + самоиндукции, затем топология, ядро, затухание, земля. Новый Filaments."""
    p = dict(DEFAULTS)
    p.update(params or {})
    g = _ground_fn(ground)
    f = f.copy()
    if len(f.seg) == 0:
        return f
    X0 = f.x
    k1 = _velocity(f, X0, flow, g, p["bs_method"], p["theta"])
    Xm = _snap(X0 + 0.5 * dt * k1, f.anchored, g)
    k2 = _velocity(f, Xm, flow, g, p["bs_method"], p["theta"])
    f.x = _snap(X0 + dt * k2, f.anchored, g)
    f = relabel(f)
    f = _split(f, p["l_max"], p["l_age"], p["t"])
    f = _merge(f, p["l_min"])
    f = _reconnect(f, p["r_rec"])
    f.core = np.sqrt(f.core ** 2 + 4.0 * p["nu_t"] * dt)
    if p["tau_s"] is not None:
        f.gamma = f.gamma * np.exp(-dt / p["tau_s"])
    return _ground_and_removal(f, g, p["gamma_min"], p["bounds"])


def shed(f, line_pts, u_s, dt, core, normals, t=0.0):
    """Добавляет нить схода по line_pts (M,3); u_s (M,3) — скорость слоя в узлах; normals (M,3) — нормали земли.
    Γ отрезка = ½ū²·dt (ū — среднее модулей на концах), направление ω — n × û_t (знак Γ — по a→b).
    Концы якорные; разность Γ соседних отрезков в промежуточном узле уходит ножкой длиной core
    в якорный узел в исходной точке линии (сам узел поднят на core по n; ∇·ω = 0). Линия — на земле."""
    P = np.asarray(line_pts, float).reshape(-1, 3)
    m = len(P)
    f = Filaments() if f is None else f.copy()
    if m < 2:
        return f
    U = np.asarray(u_s, float).reshape(m, 3)
    N = np.asarray(normals, float).reshape(m, 3)
    N = N / np.linalg.norm(N, axis=1)[:, None]
    sp = np.linalg.norm(U, axis=1)
    ut = U / np.maximum(sp, 1e-300)[:, None]
    om = np.cross(N, ut)
    ubar = 0.5 * (sp[:-1] + sp[1:])
    tseg = P[1:] - P[:-1]
    omseg = om[:-1] + om[1:]
    sgn = np.where((omseg * tseg).sum(1) < 0, -1.0, 1.0)
    G = sgn * 0.5 * ubar ** 2 * dt
    nodes = list(P)
    anc = [True] + [False] * (m - 2) + [True]
    seg = [(i, i + 1) for i in range(m - 1)]
    gam = list(G)
    for k in range(1, m - 1):
        dG = G[k - 1] - G[k]  # избыток входящей
        if abs(dG) > 1e-14 * max(abs(G[k - 1]), abs(G[k]), 1e-300):
            # узел поднят на core по n, ножка уходит в якорь в исходной точке линии (на земле): ножка длиной core,
            # якорь не уходит под землю и не схлопывается проекцией на ground
            nodes[k] = P[k] + core * N[k]
            nodes.append(P[k])
            anc.append(True)
            seg.append((k, len(nodes) - 1))
            gam.append(dG)
    new = Filaments(np.array(nodes), np.array(seg, int), np.array(gam), np.full(len(seg), float(core)),
                    np.array(anc, bool), np.zeros(len(seg), int))
    m0 = len(f.x)
    out = Filaments(np.vstack([f.x, new.x]), np.vstack([f.seg, new.seg + m0]), np.concatenate([f.gamma, new.gamma]),
                    np.concatenate([f.core, new.core]), np.concatenate([f.anchored, new.anchored]),
                    np.zeros(len(f.seg) + len(new.seg), int), f.stats,
                    np.concatenate([f.t_birth, np.full(len(new.seg), float(t))]))
    return relabel(out)
