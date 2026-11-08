"""Заряды вытеснения следа (Lighthill 1958) на панелях 3D за отрывом + внутренний слой JH со следом (couple).

Схема (идея 1 SWG-1). След — тело вытеснения: на панелях между отрывом x_s и присоединением x_r граничное условие
«нормальная скорость = 0» заменяется выдувом v_n = q = d(U_e·δ*)/ds (Lighthill 1958, J. Fluid Mech. 4:383, §2).
Это только новая правая часть той же системы (A σ_w = q; матрица и LU панелей — те же), поле σ_w линейно добавляется к
потенциалу; внутренний слой JH берёт ΔS из полного внешнего поля (как velocity_jh(..., couple=True)).

Геометрия следа — по профилям земли вдоль ветра (квазидвумерно, как правила гребней panels3d/rotor3d), одно правило:
  * гребни — panels3d.jh.crests_profile; для каждого гребня x_r — rotor3d.profile_rule (подножие склона или середина
    долины до следующего гребня, что ближе) — правило SWD7 v2;
  * триггер «slope»: максимум подветренного уклона rotor3d.lee_slope (сглаживание 1·ds_min) > 0,27 (SWD9 v3 п. 2);
  * мёртвая зона — область между поверхностью и «натянутой нитью» (верхней выпуклой оболочкой профиля) от гребня до
    x_r: разделяющая линия тока не может пройти ниже профиля и при u ≈ 0 под ней даёт вклад в δ* = ∫(1 − u/U_e)dn,
    равный её высоте h_env; x_s — точка, где оболочка отходит от профиля;
  * слой смешения над ней: толщина завихренности δ_ω = C_ω·(s − x_s), C_ω = 0,181 (Brown & Roshko 1974, J. Fluid
    Mech. 64:775, λ = 1 — односторонний слой смешения); его вклад в δ* — δ_ω/2 (линейный профиль скорости 0…U_e);
    закрытие к присоединению — множитель (1 − ξ), ξ = (s − x_s)/(x_r − x_s) (допущение: δ* → 0 в x_r);
  * δ* = h_env + (δ_ω/2)(1 − ξ) на [x_s, x_r], 0 вне; несколько гребней — максимум.
U_e — касательная скорость невязкого решения на поверхности (однородный поток U_ref + след), q считается по
U_e·dδ*/ds + δ*·dU_e/ds вдоль ветра; несколько итераций (U_e со следом → q) — вязко-невязкое взаимодействие.
"""
from __future__ import annotations

import numpy as np
from scipy.interpolate import LinearNDInterpolator, RegularGridInterpolator

from ground import model as M  # noqa: F401  (патчи panels3d: lu overwrite_a, assemble в потоках; не менять)
from panels3d import influence as _inf
from panels3d.jh import crests_profile, _line_profile, _column_scales, inner_depth, middle_top
from panels3d.terrain import bg_uniform, wind_of, u_ref_of
from rotor3d.rotor import profile_rule, lee_slope

SLOPE_MIN = 0.27      # порог подветренного уклона (SWD7/SWD9 v3: rotor3d DEFAULTS slope_min)
C_OMEGA = 0.181       # dδ_ω/dx одностороннего слоя смешения (Brown & Roshko 1974, λ = 1)
N_ITER = 4            # итерации U_e(след) → q (сходимость — по s в точках между двумя последними)


# ---------------- профиль вдоль ветра ----------------
def upper_hull(s, z):
    """Индексы верхней выпуклой оболочки точек (s, z), s по возрастанию (монотонная цепь Эндрю)."""
    h = []
    for i in range(s.size):
        while len(h) >= 2:
            a, b = h[-2], h[-1]
            if (s[b] - s[a]) * (z[i] - z[a]) - (z[b] - z[a]) * (s[i] - s[a]) >= 0:
                h.pop()
            else:
                break
        h.append(i)
    return np.array(h)


def profile_dstar(s, z, ds_min, gate="slope", slope_min=SLOPE_MIN, c_omega=C_OMEGA, sep_mask=None):
    """δ*(s) следа на профиле земли z(s) (равномерный шаг). gate: "slope" — порог уклона; "all" — каждый гребень;
    "mask" — гребни, у которых в подветренном отрезке есть True в sep_mask (внешний триггер, напр. Хед).
    → (dstar, segments: список dict с s_c, s_s, s_r, slope, H, rule_r, gated, dmax)."""
    s = np.asarray(s, float)
    z = np.asarray(z, float)
    d = np.zeros(s.size)
    segs = []
    if s.size < 5:
        return d, segs
    _, cr = crests_profile(s, z, ds_min)
    for c in cr:
        rule = profile_rule(s, z, ds_min, s_axis=c["s_c"])
        if rule is None:
            continue
        slope = lee_slope(s, z, rule["s_c"], rule["s_r"], ds_min)
        i0 = int(c["i"])
        i1 = int(min(np.searchsorted(s, rule["s_r"]), s.size - 1))
        seg = dict(s_c=float(rule["s_c"]), s_r=float(rule["s_r"]), slope=float(slope), H=float(rule["H"]),
                   rule_r=rule["rule_r"], gated=False, s_s=None, dmax=0.0)
        if gate == "slope":
            ok = slope > slope_min
        elif gate == "mask":
            ok = sep_mask is not None and bool(np.any(sep_mask[i0:i1 + 1]))
        else:
            ok = True
        segs.append(seg)
        if not ok or i1 - i0 < 3:
            continue
        ss, zz = s[i0:i1 + 1], z[i0:i1 + 1]
        hv = upper_hull(ss, zz)
        env = np.interp(ss, ss[hv], zz[hv])
        h = np.maximum(env - zz, 0.0)
        pos = np.nonzero(h > 1e-6 * max(rule["H"], 1.0))[0]
        if pos.size == 0:
            continue
        # отрыв — вершина оболочки перед первым отходом от профиля
        k = hv[hv < pos[0]]
        j_s = int(k[-1]) if k.size else 0
        s_s = float(ss[j_s])
        Ls = float(ss[-1] - s_s)
        xi = np.clip((ss - s_s) / max(Ls, 1e-9), 0.0, 1.0)
        dsl = np.where(ss >= s_s, 0.5 * c_omega * (ss - s_s) * (1.0 - xi), 0.0)
        dd = h + dsl
        d[i0:i1 + 1] = np.maximum(d[i0:i1 + 1], dd)
        seg.update(gated=True, s_s=s_s, dmax=float(dd.max()))
    return d, segs


class WakeGrid:
    """δ*(x, y) на решётке профилей вдоль ветра (шаг вдоль step, поперёк dc) по рельефу terrain."""

    def __init__(self, terrain, wind_to, ds_min, step=None, dc=None, gate="slope", slope_min=SLOPE_MIN,
                 c_omega=C_OMEGA, sep_fn=None):
        w = np.asarray(wind_to, float)
        self.ex, self.ey = w / np.hypot(w[0], w[1])
        self.px, self.py = -self.ey, self.ex
        self.cx, self.cy = float(terrain.cx), float(terrain.cy)
        self.step = float(step if step is not None else min(0.5 * ds_min, terrain.dx * 2, 12.5))
        self.dc = float(dc if dc is not None else ds_min)
        R = 0.5 * float(np.hypot(terrain.x[-1] - terrain.x[0], terrain.y[-1] - terrain.y[0]))
        K = int(np.ceil(R / self.step)) + 2
        self.svals = self.step * np.arange(-K, K + 1)
        nc = int(np.ceil(R / self.dc)) + 1
        self.cvals = self.dc * np.arange(-nc, nc + 1)
        D = np.zeros((self.cvals.size, self.svals.size))
        self.segs = []
        for ic, c in enumerate(self.cvals):
            x0, y0 = self.cx + c * self.px, self.cy + c * self.py
            s, z = _line_profile(terrain, x0, y0, self.ex, self.ey, self.step)
            if s.size < 10:
                continue
            m = None
            if sep_fn is not None:
                m = sep_fn(x0 + s * self.ex, y0 + s * self.ey)
            d, segs = profile_dstar(s, z, ds_min, gate if sep_fn is None else "mask", slope_min, c_omega, m)
            k = np.rint(s / self.step).astype(int) + K
            D[ic, k] = d
            for g in segs:
                g.update(c=float(c), x_c=float(x0 + g["s_c"] * self.ex), y_c=float(y0 + g["s_c"] * self.ey),
                         x_r=float(x0 + g["s_r"] * self.ex), y_r=float(y0 + g["s_r"] * self.ey))
                self.segs.append(g)
        self.D = D
        self._it = RegularGridInterpolator((self.cvals, self.svals), D, bounds_error=False, fill_value=0.0)

    def rot(self, x, y):
        x = np.asarray(x, float) - self.cx
        y = np.asarray(y, float) - self.cy
        return x * self.px + y * self.py, x * self.ex + y * self.ey

    def dstar(self, x, y):
        c, a = self.rot(x, y)
        return self._it(np.stack([np.ravel(c), np.ravel(a)], 1)).reshape(np.shape(c))

    def ddstar(self, x, y):
        """dδ*/ds вдоль ветра (горизонтально), центральная разность с шагом step."""
        h = self.step
        x = np.asarray(x, float)
        y = np.asarray(y, float)
        return (self.dstar(x + h * self.ex, y + h * self.ey) - self.dstar(x - h * self.ex, y - h * self.ey)) / (2 * h)


# ---------------- заряды на панелях ----------------
def solve_rhs(infl, b):
    """σ: A σ = b тем же LU (кеш Influence)."""
    xp = infl._xp
    if infl.backend == "cupy":
        from cupyx.scipy.linalg import lu_solve
    else:
        from scipy.linalg import lu_solve
    sig = lu_solve(infl.lu(), xp.asarray(b))
    return np.asarray(sig.get() if hasattr(sig, "get") else sig)


def wake_panels(panels, grid):
    """Панели, на которых след (δ* или dδ*/ds ≠ 0 в центре, серединах рёбер или ±ds по ветру) → индексы, средние по
    серединам рёбер δ*, dδ*/ds, cos β вдоль ветра."""
    v = panels.v
    c = panels.c
    mids = 0.5 * (v + v[:, [1, 2, 0]])                 # (N, 3, 3)
    ex, ey = grid.ex, grid.ey
    probe = [grid.dstar(c[:, 0], c[:, 1])]
    for k in range(3):
        probe.append(grid.dstar(mids[:, k, 0], mids[:, k, 1]))
    for sg in (-1, 1):
        probe.append(grid.dstar(c[:, 0] + sg * panels.ds * ex, c[:, 1] + sg * panels.ds * ey))
    sub = np.nonzero(np.max(np.stack(probe), 0) > 0)[0]
    d = np.mean([grid.dstar(mids[sub, k, 0], mids[sub, k, 1]) for k in range(3)], 0)
    dd = np.mean([grid.ddstar(mids[sub, k, 0], mids[sub, k, 1]) for k in range(3)], 0)
    n = panels.n[sub]
    sl = -(n[:, 0] * ex + n[:, 1] * ey) / np.maximum(n[:, 2], 1e-6)      # уклон вдоль ветра dz/ds_h
    cosb = 1.0 / np.sqrt(1.0 + sl * sl)
    return sub, d, dd, cosb


def surface_ue(panels, sigma, bgu, sub, backend):
    """|касательная скорость| в центрах панелей sub (σ — полный, bgu — однородный фон)."""
    c = panels.c[sub]
    u, v, w = bgu(c[:, 0], c[:, 1], c[:, 2])
    pv = _inf.panel_velocity(panels, sigma, c, backend, self_idx=sub)
    U = np.stack([np.asarray(u, float), np.asarray(v, float), np.asarray(w, float)], 1) + pv
    n = panels.n[sub]
    Ut = U - (U * n).sum(1)[:, None] * n
    return np.linalg.norm(Ut, axis=1)


def wake_sigma(run, grid, n_iter=N_ITER, log=None):
    """σ_w следа на сетке run (GRun): итерации U_e → q → σ_w. → (σ_w, info)."""
    panels, infl = run.panels, run.infl
    be = infl.backend
    ex, ey = wind_of(run.bg, panels.terrain)
    U_ref, _ = u_ref_of(run.bg, panels.terrain)
    key = ("uniform", float(U_ref), round(ex, 12), round(ey, 12))
    if key not in infl._cache:
        from panels3d import solve
        infl._cache[key] = solve(panels, bg_uniform(U_ref, (ex, ey)), None, infl)[0]
    sig_u = infl._cache[key]
    bgu = bg_uniform(U_ref, (ex, ey))
    sub, d, dd, cosb = wake_panels(panels, grid)
    sig_w = np.zeros(panels.N)
    info = dict(n_wake_panels=int(sub.size), iters=[], U_ref=float(U_ref))
    if sub.size == 0:
        return sig_w, info
    cxy = panels.c[sub, :2]
    hstep = np.maximum(0.5 * panels.ds[sub], grid.step)
    q_prev = None
    sigs = []
    for it in range(n_iter):
        ue = surface_ue(panels, sig_u + sig_w, bgu, sub, be)
        f = LinearNDInterpolator(cxy, ue)
        up = f(cxy[:, 0] + hstep * ex, cxy[:, 1] + hstep * ey)
        dn = f(cxy[:, 0] - hstep * ex, cxy[:, 1] - hstep * ey)
        due = np.where(np.isfinite(up) & np.isfinite(dn), (up - dn) / (2 * hstep), 0.0)
        q = cosb * (ue * dd + d * due)
        b = np.zeros(panels.N)
        b[sub] = q
        sig_w = solve_rhs(infl, b)
        sigs.append(sig_w)
        dq = None if q_prev is None else float(np.max(np.abs(q - q_prev)) / max(np.max(np.abs(q)), 1e-12))
        info["iters"].append(dict(it=it, q_max=float(np.max(np.abs(q))), dq_rel=dq,
                                  flux=float(np.sum(q * panels.area[sub])), ue_mean=float(np.mean(ue[d > 0])) if np.any(d > 0) else None))
        q_prev = q
    info["q"] = q
    info["sub"] = sub
    info["sigs"] = sigs
    return sig_w, info


# ---------------- поле в точках: potential_jh + след ----------------
def wake_parts(run, x, y, z, sig_w, z0=None):
    """Как ground.model.jh_parts (velocity_jh), но с полем следа σ_w: снаружи слоя — потенциал + σ_w; ΔS внутреннего
    слоя — из полной внешней скорости на max(z_agl, l) (как velocity_jh couple=True: проекция поля следа на
    направление потенциального потока). При σ_w ≡ 0 совпадает с jh_parts побитно."""
    panels, sigma, bg, infl = run.panels, run.sigma, run.bg, run.infl
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
    zg = panels.height(x, y)
    zagl = z - zg
    L = _column_scales(terrain, x, y, ex, ey, panels.ds_min)
    l = inner_depth(L, z0)
    hm = middle_top(L, z0)
    uv, vv, wv = _inf.velocity(panels, sigma, bg, x, y, z, None, be)
    ok = np.isfinite(uv)
    P = np.stack([x, y, np.where(ok, z, zg + 1.0)], 1)
    pw = _inf.panel_velocity(panels, sig_w, P, be)
    uv_w, vv_w, wv_w = uv + pw[:, 0], vv + pw[:, 1], wv + pw[:, 2]
    zz = np.where(ok, np.maximum(zagl, z0), z0)
    ze = np.maximum(zz, l)
    Pe = np.stack([x, y, np.where(ok, zg + ze, zg + 1.0)], 1)
    up, vp, _ = _inf.velocity(panels, sig_u, bgu, Pe[:, 0], Pe[:, 1], Pe[:, 2], None, be)
    pwe = _inf.panel_velocity(panels, sig_w, Pe, be)
    sp = np.hypot(up, vp)
    dx_ = np.where(sp > 1e-9, up / np.maximum(sp, 1e-12), ex)
    dy_ = np.where(sp > 1e-9, vp / np.maximum(sp, 1e-12), ey)
    dS_pot = sp / U_ref - 1.0
    dS_w = (pwe[:, 0] * dx_ + pwe[:, 1] * dy_) / U_ref
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
    return dict(u=U, v=V, w=W, speed=np.hypot(U, V), pot_speed=np.where(ok, np.hypot(uv, vv), np.nan),
                potw_speed=np.where(ok, uh_out, np.nan), dS=dS, dS_pot=dS_pot, dS_w=dS_w, A=A, t=t, l=l, hm=hm,
                ok=ok, U_ref=float(U_ref), uin=uin, u0=u0)


def _zero_extra(x, y, z):
    o = np.zeros(np.shape(x))
    return o, o.copy(), o.copy()


def separation3d_wrap(run, sig_w=None):
    """Хед (panels3d.separation3d, lee_only) по полю потенциал (+ след σ_w): u_s — полная касательная скорость,
    линии тока — по решению для фона (streamlines_from="bg")."""
    from panels3d import separation3d
    panels = run.panels
    panels._infl_obj = run.infl
    run.infl._cache[("bg", run.bg)] = run.sigma
    try:
        if sig_w is None:
            return separation3d(panels, run.sigma, run.bg, run.z0, None, "head", True)
        return separation3d(panels, run.sigma + sig_w, run.bg, run.z0, _zero_extra, "head", True)
    finally:
        panels._infl_obj = None      # иначе Influence (A/LU на GPU) переживает run.free()
