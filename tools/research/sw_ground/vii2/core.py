"""VII-2 (SWG-11, круг 4A задачи 1): панели 3D + тонкий интегральный слой (внутренний слой Jackson–Hunt), связь
одновременная — глобальный Ньютон по (a, λ, U_e) во всех узлах всех профилей, как XFOIL (ISES: Drela & Giles 1987).

Отличия от SWG-10 (vii/, импорт без изменений: bl — семейство Coles, замыкания Хеда, Equilibrium; core — Strips,
LayerField, u_inf):
  * толщина равновесного слоя δ0 = l — внутренний слой JH: l·ln(l/z0) = 2κ²L (panels3d.jh.inner_depth, тот же z0),
    L — медиана по профилям вдоль ветра наветренной полуширины старшего гребня (правило гребней panels3d.jh,
    ds_min 25 м); U_l = bg_log(l) — скорость фона на верху слоя; стоки равновесия — от слоя (l, U_l);
  * над слоем — невязкий сдвиговый поток: потенциал панелей с лог-фоном (run.sigma, run.bg) + вдув σ_d;
    U_e слоя — U_l × ускорение однородного потока на поверхности (касательная скорость в центрах панелей, как SWG-10)
    + вклад вдува; скорость в точке: |U_o(x, y, max(z_agl, δ))|·f(z_agl), f — профиль слоя (f = 1 выше δ);
  * связь — система  R1 (Карман), R2 (вовлечение) на каждом интервале, R3: U_i − U_e(m)_i = 0 во всех узлах, где
    U_e(m) — точное 3D-невязкое с вдувом σ_d = A⁻¹Q·m, m = U·δ* (Q — линейная матрица q = cos β·dm/ds_h).
    Ньютон: якобиан BL-строк — разностный по 6 локальным неизвестным; строка связи — точный линеаризованный
    оператор (через LU и матрицу касательных скоростей) в GMRES; предобусловливатель — блок на профиль: BL-строки
    точно + связь матрицей влияния D «вдув-линия поперёк ветра» (столбец j — отклик U_e на единичный m в узлах
    s-индекса j всех профилей). Демпфирование — XFOIL UPDATE: RLX профиля так, что RLX·Δθ/θ, RLX·Δδ*/δ*,
    RLX·|ΔU|/(0,25·U_l) ∈ [−0,5; 1,5] (DLO, DHI). В отрыве — та же система (без смены режима).
"""
from __future__ import annotations

import math
import os
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from scipy.linalg import lu_factor, lu_solve
from scipy.ndimage import gaussian_filter1d
from scipy.sparse import coo_matrix
from scipy.sparse.linalg import LinearOperator, gmres
from scipy.spatial import Delaunay

from ground import model as M  # noqa: F401  (патчи panels3d при импорте)
from panels3d import influence as _inf
from panels3d.jh import L_FLAT, crests_profile, inner_depth
from panels3d.terrain import bg_uniform, wind_of
from wake.core import solve_rhs

from vii import bl
from vii import core as V

UE_SMOOTH = V.UE_SMOOTH       # σ сглаживания U_e вдоль профиля, м (как SWG-10)
TOL = 1e-6                    # max |R| (масштабированная невязка) — критерий карточки
NEWTON_MAX = 40
EPS0 = 0.25                   # первый шаг продолжения по рельефу (доля ускорения U_inv − U_l)
DS0, DS_MIN, DS_MAX = 0.25, 1e-3, 0.25   # шаг псевдодлины дуги (норма — среднее по узлам + ε)
ARC_STEPS = 400
VERBOSE = os.environ.get("VII2_VERBOSE") == "1"
TOL_MID = 1e-4                # критерий промежуточных шагов продолжения
NEWTON_MID = 12               # итераций на промежуточном шаге
DHI, DLO = 1.5, -0.5          # XFOIL 6.99 xbl.f UPDATE: пределы RLX·Δ/величина
DU_REF = 0.25                 # XFOIL UPDATE: DN4 = |ΔU_e|/0,25 (U_e в долях U_∞) → здесь доля U_l
GMRES_RTOL = 1e-2             # неточный Ньютон: относительная точность линейного шага
GMRES_RESTART, GMRES_MAXIT = 40, 2
CREST_DS = 25.0               # ds_min правила гребней для L (как JH в основном наборе SWD5)
STEP = float(os.environ.get("VII2_STEP", 25.0))   # шаг узлов слоя вдоль ветра, м (SWG-10: 12,5; здесь 25 — плотный Ньютон на профиль,
                              # узлов в 2 раза меньше; δ0 ~ 15–35 м, шаг ~ δ, как у XFOIL панель ≫ δ)
DC = float(os.environ.get("VII2_DC", 50.0))       # шаг профилей поперёк, м (SWG-10: 25; сетка панелей слоя ds_min 100 м)


def _cupy():
    try:
        import cupy as cp
        cp.zeros(1)
        return cp
    except Exception:
        return None


def log0(*a):
    print(*a, flush=True)


LAM_MIN = 2.3                 # нижний предел λ = ln(δ/z0) Ньютона (у лога H = λ/(λ − 2) → ∞ при λ → 2; vii.bl: 2,6)
A_MAX = 1.6                   # верхний предел a (профиль «полнее лога»: ускорение на гребне)


def a_limits_newton(n=400):
    """Пределы a для Ньютона: θ > 0 и H ≤ 30 при a ∈ [−0,6; A_MAX] (единственность H(a) не нужна — неизвестные
    (a, λ), а не H; у vii.bl.a_limits верх — минимум H, при λ < 3,4 он ниже a = 1 равновесия)."""
    lam = np.linspace(LAM_MIN, bl.LAM_MAX, n)
    aa = np.linspace(-0.6, A_MAX, 2201)
    g = bl.integrals(aa[None, :], lam[:, None])
    T = g["I1"] - g["I2"]
    H = np.where(T > 0, (1 - g["I1"]) / np.maximum(T, 1e-12), np.inf)
    ok = (T > 0) & (H <= 30.0)
    lo = np.array([aa[np.nonzero(r)[0][0]] for r in ok])
    hi = np.array([aa[np.nonzero(r)[0][-1]] for r in ok])
    return lam, lo, hi


LAM_CAP = 2.4                 # предел толщины δ ≥ e^2,4·z0 ≈ 11·z0 (ниже — семейство лога вырождено, H = λ/(λ − 2) → ∞;
                              # для леса Perdigão z0 1,8 м это 20 м — порядок слоя шероховатости); узлы на пределе:
                              # уравнение Кармана заменено на λ = LAM_CAP (счётчик в отчёте)
A_CAP_MARGIN = 0.05            # запас по a над точкой dH1/dH = 0 семейства (предел «прямого» хода — аналог HTMAX)


def a_singular(n=300):
    """a*(λ): минимум H1 по a при данном λ (dH1/dH = 0 — аналог сингулярности Голдстейна семейства Coles + Хед;
    в ней якобиан строк слоя при заданном U вырожден). → (λ, a*, H*)."""
    lam = np.linspace(LAM_MIN, bl.LAM_MAX, n)
    aa = np.linspace(-0.6, 1.0, 3201)
    g = bl.integrals(aa[None, :], lam[:, None])
    T = g["I1"] - g["I2"]
    H1 = np.where(T > 0, g["I1"] / np.maximum(T, 1e-12), np.inf)
    H = np.where(T > 0, (1 - g["I1"]) / np.maximum(T, 1e-12), np.inf)
    H1 = np.where(H <= 30, H1, np.inf)
    k = np.argmin(H1, 1)
    return lam, aa[k], H[np.arange(n), k]


def delta0_rule(strips, z0, ds_min=CREST_DS):
    """δ0 = l(L): L — медиана по профилям наветренной полуширины старшего (высшего) гребня профиля; без гребней —
    L_FLAT (ровная земля). → (l, L, число профилей с гребнем)."""
    Ls = []
    for ic in range(strips.cvals.size):
        v = np.nonzero(strips.valid[ic])[0]
        if v.size < 10:
            continue
        _, cr = crests_profile(strips.svals[v], strips.zs[ic, v], ds_min)
        if cr:
            Ls.append(max(cr, key=lambda c: c["z_c"])["L"])
    L = float(np.median(Ls)) if Ls else L_FLAT
    return float(inner_depth(np.array([L]), z0)[0]), L, len(Ls)


class Omega:
    """Узлы слоя: на каждом профиле — самый длинный непрерывный отрезок ok (≥ 5 узлов). ext — индекс узла Ω, чьё
    значение берётся в узле решётки (до отрезка — первый, после — последний; профили без отрезка — ближайший)."""

    def __init__(self, strips, ok):
        nl, ns = ok.shape
        self.nl, self.ns = nl, ns
        lines, idx = [], np.full((nl, ns), -1, int)
        o = 0
        for ic in range(nl):
            v = np.nonzero(ok[ic])[0]
            if v.size < 5:
                continue
            br = np.nonzero(np.diff(v) > 1)[0]
            starts = np.concatenate([[0], br + 1])
            ends = np.concatenate([br + 1, [v.size]])
            k = int(np.argmax(ends - starts))
            seg = v[starts[k]:ends[k]]
            if seg.size < 5:
                continue
            lines.append((ic, int(seg[0]), int(seg.size), o))
            idx[ic, seg] = o + np.arange(seg.size)
            o += seg.size
        self.lines, self.idx, self.n = lines, idx, o
        self.node_ic = np.concatenate([np.full(n, ic) for ic, _, n, _ in lines])
        self.node_is = np.concatenate([i0 + np.arange(n) for _, i0, n, _ in lines])
        ext = np.full((nl, ns), -1, int)
        for ic, i0, n, o_ in lines:
            ext[ic, :i0] = o_
            ext[ic, i0:i0 + n] = o_ + np.arange(n)
            ext[ic, i0 + n:] = o_ + n - 1
        rows = np.array([ln[0] for ln in lines])
        for ic in range(nl):
            if ext[ic, 0] < 0:
                ext[ic] = ext[rows[np.argmin(np.abs(rows - ic))]]
        self.ext = ext
        first = np.array([o_ for _, _, _, o_ in lines])
        self.first = first
        cur = np.concatenate([o_ + np.arange(1, n) for _, _, n, o_ in lines])
        self.cur, self.prev = cur, cur - 1
        self.h = strips.arc[self.node_ic[cur], self.node_is[cur]] - strips.arc[self.node_ic[cur], self.node_is[cur] - 1]
        self.X = strips.X[self.node_ic, self.node_is]
        self.Y = strips.Y[self.node_ic, self.node_is]

    def grid(self, vals, fill=np.nan):
        G = np.full((self.nl, self.ns), fill, float)
        G[self.node_ic, self.node_is] = vals
        return G

    def extended(self, vals):
        return np.asarray(vals)[self.ext]


def bilinear(strips, om, x, y):
    """Билинейные веса решётки профилей (как RegularGridInterpolator; за краями — край) → узлы Ω через ext.
    → (веса (n, 4), индексы узлов Ω (n, 4))."""
    c, a = strips.rot(x, y)
    cv, sv = strips.cvals, strips.svals
    c = np.clip(np.ravel(c), cv[0], cv[-1])
    a = np.clip(np.ravel(a), sv[0], sv[-1])
    i = np.clip(np.floor((c - cv[0]) / strips.dc).astype(int), 0, cv.size - 2)
    j = np.clip(np.floor((a - sv[0]) / strips.step).astype(int), 0, sv.size - 2)
    tc = (c - cv[i]) / strips.dc
    ts = (a - sv[j]) / strips.step
    W = np.stack([(1 - tc) * (1 - ts), (1 - tc) * ts, tc * (1 - ts), tc * ts], 1)
    E = om.ext
    I = np.stack([E[i, j], E[i, j + 1], E[i + 1, j], E[i + 1, j + 1]], 1)
    return W, I


def build_Q(panels, strips, om):
    """Q (N × n_Ω): q = cos β·dm/ds_h в панелях внутри растра (среднее по серединам рёбер центральной разностью ±step
    вдоль ветра, как wake.core.wake_panels + vii.core._MGrid); вне растра q = 0. Линейна по m."""
    t = panels.terrain
    c = panels.c
    inside = (c[:, 0] >= t.x[0]) & (c[:, 0] <= t.x[-1]) & (c[:, 1] >= t.y[0]) & (c[:, 1] <= t.y[-1])
    pid = np.nonzero(inside)[0]
    v = panels.v[pid]
    mids = 0.5 * (v + v[:, [1, 2, 0]])
    ex, ey, h = strips.ex, strips.ey, strips.step
    n = panels.n[pid]
    sl = -(n[:, 0] * ex + n[:, 1] * ey) / np.maximum(n[:, 2], 1e-6)
    cosb = 1.0 / np.sqrt(1.0 + sl * sl)
    R, Cc, Vv = [], [], []
    for k in range(3):
        for sg in (1.0, -1.0):
            W, I = bilinear(strips, om, mids[:, k, 0] + sg * h * ex, mids[:, k, 1] + sg * h * ey)
            coef = (cosb * sg / (2 * h) / 3.0)[:, None] * W
            R.append(np.repeat(pid, 4))
            Cc.append(I.ravel())
            Vv.append(coef.ravel())
    return coo_matrix((np.concatenate(Vv), (np.concatenate(R), np.concatenate(Cc))),
                      shape=(panels.N, om.n)).tocsr()


def tmatrix64(panels, strips):
    """Матрица касательных скоростей от единичных σ в центрах панелей растра (+ край), float64 (копия
    vii.core.VII._tmatrix с float64: невязка Ньютона 1e-6 требует точности выше float32)."""
    t = panels.terrain
    c = panels.c
    mg = 2 * strips.step + float(np.max(panels.ds))
    rows = np.nonzero((c[:, 0] >= t.x[0] - mg) & (c[:, 0] <= t.x[-1] + mg) & (c[:, 1] >= t.y[0] - mg)
                      & (c[:, 1] <= t.y[-1] + mg))[0]
    g = _inf._geom(panels, np)
    nn = panels.n[rows]
    T = np.empty((rows.size, 3, panels.N))
    step = _inf._rows(np, rows.size, panels.N)

    def work(i):
        sl = slice(i, min(rows.size, i + step))
        ri = rows[sl]
        si = ri[:, None] == np.arange(panels.N)[None]
        Vm = _inf._influence(np, c[ri], g, slice(None), si)
        Vn = np.einsum("mkc,mc->mk", Vm, nn[sl])
        T[sl] = np.transpose(Vm - Vn[..., None] * nn[sl][:, None, :], (0, 2, 1))
    with ThreadPoolExecutor(M.CPU_THREADS) as ex:
        list(ex.map(work, range(0, rows.size, step)))
    return T.reshape(rows.size * 3, panels.N), rows


def bary_matrix(tri, x, y, ncol):
    """Линейная интерполяция по треугольникам Delaunay (как LinearNDInterpolator) — разреженная матрица (n × ncol);
    вне оболочки — строка пустая, маска out."""
    P = np.stack([np.ravel(x), np.ravel(y)], 1)
    s = tri.find_simplex(P)
    ok = s >= 0
    Tr = tri.transform[s[ok]]
    b = np.einsum("nij,nj->ni", Tr[:, :2], P[ok] - Tr[:, 2])
    B = np.concatenate([b, 1 - b.sum(1, keepdims=True)], 1)
    V_ = tri.simplices[s[ok]]
    r = np.repeat(np.nonzero(ok)[0], 3)
    return coo_matrix((B.ravel(), (r, V_.ravel())), shape=(P.shape[0], ncol)).tocsr(), ok


class VII2:
    """Тонкий слой + одновременная связь на сетке run (GRun или синтетика) и профилях strips."""

    def __init__(self, run, strips=None, delta0=None, log=None, fine=True, cap=True):
        self.run = run
        self.panels, self.infl = run.panels, run.infl
        self.z0 = float(run.z0)
        ex, ey = wind_of(run.bg, self.panels.terrain)
        self.e = (ex, ey)
        self.strips = strips if strips is not None else V.Strips(self.panels.terrain, (ex, ey), STEP, DC)
        self.log = log or (lambda *a: None)
        if delta0 is None:
            self.delta0, self.L_rule, self.n_crest = delta0_rule(self.strips, self.z0)
        else:
            self.delta0, self.L_rule, self.n_crest = float(delta0), None, None
        self.U_l = V.u_inf(self.z0, self.delta0)
        self.eq = bl.Equilibrium(self.z0, self.delta0, self.U_l)
        self.bgu = bg_uniform(self.U_l, (ex, ey))
        self.sig_u = np.asarray(M.solve(self.panels, self.bgu, None, self.infl)[0])
        self.alim = a_limits_newton()
        lo_m, hi_m = bl.a_limits(np.linspace(bl.LAM_MIN, bl.LAM_MAX, 400))
        self.alim_march = (np.linspace(bl.LAM_MIN, bl.LAM_MAX, 400), lo_m, hi_m)
        t0 = time.time()
        self.T, self.rows = tmatrix64(self.panels, self.strips)
        self.cp = _cupy()
        self.Tg = None
        if self.cp is not None:
            try:
                self.Tg = self.cp.asarray(self.T)
            except Exception:
                self.Tg = None
        self.log(f"  матрица касательных скоростей {self.T.shape}, {time.time() - t0:.0f} с, "
                 f"{'GPU' if self.Tg is not None else 'CPU'}")
        p = self.panels
        cr = p.c[self.rows]
        u, v, w = self.bgu(cr[:, 0], cr[:, 1], cr[:, 2])
        B = np.stack([np.asarray(u, float), np.asarray(v, float), np.asarray(w, float)], 1)
        self.B = B - (B * p.n[self.rows]).sum(1)[:, None] * p.n[self.rows]
        tri = Delaunay(cr[:, :2])
        st = self.strips
        Pg, okg = bary_matrix(tri, st.X, st.Y, self.rows.size)
        ok = st.valid & okg.reshape(st.X.shape)
        self.om = Omega(st, ok)
        om = self.om
        self.P = Pg[(om.node_ic * st.svals.size + om.node_is)]
        self.Q = build_Q(p, st, om)
        self.sig_d = np.zeros(p.N)
        self.cap = bool(cap)
        lt, asg, _ = a_singular()
        self.acap_tab = (lt, asg + A_CAP_MARGIN)
        self.active = np.zeros(om.n, bool)        # узлы на пределе: R2 заменено на a − a_cap(λ) = 0
        self.active_l = np.zeros(om.n, bool)      # узлы на пределе толщины: R1 заменено на λ − LAM_CAP = 0
        self.fine_sigma = float(p.ds_min) if fine else 0.0
        self.F = self.build_fine() if fine else None

    # ---- невязкое -------------------------------------------------------------------------------------------------
    def smooth(self, A):
        """Гауссово сглаживание вдоль отрезка профиля (σ UE_SMOOTH, mode nearest) — линейно; A (n_Ω,) или (n_Ω, k)."""
        A = np.asarray(A, float)
        G = np.empty_like(A)
        sg = UE_SMOOTH / self.strips.step
        for _, _, n, o in self.om.lines:
            G[o:o + n] = gaussian_filter1d(A[o:o + n], sg, axis=0, mode="nearest")
        return G

    def Tmul(self, sig):
        if self.Tg is not None:
            return self.cp.asnumpy(self.Tg @ self.cp.asarray(sig))
        return self.T @ sig

    def tang(self, sig):
        return self.B + self.Tmul(self.sig_u + sig).reshape(self.rows.size, 3)

    def surf(self, sig):
        """U_e невязкое (|касательная| однородного потока U_l + σ_u + σ), на узлах Ω, сглажено. → (U, Ut)."""
        Ut = self.tang(sig)
        return self.smooth(self.P @ np.linalg.norm(Ut, axis=1)), Ut

    def sigma_of_m(self, m):
        return solve_rhs(self.infl, self.Q @ m)

    def G_lin(self, dm, that):
        """Линейный отклик U_e на Δm (n_Ω,) или (n_Ω, k): t̂·T·A⁻¹Q·Δm → узлы → сглаживание."""
        sig = solve_rhs(self.infl, self.Q @ dm)
        if sig.ndim == 1:
            ut = np.einsum("rc,rc->r", that, self.Tmul(sig).reshape(self.rows.size, 3))
        else:
            ut = np.einsum("rc,rck->rk", that, self.Tmul(sig).reshape(self.rows.size, 3, sig.shape[1]))
        return self.smooth(self.P @ ut)

    def line_D(self, that, chunk=48):
        """D_ℓ (n × n) на профиль: столбец j — отклик U_e узлов профиля на m = 1 в узлах s-индекса j всех профилей."""
        om = self.om
        D = [np.zeros((n, n)) for _, _, n, _ in om.lines]
        js = np.unique(om.node_is)
        for k0 in range(0, js.size, chunk):
            J = js[k0:k0 + chunk]
            dm = (om.node_is[:, None] == J[None, :]).astype(float)
            Rr = self.G_lin(dm, that)
            for li, (ic, i0, n, o) in enumerate(om.lines):
                sel = (J >= i0) & (J < i0 + n)
                if sel.any():
                    D[li][:, J[sel] - i0] = Rr[o:o + n][:, sel]
        return D

    def build_fine(self):
        """Подсеточное взаимодействие (допущение SWG-11): панели не разрешают вдув мельче своего размера, поэтому к
        отклику панелей добавляется 2D-закон тонкого профиля (Lighthill 1958; «interaction law» Veldman 1981) для
        мелкомасштабной части m: ΔU_i = (1/π) Σ_j q_j ln|(s_i − s_j + h_j/2)/(s_i − s_j − h_j/2)|, q = d(m − S_p m)/ds,
        S_p — гауссово сглаживание с σ = ds_min сетки панелей (масштаб, который панели уже разрешают). → [F_ℓ (n × n)]."""
        st = self.strips
        out = []
        sg = self.fine_sigma
        for ic, i0, n, o in self.om.lines:
            s_ = st.arc[ic, i0:i0 + n]
            h = np.gradient(s_)
            d = s_[:, None] - s_[None, :]
            with np.errstate(divide="ignore"):
                K = np.log(np.abs((d + 0.5 * h[None, :]) / (d - 0.5 * h[None, :]))) / math.pi
            np.fill_diagonal(K, 0.0)
            Gd = np.zeros((n, n))
            Gd[0, :2] = np.array([-1.0, 1.0]) / (s_[1] - s_[0])
            Gd[-1, -2:] = np.array([-1.0, 1.0]) / (s_[-1] - s_[-2])
            for k in range(1, n - 1):
                Gd[k, k - 1], Gd[k, k + 1] = -1.0 / (s_[k + 1] - s_[k - 1]), 1.0 / (s_[k + 1] - s_[k - 1])
            Sp = gaussian_filter1d(np.eye(n), sg / st.step, axis=0, mode="nearest") if sg > 0 else np.zeros((n, n))
            out.append(K @ Gd @ (np.eye(n) - Sp))
        return out

    def fine_apply(self, m):
        if self.F is None:
            return np.zeros_like(m)
        out = np.empty_like(m)
        for li, (_, _, n, o) in enumerate(self.om.lines):
            out[o:o + n] = self.F[li] @ m[o:o + n]
        return out

    # ---- слой ------------------------------------------------------------------------------------------------------
    def clamp(self, a, lam):
        lam_tab, lo, hi = self.alim
        lam = np.clip(lam, LAM_MIN, bl.LAM_MAX)
        return np.clip(a, np.interp(lam, lam_tab, lo) + 1e-3, np.interp(lam, lam_tab, hi)), lam

    def pair_res(self, a1, l1, U1, a2, l2, U2, h):
        """Невязки интервала (трапеция; Карман в лог-форме по U, как XFOIL): → (R1/θ0, R2/(U_l·δ0))."""
        eq = self.eq
        s1, s2 = bl.state(a1, l1, self.z0), bl.state(a2, l2, self.z0)
        thm = 0.5 * (s1["theta"] + s2["theta"])
        Hm = 0.5 * (s1["H"] + s2["H"])
        R1 = (s2["theta"] - s1["theta"] + (Hm + 2) * thm * (np.log(U2) - np.log(U1))
              - h * (0.5 * (s1["cf2"] + s2["cf2"]) - eq.S_m * 0.5 * (1 / U1 ** 2 + 1 / U2 ** 2)))
        E1 = U1 * (s1["delta"] - s1["dstar"])
        E2 = U2 * (s2["delta"] - s2["dstar"])
        R2 = E2 - E1 - h * (0.5 * (U1 * bl.F_head(s1["H1"]) + U2 * bl.F_head(s2["H1"])) - eq.S_e)
        return R1 / eq.theta0, R2 / (self.U_l * self.delta0)

    def residual(self, a, lam, U, Ue3):
        om = self.om
        R = np.zeros((om.n, 3))
        R[om.first, 0] = a[om.first] - 1.0
        R[om.first, 1] = lam[om.first] - self.eq.lam0
        p, c = om.prev, om.cur
        R[c, 0], R[c, 1] = self.pair_res(a[p], lam[p], U[p], a[c], lam[c], U[c], om.h)
        if self.cap and self.active.any():
            ca = c[self.active[c]]
            R[ca, 1] = a[ca] - self.a_cap(lam[ca])
        if self.cap and self.active_l.any():
            cl = c[self.active_l[c]]
            R[cl, 0] = lam[cl] - LAM_CAP
        R[:, 2] = (U - Ue3) / self.U_l
        return R

    def a_cap(self, lam):
        return np.interp(lam, *self.acap_tab)

    def activate(self, x):
        """Узлы с a < a_cap(λ) (кроме входа) → активны (зона только растёт, как зона обратного хода SWG-10). → число."""
        if not self.cap:
            return 0
        new = (x[:, 0] < self.a_cap(x[:, 1])) & ~self.active
        new[self.om.first] = False
        self.active |= new
        nl_ = (x[:, 1] < LAM_CAP) & ~self.active_l
        nl_[self.om.first] = False
        self.active_l |= nl_
        return int(new.sum())

    def pair_jac(self, a, lam, U):
        """∂(R1, R2)/∂(a, λ, U)_{k−1, k} центральными разностями → (n_pairs, 2, 6)."""
        om = self.om
        p, c = om.prev, om.cur
        X = np.stack([a[p], lam[p], U[p], a[c], lam[c], U[c]], 1)
        eps = np.array([1e-6, 1e-6, 1e-6 * self.U_l] * 2)
        J = np.zeros((X.shape[0], 2, 6))
        for k in range(6):
            Xp, Xm = X.copy(), X.copy()
            Xp[:, k] += eps[k]
            Xm[:, k] -= eps[k]
            rp = self.pair_res(*Xp.T, om.h)
            rm = self.pair_res(*Xm.T, om.h)
            J[:, 0, k] = (rp[0] - rm[0]) / (2 * eps[k])
            J[:, 1, k] = (rp[1] - rm[1]) / (2 * eps[k])
        return J

    def march_nc(self, Ui):
        """Слой без связи (SWG-10 bl.march по невязкому U_e; при H > 2,5 — обратный ход с H = const) → (a, λ) на Ω."""
        om, st = self.om, self.strips
        Ug = om.grid(Ui, 0.0)
        dU = np.zeros_like(Ug)
        for ic, i0, n, o in om.lines:
            dU[ic, i0:i0 + n] = np.gradient(Ui[o:o + n], st.arc[ic, i0:i0 + n])
        valid = om.idx >= 0
        r = bl.march(st.arc, Ug, dU, valid, self.eq, alim=self.alim_march)
        a = r["a"][om.node_ic, om.node_is]
        lam = r["lam"][om.node_ic, om.node_is]
        bad = ~np.isfinite(a + lam)
        a[bad], lam[bad] = 1.0, self.eq.lam0
        return a, lam, r

    def solve(self, newton_max=NEWTON_MAX, tol=TOL, eps0=EPS0, ds0=DS0, max_steps=ARC_STEPS, ds_min=DS_MIN):
        """Глобальный Ньютон с продолжением по рельефу: U_e,eff = U_e(m) − (1 − ε)(U_inv − U_l); ε = 1 — задача
        (как развёртка по углу атаки в XFOIL). Начальное — равновесный слой (a = 1, λ0), U = U_l, ε = 0 (точное
        решение). Продолжение — псевдодлина дуги (Keller 1977): неизвестные (x, ε), предиктор по секущей двух
        последних решений, корректор — Ньютон на [R(x, ε); t·(y − y_pred)] = 0 (проходит точки поворота по ε).
        Когда ε переходит 1 — Ньютон при ε = 1 от интерполированного состояния. → dict."""
        om = self.om
        t0 = time.time()
        U_inv, Ut0 = self.surf(np.zeros(self.panels.N))
        self.U_inv = U_inv
        a, lam = self.clamp(np.ones(om.n), np.full(om.n, self.eq.lam0))
        U = np.full(om.n, self.U_l)
        that0 = Ut0 / np.maximum(np.linalg.norm(Ut0, axis=1, keepdims=True), 1e-12)
        self.D = D = self.line_D(that0)
        self.Dp = D if self.F is None else [d_ + f_ for d_, f_ in zip(D, self.F)]
        self.log(f"  матрица влияния D ({len(D)} профилей, n_Ω {om.n}), {time.time() - t0:.0f} с")
        hist = []
        Y0 = (self._pack(a, lam, U), 0.0)                         # ε = 0: равновесие — точное решение
        while True:
            self.active[:] = False
            self.active_l[:] = False
            x1, ok = self._correct(Y0[0], eps0, None, None, TOL_MID, NEWTON_MID, hist, t0, phase="first")
            if ok or eps0 < 1.0 / 64:
                break
            eps0 *= 0.5
        if not ok:
            raise RuntimeError("продолжение: первый шаг не сошёлся (ε0 < 1/64)")
        Y1 = (x1, eps0)
        ds = ds0
        branch = [Y0, Y1]
        n_fail, turns = 0, 0
        final = None
        for step in range(max_steps):
            (xa, ea), (xb, eb) = branch[-2], branch[-1]
            dxv, de = xb - xa, eb - ea
            nrm = math.sqrt(self._wdot(dxv, dxv) + de * de)
            tx, te = dxv / nrm, de / nrm
            xp, ep = xb + ds * tx, eb + ds * te
            xc, ec, ok = self._correct_arc(xp, ep, tx, te, TOL_MID, NEWTON_MID, hist, t0)
            if not ok:
                n_fail += 1
                ds *= 0.5
                if ds < ds_min:
                    self.log(f"  продолжение остановилось: ε = {eb:.4f}, шаг дуги < {ds_min}")
                    break
                continue
            if (ec - eb) * te < 0:
                turns += 1
            branch.append((xc, ec))
            self.log(f"  дуга: ε = {ec:.4f} (шаг {ds:.3g}), C_f<0 {hist[-1]['n_sep']}, H_max {hist[-1]['H_max']:.2f}")
            if ec >= 1.0:
                w = (1.0 - eb) / (ec - eb)
                final = (1 - w) * xb + w * xc
                break
            ds = min(ds * 1.5, DS_MAX)
        conv = False
        self.stall = None
        if final is None:
            final = branch[-1][0]
            e_last = branch[-1][1]
            self.stall = self._stall_stats(branch[-1][0])
            self.log(f"  ε = 1 не достигнуто (последнее {e_last:.4f}): {self.stall} — Ньютон при ε = 1 от последнего решения")
        act0, actl0 = self.active.copy(), self.active_l.copy()
        x, conv = self._correct(final, 1.0, None, None, tol, newton_max, hist, t0)
        if not conv and self.stall is not None:
            # ε = 1 не сошлось: результат — последнее сошедшееся решение ветви (ε_reached), с пометкой
            x = branch[-1][0]
            self.active, self.active_l = act0, actl0
        self.eps_result = 1.0 if conv else float(branch[-1][1])
        a, lam, U = self._unpack(x)
        st = bl.state(a, lam, self.z0)
        sig = self.sigma_of_m(U * st["dstar"])
        self.a, self.lam, self.U, self.sig_d = a, lam, U, sig
        self.m = U * st["dstar"]
        self.hist = hist
        self.branch_eps = [float(e) for _, e in branch]
        self.branch = branch
        fin = [h for h in hist if h.get("phase") == "final"]
        return dict(a=a, lam=lam, U=U, hist=hist, converged=conv, n_bad_lines=hist[-1]["n_bad_lines"],
                    branch_eps=self.branch_eps, eps_result=self.eps_result, stall=self.stall, n_turns=turns, n_arc_fail=n_fail, iters_final=len(fin) - 1,
                    iters_total=sum(1 for h in hist if "gmres_it" in h), rmax=hist[-1]["rmax"])

    def _stall_stats(self, x):
        a, lam = x[:, 0], x[:, 1]
        st = bl.state(a, lam, self.z0)
        lt, lo, hi = self.alim
        k = int(np.argmax(st["H"]))
        return dict(n_lam_min=int((lam <= LAM_MIN + 1e-6).sum()), n_a_lo=int((a <= np.interp(lam, lt, lo) + 2e-3).sum()),
                    n_a_hi=int((a >= np.interp(lam, lt, hi) - 1e-6).sum()), n_active=int(self.active.sum()),
                    n_active_l=int(self.active_l.sum()), lam_min=float(lam.min()), H_max=float(st["H"][k]), a_at_Hmax=float(a[k]), lam_at_Hmax=float(lam[k]),
                    n_sep=int((st["cf2"] < 0).sum()))

    # упаковка: x (n, 3) = (a, λ, U/U_l); взвешенное скалярное произведение — среднее по узлам
    def _pack(self, a, lam, U):
        return np.stack([a, lam, U / self.U_l], 1)

    def _unpack(self, x):
        return x[:, 0], x[:, 1], x[:, 2] * self.U_l

    def _wdot(self, p, q):
        return float(np.sum(p * q)) / p.shape[0]

    def _lin(self, x, eps, tol):
        """Невязка и линеаризация в x при ε: → dict (R, Jp, dm*, that, st, flags)."""
        om = self.om
        a, lam, U = self._unpack(x)
        st = bl.state(a, lam, self.z0)
        m = U * st["dstar"]
        sig = self.sigma_of_m(m)
        Ue3, Ut = self.surf(sig)
        Ue3 = Ue3 + self.fine_apply(m)
        R = self.residual(a, lam, U, Ue3 - (1.0 - eps) * (self.U_inv - self.U_l))
        rl = np.array([np.abs(R[o:o + n]).max() for _, _, n, o in om.lines])
        return dict(R=R, rl=rl, rmax=float(rl.max()), st=st, Ut=Ut, a=a, lam=lam, U=U,
                    n_bad=int((rl > tol).sum()), n_sep=int((st["cf2"] < 0).sum()), H_max=float(st["H"].max()))

    def _ops(self, L):
        """Операторы J·v (точный) и P⁻¹ (блок профиля с D) в упакованных переменных (U в долях U_l)."""
        om = self.om
        a, lam, U, st = L["a"], L["lam"], L["U"], L["st"]
        Jp = self.pair_jac(a, lam, U)
        Jp = Jp.copy()
        Jp[:, :, 2] *= self.U_l
        Jp[:, :, 5] *= self.U_l
        if self.cap and self.active.any():
            pa = np.nonzero(self.active[om.cur])[0]
            ca = om.cur[pa]
            e_ = 1e-4
            Jp[pa, 1, :] = 0.0
            Jp[pa, 1, 3] = 1.0
            Jp[pa, 1, 4] = -(self.a_cap(lam[ca] + e_) - self.a_cap(lam[ca] - e_)) / (2 * e_)
        if self.cap and self.active_l.any():
            pl = np.nonzero(self.active_l[om.cur])[0]
            Jp[pl, 0, :] = 0.0
            Jp[pl, 0, 4] = 1.0
        dma, dml, dmU = U * st["ds_a"], U * st["ds_l"], st["dstar"] * self.U_l
        that = L["Ut"] / np.maximum(np.linalg.norm(L["Ut"], axis=1, keepdims=True), 1e-12)
        lus = self._factor(Jp, self.Dp, dma, dml, dmU)

        def prec(r):
            r = r.reshape(om.n, 3)
            out = np.empty_like(r)
            for li, (_, _, n, o) in enumerate(om.lines):
                out[o:o + n] = lu_solve(lus[li], r[o:o + n].ravel()).reshape(n, 3)
            return out

        def jvp(v):
            v = v.reshape(om.n, 3)
            out = np.zeros_like(v)
            out[om.first, 0] = v[om.first, 0]
            out[om.first, 1] = v[om.first, 1]
            out[om.cur, :2] = np.einsum("pij,pj->pi", Jp, np.concatenate([v[om.prev], v[om.cur]], 1))
            dm = dma * v[:, 0] + dml * v[:, 1] + dmU * v[:, 2]
            out[:, 2] = v[:, 2] - (self.G_lin(dm, that) + self.fine_apply(dm)) / self.U_l
            return out
        R_eps = np.zeros((om.n, 3))
        R_eps[:, 2] = -(self.U_inv - self.U_l) / self.U_l      # ∂R3/∂ε
        return jvp, prec, R_eps

    def _damp(self, L, dx):
        """RLX по XFOIL UPDATE на профиль: RLX·Δθ/θ, RLX·Δδ*/δ*, RLX·|ΔU|/(0,25 U_l) ∈ [DLO, DHI]. → (n,) RLX."""
        om, st = self.om, L["st"]
        dth = st["th_a"] * dx[:, 0] + st["th_l"] * dx[:, 1]
        dds = st["ds_a"] * dx[:, 0] + st["ds_l"] * dx[:, 1]
        dns = np.stack([dth / st["theta"], dds / st["dstar"], np.abs(dx[:, 2]) / DU_REF], 1)
        lim = np.where(dns > 0, DHI / np.maximum(dns, 1e-300), np.where(dns < 0, DLO / np.minimum(dns, -1e-300), np.inf))
        rn = lim.min(1)
        rlx = np.ones(om.n)
        for _, _, n, o in om.lines:
            rlx[o:o + n] = min(1.0, float(rn[o:o + n].min()))
        return rlx

    def _apply(self, x, rlx, dx):
        a, lam = self.clamp(x[:, 0] + rlx * dx[:, 0], x[:, 1] + rlx * dx[:, 1])
        n_clamp = int(((a != x[:, 0] + rlx * dx[:, 0]) | (lam != x[:, 1] + rlx * dx[:, 1])).sum())
        return np.stack([a, lam, np.maximum(x[:, 2] + rlx * dx[:, 2], 0.05)], 1), n_clamp

    def _gmres(self, op, prec, rhs):
        nn = rhs.size
        cnt = [0]

        def cb(_):
            cnt[0] += 1
        sol, info = gmres(LinearOperator((nn, nn), op), rhs, M=LinearOperator((nn, nn), prec), rtol=GMRES_RTOL,
                          restart=GMRES_RESTART, maxiter=GMRES_MAXIT, callback=cb, callback_type="pr_norm")
        return sol, info, cnt[0]

    def _record(self, hist, L, eps, it, t0, phase, extra=None):
        h = dict(phase=phase, eps=float(eps), it=it, rmax=L["rmax"], n_active=int(self.active.sum()),
                 n_active_l=int(self.active_l.sum()),
                 r_comp=[float(np.abs(L["R"][:, k]).max()) for k in range(3)], n_bad_lines=L["n_bad"],
                 n_lines=len(self.om.lines), n_sep=L["n_sep"], H_max=L["H_max"], t_s=time.time() - t0)
        h.update(extra or {})
        hist.append(h)
        return h

    def _correct(self, x, eps, _tx, _te, tol, nmax, hist, t0, phase="final"):
        """Ньютон при фиксированном ε. → (x, сошлось)."""
        om = self.om
        for it in range(nmax + 1):
            L = self._lin(x, eps, tol)
            if L["rmax"] < tol or it == nmax:
                self._record(hist, L, eps, it, t0, phase)
                self.log(f"  ε {eps:.4f} Ньютон {it}: max|R| {L['rmax']:.2e}, профилей > tol {L['n_bad']}, "
                         f"C_f<0 {L['n_sep']}, H_max {L['H_max']:.2f}" + (" — сошлось" if L["rmax"] < tol else " — предел"))
                return x, L["rmax"] < tol
            jvp, prec, _ = self._ops(L)
            dx, info, ng = self._gmres(lambda v: jvp(v).ravel(), lambda r: prec(r).ravel(), -L["R"].ravel())
            dx = dx.reshape(om.n, 3)
            rlx = self._damp(L, dx)
            x, ncl = self._apply(x, rlx, dx)
            self.activate(x)
            self._record(hist, L, eps, it, t0, phase, dict(gmres_it=ng, gmres_info=int(info),
                                                           rlx_min=float(rlx.min()), n_clamp=ncl))
        return x, False

    def _correct_arc(self, xp, ep, tx, te, tol, nmax, hist, t0):
        """Корректор псевдодлины дуги: [R(x, ε); ⟨t, y − y_p⟩] = 0, ⟨·,·⟩ — _wdot для x + ε·ε; GMRES по
        окаймлённой системе, предобусловливатель — diag(P⁻¹, 1/t_ε). → (x, ε, сошлось)."""
        om = self.om
        x, e = xp.copy(), float(ep)
        n3 = om.n * 3
        for it in range(nmax + 1):
            L = self._lin(x, e, tol)
            g = self._wdot(tx, x - xp) + te * (e - ep)
            if (L["rmax"] < tol and abs(g) < tol) or it == nmax or not np.isfinite(L["rmax"]):
                ok = L["rmax"] < tol and abs(g) < tol
                self._record(hist, L, e, it, t0, "arc")
                return x, e, ok
            jvp, prec, R_eps = self._ops(L)
            Re = R_eps.ravel()
            txr = tx.ravel() / om.n
            ted = te if abs(te) > 1e-3 else math.copysign(1e-3, te if te != 0 else 1.0)

            def op(v):
                return np.concatenate([jvp(v[:n3]).ravel() + Re * v[n3], [txr @ v[:n3] + te * v[n3]]])

            def pr(r):
                return np.concatenate([prec(r[:n3]).ravel(), [r[n3] / ted]])
            sol, info, ng = self._gmres(op, pr, -np.concatenate([L["R"].ravel(), [g]]))
            dx, de = sol[:n3].reshape(om.n, 3), float(sol[n3])
            rlx = self._damp(L, dx)
            r_ = float(rlx.min())
            x, ncl = self._apply(x, np.full(om.n, r_), dx)
            self.activate(x)
            e += r_ * de
            self._record(hist, L, e, it, t0, "arc", dict(gmres_it=ng, gmres_info=int(info), rlx_min=r_, n_clamp=ncl))
            if VERBOSE:
                self.log(f"    корректор {it}: ε {e:.5f} max|R| {L['rmax']:.2e} g {g:+.1e} GMRES {ng} ({info}) RLX {r_:.3f} "
                         f"на пределе {ncl} H_max {L['H_max']:.2f} C_f<0 {L['n_sep']}")
        return x, e, False

    def _factor(self, Jp, D, dma, dml, dmU):
        om = self.om
        pidx = np.empty(om.n, int)
        pidx[om.cur] = np.arange(om.cur.size)
        Ul = self.U_l

        def one(li):
            _, _, n, o = om.lines[li]
            A = np.zeros((3 * n, 3 * n))
            A[0, 0] = 1.0
            A[1, 1] = 1.0
            for k in range(1, n):
                A[3 * k:3 * k + 2, 3 * (k - 1):3 * k + 3] = Jp[pidx[o + k]]
            r3 = np.arange(n) * 3 + 2
            sl = slice(o, o + n)
            A[r3[:, None], (np.arange(n) * 3)[None, :]] -= D[li] * dma[sl][None, :] / Ul
            A[r3[:, None], (np.arange(n) * 3 + 1)[None, :]] -= D[li] * dml[sl][None, :] / Ul
            A[r3[:, None], (np.arange(n) * 3 + 2)[None, :]] -= D[li] * dmU[sl][None, :] / Ul
            A[r3, r3] += 1.0                    # R3 = (U − U_e)/U_l, неизвестная U/U_l
            return lu_factor(A, check_finite=False)
        with ThreadPoolExecutor(M.CPU_THREADS) as ex:
            return list(ex.map(one, range(len(om.lines))))

    # ---- выход -----------------------------------------------------------------------------------------------------
    def layer_grid(self, a=None, lam=None, U=None):
        a = self.a if a is None else a
        lam = self.lam if lam is None else lam
        U = self.U if U is None else U
        st = bl.state(a, lam, self.z0)
        om = self.om
        L = {k: om.grid(st[k]) for k in ("theta", "dstar", "delta", "H")}
        L.update(a=om.grid(a), lam=om.grid(lam), cf=om.grid(2 * st["cf2"]), U=om.grid(U),
                 mode=np.zeros((om.nl, om.ns), int))
        return L


def sigma_on(run, strips, om, m):
    """σ_d на другой сетке панелей (группа точек) из m на Ω — та же линейная Q."""
    return solve_rhs(run.infl, build_Q(run.panels, strips, om) @ m)


def vii2_parts(run, x, y, z, sig_d=None, lf=None, z0=None):
    """Скорость в точках (абсолютные z). lf = None — слой выключен: потенциал (run.sigma + лог-фон) + вдув σ_d (при
    σ_d = None — побитно potential). lf задан: u = |U_o(x, y, max(z_agl, δ))|·f(z_agl), U_o = потенциал + вдув.
    → dict: speed, upar_sign, f, outer_speed, layer, zagl, ok."""
    panels, be = run.panels, run.infl.backend
    x = np.asarray(x, float).ravel()
    y = np.asarray(y, float).ravel()
    z = np.asarray(z, float).ravel()
    zg = panels.height(x, y)
    zagl = z - zg
    if lf is None:
        u, v, w = _inf.velocity(panels, run.sigma, run.bg, x, y, z, None, be)
        if sig_d is not None:
            ok = np.isfinite(u)
            pw = _inf.panel_velocity(panels, sig_d, np.stack([x, y, np.where(ok, z, zg + 1)], 1), be)
            u, v = u + pw[:, 0], v + pw[:, 1]
        return dict(speed=np.hypot(u, v), ok=np.isfinite(u), zagl=zagl)
    z0 = run.z0 if z0 is None else z0
    st = lf.at(x, y)
    d = z0 * np.exp(st["lam"])
    ze = np.maximum(zagl, d)
    u, v, w = _inf.velocity(panels, run.sigma, run.bg, x, y, zg + ze, None, be)
    ok = np.isfinite(u)
    if sig_d is not None:
        pw = _inf.panel_velocity(panels, sig_d, np.stack([x, y, np.where(ok, zg + ze, zg + 1)], 1), be)
        u, v = u + pw[:, 0], v + pw[:, 1]
    f = bl.profile(np.maximum(zagl, 0.0), st["a"], st["lam"], z0)
    sp = np.hypot(u, v)
    return dict(speed=sp * np.abs(f), upar_sign=np.sign(f), f=f, outer_speed=sp, layer=st, zagl=zagl, ok=ok)
