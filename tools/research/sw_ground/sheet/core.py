"""Вихревой лист слоя сдвига над мёртвой зоной (ток вместо заряда) по геометрии следа SWG-4 + внутренний слой JH (couple).

Схема (идея 2 SWG-1, круг 2 задачи 1). Геометрия — та же, что SWG-4 (wake.core.WakeGrid, триггер «slope»: гребень
crests_profile, x_r — rotor3d.profile_rule, отрыв при lee_slope > 0,27; оболочка upper_hull от x_s до x_r), импортируется
без изменений. По оболочке на каждом профиле вдоль ветра лежит разделяющая линия тока (Kirchhoff — Helmholtz — Roshko):
снаружи — внешний поток U_e, под ней — мёртвая зона со скоростью u_d. Скачок касательной скорости через неё — вихревой
лист γ = U_e − u_d (Batchelor 1967, §2.6, вихревой слой; Roshko 1955, NACA TN 3168 — давление в зоне постоянно).

Дискретизация (как sheet3d SWD6: ряды поперёк потока, замкнутые петли с возвратом под землёй): станции вдоль ветра шаг
ds_sheet; на станции узлы всех профилей c, где станция лежит в [x_s, x_r] гребня; узел — на оболочке (высота h = env − z
над поверхностью панелей, не ниже core/2). Отрезок ряда между соседними узлами — петля: ряд → ножка вниз к земле →
возврат под землёй на глубине max h + core → вторая ножка (Γ = γ̄·Δl, Δl — длина дуги оболочки на станцию); ножки
соседних петель на общем узле складываются (Γ_{k−1} − Γ_k). Направление ряда +p = ẑ × ê (завихренность ∂u/∂z > 0).
Отражение — панелями: σ_ex = A⁻¹·(−(u_лист·n)) теми же LU; поле — velocity_jh(..., extra=лист, couple=True).

Замыкание γ (два варианта, основной выбран до сравнения):
  * "rest" (основной): u_d = 0 (покой в зоне), γ = U_e; U_e — касательная (вдоль оболочки) скорость внешнего поля
    (панели + лог-фон + лист) на внешней стороне листа = U_ср + γ/2 (U_ср — значение на листе, главное значение);
    итерации γ ← U_ср(γ) + γ/2 до max|Δγ|/U_ref < 1e-3 (не более N_ITER), несошедшиеся узлы — счётчиком.
    В 2D (ровный лист над стенкой) U_ср = U − γ/2 → γ = U за одну итерацию: снаружи поток не меняется, под листом 0.
  * "cpb": γ = U_ref·√(1 − C_pb), C_pb = −0,2 (sheet3d v6 CPB_DEFAULT; Tani 1964, Roshko & Lau 1965 — по памяти
    литературы, см. README sheet3d), без итераций.
"""
from __future__ import annotations

import numpy as np
from scipy.interpolate import RegularGridInterpolator

from ground import model as M  # noqa: F401  (патчи panels3d: lu overwrite_a, assemble в потоках)
import filaments3d as F
from panels3d import influence as _inf
from panels3d.jh import _line_profile, _column_scales, inner_depth, middle_top
from panels3d.terrain import bg_uniform, wind_of, u_ref_of
from wake.core import upper_hull, solve_rhs

TOL = 1e-3            # max|Δγ|/U_ref — критерий остановки (замечание ревью SWG-4)
N_ITER = 30           # предел итераций γ
CPB = -0.2            # C_pb варианта "cpb" (sheet3d CPB_DEFAULT)


# ---------------- геометрия листа ----------------
class SheetGeom:
    """Узлы листа на решётке (профиль c × станция a) по WakeGrid: active, h (м над землёй профиля), tanθ, w (Δl, м)."""

    def __init__(self, grid, terrain, ds_sheet=None):
        self.grid = grid
        g = grid
        self.ds = float(ds_sheet if ds_sheet is not None else 2.0 * g.step)       # ds_min при step = ds_min/2
        st = max(1, int(round(self.ds / g.step)))
        self.ds = st * g.step
        K = (g.svals.size - 1) // 2
        self.avals = g.svals[::st]
        na, nc = self.avals.size, g.cvals.size
        self.act = np.zeros((nc, na), bool)
        self.h = np.zeros((nc, na))
        self.tan = np.zeros((nc, na))
        self.w = np.zeros((nc, na))
        self.Hfine = np.zeros((nc, g.svals.size))              # высота оболочки над землёй на шаге профиля (зона)
        by_c = {}
        for q in g.segs:
            if q["gated"] and q["s_s"] is not None:
                by_c.setdefault(q["c"], []).append(q)
        self.segs = []
        for ic, c in enumerate(g.cvals):
            qs = by_c.get(float(c))
            if not qs:
                continue
            x0, y0 = g.cx + c * g.px, g.cy + c * g.py
            s, z = _line_profile(terrain, x0, y0, g.ex, g.ey, g.step)
            kk = np.rint(s / g.step).astype(int) + K
            for q in qs:
                i0 = int(np.argmin(np.abs(s - q["s_c"])))
                i1 = int(min(np.searchsorted(s, q["s_r"]), s.size - 1))
                ss, zz = s[i0:i1 + 1], z[i0:i1 + 1]
                hv = upper_hull(ss, zz)
                env = np.interp(ss, ss[hv], zz[hv])
                he = np.maximum(env - zz, 0.0)
                m = ss >= q["s_s"] - 1e-9
                self.Hfine[ic, kk[i0:i1 + 1]] = np.maximum(self.Hfine[ic, kk[i0:i1 + 1]], np.where(m, he, 0.0))
                # станции
                ia = np.nonzero((self.avals >= q["s_s"] - 1e-9) & (self.avals <= q["s_r"] + 1e-9))[0]
                if ia.size < 2:
                    continue
                a = self.avals[ia]
                ea = np.interp(a, ss[hv], zz[hv])
                za = np.interp(a, ss, zz)
                tn = np.gradient(ea, a) if a.size > 1 else np.zeros_like(a)
                lo = np.maximum(a - 0.5 * self.ds, q["s_s"])
                hi = np.minimum(a + 0.5 * self.ds, q["s_r"])
                wl = np.maximum(hi - lo, 0.0) * np.sqrt(1.0 + tn * tn)
                self.act[ic, ia] = True
                self.h[ic, ia] = np.maximum(self.h[ic, ia], ea - za)
                self.tan[ic, ia] = tn
                self.w[ic, ia] = np.maximum(self.w[ic, ia], wl)
                self.segs.append(dict(c=float(c), s_s=float(q["s_s"]), s_r=float(q["s_r"]), n=int(ia.size),
                                      hmax=float((ea - za).max())))
        self.n_nodes = int(self.act.sum())
        self._hz = RegularGridInterpolator((g.cvals, g.svals), self.Hfine, bounds_error=False, fill_value=0.0)

    def xy(self, ic, ia):
        g = self.grid
        c, a = g.cvals[ic], self.avals[ia]
        return g.cx + c * g.px + a * g.ex, g.cy + c * g.py + a * g.ey

    def zone_height(self, x, y):
        """Высота оболочки (разделяющей линии тока) над землёй в точке (0 вне зоны)."""
        c, a = self.grid.rot(x, y)
        return self._hz(np.stack([np.ravel(c), np.ravel(a)], 1)).reshape(np.shape(c))

    def nodes(self, panels, core):
        """Узлы (активные, по порядку ic, ia): X (n, 3) абсолютные, tangent (n, 3), w (n), index (n, 2)."""
        ic, ia = np.nonzero(self.act)
        x, y = self.xy(ic, ia)
        zg = np.asarray(panels.height(x, y), float)
        h = np.maximum(self.h[ic, ia], 0.5 * core)
        X = np.stack([x, y, zg + h], 1)
        tn = self.tan[ic, ia]
        cth = 1.0 / np.sqrt(1.0 + tn * tn)
        T = np.stack([cth * self.grid.ex, cth * self.grid.ey, cth * tn], 1)
        return X, T, self.w[ic, ia], np.stack([ic, ia], 1), h


def build_filaments(geom, X, idx, h, gam, core, panels):
    """Нити листа: по станциям — непрерывные серии активных профилей; отрезок k→k+1 с Γ_k = ½(γ_k w_k + γ_{k+1} w_{k+1}),
    ножки (воздух → земля → глубина) с Γ_{k−1} − Γ_k, возврат под землёй с −Γ_k. → Filaments (сумма замкнутых петель)."""
    xs, segs, G = [], [], []
    n0 = 0
    order = {(int(a), int(b)): i for i, (a, b) in enumerate(idx)}
    na = geom.act.shape[1]
    for ja in range(na):
        col = np.nonzero(geom.act[:, ja])[0]
        if col.size < 2:
            continue
        runs, cur = [], [col[0]]
        for c in col[1:]:
            if c == cur[-1] + 1:
                cur.append(c)
            else:
                runs.append(cur)
                cur = [c]
        runs.append(cur)
        for r in runs:
            if len(r) < 2:
                continue
            ii = np.array([order[(c, ja)] for c in r])
            A = X[ii]
            zg = A[:, 2] - h[ii]
            depth = float(h[ii].max()) + core
            Gd = A.copy()
            Gd[:, 2] = zg
            R = A.copy()
            R[:, 2] = zg - depth
            m = len(ii)
            gk = 0.5 * (gam[ii[:-1]] + gam[ii[1:]])            # γ̄·Δl на отрезок
            # узлы: A_0..A_{m-1}, G_0..G_{m-1}, R_0..R_{m-1}
            pa, pg, pr = n0 + np.arange(m), n0 + m + np.arange(m), n0 + 2 * m + np.arange(m)
            xs += [A, Gd, R]
            s_air = np.stack([pa[:-1], pa[1:]], 1)
            s_ret = np.stack([pr[1:], pr[:-1]], 1)
            gl = np.zeros(m)                                # вниз по ножке: Γ_{k−1} − Γ_k
            gl[1:] += gk
            gl[:-1] -= gk
            s_l1 = np.stack([pa, pg], 1)
            s_l2 = np.stack([pg, pr], 1)
            segs += [s_air, s_ret, s_l1, s_l2]
            G += [gk, gk, gl, gl]
            n0 += 3 * m
    if not segs:
        return F.Filaments()
    xs = np.concatenate(xs)
    seg = np.concatenate(segs)
    G = np.concatenate(G)
    keep = np.abs(G) > 0
    anc = np.zeros(len(xs), bool)
    return F.Filaments(xs, seg[keep], G[keep], core, anc, np.zeros(int(keep.sum()), int))


def _extra(fil):
    if fil is None or len(fil.seg) == 0:
        return None
    return lambda x, y, z: F.induced(fil, x, y, z)


def sigma_extra(run, extra):
    """σ_ex: непротекание для поля листа (те же LU)."""
    c = run.panels.c
    eu, ev, ew = _inf.horizontal_extra(extra, c)
    b = -(np.stack([eu, ev, ew], 1) * run.panels.n).sum(1)
    return solve_rhs(run.infl, b)


class Sheet:
    """Лист на сетке run (GRun): геометрия geom, γ по узлам, нити fil, σ_ex. closure: "rest" | "cpb"."""

    def __init__(self, run, geom, closure="rest", core=None, tol=TOL, n_iter=N_ITER, cpb=CPB, gamma=None):
        self.run, self.geom, self.closure = run, geom, closure
        panels = run.panels
        self.core = float(core if core is not None else 0.5 * panels.ds_min)
        self.U_ref = float(u_ref_of(run.bg, panels.terrain)[0])
        self.info = dict(closure=closure, n_nodes=geom.n_nodes, iters=0, converged=True, n_unconverged=0, hist=[])
        self.fil, self.sig_ex = F.Filaments(), np.zeros(panels.N)
        if geom.n_nodes == 0:
            self.gamma = np.zeros(0)
            return
        X, T, w, idx, h = geom.nodes(panels, self.core)
        self.X, self.T, self.w, self.idx, self.h = X, T, w, idx, h
        if gamma is not None:
            g = np.asarray(gamma, float)
            self._set(g)
        elif closure == "cpb":
            g = np.full(len(X), self.U_ref * np.sqrt(1.0 - cpb))
            self._set(g)
            self.info.update(u_b=float(g[0]), cpb=float(cpb))
        elif closure == "rest":
            g = self._ut(None, None)                       # γ⁰ = U_e без листа
            self._set(g)
            for it in range(1, n_iter + 1):
                um = self._ut(_extra(self.fil), self.sig_ex)
                gn = np.maximum(um + 0.5 * g, 0.0)
                dg = np.abs(gn - g) / self.U_ref
                self.info["hist"].append(float(dg.max()))
                g = gn
                self._set(g)
                self.info["iters"] = it
                if dg.max() < tol:
                    break
            self.info["n_unconverged"] = int(np.sum(dg >= tol))
            self.info["converged"] = bool(dg.max() < tol)
            self.info["dgamma_last"] = float(dg.max())
        else:
            raise ValueError("closure: rest | cpb")
        self.info.update(gamma_mean=float(np.mean(self.gamma)), gamma_max=float(np.max(self.gamma)),
                         gamma_over_Uref=float(np.mean(self.gamma) / self.U_ref), n_seg=int(len(self.fil.seg)))

    def _set(self, g):
        self.gamma = g
        self.fil = build_filaments(self.geom, self.X, self.idx, self.h, g * self.w, self.core, self.run.panels)
        self.sig_ex = sigma_extra(self.run, _extra(self.fil))

    def _ut(self, extra, sig_ex):
        """Касательная (вдоль оболочки) скорость поля панели + фон (+ лист) в узлах листа."""
        r = self.run
        X = self.X
        u, v, w = r.bg(X[:, 0], X[:, 1], X[:, 2])
        U = np.stack([np.asarray(u, float), np.asarray(v, float), np.asarray(w, float)], 1)
        U += _inf.panel_velocity(r.panels, r.sigma if sig_ex is None else r.sigma + sig_ex, X, r.infl.backend)
        if extra is not None:
            eu, ev, ew = extra(X[:, 0], X[:, 1], X[:, 2])
            U += np.stack([eu, ev, ew], 1)
        return (U * self.T).sum(1)

    @property
    def extra(self):
        return _extra(self.fil)


# ---------------- поле в точках: potential_jh + лист ----------------
def sheet_parts(run, x, y, z, sheet=None, z0=None):
    """ground.model.jh_parts с полем листа (extra = нити, σ_ex): снаружи слоя — потенциал + лист; ΔS внутреннего слоя —
    из полной внешней u∥ на max(z_agl, l) (как velocity_jh(..., extra, couple=True)). Без листа (sheet None или пуст) —
    jh_parts побитно. Также zone_speed — вариант «под листом скорость зоны»: в точках z_agl < h_зоны — |внешнее поле
    (потенциал + лист) в точке| · ln(z/z0)/ln(h/z0) (лог-профиль от земли зоны), выше — как speed."""
    panels, sigma, bg, infl = run.panels, run.sigma, run.bg, run.infl
    empty = sheet is None or len(sheet.fil.seg) == 0
    if empty:
        p = M.jh_parts(run, x, y, z, z0)
        p.update(potw_speed=p["pot_speed"], dS_w=np.zeros_like(p["dS"]), zone_h=np.zeros_like(p["dS"]),
                 zone_speed=p["speed"], under=np.zeros(p["dS"].shape, bool))
        return p
    z0 = run.z0 if z0 is None else z0
    terrain = panels.terrain
    ex, ey = wind_of(bg, terrain)
    U_ref, _ = u_ref_of(bg, terrain)
    x = np.asarray(x, float).ravel()
    y = np.asarray(y, float).ravel()
    z = np.asarray(z, float).ravel()
    be = infl.backend
    key = ("uniform", float(U_ref), round(ex, 12), round(ey, 12))
    if key not in infl._cache:
        from panels3d import solve
        infl._cache[key] = solve(panels, bg_uniform(U_ref, (ex, ey)), None, infl)[0]
    sig_u = infl._cache[key]
    bgu = bg_uniform(U_ref, (ex, ey))
    ext, sig_ex = sheet.extra, sheet.sig_ex
    zg = panels.height(x, y)
    zagl = z - zg
    L = _column_scales(terrain, x, y, ex, ey, panels.ds_min)
    l = inner_depth(L, z0)
    hm = middle_top(L, z0)
    uv, vv, wv = _inf.velocity(panels, sigma, bg, x, y, z, None, be)
    ok = np.isfinite(uv)
    P = np.stack([x, y, np.where(ok, z, zg + 1.0)], 1)
    eu, ev, ew = _inf.horizontal_extra(ext, P)
    pw = _inf.panel_velocity(panels, sig_ex, P, be)
    uv_w, vv_w, wv_w = uv + eu + pw[:, 0], vv + ev + pw[:, 1], wv + ew + pw[:, 2]
    zz = np.where(ok, np.maximum(zagl, z0), z0)
    ze = np.maximum(zz, l)
    Pe = np.stack([x, y, np.where(ok, zg + ze, zg + 1.0)], 1)
    up, vp, _ = _inf.velocity(panels, sig_u, bgu, Pe[:, 0], Pe[:, 1], Pe[:, 2], None, be)
    eue, eve, _ = _inf.horizontal_extra(ext, Pe)
    pwe = _inf.panel_velocity(panels, sig_ex, Pe, be)
    sp = np.hypot(up, vp)
    dx_ = np.where(sp > 1e-9, up / np.maximum(sp, 1e-12), ex)
    dy_ = np.where(sp > 1e-9, vp / np.maximum(sp, 1e-12), ey)
    dS_pot = sp / U_ref - 1.0
    dS_w = ((eue + pwe[:, 0]) * dx_ + (eve + pwe[:, 1]) * dy_) / U_ref
    dS = dS_pot + dS_w
    lnh = np.log(np.maximum(hm, 1.01 * z0) / z0)
    A = np.where(ze < hm, (lnh / np.log(np.maximum(ze, 1.0001 * z0) / z0)) ** 2, 1.0)
    u0 = U_ref * np.log(zz / z0) / np.log(100.0 / z0)
    uin = u0 * (1.0 + A * dS)
    t = np.clip(np.log(zz / hm) / np.log(2.0), 0.0, 1.0)
    uh_out = np.hypot(uv_w, vv_w)
    spo = np.maximum(uh_out, 1e-12)
    ox = np.where(uh_out > 1e-9, uv_w / spo, dx_)
    oy = np.where(uh_out > 1e-9, vv_w / spo, dy_)
    U = (1 - t) * uin * dx_ + t * uh_out * ox
    V = (1 - t) * uin * dy_ + t * uh_out * oy
    U = np.where(ok, U, np.nan)
    V = np.where(ok, V, np.nan)
    W = np.where(ok, wv_w, np.nan)
    speed = np.hypot(U, V)
    hz = sheet.geom.zone_height(x, y)
    under = ok & (zagl < hz)
    prof = np.log(np.maximum(zz, 1.0001 * z0) / z0) / np.log(np.maximum(hz, 1.01 * z0) / z0)
    zone = np.where(under, uh_out * np.clip(prof, 0.0, 1.0), speed)
    return dict(u=U, v=V, w=W, speed=speed, pot_speed=np.where(ok, np.hypot(uv, vv), np.nan),
                potw_speed=np.where(ok, uh_out, np.nan), dS=dS, dS_pot=dS_pot, dS_w=dS_w, A=A, t=t, l=l, hm=hm,
                ok=ok, U_ref=float(U_ref), uin=uin, u0=u0, zone_h=hz, under=under,
                zone_speed=np.where(ok, zone, np.nan))
