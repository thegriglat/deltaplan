"""Триангуляция рельефа по дереву квадрантов (без висячих узлов, баланс 2:1) для panels3d (SWD2)."""
from dataclasses import dataclass
import numpy as np


@dataclass
class Panels:
    v: np.ndarray        # (N, 3, 3) вершины
    c: np.ndarray        # (N, 3) центроиды
    n: np.ndarray        # (N, 3) единичная нормаль в воздух
    area: np.ndarray     # (N)
    ds: np.ndarray       # (N) √area
    ds_min: float
    terrain: object
    nodes: np.ndarray = None   # (K, 3) узлы
    tris: np.ndarray = None    # (N, 3) индексы узлов
    _finder: object = None
    _geom: dict = None

    @property
    def N(self):
        return self.v.shape[0]

    def locate(self, x, y):
        """Треугольник и барицентрические координаты (по проекции на плоскость x–y): (t, l1, l2, l3); t = −1 вне."""
        from matplotlib.tri import Triangulation
        x = np.asarray(x, float).ravel()
        y = np.asarray(y, float).ravel()
        if self._finder is None:
            tr = Triangulation(self.nodes[:, 0], self.nodes[:, 1], self.tris)
            self._finder = tr.get_trifinder()
        t = np.asarray(self._finder(x, y))
        tt = np.maximum(t, 0)
        A, B, C = self.v[tt, 0], self.v[tt, 1], self.v[tt, 2]
        det = (B[:, 1] - C[:, 1]) * (A[:, 0] - C[:, 0]) + (C[:, 0] - B[:, 0]) * (A[:, 1] - C[:, 1])
        l1 = ((B[:, 1] - C[:, 1]) * (x - C[:, 0]) + (C[:, 0] - B[:, 0]) * (y - C[:, 1])) / det
        l2 = ((C[:, 1] - A[:, 1]) * (x - C[:, 0]) + (A[:, 0] - C[:, 0]) * (y - C[:, 1])) / det
        return t, l1, l2, 1.0 - l1 - l2

    def height(self, x, y):
        """Высота поверхности панелей (кусочно-линейная по треугольникам); вне треугольников — рельеф."""
        x = np.asarray(x, float)
        y = np.asarray(y, float)
        t, l1, l2, l3 = self.locate(x, y)
        out = np.asarray(self.terrain.height(x.ravel(), y.ravel()), float).copy()
        ok = t >= 0
        if np.any(ok):
            tt = t[ok]
            out[ok] = l1[ok] * self.v[tt, 0, 2] + l2[ok] * self.v[tt, 1, 2] + l3[ok] * self.v[tt, 2, 2]
        return out.reshape(x.shape)


def _enc(l, i, j):
    return (l.astype(np.int64) << 40) | (i.astype(np.int64) << 20) | j.astype(np.int64)


def _dist_to_focus(x0, y0, x1, y1, focus, rect):
    """Расстояние от прямоугольника [x0,x1]×[y0,y1] до ближайшей точки focus (M,2) или до прямоугольника rect."""
    if focus is not None:
        fx, fy = focus[:, 0][None], focus[:, 1][None]
        dx = np.maximum(np.maximum(x0[:, None] - fx, fx - x1[:, None]), 0.0)
        dy = np.maximum(np.maximum(y0[:, None] - fy, fy - y1[:, None]), 0.0)
        return np.sqrt(dx * dx + dy * dy).min(axis=1)
    rx0, ry0, rx1, ry1 = rect
    dx = np.maximum(np.maximum(x0 - rx1, rx0 - x1), 0.0)
    dy = np.maximum(np.maximum(y0 - ry1, ry0 - y1), 0.0)
    return np.hypot(dx, dy)


def build_panels(terrain, focus=None, ds_min=25.0, ds_max=1000.0, growth=1.2, focus_r=None):
    """Дерево квадрантов на квадрате со стороной ds_min·2^k ≥ 2·far_m (центр — центр растра), так что листья у
    фокусов ровно ds_min. Лист делится, пока его сторона больше h(d), d — расстояние от листа до ближайшей точки
    focus (или до растра, если focus=None): h = ds_min при d ≤ focus_r, иначе min(ds_max, ds_min + (growth−1)·d).
    Затем баланс 2:1, треугольники: лист без висячих узлов — 2 треугольника, иначе веер из центра листа."""
    ds_min = float(ds_min)
    if focus_r is None:
        focus_r = 10.0 * ds_min
    far = terrain.far_m
    k = max(1, int(np.ceil(np.log2(2 * far / ds_min))))
    side = ds_min * 2 ** k
    ox, oy = terrain.cx - side / 2, terrain.cy - side / 2
    fc = None if focus is None else np.atleast_2d(np.asarray(focus, float))
    rect = (terrain.x[0], terrain.y[0], terrain.x[-1], terrain.y[-1])

    def target(s, d):
        h = np.where(d <= focus_r, ds_min, np.minimum(ds_max, ds_min + (growth - 1.0) * d))
        return np.maximum(h, ds_min)

    # --- уровни: l = 0 корень (сторона side), l = k сторона ds_min ---
    L = np.zeros(1, np.int64)
    I = np.zeros(1, np.int64)
    J = np.zeros(1, np.int64)
    while True:
        s = side / 2.0 ** L
        x0, y0 = ox + I * s, oy + J * s
        d = _dist_to_focus(x0, y0, x0 + s, y0 + s, fc, rect)
        sp = (s > target(s, d) * (1 + 1e-9)) & (L < k)
        if not sp.any():
            break
        keep = ~sp
        Ls, Is, Js = L[sp], I[sp], J[sp]
        cl = np.concatenate([np.repeat(Ls + 1, 4)])
        ci = np.concatenate([(2 * Is[:, None] + np.array([0, 1, 0, 1])).ravel()])
        cj = np.concatenate([(2 * Js[:, None] + np.array([0, 0, 1, 1])).ravel()])
        L = np.concatenate([L[keep], cl])
        I = np.concatenate([I[keep], ci])
        J = np.concatenate([J[keep], cj])

    def find(lv, ii, jj, keys_sorted):
        """Уровень листа, покрывающего ячейку (lv, ii, jj) (того же или более крупного), иначе −1 (разбита или вне)."""
        res = np.full(lv.shape, -1, np.int64)
        inside = (ii >= 0) & (jj >= 0) & (ii < 2 ** lv) & (jj < 2 ** lv)
        for m in range(int(lv.max()) + 1 if lv.size else 0):
            sel = inside & (res < 0) & (m <= lv)
            if not sel.any():
                continue
            sh = lv[sel] - m
            q = _enc(np.full(sh.shape, m), ii[sel] >> sh, jj[sel] >> sh)
            pos = np.searchsorted(keys_sorted, q)
            pos = np.minimum(pos, keys_sorted.size - 1)
            hit = keys_sorted[pos] == q
            idx = np.nonzero(sel)[0][hit]
            res[idx] = m
        return res, inside

    D = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    # --- баланс 2:1 ---
    for _ in range(64):
        keys = np.sort(_enc(L, I, J))
        split = np.zeros(0, np.int64)
        bad = []
        for di, dj in D:
            lv, inside = find(L, I + di, J + dj, keys)
            # сосед покрыт более крупным листом на ≥ 2 уровня крупнее — разбить его
            need = inside & (lv >= 0) & (lv <= L - 2)
            if need.any():
                sh = L[need] - lv[need]
                bad.append(_enc(lv[need], (I[need] + di) >> sh, (J[need] + dj) >> sh))
        if not bad:
            break
        bad = np.unique(np.concatenate(bad))
        kk = _enc(L, I, J)
        sp = np.isin(kk, bad)
        Ls, Is, Js = L[sp], I[sp], J[sp]
        L = np.concatenate([L[~sp], np.repeat(Ls + 1, 4)])
        I = np.concatenate([I[~sp], (2 * Is[:, None] + np.array([0, 1, 0, 1])).ravel()])
        J = np.concatenate([J[~sp], (2 * Js[:, None] + np.array([0, 0, 1, 1])).ravel()])
    else:
        raise RuntimeError("баланс 2:1 не сошёлся")

    # --- треугольники; решётка узлов — полушаг листа самого мелкого уровня ---
    keys = np.sort(_enc(L, I, J))
    lmax = int(L.max())
    u = 2 ** (lmax + 1)                       # узлов решётки на сторону корня (полушаги)
    size = (2 ** (lmax + 1)) // (2 ** L)      # сторона листа в полушагах (чётное)
    X0, Y0 = I * size, J * size
    hang = np.zeros((L.size, 4), bool)        # соседи: +x (правое ребро), −x, +y, −y
    for e, (di, dj) in enumerate(D):
        lv, inside = find(L, I + di, J + dj, keys)
        hang[:, e] = inside & (lv < 0)

    def nid(a, b):
        return a.astype(np.int64) * (u + 1) + b.astype(np.int64)

    polys = []   # для каждого листа — список узлов-полигона (CCW) и признак «веер»
    tri_ids = []
    cx_ = X0 + size // 2
    cy_ = Y0 + size // 2
    nh = hang.any(axis=1)
    # листья без висячих: 2 треугольника, диагональ по чётности (I+J)
    s0 = np.nonzero(~nh)[0]
    A = nid(X0[s0], Y0[s0]); B = nid(X0[s0] + size[s0], Y0[s0])
    C = nid(X0[s0] + size[s0], Y0[s0] + size[s0]); Dn = nid(X0[s0], Y0[s0] + size[s0])
    par = ((I[s0] + J[s0]) % 2 == 0)
    t1 = np.where(par[:, None], np.stack([A, B, C], 1), np.stack([A, B, Dn], 1))
    t2 = np.where(par[:, None], np.stack([A, C, Dn], 1), np.stack([B, C, Dn], 1))
    tri_ids += [t1, t2]
    # листья с висячими узлами: веер из центра по периметру (CCW)
    s1 = np.nonzero(nh)[0]
    fan = []
    for q in s1:
        x0, y0, sz = X0[q], Y0[q], size[q]
        h = sz // 2
        per = [(x0, y0)]
        if hang[q, 3]:
            per.append((x0 + h, y0))
        per.append((x0 + sz, y0))
        if hang[q, 0]:
            per.append((x0 + sz, y0 + h))
        per.append((x0 + sz, y0 + sz))
        if hang[q, 2]:
            per.append((x0 + h, y0 + sz))
        per.append((x0, y0 + sz))
        if hang[q, 1]:
            per.append((x0, y0 + h))
        c = (x0 + h, y0 + h)
        for a in range(len(per)):
            p, r = per[a], per[(a + 1) % len(per)]
            fan.append((nid(np.array(p[0]), np.array(p[1])), nid(np.array(r[0]), np.array(r[1])),
                        nid(np.array(c[0]), np.array(c[1]))))
    if fan:
        tri_ids.append(np.array(fan, np.int64))
    T = np.concatenate(tri_ids, axis=0)
    uniq, inv = np.unique(T.ravel(), return_inverse=True)
    tris = inv.reshape(-1, 3)
    gx, gy = uniq // (u + 1), uniq % (u + 1)
    half = side / u
    nx_ = ox + gx * half
    ny_ = oy + gy * half
    nz_ = terrain.height(nx_, ny_)
    nodes = np.stack([nx_, ny_, nz_], 1)
    v = nodes[tris]
    cr = np.cross(v[:, 1] - v[:, 0], v[:, 2] - v[:, 0])
    flip = cr[:, 2] < 0
    tris[flip] = tris[flip][:, [0, 2, 1]]
    v = nodes[tris]
    cr = np.cross(v[:, 1] - v[:, 0], v[:, 2] - v[:, 0])
    nrm = np.linalg.norm(cr, axis=1)
    n = cr / nrm[:, None]
    area = 0.5 * nrm
    c = v.mean(axis=1)
    return Panels(v=v, c=c, n=n, area=area, ds=np.sqrt(area), ds_min=ds_min, terrain=terrain, nodes=nodes, tris=tris)
