"""Установившаяся нить ротора за гребнем (Фёппль): одна прямая нить вдоль оси хребта, подкова ножками в землю.

Неизвестные на хребет — s (за гребнем, поперёк оси, по ветру), h (над землёй) и Γ; три уравнения:
скорость в середине нити (фон + панели + ножки) вдоль и поперёк оси в плоскости (n, z) равна нулю (равновесие
вихря, Föppl 1913) и касательная скорость у земли в точке гребня на середине нити равна нулю (условие отрыва,
аналог Кутты). Панели видят нить как extra (отражение в земле), ∇·ω = 0 даёт подкова. Только вызывает panels3d и
filaments3d."""
import time

import numpy as np
from scipy.optimize import root

import filaments3d as F
import panels3d as P
from panels3d import influence as _inf

S_MAX, H_MAX = 6.0, 3.0      # физичные пределы корня: s ≤ 6·H, h ≤ 3·H (дальше — корни на бесконечности)
DEFAULTS = dict(core=None, sep="crest", tol=1e-3, gate="head", sep_point=None, sweeps=2, seg=None, maxfev=60, patch=1.5)


def _wind(bg, terrain):
    from panels3d.terrain import wind_of
    return wind_of(bg, terrain)


def _empty():
    return F.Filaments()


def _merge(fils):
    fils = [f for f in fils if len(f.seg)]
    if not fils:
        return _empty()
    xs, segs, gam, core, anc, fid, n0 = [], [], [], [], [], [], 0
    stats = {}
    for k, f in enumerate(fils):
        xs.append(f.x)
        segs.append(f.seg + n0)
        gam.append(f.gamma)
        core.append(f.core)
        anc.append(f.anchored)
        fid.append(np.full(len(f.seg), k, int))
        n0 += len(f.x)
    return F.Filaments(np.concatenate(xs), np.concatenate(segs), np.concatenate(gam), np.concatenate(core),
                       np.concatenate(anc), np.concatenate(fid), stats)


def _induced_fn(fil):
    if fil is None or len(fil.seg) == 0:
        return None
    return lambda x, y, z: F.induced(fil, x, y, z)


# ---------- гребни ----------
def find_ridges(terrain, wind, ds_min, dc=None, d_along=None):
    """Хребты по гребням `hill_length` на линиях поперёк ветра: [{x_c, y_c, z_c, L, pts, lines}]."""
    wx, wy = wind
    cx_, cy_ = -wy, wx
    xs = np.array([terrain.x[0], terrain.x[-1]])
    ys = np.array([terrain.y[0], terrain.y[-1]])
    corners = np.array([[a, b] for a in xs for b in ys])
    cc = corners[:, 0] * cx_ + corners[:, 1] * cy_
    aa = corners[:, 0] * wx + corners[:, 1] * wy
    dc = 2.0 * ds_min if dc is None else dc
    dc = max(dc, (cc.max() - cc.min()) / 400.0)
    da = 3.0 * ds_min if d_along is None else d_along
    da = max(da, (aa.max() - aa.min()) / 120.0)
    cvals = cc.min() + dc * (np.arange(int((cc.max() - cc.min()) // dc) + 1) + 0.5)
    avals = aa.min() + da * (np.arange(int((aa.max() - aa.min()) // da) + 1) + 0.5)
    found = []   # (j, a_c, x_c, y_c, z_c, L)
    for j, c in enumerate(cvals):
        seen = []
        for a in avals:
            x, y = c * cx_ + a * wx, c * cy_ + a * wy
            if not (terrain.x[0] <= x <= terrain.x[-1] and terrain.y[0] <= y <= terrain.y[-1]):
                continue
            r = P.hill_length(terrain, x, y, (wx, wy), ds_min=ds_min)
            if r is None:
                continue
            ac = r["x_c"] * wx + r["y_c"] * wy
            if any(abs(ac - q) < 0.5 * ds_min for q in seen):
                continue
            seen.append(ac)
            found.append((j, ac, r["x_c"], r["y_c"], r["z_c"], r["L"]))
    # связываем гребни соседних линий: |Δa| ≤ 2·ds_min
    n = len(found)
    par = list(range(n))

    def fd(i):
        while par[i] != i:
            par[i] = par[par[i]]
            i = par[i]
        return i
    by_line = {}
    for i, f in enumerate(found):
        by_line.setdefault(f[0], []).append(i)
    for j, ids in by_line.items():
        for i in ids:
            for k in by_line.get(j + 1, []):
                if abs(found[i][1] - found[k][1]) <= 2.0 * ds_min:
                    par[fd(i)] = fd(k)
    groups = {}
    for i in range(n):
        groups.setdefault(fd(i), []).append(i)
    out = []
    for ids in groups.values():
        lines = sorted({found[i][0] for i in ids})
        if len(lines) < 2:
            continue
        pts = np.array([[found[i][2], found[i][3], found[i][4]] for i in ids])
        out.append(dict(pts=pts, lines=lines, L=float(np.median([found[i][5] for i in ids])), dc=dc,
                        x_c=float(pts[:, 0].mean()), y_c=float(pts[:, 1].mean()), z_c=float(pts[:, 2].mean())))
    out.sort(key=lambda r: r["x_c"] * wx + r["y_c"] * wy)
    return out


def _axis_of(r, wind, dc):
    pts = r["pts"][:, :2]
    c0 = pts.mean(0)
    wx, wy = wind
    a_ref = np.array([-wy, wx])      # ẑ × ŵ: ω_y = ∂u/∂z − ∂w/∂x > 0 в слое сдвига, Γ > 0 вдоль оси
    if len(pts) >= 2:
        u, sv, vt = np.linalg.svd(pts - c0)
        a = vt[0] if sv[0] > 1e-9 else a_ref
    else:
        a = a_ref
    a = a / np.hypot(*a)
    if a @ a_ref < 0:
        a = -a
    na = np.array([a[1], -a[0]])     # a × ẑ — поперёк оси, по ветру
    t = (pts - c0) @ a
    return dict(c0=c0, a=a, na=na, t0=float(t.min() - 0.5 * dc), t1=float(t.max() + 0.5 * dc))


def _ridge_height(terrain, r, wind):
    wx, wy = wind
    s = np.linspace(-4 * r["L"], 4 * r["L"], 81)
    z = terrain.height(r["x_c"] + s * wx, r["y_c"] + s * wy)
    return float(z.max() - z.min())


class _Ridge:
    """Геометрия и невязки одного хребта."""

    def __init__(self, panels, bg, ridge, wind, U_ref, core, seg_len, patch, p_sep=None):
        self.panels = panels
        self.bg = bg
        self.U = U_ref
        ax = _axis_of(ridge, wind, ridge["dc"])
        self.__dict__.update(ax)
        self.H = max(_ridge_height(panels.terrain, ridge, wind), 2.0 * panels.ds_min)
        self.core = core
        self.t_mid = 0.5 * (self.t0 + self.t1)
        self.Lax = self.t1 - self.t0
        nseg = max(4, int(np.ceil(self.Lax / seg_len)))
        nseg += nseg % 2                       # середина — узел
        self.tt = np.linspace(self.t0, self.t1, nseg + 1)
        self.P_c = self.c0 + self.t_mid * self.a            # точка гребня на середине нити
        self.P_sep = self.P_c if p_sep is None else np.asarray(p_sep, float)    # точка отрыва (гребень или Хед)
        # окно панелей у гребня для касательной скорости
        c = panels.c
        d = np.hypot(c[:, 0] - self.P_sep[0], c[:, 1] - self.P_sep[1])
        rr = patch * panels.ds_min
        idx = np.nonzero(d <= rr)[0]
        while idx.size < 4 and rr < 6 * panels.ds_min:
            rr *= 1.3
            idx = np.nonzero(d <= rr)[0]
        self.idx = idx
        self.cp = c[idx]
        self.dn = (self.cp[:, :2] - self.P_sep) @ self.na
        self.da = (self.cp[:, :2] - self.P_sep) @ self.a
        self.bgp = np.stack([np.asarray(q, float) for q in bg(self.cp[:, 0], self.cp[:, 1], self.cp[:, 2])], 1)
        self.nfev = 0

    def node_xy(self, s):
        return self.c0[None] + self.tt[:, None] * self.a[None] + s * self.na[None]

    def mid_point(self, s, h):
        xy = self.c0 + self.t_mid * self.a + s * self.na
        return xy, float(self.panels.height(xy[0], xy[1])) + h

    def build(self, s, h, G):
        """Замкнутая петля: подкова над землёй (ножки до поверхности панелей) + возврат под землёй на глубине h + core.
        Подкова без замыкания даёт фантомные источники на концах (BS открытой линии не соленоидален) — панели
        отражают её с ошибкой ~20 %; замкнутая петля (возврат под землёй, где завихренности в воздухе нет) даёт
        точное отражение (проверено: = метод изображений ± 0,2 %)."""
        xy = self.node_xy(s)
        _, zm = self.mid_point(s, h)
        n1 = len(xy)
        zg = np.asarray(self.panels.height(xy[:, 0], xy[:, 1]), float)
        depth = h + self.core
        top = np.column_stack([xy, np.full(n1, zm)])
        ret = np.column_stack([xy, zg - depth])
        g0 = np.array([xy[0, 0], xy[0, 1], zg[0]])
        g1 = np.array([xy[-1, 0], xy[-1, 1], zg[-1]])
        # R0 → G0 → T0..Tn → G1 → Rn → ... → R1 (→ R0)
        pts = np.vstack([ret[:1], g0[None], top, g1[None], ret[::-1][:-1]])
        m = len(pts)
        seg = np.stack([np.arange(m), (np.arange(m) + 1) % m], 1)
        anc = np.zeros(m, bool)
        anc[1] = True
        anc[2 + n1] = True
        return F.Filaments(pts, seg, G, self.core, anc, np.zeros(m, int))

    def tangent_crest(self, sigma, extra):
        """Компонента касательной скорости вдоль n_a в точке гребня (МНК-плоскость по окну панелей)."""
        panels = self.panels
        pv = _inf.panel_velocity(panels, sigma, self.cp, "auto", self_idx=self.idx)
        U = self.bgp + pv
        if extra is not None:
            eu, ev, ew = extra(self.cp[:, 0], self.cp[:, 1], self.cp[:, 2])
            U = U + np.stack([eu, ev, ew], 1)
        nn = panels.n[self.idx]
        ut = U - (U * nn).sum(1)[:, None] * nn
        v = ut[:, 0] * self.na[0] + ut[:, 1] * self.na[1]
        if len(v) >= 4:
            A = np.column_stack([np.ones(len(v)), self.dn, self.da])
            coef = np.linalg.lstsq(A, v, rcond=None)[0]
            return float(coef[0])
        return float(v.mean())

    def residual(self, x, infl, others, bg):
        s, h, G = x[0] * self.H, x[1] * self.H, x[2] * self.U * self.H
        self.nfev += 1
        if h < 0.2 * self.core:
            h = 0.2 * self.core
        fil = self.build(s, h, G)
        allf = _merge([others, fil]) if others is not None and len(others.seg) else fil
        extra = _induced_fn(allf)
        sigma, _ = P.solve(self.panels, bg, extra, infl)
        xy, zm = self.mid_point(s, h)
        u, v, w = P.velocity(self.panels, sigma, bg, np.array([xy[0]]), np.array([xy[1]]), np.array([zm]), extra)
        un = u[0] * self.na[0] + v[0] * self.na[1]
        ut = self.tangent_crest(sigma, extra)
        return np.array([un, w[0], ut]) / self.U, fil, sigma


def foppl_vortex(panels, bg, z0, infl=None, params=None):
    """Нити Фёппля за гребнями (контракт SWD6 v2). → (fil, sigma, info)."""
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
    ridges = find_ridges(terrain, wind, ds)
    info = dict(ridges=[], n_ridges=len(ridges), n_rejected=0, n_unconverged=0, t_s=0.0, nfev=0)
    if ridges and (pr["gate"] == "head" or pr["sep"] == "separation3d"):
        sep = P.separation3d(panels, sigma_bg, bg, z0, None, "head", True)
        ridges = _gate_by_separation(ridges, sep, wind, ds, info)
    objs = []
    for r in ridges:
        seg_len = 2.0 * ds if pr["seg"] is None else float(pr["seg"])
        ps = r.get("p_sep") if pr["sep"] == "separation3d" else None
        if pr["sep_point"] is not None:
            ps = pr["sep_point"]
        objs.append(_Ridge(panels, bg, r, wind, U_ref, core, seg_len, pr["patch"], ps))
    fils = [None] * len(objs)
    res = [None] * len(objs)
    sweeps = 1 if len(objs) <= 1 else int(pr["sweeps"])
    sigma = sigma_bg
    for sw in range(sweeps):
        for i, ob in enumerate(objs):
            others = _merge([f for k, f in enumerate(fils) if k != i and f is not None])
            x0 = np.array([1.0, 0.5, 1.0]) if res[i] is None or not res[i]["converged"] else res[i]["x"]
            res[i] = _solve_ridge(ob, x0, infl, others, bg, pr)
            fils[i] = res[i]["fil"] if res[i]["converged"] else None
    for i, ob in enumerate(objs):
        rr = res[i]
        rec = dict(x_c=float(ob.P_c[0]), y_c=float(ob.P_c[1]), axis=(float(ob.a[0]), float(ob.a[1])),
                   L_axis=float(ob.Lax), H=float(ob.H), s=rr["s"], h=rr["h"], Gamma=rr["G"],
                   converged=bool(rr["converged"]), residual=rr["res"], iters=rr["nfev"], starts=rr["starts"])
        rec["p_sep"] = (float(ob.P_sep[0]), float(ob.P_sep[1]))
        info["ridges"].append(rec)
        info["nfev"] += rr["nfev"]
        if not rr["converged"]:
            info["n_unconverged"] += 1
    fil = _merge([f for f in fils if f is not None])
    if len(fil.seg):
        sigma, _ = P.solve(panels, bg, _induced_fn(fil), infl)
    else:
        sigma = sigma_bg
    info["t_s"] = time.time() - t_start
    return fil, sigma, info


def _solve_ridge(ob, x0, infl, others, bg, pr):
    """root(hybr) по (s/H, h/H, Γ/(U·H)) с начальным (1, 1/2, 1); корень принимается, если |r| < tol, s > 0 и
    h ≥ 2·core (вихрь не в ядре у земли), s ≤ 6·H, h ≤ 3·H. Иначе — запасные старты на сетке (s, h) с Γ из МНК по двум линейным по Γ
    уравнениям равновесия."""
    nf0 = ob.nfev
    best = dict(x=np.asarray(x0, float), err=np.inf, ok=False)
    hmin = 2.0 * ob.core / ob.H

    def run(start):
        cache = {}

        def fun(x):
            r, fil, sig = ob.residual(x, infl, others, bg)
            cache["last"] = (x.copy(), r, fil)
            return r
        try:
            sol = root(fun, start, method="hybr", options=dict(maxfev=int(pr["maxfev"]), xtol=1e-6))
            x = sol.x
            r = fun(x)
            err = float(np.abs(r).max())
            ok = bool(np.all(np.isfinite(r)) and err < pr["tol"] and 0 < x[0] <= S_MAX and hmin <= x[1] <= H_MAX)
            return dict(x=x, err=err, ok=ok, fil=cache["last"][2])
        except Exception:
            return dict(x=np.asarray(start, float), err=np.inf, ok=False, fil=None)

    starts = [np.asarray(x0, float)]
    n_starts = 0
    for k, st in enumerate(starts + [None] * 8):
        if st is None:
            grid = [(sg, hg) for sg in (1.0, 2.5) for hg in (0.5, 1.0, 0.25, 1.5)]
            if k - 1 >= len(grid):
                break
            sg, hg = grid[k - 1]
            r0 = ob.residual(np.array([sg, hg, 0.0]), infl, others, bg)[0]
            r1 = ob.residual(np.array([sg, hg, 1.0]), infl, others, bg)[0] - r0
            den = float(r1[:2] @ r1[:2])
            g0 = -float(r0[:2] @ r1[:2]) / den if den > 0 else 1.0
            st = np.array([sg, hg, g0])
        n_starts += 1
        res = run(st)
        if res["ok"]:
            best = res
            break
        if res["err"] < best["err"]:
            best = res
    x = best["x"]
    return dict(x=x, s=float(x[0] * ob.H), h=float(x[1] * ob.H), G=float(x[2] * ob.U * ob.H), res=best["err"],
                converged=best["ok"], fil=best.get("fil"), nfev=ob.nfev - nf0, starts=n_starts)


def _gate_by_separation(ridges, sep, wind, ds, info):
    """Хребет принимается, если Хед даёт отрыв за ним: точка отрыва лежит позади гребня (по ветру, до 12·L)
    в полосе поперёк ветра по протяжению хребта."""
    wx, wy = wind
    cx_, cy_ = -wy, wx
    pp = sep.get("points", {})
    pts = [dict(x=float(a), y=float(b)) for a, b in zip(pp.get("x", []), pp.get("y", []))]
    keep = []
    for r in ridges:
        r["p_sep"] = None
        c = r["pts"][:, 0] * cx_ + r["pts"][:, 1] * cy_
        lo, hi = c.min() - r["dc"], c.max() + r["dc"]
        a_c = float(np.median(r["pts"][:, 0] * wx + r["pts"][:, 1] * wy))
        ok = False
        cm = float(c.mean())
        best = np.inf
        for p in pts:
            cp = p["x"] * cx_ + p["y"] * cy_
            ap = p["x"] * wx + p["y"] * wy
            if lo <= cp <= hi and 0.0 <= ap - a_c <= 12.0 * r["L"] + 4 * ds:
                ok = True
                if abs(cp - cm) < best:
                    best = abs(cp - cm)
                    r["p_sep"] = (p["x"], p["y"])
        if ok:
            keep.append(r)
        else:
            info["n_rejected"] += 1
    return keep


def velocity_foppl(panels, sigma, bg, fil, x, y, z, z0, U_ref=None, infl=None):
    """(u, v, w) = velocity_jh(..., extra=induced(fil), couple=True); без нитей — velocity_jh без extra."""
    return P.velocity_jh(panels, sigma, bg, x, y, z, z0, U_ref=U_ref, extra=_induced_fn(fil), infl=infl, couple=True)
