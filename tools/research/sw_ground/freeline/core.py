"""SWG-12 (круг 4B задачи 1): геометрия мёртвой зоны — свободная линия тока с гребня вместо оболочки.

Исходное — SWG-8 (zone.core: правило зоны, слой смешения), SWG-7 (sheet.core: лист «rest», нити, sheet_parts), SWG-4
(wake.core.WakeGrid, wake.run.make_grid — гребни, триггеры «slope»/«head»). Импорт без изменений; изменённые копии — здесь
под новыми именами: FreeGeom (вместо SheetGeom), FreeMix (вместо zone.MixSheet), free_profile/free_parts (вместо
zone_profile/zone_parts).

Геометрия (FreeGeom). На каждом профиле вдоль ветра (решётка WakeGrid: шаг 12,5 м, поперёк 25 м) для каждого гребня,
прошедшего триггер, разделяющая линия тока η(s) — свободная линия тока Кирхгофа (Kirchhoff 1869; Roshko 1955):
  * сходит с гребня x_s = s_c (crests_profile) по касательной к наветренному склону: η'(x_s+) = z'(x_s−);
  * на [x_s, x_r] — нормальная скорость 0 (η — линия тока) и постоянное давление (|u| = const ⇒ u' = u_b);
  * присоединение x_r: (1) мост — первая точка за гребнем, где земля снова поднимается до высоты гребня z(x_s), если она
    раньше следующего гребня (долина между хребтами перекрыта); (2) иначе — правило SWD7 v2 rotor3d.profile_rule
    (подножие или середина долины); закрытие η(x_r) = z(x_r);
  * форма — линейная (малые уклоны) теория обтекания: u'(x)/U = (1/π) v.p.∫ g'(ξ)/(x − ξ) dξ, g — эффективная
    поверхность (земля вне [x_s, x_r], η внутри); дискретно — уклоны на полуузлах, u' в узлах, ядро 1/(π(k − j − ½)).
    Неизвестные — η' на полуузлах зоны и u_b; уравнения — u' = u_b во внутренних узлах, закрытие, касательная у гребня:
    одна линейная система на отрезок, без итераций по форме. Если η уходит под землю раньше x_r — x_r переносится в
    первое пересечение и система решается снова (≤ N_CUT раз, счётчик).
  * u_b получается из решения (не задаётся): −2·u_b — C_pb линейной теории (давление в зоне, Roshko 1955); u_sep — u' на
    гребне без зоны; u_b = u_sep — условие Кирхгофа (Brillouin — Villat), здесь не требуется (длина задана присоединением).
Высота зоны h = max(η − z, 0); листы SWG-7 — на η (узлы, касательная η'), Γ — «rest» SWG-7 без изменений.

Слой смешения (FreeMix) — как zone.MixSheet, но δ_ω = 0,181·(s − x_s) ограничено сверху: δ ≤ max(h − core/2, core)
(ревью SWG-8: слои не уходят под землю и не слипаются у пола).

Скорость зоны (free_parts) — правило SWG-8 с поправками ревью: u_h — со знаком (проекция на ветер); U_e — γ листа
(«rest»: γ = касательная внешняя скорость на листе) в ближайшем узле, а не модель на h + δ; δ — то же, что у FreeMix;
предел u_r ≤ C_MAX·U_e — предохранитель (без источника), доля точек на пределе — счётчиком.
"""
from __future__ import annotations

import numpy as np
from scipy.interpolate import RegularGridInterpolator

from ground import model as M  # noqa: F401  (патчи panels3d)
import filaments3d as F
from panels3d.jh import _line_profile, crests_profile
from panels3d.terrain import wind_of
from rotor3d.rotor import profile_rule
from sheet import core as SH
from zone import core as Z

C_DW = Z.C_DW
N_LAYERS = Z.N_LAYERS
C_MAX = Z.C_MAX
N_CUT = 20
NQ = Z.NQ


# ---------------- 2D: свободная линия тока на профиле ----------------
def hilbert(n):
    """K (n × n−1): u'_k/U = Σ_j K[k, j]·g'_j, узлы k, полуузлы j + ½ (равномерный шаг; от шага не зависит)."""
    k = np.arange(n)[:, None]
    j = np.arange(n - 1)[None, :]
    return 1.0 / (np.pi * (k - j - 0.5))


def free_solve(z, i_s, i_r, K):
    """Свободная линия тока на [i_s, i_r] профиля z. → (η на i_s..i_r, u_b·ds, u'·ds по узлам): уклоны берутся как
    разности z (уклон·ds), поэтому u' выходит умноженным на шаг ds (free_line делит)."""
    n = z.size
    gp = np.diff(z)                       # уклон·ds
    m = i_r - i_s
    free = np.arange(i_s, i_r)
    msk = np.ones(n - 1, bool)
    msk[free] = False
    base = K[:, msk] @ gp[msk]
    nodes = np.arange(i_s + 1, i_r)
    A = np.zeros((m + 1, m + 1))
    b = np.zeros(m + 1)
    A[:m - 1, :m] = K[np.ix_(nodes, free)]
    A[:m - 1, m] = -1.0
    b[:m - 1] = -base[nodes]
    A[m - 1, :m] = 1.0
    b[m - 1] = z[i_r] - z[i_s]
    A[m, 0] = 1.0
    b[m] = gp[i_s - 1] if i_s > 0 else 0.0
    x = np.linalg.solve(A, b)
    g = gp.copy()
    g[free] = x[:m]
    eta = z[i_s] + np.concatenate([[0.0], np.cumsum(x[:m])])
    return eta, float(x[m]), K @ g


def attach_index(s, z, i_s, zs_crests, rule_sr):
    """x_r: мост (земля снова на высоте гребня до следующего гребня) или правило SWD7 v2. → (i_r, rule)."""
    nxt = [c for c in zs_crests if c["i"] > i_s + 1]
    i_n = nxt[0]["i"] if nxt else z.size - 1
    up = np.nonzero(z[i_s + 2:i_n + 1] >= z[i_s])[0]
    if up.size:
        return int(i_s + 2 + up[0]), "bridge"
    return int(min(np.searchsorted(s, rule_sr), s.size - 1)), "rule"


def free_line(s, z, i_s, i_r, K, tol=0.5):
    """Решение с переносом x_r в первое пересечение η с землёй. → dict(eta, i_r, u_b, u_sep, u_s, n_cut) или None;
    u_b, u_sep (гребень без зоны), u_s (гребень с зоной) — u'/U линейной теории."""
    ds = float(s[1] - s[0])
    gp = np.diff(z)
    u_sep = float((K @ gp)[i_s]) / ds
    n_cut = 0
    while i_r - i_s >= 3:
        eta, ub, u = free_solve(z, i_s, i_r, K)
        d = eta - z[i_s:i_r + 1]
        bad = np.nonzero(d[1:-1] < -tol)[0]
        if bad.size == 0 or n_cut >= N_CUT:
            return dict(eta=eta, i_r=i_r, u_b=ub / ds, u_sep=u_sep, u_s=float(u[i_s]) / ds, n_cut=n_cut,
                        neg=bool(bad.size > 0))
        i_r = i_s + 1 + int(bad[0])
        n_cut += 1
    return None


# ---------------- геометрия на решётке ----------------
class FreeGeom(SH.SheetGeom):
    """Как sheet.core.SheetGeom (act, h, tan, w, Hfine, segs, zone_height, nodes), но высота зоны — свободная линия тока."""

    def __init__(self, grid, terrain, ds_sheet=None):
        self.grid = g = grid
        self.ds = float(ds_sheet if ds_sheet is not None else 2.0 * g.step)
        st = max(1, int(round(self.ds / g.step)))
        self.ds = st * g.step
        Kc = (g.svals.size - 1) // 2
        self.avals = g.svals[::st]
        na, nc = self.avals.size, g.cvals.size
        self.act = np.zeros((nc, na), bool)
        self.h = np.zeros((nc, na))
        self.tan = np.zeros((nc, na))
        self.w = np.zeros((nc, na))
        self.Hfine = np.zeros((nc, g.svals.size))
        self.Gam = np.zeros((nc, na))                # γ узлов (заполняет set_gamma) — U_e правила зоны
        by_c = {}
        for q in g.segs:
            if q["gated"]:
                by_c.setdefault(q["c"], []).append(q)
        self.segs, self.lines = [], []
        Kcache = {}
        for ic, c in enumerate(g.cvals):
            qs = by_c.get(float(c))
            if not qs:
                continue
            x0, y0 = g.cx + c * g.px, g.cy + c * g.py
            s, z = _line_profile(terrain, x0, y0, g.ex, g.ey, g.step)
            n = s.size
            if n not in Kcache:
                Kcache[n] = hilbert(n)
            K = Kcache[n]
            _, crs = crests_profile(s, z, M.C.DS_MAIN)
            kk = np.rint(s / g.step).astype(int) + Kc
            for q in qs:
                i_s = int(np.argmin(np.abs(s - q["s_c"])))
                i_r, rule = attach_index(s, z, i_s, crs, q["s_r"])
                if i_r - i_s < 3:
                    continue
                fl = free_line(s, z, i_s, i_r, K)
                if fl is None:
                    continue
                i_r = fl["i_r"]
                ss, zz, eta = s[i_s:i_r + 1], z[i_s:i_r + 1], fl["eta"]
                he = np.maximum(eta - zz, 0.0)
                self.Hfine[ic, kk[i_s:i_r + 1]] = np.maximum(self.Hfine[ic, kk[i_s:i_r + 1]], he)
                ia = np.nonzero((self.avals >= ss[0] - 1e-9) & (self.avals <= ss[-1] + 1e-9))[0]
                if ia.size < 2:
                    continue
                a = self.avals[ia]
                ea = np.interp(a, ss, eta)
                za = np.interp(a, ss, zz)
                tn = np.interp(a, 0.5 * (ss[1:] + ss[:-1]), np.diff(eta) / g.step)
                lo = np.maximum(a - 0.5 * self.ds, ss[0])
                hi = np.minimum(a + 0.5 * self.ds, ss[-1])
                wl = np.maximum(hi - lo, 0.0) * np.sqrt(1.0 + tn * tn)
                newer = (ea - za) > self.h[ic, ia]
                self.act[ic, ia] = True
                self.h[ic, ia] = np.where(newer, ea - za, self.h[ic, ia])
                self.tan[ic, ia] = np.where(newer, tn, self.tan[ic, ia])
                self.w[ic, ia] = np.maximum(self.w[ic, ia], wl)
                seg = dict(c=float(c), s_s=float(ss[0]), s_r=float(ss[-1]), n=int(ia.size), hmax=float(he.max()),
                           rule=rule, u_b=fl["u_b"], u_sep=fl["u_sep"], u_s=fl["u_s"], n_cut=fl["n_cut"],
                           neg=fl["neg"], bulge=float(eta.max() - zz[0]), z_s=float(zz[0]), z_r=float(zz[-1]),
                           depth_below_crest=float(zz[0] - zz.min()), slope=float(q["slope"]))
                self.segs.append(seg)
        self.n_nodes = int(self.act.sum())
        self._hz = RegularGridInterpolator((g.cvals, g.svals), self.Hfine, bounds_error=False, fill_value=0.0)

    def set_gamma(self, sheet):
        """γ узлов листа sheet (Sheet на этой геометрии) → решётка; U_e(x, y) — ближайший узел той же колонки."""
        G = np.zeros_like(self.Gam)
        if self.n_nodes and len(sheet.gamma):
            G[sheet.idx[:, 0], sheet.idx[:, 1]] = sheet.gamma
        self.Gam = G
        self._gi = RegularGridInterpolator((self.grid.cvals, self.avals), G, method="nearest", bounds_error=False,
                                           fill_value=0.0)

    def gamma_at(self, x, y):
        c, a = self.grid.rot(x, y)
        return self._gi(np.stack([np.ravel(c), np.ravel(a)], 1)).reshape(np.shape(c))


# ---------------- слой смешения с ограничением δ ----------------
def delta_cap(dw, h, core):
    """δ = min(max(δ_ω, core), max(h − core/2, core)) — нижний слой не ниже core/2 (кроме h < 1,5·core)."""
    return np.minimum(np.maximum(dw, core), np.maximum(h - 0.5 * core, core))


class FreeMix:
    """zone.MixSheet с ограничением δ сверху (delta_cap). Γ та же, что у тонкого листа sh."""

    def __init__(self, sh, n=N_LAYERS, c_dw=C_DW, sep=None):
        self.thin, self.geom, self.run, self.n = sh, sh.geom, sh.run, n
        self.core = sh.core
        self.info = dict(n_layers=n, c_dw=c_dw)
        if sh.geom.n_nodes == 0 or len(sh.fil.seg) == 0:
            self.fil, self.sig_ex = F.Filaments(), np.zeros(sh.run.panels.N)
            return
        sep = sep if sep is not None else Z.SepDist(sh.geom)
        g = sh.geom
        ic, ia = sh.idx[:, 0], sh.idx[:, 1]
        dw0 = c_dw * sep.at_ca(g.grid.cvals[ic], g.avals[ia])
        self.dw = delta_cap(dw0, sh.h, self.core)
        zeta, wk = Z.layer_weights(n)
        zg = sh.X[:, 2] - sh.h
        fs, lifted = [], 0
        for zk, w in zip(zeta, wk):
            hk = sh.h + zk * self.dw
            lifted += int(np.sum(hk < 0.5 * self.core - 1e-9))
            hk = np.maximum(hk, 0.5 * self.core)
            Xk = sh.X.copy()
            Xk[:, 2] = zg + hk
            fs.append(SH.build_filaments(g, Xk, sh.idx, hk, sh.gamma * sh.w * w, self.core, sh.run.panels))
        self.fil = Z.concat(fs)
        self.sig_ex = SH.sigma_extra(sh.run, self.extra)
        self.info.update(n_seg=int(len(self.fil.seg)), lifted_frac=lifted / float(n * len(sh.h)),
                         dw_median=float(np.median(self.dw)), dw_max=float(np.max(self.dw)),
                         capped_frac=float(np.mean(self.dw < np.maximum(dw0, self.core) - 1e-9)))

    @property
    def extra(self):
        return SH._extra(self.fil)


# ---------------- скорость зоны ----------------
def free_profile(z, h, delta, u_h, U_e, z0, c_max=C_MAX, nq=NQ):
    """zone.zone_profile, но u_h — со знаком (u_r берёт его знак); предел |u_r| ≤ c_max·|U_e|. → (u∥, u_r, capped, resid).
    resid — ∫u dz/(max(|u_h|, |u_r|)·h) после предела (0 — баланс замкнут)."""
    z = np.asarray(z, float)
    h = np.maximum(np.asarray(h, float), 1.01 * z0)
    t = np.linspace(0.0, 1.0, nq)
    zq = z0 + (h[:, None] - z0) * t[None, :]
    Gq = 1.0 + np.tanh(2.0 * (zq - h[:, None]) / delta[:, None])
    phq = np.clip(np.log(zq / z0) / np.log(h / z0)[:, None], 0.0, 1.0)
    num = np.trapezoid(Gq, zq, axis=1)
    den = np.trapezoid((1.0 - Gq) * phq, zq, axis=1)
    ur = u_h * num / np.maximum(den, 1e-12)
    cap = c_max * np.abs(U_e)
    capped = np.abs(ur) > cap
    ur = np.clip(ur, -cap, cap)
    resid = (u_h * num - ur * den) / (np.maximum(np.abs(u_h), np.abs(ur)) * h + 1e-12)
    G = 1.0 + np.tanh(2.0 * (z - h) / delta)
    ph = np.clip(np.log(np.maximum(z, z0) / z0) / np.log(h / z0), 0.0, 1.0)
    u = G * u_h - (1.0 - G) * ur * ph
    return u, ur, capped, resid


def free_parts(run, x, y, z, sheet, geom, sep, delta_mode, z0=None):
    """Модель листа sheet (sheet_parts) + правило зоны под η. delta_mode: "mix" (delta_cap) | "thin" (core).
    geom.set_gamma(тонкий лист) должен быть вызван. → dict(speed_sheet, speed, u_par, under, ur, Ue, capped, resid, delta)."""
    z0 = run.z0 if z0 is None else z0
    x = np.asarray(x, float).ravel()
    y = np.asarray(y, float).ravel()
    z = np.asarray(z, float).ravel()
    ex, ey = wind_of(run.bg, run.panels.terrain)
    p = SH.sheet_parts(run, x, y, z, sheet, z0)
    nan = np.full(x.size, np.nan)
    out = dict(speed_sheet=p["speed"], speed=p["speed"].copy(), u_par=Z._signed(p, ex, ey), under=p["under"].copy(),
               ur=nan.copy(), Ue=nan.copy(), capped=np.zeros(x.size, bool), resid=nan.copy(), delta=np.zeros(x.size),
               zone_h=p["zone_h"], parts=p)
    if sheet is None or len(sheet.fil.seg) == 0:
        return out
    core = 0.5 * run.panels.ds_min
    hz = p["zone_h"]
    if delta_mode == "mix":
        delta = delta_cap(C_DW * sep.at_xy(x, y), hz, core)
    else:
        delta = np.full(x.size, core)
    out["delta"] = delta
    u = p["under"]
    if not np.any(u):
        return out
    iu = np.nonzero(u)[0]
    zg = run.panels.height(x[iu], y[iu])
    h = hz[iu]
    ph = SH.sheet_parts(run, x[iu], y[iu], zg + h, sheet, z0)
    u_h = Z._signed(ph, ex, ey)
    U_e = geom.gamma_at(x[iu], y[iu])
    upar, ur, capped, resid = free_profile(z[iu] - zg, h, delta[iu], u_h, U_e, z0)
    out["speed"][iu] = np.abs(upar)
    out["u_par"][iu] = upar
    out["ur"][iu] = ur
    out["Ue"][iu] = U_e
    out["capped"][iu] = capped
    out["resid"][iu] = resid
    return out
