"""Нить ротора с геометрическим замыканием (SWD7 v2; closure="two_point" — v1).

Вихрь в потенциальном потоке сам не держится (равновесие Фёппля корня при отрыве на гребне не имеет — sheet3d),
поэтому положение нити задаёт геометрия, одно правило на все места: линия тока над серединой хребта — гребень x_c
и точка присоединения x_r (подножие подветренного склона или середина долины до следующего гребня, что ближе по
ветру); нить — прямая вдоль оси хребта через точку x_m + R·n (x_m — середина между x_c и x_r на поверхности,
n — нормаль к сглаженному склону). Неизвестные R и Γ определяются двумя условиями: касательная скорость по ветру
у поверхности (фон + панели + нить) равна нулю в x_c и в x_r. Скорость линейна по Γ (панели линейны по extra), поэтому
для каждого R два условия решаются: Γ — из первого, R — корень второго (1-D). Подбора по месту нет."""
import time

import numpy as np

import filaments3d as F
import panels3d as P
from panels3d import influence as _inf
from panels3d.jh import crests_profile, _line_profile
from sheet3d import foppl as _fp

DEFAULTS = dict(core=None, closure="reattach", R_rule=0.25, gate="slope", slope_min=0.27, tail_frac=0.10, seg=None, patch=1.5, tol=4e-4,
                r_min=None, r_max=3.0, maxfev=6, m_frac=0.5, slope_smooth=1.0)


def _wind(bg, terrain):
    return _fp._wind(bg, terrain)


# ---------- профиль вдоль ветра: x_c, x_r, x_m ----------
def profile_rule(s, z, ds_min, s_axis=0.0, tail_frac=0.10, m_frac=0.5):
    """Правило геометрии по профилю земли вдоль ветра (s=0 — середина оси). → dict(s_c, s_r, s_m, z_m, slope_m,
    rule_r, zs, H, slope_max_lee) или None, если гребня нет."""
    zs, cr = crests_profile(s, z, ds_min)
    if not cr:
        return None
    c = min(cr, key=lambda q: abs(q["s_c"] - s_axis))
    i = c["i"]
    h = float(s[1] - s[0])
    # подножие: первый минимум сглаженного профиля за гребнем
    d = np.diff(zs)
    j = None
    for k in range(i, len(d)):
        if d[k] > 1e-9:
            j = k
            break
    foot = None
    if j is not None:
        foot = float(s[j])
    nxt = [q for q in cr if q["i"] > i]
    valley = float(s[i] + 0.5 * (nxt[0]["s_c"] - s[i])) if nxt else None
    rule = "foot"
    if foot is None:       # монотонный спад до края профиля: подножие — остаток 10 % высоты над основанием
        zb = float(zs.min())
        lim = zb + tail_frac * (c["z_c"] - zb)
        k = np.nonzero(zs[i:] <= lim)[0]
        foot = float(s[i + k[0]]) if k.size else float(s[-1])
    s_r = foot
    if valley is not None and valley < foot:
        s_r, rule = valley, "valley_mid"
    s_m = c["s_c"] + m_frac * (s_r - c["s_c"])
    z_m = float(np.interp(s_m, s, zs))
    slope_m = float(np.interp(s_m, s[:-1] + 0.5 * h, d / h))
    lee = (s >= c["s_c"]) & (s <= s_r)
    slope_lee = float(-(np.gradient(zs, h)[lee]).min()) if lee.sum() > 1 else 0.0
    return dict(s_c=c["s_c"], s_r=float(s_r), s_m=float(s_m), z_m=z_m, slope_m=slope_m, rule_r=rule,
                z_c=c["z_c"], zs=zs, H=float(c["z_c"] - zs.min()), slope_lee=slope_lee)


class _Rotor(_fp._Ridge):
    """Хребет с двумя станциями (x_c, x_r) на линии тока через середину оси."""

    def __init__(self, panels, bg, ridge, wind, U_ref, core, seg_len, patch, rule):
        self._patch = patch
        super().__init__(panels, bg, ridge, wind, U_ref, core, seg_len, patch, None)
        self.rule = rule
        self.wind = np.asarray(wind, float)
        wv = self.wind / np.hypot(*self.wind)
        self.wv = wv
        # станция 1 — x_c (окно уже построено родителем вокруг P_c = P_sep); станция 2 — x_r
        self.st = [self._station(self.P_c)]
        self.P_r = self.P_c + rule["s_r"] * self.wv
        self.st.append(self._station(self.P_r))
        self.P_m = self.P_c + rule["s_m"] * self.wv
        sl = rule["slope_m"]
        nrm = np.array([-sl, 1.0])
        self.n_h, self.n_z = nrm / np.hypot(*nrm)      # горизонтальная (вдоль ветра) и вертикальная части нормали
        self.nsolve = 0

    def _station(self, pt):
        panels = self.panels
        c = panels.c
        d = np.hypot(c[:, 0] - pt[0], c[:, 1] - pt[1])
        rr = self._patch * panels.ds_min
        idx = np.nonzero(d <= rr)[0]
        while idx.size < 4 and rr < 6 * panels.ds_min:
            rr *= 1.3
            idx = np.nonzero(d <= rr)[0]
        cp = c[idx]
        bgp = np.stack([np.asarray(q, float) for q in self.bg(cp[:, 0], cp[:, 1], cp[:, 2])], 1)
        return dict(pt=pt, idx=idx, cp=cp, dn=(cp[:, :2] - pt) @ self.na, da=(cp[:, :2] - pt) @ self.a, bgp=bgp)

    def tangent(self, st, sigma, extra, with_bg=True):
        """Касательная скорость по ветру (вдоль n_a) в станции: пересечение МНК-плоскости по окну панелей."""
        panels = self.panels
        pv = _inf.panel_velocity(panels, sigma, st["cp"], "auto", self_idx=st["idx"])
        U = (st["bgp"] + pv) if with_bg else pv
        if extra is not None:
            eu, ev, ew = extra(st["cp"][:, 0], st["cp"][:, 1], st["cp"][:, 2])
            U = U + np.stack([eu, ev, ew], 1)
        nn = panels.n[st["idx"]]
        ut = U - (U * nn).sum(1)[:, None] * nn
        v = ut[:, 0] * self.na[0] + ut[:, 1] * self.na[1]
        A = np.column_stack([np.ones(len(v)), st["dn"], st["da"]])
        return float(np.linalg.lstsq(A, v, rcond=None)[0][0]) if len(v) >= 4 else float(v.mean())

    def geometry(self, R):
        """(s, h) нити для R: s — смещение от P_c по нормали к оси (проекция смещения вдоль ветра, s_w·(wv·na)), h — высота над землёй под серединой нити."""
        s_w = self.rule["s_m"] + R * self.n_h                    # смещение вдоль ветра (в плоскости профиля)
        s = s_w * float(self.wv @ self.na)                       # → вдоль нормали к оси na: так build/node_xy ставят нить
        xy = self.P_c + s * self.na
        zf = self.rule["z_m"] + R * self.n_z
        return float(s), float(zf - float(self.panels.height(xy[0], xy[1])))

    def unit(self, R, infl, bg0):
        """b_i = касательная скорость от единичной нити (панели откликаются; фон 0): одно решение панелей."""
        s, h = self.geometry(R)
        if h < 2.0 * self.core:
            return None
        fil = self.build(s, h, 1.0)
        extra = _fp._induced_fn(fil)
        sig, _ = P.solve(self.panels, bg0, extra, infl)
        self.nsolve += 1
        return np.array([self.tangent(st, sig, extra, False) for st in self.st]), sig


def _solve_reattach(ob, infl, sigma_bg, bg0, pr):
    """v2: R — правило геометрии (R_rule·(x_r − x_c) по нормали от x_m), единственная неизвестная Γ из условия
    u_t(x_r) = 0 (линейно по Γ: a₂ + Γ·b₂ = 0, одно решение панелей); x_c — не условие, u_t(x_c) — результат."""
    a = np.array([ob.tangent(st, sigma_bg, None) for st in ob.st])
    rule = ob.rule
    R = float(pr["R_rule"]) * (rule["s_r"] - rule["s_c"])
    rec = dict(R=R, G=np.nan, s=np.nan, h=np.nan, res=np.inf, converged=False, fil=None,
               a=(float(a[0]), float(a[1])), nsolve=0, grid=[], ut_c=np.nan)
    u = ob.unit(R, infl, bg0)
    if u is not None:
        b, sig1 = u
        if abs(b[1]) > 1e-12 * ob.U:
            G = -a[1] / b[1]
            s, h = ob.geometry(R)
            res = abs(a[1] + G * b[1]) / ob.U
            ok = bool(np.isfinite(G) and G > 0 and res < 1e-3)
            rec.update(G=float(G), s=s, h=h, res=float(res), converged=ok, ut_c=float(a[0] + G * b[0]))
            if ok:
                rec["fil"] = ob.build(s, h, G)
                rec["sigma"] = sigma_bg + G * sig1       # линейность по Γ
    rec["nsolve"] = ob.nsolve
    return rec


def lee_slope(s, z, s_c, s_r, smooth_m):
    """Правило уклона для порога 0,27 (SWD9 v3 п. 2, одно с chain3d): максимум подветренного уклона профиля рельефа
    вдоль ветра между гребнем s_c и присоединением s_r при сглаживании smooth_m = 1·ds_min панелей, без доп. сглаживания."""
    from scipy.ndimage import gaussian_filter1d
    h = float(s[1] - s[0])
    zg = gaussian_filter1d(np.asarray(z, float), smooth_m / h, mode="nearest")
    lee = (s >= s_c) & (s <= s_r)
    return float(-np.gradient(zg, h)[lee].min()) if lee.sum() > 1 else 0.0


def _gate_slope(rule, slope_min):
    return rule["slope_lee"] > slope_min


def rotor_vortex(panels, bg, z0, infl=None, params=None):
    """Нить ротора по хребтам (контракт SWD7 v2). → (fil, sigma, info)."""
    t_start = time.time()
    pr = dict(DEFAULTS)
    pr.update(params or {})
    terrain = panels.terrain
    ds = panels.ds_min
    core = 0.5 * ds if pr["core"] is None else float(pr["core"])
    if infl is None:
        infl = P.assemble(panels, "auto")
    sigma_bg, _ = P.solve(panels, bg, None, infl)
    from panels3d.terrain import u_ref_of
    U_ref, _ = u_ref_of(bg, terrain)
    wind = _wind(bg, terrain)
    ridges = _fp.find_ridges(terrain, wind, ds)
    info = dict(ridges=[], n_ridges=len(ridges), n_rejected=0, n_unconverged=0, t_s=0.0, nsolve=0, candidates=[])
    gate = pr["gate"]
    if pr["closure"] not in ("reattach", "two_point"):
        raise ValueError("closure: reattach | two_point")
    if gate not in ("head", "slope", "none"):
        raise ValueError("gate: head | slope | none")
    kept_ids = {id(r) for r in ridges}
    if ridges:
        sep = P.separation3d(panels, sigma_bg, bg, z0, None, "head", True)
        kept_ids = {id(r) for r in _fp._gate_by_separation(list(ridges), sep, wind, ds, dict(n_rejected=0))}
    wv = np.asarray(wind, float) / np.hypot(*wind)
    step = min(ds, terrain.dx, terrain.dy, ds / 2.0)
    recs, fils = [], []
    bg0 = P.bg_zero()
    for r in ridges:
        ax = _fp._axis_of(r, wind, r["dc"])
        P_c = ax["c0"] + 0.5 * (ax["t0"] + ax["t1"]) * ax["a"]
        s, z = _line_profile(terrain, float(P_c[0]), float(P_c[1]), wv[0], wv[1], step)
        rule = profile_rule(s, z, ds, 0.0, pr["tail_frac"], pr["m_frac"])
        if rule is not None:
            rule["slope_lee"] = lee_slope(s, z, rule["s_c"], rule["s_r"], ds * pr["slope_smooth"])
        head_ok = id(r) in kept_ids
        slope_ok = rule is not None and _gate_slope(rule, pr["slope_min"])
        info["candidates"].append(dict(x_c=float(P_c[0]), y_c=float(P_c[1]), head=bool(head_ok), slope=bool(slope_ok),
                                       slope_lee=None if rule is None else float(rule["slope_lee"])))
        ok = {"head": head_ok, "slope": slope_ok, "none": True}[gate]
        if rule is None or not ok:
            info["n_rejected"] += 1
            continue
        ob = _Rotor(panels, bg, r, wind, U_ref, core, 2.0 * ds if pr["seg"] is None else float(pr["seg"]),
                    pr["patch"], rule)
        if pr["closure"] == "reattach":
            recs.append((ob, _solve_reattach(ob, infl, sigma_bg, bg0, pr)))
        else:
            recs.append((ob, _solve_rotor(ob, infl, bg, sigma_bg, bg0, pr)))
    for ob, rec in recs:
        rule = ob.rule
        out = dict(x_c=float(ob.P_c[0]), y_c=float(ob.P_c[1]), x_r=float(ob.P_r[0]), y_r=float(ob.P_r[1]),
                   x_m=float(ob.P_m[0]), y_m=float(ob.P_m[1]), axis=(float(ob.a[0]), float(ob.a[1])),
                   L_axis=float(ob.Lax), H=float(ob.H), rule_r=rule["rule_r"], slope_lee=float(rule["slope_lee"]),
                   R=rec["R"], Gamma=rec["G"], s=rec["s"], h=rec["h"], gate=gate, placed=bool(rec["converged"]),
                   converged=bool(rec["converged"]), residual=rec["res"], nsolve=rec["nsolve"], ut_bg=rec["a"], grid=rec["grid"],
                   ut_c=rec.get("ut_c", np.nan), closure=pr["closure"])
        info["ridges"].append(out)
        info["nsolve"] += rec["nsolve"]
        if rec["converged"]:
            fils.append(rec["fil"])
        else:
            info["n_unconverged"] += 1
    fil = _fp._merge(fils)
    sigma = sigma_bg
    if len(fil.seg):
        if len(fils) == 1:
            sigma = [rec for ob, rec in recs if rec["converged"]][0]["sigma"]
        else:
            sigma, _ = P.solve(panels, bg, _fp._induced_fn(fil), infl)      # несколько хребтов: общее решение
            info["nsolve"] += 1
    info["t_s"] = time.time() - t_start
    return fil, sigma, info


def _solve_rotor(ob, infl, bg, sigma_bg, bg0, pr):
    """R/H: корень g(R) = a₂ − a₁·b₂/b₁ = 0 (Γ = −a₁/b₁ > 0) — сетка из 3 точек, затем секущие/Мюллер."""
    a = np.array([ob.tangent(st, sigma_bg, None) for st in ob.st])
    U = ob.U
    H = ob.H
    rmin = (2.5 * ob.core / H) if pr["r_min"] is None else pr["r_min"]
    cache = {}

    def b_of(r):
        key = round(float(r), 12)
        if key not in cache:
            cache[key] = ob.unit(r * H, infl, bg0)
        return None if cache[key] is None else cache[key][0]

    def g_of(r):
        b = b_of(r)
        if b is None or abs(b[0]) < 1e-12 * U:
            return np.nan
        G = -a[0] / b[0]
        return (a[1] + G * b[1]) / U

    def gamma_of(r):
        b = b_of(r)
        return -a[0] / b[0]
    # поиск смены знака g(R) по R/H на геометрической сетке
    grid = [rmin * (pr["r_max"] / rmin) ** (k / 2.0) for k in range(3)]
    vals = [g_of(r) for r in grid]
    best = dict(R=np.nan, G=np.nan, res=np.inf, converged=False, fil=None)
    roots = []
    for k in range(len(grid) - 1):
        if np.isfinite(vals[k]) and np.isfinite(vals[k + 1]) and vals[k] * vals[k + 1] < 0 and \
                gamma_of(grid[k]) > 0 and gamma_of(grid[k + 1]) > 0:
            roots.append((grid[k], grid[k + 1], vals[k], vals[k + 1]))
    rec = dict(R=np.nan, G=np.nan, s=np.nan, h=np.nan, res=float(np.nanmin(np.abs(vals))) if np.any(np.isfinite(vals)) else np.inf,
               converged=False, fil=None, a=(float(a[0]), float(a[1])), nsolve=0, grid=list(zip(grid, vals)))
    if roots:
        lo, hi, flo, fhi = roots[0]                                   # скобка со сменой знака g
        pts = [(grid[k], vals[k]) for k in range(len(grid))]          # все вычисленные (R/H, g)
        for _ in range(pr["maxfev"]):
            near = sorted(pts, key=lambda q: abs(q[1]))[:3]          # обратная квадратичная по трём ближайшим к нулю
            r = None
            if len({q[1] for q in near}) == 3:
                (x0, f0), (x1, f1), (x2, f2) = near
                r = (x0 * f1 * f2 / ((f0 - f1) * (f0 - f2)) + x1 * f0 * f2 / ((f1 - f0) * (f1 - f2))
                     + x2 * f0 * f1 / ((f2 - f0) * (f2 - f1)))
            if r is None or not (lo < r < hi):
                r = hi - fhi * (hi - lo) / (fhi - flo)                # иначе — метод ложного положения
            fr = g_of(r)
            pts.append((r, fr))
            if not np.isfinite(fr) or abs(fr) < pr["tol"]:
                break
            if fr * flo < 0:
                hi, fhi = r, fr
            else:
                lo, flo = r, fr
        r = pts[-1][0]
        G = gamma_of(r)
        res = abs(g_of(r))
        s, h = ob.geometry(r * H)
        ok = bool(np.isfinite(res) and res < 1e-3 and G > 0)
        rec.update(R=float(r * H), G=float(G * 1.0), s=s, h=h, res=float(res), converged=ok)
        if ok:
            rec["fil"] = ob.build(s, h, G)
            rec["sigma"] = sigma_bg + G * cache[round(float(r), 12)][1]      # линейность по Γ: без нового решения
    rec["nsolve"] = ob.nsolve
    return rec


def velocity_rotor(panels, sigma, bg, fil, x, y, z, z0, U_ref=None, infl=None):
    """(u, v, w) = velocity_jh(..., extra=induced(fil), couple=True)."""
    return P.velocity_jh(panels, sigma, bg, x, y, z, z0, U_ref=U_ref, extra=_fp._induced_fn(fil), infl=infl,
                         couple=True)
