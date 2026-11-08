"""SWG-6: быстрый опрос поля панелей 3D (замена `panels3d.influence.panel_velocity`).

Рычаги: FP32 (слитое ядро CUDA, координаты сдвинуты в центр окна), агрегирование дальних панелей (октодерево по
центроидам, листья — списки панелей, узлы — монополь + диполь), списки на блоки целевых точек (Барнс–Хат по блокам).
Ядро одно для всех режимов: поток = точка, цикл по диапазонам панелей и по узлам своего блока.

Скорость единичного источника на треугольнике — как `influence._influence` (Hess & Smith 1967); вычитание в
q = 2(r1 r2 + d1·d2)/(s + L) при d1·d2 < 0 заменено тождеством через |d1×d2|² (устойчиво в FP32).
Дальнее поле узла (источники q_i = σ_i A_i/4π в центроидах c_i, центр узла C, R = P − C):
  V = Q R/R³ − D/R³ + 3 (D·R) R/R⁵,   Q = Σ q_i,   D = Σ q_i (c_i − C)
(следующий член — квадруполь, порядок (размер/R)² относительно монополя).
"""
import contextlib
import time

import numpy as np

_SRC = r"""
#define PANEL_STRIDE 25
extern "C" __global__ void query(const T* __restrict__ pts, const int* __restrict__ blk, const int* __restrict__ dst,
    const int2* __restrict__ rng, const int* __restrict__ cst, const int* __restrict__ cl, const T* __restrict__ pan,
    const T* __restrict__ sg, const T* __restrict__ nd, double* __restrict__ out, int M)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= M) return;
    const T px = pts[3 * i], py = pts[3 * i + 1], pz = pts[3 * i + 2];
    const int b = blk[i];
    double ax = 0, ay = 0, az = 0;
    for (int ri = dst[b]; ri < dst[b + 1]; ++ri) {
        int2 r = rng[ri];
        int p = r.x;
        while (p < r.y) {
            int pe = min(r.y, p + 64);
            T sx = 0, sy = 0, sz = 0;
            for (; p < pe; ++p) {
                const T* q = pan + (size_t)p * PANEL_STRIDE;
                T d[3][3], rr[3];
                #pragma unroll
                for (int k = 0; k < 3; ++k) {
                    d[k][0] = q[3 * k] - px; d[k][1] = q[3 * k + 1] - py; d[k][2] = q[3 * k + 2] - pz;
                    rr[k] = sqrt(d[k][0] * d[k][0] + d[k][1] * d[k][1] + d[k][2] * d[k][2]);
                }
                T cx = d[1][1] * d[2][2] - d[1][2] * d[2][1];
                T cy = d[1][2] * d[2][0] - d[1][0] * d[2][2];
                T cz = d[1][0] * d[2][1] - d[1][1] * d[2][0];
                T num = d[0][0] * cx + d[0][1] * cy + d[0][2] * cz;
                T ab = d[0][0] * d[1][0] + d[0][1] * d[1][1] + d[0][2] * d[1][2];
                T ac = d[0][0] * d[2][0] + d[0][1] * d[2][1] + d[0][2] * d[2][2];
                T bc = d[1][0] * d[2][0] + d[1][1] * d[2][1] + d[1][2] * d[2][2];
                T den = rr[0] * rr[1] * rr[2] + ab * rr[2] + ac * rr[1] + bc * rr[0];
                T om = (T)(-2.0) * atan2(num, den);
                T vx = om * q[9], vy = om * q[10], vz = om * q[11];
                const T eps = q[24];
                const T e2 = eps * eps;
                #pragma unroll
                for (int k = 0; k < 3; ++k) {
                    int k1 = (k + 1) % 3;
                    T r1 = sqrt(rr[k] * rr[k] + e2), r2 = sqrt(rr[k1] * rr[k1] + e2);
                    T dot = d[k][0] * d[k1][0] + d[k][1] * d[k1][1] + d[k][2] * d[k1][2];
                    T s = r1 + r2, Lk = q[21 + k];
                    T qq;
                    if (dot < 0) {
                        T c0 = d[k][1] * d[k1][2] - d[k][2] * d[k1][1];
                        T c1 = d[k][2] * d[k1][0] - d[k][0] * d[k1][2];
                        T c2 = d[k][0] * d[k1][1] - d[k][1] * d[k1][0];
                        T n1 = d[k][0] * d[k][0] + d[k][1] * d[k][1] + d[k][2] * d[k][2];
                        T n2 = d[k1][0] * d[k1][0] + d[k1][1] * d[k1][1] + d[k1][2] * d[k1][2];
                        T cr2 = c0 * c0 + c1 * c1 + c2 * c2 + e2 * (n1 + n2) + e2 * e2;
                        qq = 2 * cr2 / ((r1 * r2 - dot) * (s + Lk));
                    } else {
                        qq = 2 * (r1 * r2 + dot) / (s + Lk);
                    }
                    T le = log((s + Lk) / max(qq, (T)LOG_FLOOR));
                    vx += le * q[12 + 3 * k]; vy += le * q[13 + 3 * k]; vz += le * q[14 + 3 * k];
                }
                const T sig = sg[p];
                sx += sig * vx; sy += sig * vy; sz += sig * vz;
            }
            ax += (double)(sx * (T)0.07957747154594767); ay += (double)(sy * (T)0.07957747154594767); az += (double)(sz * (T)0.07957747154594767);
        }
    }
    for (int ci = cst[b]; ci < cst[b + 1]; ++ci) {
        const T* n = nd + (size_t)cl[ci] * 7;       // Q, C(3), D(3)
        T Rx = px - n[1], Ry = py - n[2], Rz = pz - n[3];
        T R2 = Rx * Rx + Ry * Ry + Rz * Rz;
        T ir = rsqrt(R2), ir3 = ir * ir * ir, ir5 = ir3 * ir * ir;
        T dr = n[4] * Rx + n[5] * Ry + n[6] * Rz;
        ax += (double)(n[0] * Rx * ir3 - n[4] * ir3 + 3 * dr * Rx * ir5);
        ay += (double)(n[0] * Ry * ir3 - n[5] * ir3 + 3 * dr * Ry * ir5);
        az += (double)(n[0] * Rz * ir3 - n[6] * ir3 + 3 * dr * Rz * ir5);
    }
    out[3 * i] = ax; out[3 * i + 1] = ay; out[3 * i + 2] = az;
}
"""

_MODS = {}


def _kernel(cp, dt):
    key = np.dtype(dt).name
    if key not in _MODS:
        if key == "float32":
            defs = "typedef float T;\n#define LOG_FLOOR 1e-30f\n"
        else:
            defs = "typedef double T;\n#define LOG_FLOOR 1e-300\n"
        _MODS[key] = cp.RawModule(code=defs + _SRC).get_function("query")
    return _MODS[key]


def _spread(a, bits):
    a = a.astype(np.uint64)
    out = np.zeros_like(a)
    for b in range(bits):
        out |= ((a >> np.uint64(b)) & np.uint64(1)) << np.uint64(3 * b)
    return out


class Tree:
    """Октодерево по центроидам панелей (геометрия не зависит от ветра). Узлы всех уровней в одном массиве; панели
    отсортированы по коду Мортона, у каждого узла — диапазон [a, b) отсортированных панелей. Лист: ≤ leaf панелей."""

    def __init__(self, panels, leaf=24, bits=14):
        c = np.asarray(panels.c, float)
        lo, hi = c.min(0), c.max(0)
        size = float((hi - lo).max()) * (1 + 1e-9) + 1e-9
        q = np.minimum(((c - lo) / size * (1 << bits)).astype(np.int64), (1 << bits) - 1)
        code = _spread(q[:, 0], bits) | (_spread(q[:, 1], bits) << np.uint64(1)) | (_spread(q[:, 2], bits) << np.uint64(2))
        order = np.argsort(code, kind="stable")
        self.order = order
        cs = code[order]
        N = c.shape[0]
        self.area = np.asarray(panels.area, float)[order]
        self.cc = c[order]
        v = np.asarray(panels.v, float)[order]
        a_l, b_l, par_l = [], [], []
        prev_prefix, prev_ids, base = None, None, 0
        for lev in range(bits + 1):
            pref = cs >> np.uint64(3 * (bits - lev))
            u, st = np.unique(pref, return_index=True)
            en = np.append(st[1:], N)
            ids = np.arange(len(u)) + base
            par = np.full(len(u), -1) if lev == 0 else prev_ids[np.searchsorted(prev_prefix, u >> np.uint64(3))]
            a_l.append(st), b_l.append(en), par_l.append(par)
            prev_prefix, prev_ids, base = u, ids, base + len(u)
        self.a, self.b, self.par = np.concatenate(a_l), np.concatenate(b_l), np.concatenate(par_l)
        n = len(self.a)
        ok = self.par >= 0
        haschild = np.zeros(n, bool)
        haschild[self.par[ok]] = True
        self.leaf = ((self.b - self.a) <= leaf) | ~haschild
        ch = [[] for _ in range(n)]
        for k in np.nonzero(ok)[0]:
            ch[self.par[k]].append(k)
        self.children = ch
        cum_a = np.concatenate([[0], np.cumsum(self.area)])
        cum_ac = np.vstack([np.zeros(3), np.cumsum(self.area[:, None] * self.cc, 0)])
        A = cum_a[self.b] - cum_a[self.a]
        self.C = (cum_ac[self.b] - cum_ac[self.a]) / A[:, None]
        rad = np.empty(n)
        for k in range(n):
            vv = v[self.a[k]:self.b[k]].reshape(-1, 3)
            rad[k] = np.sqrt(((vv - self.C[k]) ** 2).sum(1).max())
        self.R = rad
        self.n_nodes, self.N = n, N

    def moments(self, sigma):
        """Q (n,) и D (n, 3) узлов по σ в исходном порядке панелей."""
        s = np.asarray(sigma, float)[self.order]
        q = s * self.area / (4 * np.pi)
        cq = np.concatenate([[0], np.cumsum(q)])
        cqc = np.vstack([np.zeros(3), np.cumsum(q[:, None] * self.cc, 0)])
        Q = cq[self.b] - cq[self.a]
        D = (cqc[self.b] - cqc[self.a]) - Q[:, None] * self.C
        return Q, D


class FastQuery:
    """panel_velocity: dtype float32/float64; theta = None (прямой счёт) или критерий принятия узла
    R_узла ≤ θ·(d − R_блока), d — расстояние между центром узла и центром блока точек."""

    def __init__(self, panels, dtype=np.float32, theta=None, origin=(0.0, 0.0, 0.0), block_m=400.0, tree=None):
        import cupy as cp
        self.cp, self.panels, self.dt, self.theta, self.block_m = cp, panels, np.dtype(dtype), theta, block_m
        self.origin = np.asarray(origin, float)
        self.t = dict(kernel=0.0, lists=0.0, n_calls=0, n_direct=0, n_cluster=0, n_pts=0)
        self.tree = (tree if tree is not None else Tree(panels)) if theta else None
        p = panels
        v = np.asarray(p.v, float)
        e = np.stack([v[:, 1] - v[:, 0], v[:, 2] - v[:, 1], v[:, 0] - v[:, 2]], 1)
        L = np.linalg.norm(e, axis=2)
        m = np.cross(e / L[..., None], np.asarray(p.n)[:, None, :])
        N = p.N
        buf = np.empty((N, 25))
        buf[:, 0:9] = (v - self.origin).reshape(N, 9)
        buf[:, 9:12] = p.n
        buf[:, 12:21] = m.reshape(N, 9)
        buf[:, 21:24] = L
        buf[:, 24] = 1e-3 * np.asarray(p.ds)
        if self.tree is not None:
            buf = buf[self.tree.order]
        self.pan = cp.asarray(buf.astype(self.dt).ravel())
        self.kern = _kernel(cp, self.dt)

    def _lists(self, P):
        """→ perm, blk (отсортировано по блоку), dst, rng (диапазоны панелей), cst, cl (узлы)."""
        M = P.shape[0]
        key3 = np.floor((P - P.min(0)) / self.block_m).astype(np.int64)
        dims = key3.max(0) + 1
        key = (key3[:, 0] * dims[1] + key3[:, 1]) * dims[2] + key3[:, 2]
        uk, inv = np.unique(key, return_inverse=True)
        B = len(uk)
        perm = np.argsort(inv, kind="stable")
        blk = inv[perm].astype(np.int32)
        if self.theta is None:
            return (perm, blk, np.arange(B + 1, dtype=np.int32), np.tile(np.array([[0, self.panels.N]], np.int32), (B, 1)),
                    np.zeros(B + 1, np.int32), np.zeros(0, np.int32))
        Ps = P[perm]
        st = np.concatenate([[0], np.cumsum(np.bincount(blk, minlength=B))])
        lo = np.minimum.reduceat(Ps, st[:-1], axis=0)
        hi = np.maximum.reduceat(Ps, st[:-1], axis=0)
        bc, br = 0.5 * (lo + hi), 0.5 * np.linalg.norm(hi - lo, axis=1)
        tr = self.tree
        pb, pn = np.arange(B), np.zeros(B, np.int64)
        acc_b, acc_n, dir_b, dir_n = [], [], [], []
        while pb.size:
            d = np.linalg.norm(tr.C[pn] - bc[pb], axis=1) - br[pb]
            accept = (d > 0) & (tr.R[pn] <= self.theta * d)
            acc_b.append(pb[accept]), acc_n.append(pn[accept])
            rest = ~accept
            isleaf = tr.leaf[pn] & rest
            dir_b.append(pb[isleaf]), dir_n.append(pn[isleaf])
            nb, nn = [], []
            for bb, nd in zip(pb[rest & ~tr.leaf[pn]], pn[rest & ~tr.leaf[pn]]):
                for c in tr.children[nd]:
                    nb.append(bb), nn.append(c)
            pb, pn = np.array(nb, np.int64), np.array(nn, np.int64)
        acc_b, acc_n = np.concatenate(acc_b), np.concatenate(acc_n)
        dir_b, dir_n = np.concatenate(dir_b), np.concatenate(dir_n)
        oa, od = np.argsort(acc_b, kind="stable"), np.argsort(dir_b, kind="stable")
        cst = np.concatenate([[0], np.cumsum(np.bincount(acc_b, minlength=B))]).astype(np.int32)
        dst = np.concatenate([[0], np.cumsum(np.bincount(dir_b, minlength=B))]).astype(np.int32)
        rng = np.stack([tr.a[dir_n[od]], tr.b[dir_n[od]]], 1).astype(np.int32)
        return perm, blk, dst, rng, cst, acc_n[oa].astype(np.int32)

    def panel_velocity(self, panels, sigma, P, backend="auto", self_idx=None):
        cp = self.cp
        assert self_idx is None and panels is self.panels
        P = np.atleast_2d(np.asarray(P, float))
        M = P.shape[0]
        t0 = time.perf_counter()
        perm, blk, dst, rng, cst, cl = self._lists(P)
        sg = np.asarray(sigma, float)
        if self.tree is not None:
            Q, D = self.tree.moments(sg)
            nd = np.concatenate([Q[:, None], self.tree.C - self.origin, D], 1)
            sg = sg[self.tree.order]
        else:
            nd = np.zeros((1, 7))
        g_pts = cp.asarray((P[perm] - self.origin).astype(self.dt).ravel())
        g_blk, g_dst, g_cst = (cp.asarray(a) for a in (blk, dst, cst))
        g_cl = cp.asarray(cl if cl.size else np.zeros(1, np.int32))
        g_rng = cp.asarray(rng.astype(np.int32).ravel())
        g_sg = cp.asarray(sg.astype(self.dt))
        g_nd = cp.asarray(nd.astype(self.dt).ravel())
        out = cp.empty(3 * M)
        self.t["lists"] += time.perf_counter() - t0
        B = len(dst) - 1
        npb = np.bincount(blk, minlength=B)
        dpb = np.zeros(B, np.int64)
        np.add.at(dpb, np.repeat(np.arange(B), np.diff(dst)), (rng[:, 1] - rng[:, 0]).astype(np.int64))
        self.t["n_direct"] += int(np.sum(npb * dpb))
        self.t["n_cluster"] += int(np.sum(npb * np.diff(cst)))
        t0 = time.perf_counter()
        th = 128
        self.kern(((M + th - 1) // th,), (th,), (g_pts, g_blk, g_dst, g_rng, g_cst, g_cl, self.pan, g_sg, g_nd, out, np.int32(M)))
        cp.cuda.Stream.null.synchronize()
        self.t["kernel"] += time.perf_counter() - t0
        self.t["n_calls"] += 1
        self.t["n_pts"] += M
        res = np.empty((M, 3))
        res[perm] = out.get().reshape(M, 3)
        return res


@contextlib.contextmanager
def patched(fq):
    """Подменяет `panels3d.influence.panel_velocity` на fq.panel_velocity на время блока."""
    from panels3d import influence as inf
    old = inf.panel_velocity
    inf.panel_velocity = fq.panel_velocity
    try:
        yield fq
    finally:
        inf.panel_velocity = old


def horizontal_err(u, v, ur, vr, floor=1.0):
    """Ошибка горизонтальной скорости против ref, Δ = (u−ur, v−vr): rms_rel = rms|Δ|/rms|v_ref|; max_rel = max |Δ|/|v_ref|
    по точкам |v_ref| ≥ floor; max_abs_ms = max|Δ|; допуск игры (W8): |Δ| ≤ 0,05 + 2 % |v_ref|."""
    d = np.hypot(u - ur, v - vr)
    sp = np.hypot(ur, vr)
    ok = np.isfinite(d) & np.isfinite(sp)
    d, sp = d[ok], sp[ok]
    big = sp >= floor
    return dict(n=int(d.size), rms_rel=float(np.sqrt(np.mean(d ** 2)) / np.sqrt(np.mean(sp ** 2))),
                max_rel=float(np.max(d[big] / sp[big])) if big.any() else 0.0, max_abs_ms=float(d.max()),
                frac_game_ok=float(np.mean(d <= 0.05 + 0.02 * sp)), game_excess_ms=float(np.max(d - 0.02 * sp - 0.05)))


def lu_inplace(infl):
    """Экономия памяти GPU (общая машина): LU в буфере самой матрицы, без копии. Буфер матрицы A (C-порядок) —
    это F-порядок матрицы Aᵀ; факторизуем Aᵀ на месте, а решение A·x = b — `lu_solve(..., trans=1)`.
    После вызова infl.A — не матрица (невязка в P.solve бессмысленна); подмена cupyx lu_solve — на весь процесс."""
    import cupyx.scipy.linalg as cl
    if getattr(cl, "_swg6_trans", False) is False:
        orig = cl.lu_solve

        def lu_solve_t(lu_and_piv, b, trans=0, **kw):
            return orig(lu_and_piv, b, trans=1, **kw)
        cl.lu_solve = lu_solve_t
        cl._swg6_trans = True
    infl._lu = cl.lu_factor(infl.A.T, overwrite_a=True)
    return infl._lu
