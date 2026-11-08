"""Установившийся вихревой слой из рядов за линией отрыва Хеда (SWD6 v4) и его свёртка в одну нить.

Слой смешения (Kirchhoff — Helmholtz / Roshko): с линии отрыва (`separation3d`, Хед, restart, lee_only) вниз по слою идут
ряды — замкнутые нити поперёк потока (вдоль линии отрыва) с шагом Δs; Γ ряда = γ·Δs, γ = |u_s| в точке отрыва (скачок
скорости через слой). Форма — линии тока полной скорости (фон + панели + слой без самоиндукции ряда) от точки отрыва,
итерациями с релаксацией, до присоединения (узел ближе `core` к земле). Каждый ряд (непрерывная серия активных узлов)
замыкается ножками до земли (якоря) и возвратом под землёй: открытая подкова даёт ~20 % ошибки отражения (SWD-9).
Только вызывает panels3d и filaments3d."""
import time
from dataclasses import dataclass, field

import numpy as np

import filaments3d as F
import panels3d as P
from panels3d import influence as _inf

from .foppl import _induced_fn, _merge, find_ridges, _ridge_height

DEFAULTS = dict(ds_sheet=None, h0=None, core=None, n_iter=10, L_max=None, relax=0.5, gamma_decay=None,
                tol_rel=0.05)


@dataclass
class Sheet:
    """Слой: filaments — все ряды (SWD3); rows — [{line, i, s, Gamma, n_active}]; reattach — по линиям {x, y, z} | None;
    iters, residual (м, макс. сдвиг узлов последней итерации); stats; lines — геометрия по линиям отрыва
    {nodes (nr, n, 3), active (nr, n), gamma0, Gamma, H, L_b, ...} (диагностика)."""
    filaments: F.Filaments = field(default_factory=F.Filaments)
    rows: list = field(default_factory=list)
    reattach: list = field(default_factory=list)
    iters: int = 0
    residual: float = 0.0
    stats: dict = field(default_factory=dict)
    lines: list = field(default_factory=list)
    params: dict = field(default_factory=dict)


# ---------- замкнутые петли ----------
def _loop(panels, xyz, G, core, depth):
    """Замкнутая петля: ряд xyz (m, 3) в воздухе → ножка вниз до поверхности (якорь) → возврат под землёй на глубине
    `depth` под рельефом → вторая ножка. Нить в воздухе — ряд; под землёй завихренности в воздухе нет."""
    n = len(xyz)
    zg = np.asarray(panels.height(xyz[:, 0], xyz[:, 1]), float)
    g0 = np.array([xyz[0, 0], xyz[0, 1], zg[0]])
    g1 = np.array([xyz[-1, 0], xyz[-1, 1], zg[-1]])
    ret = np.column_stack([xyz[:, 0], xyz[:, 1], zg - depth])
    pts = np.vstack([ret[:1], g0[None], xyz, g1[None], ret[::-1][:-1]])
    m = len(pts)
    seg = np.stack([np.arange(m), (np.arange(m) + 1) % m], 1)
    anc = np.zeros(m, bool)
    anc[1] = True
    anc[2 + n] = True
    return F.Filaments(pts, seg, G, core, anc, np.zeros(m, int))


def _runs(mask):
    out, i, n = [], 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j + 1 < n and mask[j + 1]:
                j += 1
            out.append((i, j))
            i = j + 1
        else:
            i += 1
    return out


def _row_loops(panels, nodes_i, act_i, G, core):
    zg = np.asarray(panels.height(nodes_i[:, 0], nodes_i[:, 1]), float)
    loops = []
    for a, b in _runs(act_i):
        if b - a < 1:
            continue
        seg = nodes_i[a:b + 1]
        depth = float((seg[:, 2] - zg[a:b + 1]).max()) + core
        loops.append(_loop(panels, seg, G, core, depth))
    return loops


# ---------- линии отрыва ----------
def _sep_lines(sep, wind):
    """Линии отрыва как списки индексов точек `points` (соседние линии тока подряд, по уровню k), по оси ẑ × ŵ."""
    pts = sep["points"]
    sk, kv = np.asarray(pts["streamline"], int), np.asarray(pts["k"], int)
    a_ref = np.array([-wind[1], wind[0]])
    out = []
    for level in sorted(set(kv.tolist())):
        sel = np.nonzero(kv == level)[0]
        sel = sel[np.argsort(sk[sel])]
        run = []
        for q in sel:
            if run and sk[q] != sk[run[-1]] + 1:
                out.append(run)
                run = []
            run.append(int(q))
        if run:
            out.append(run)
    res = []
    for run in out:
        if len(run) < 2:
            continue
        p = np.array([[pts["x"][q], pts["y"][q]] for q in run])
        if (p[-1] - p[0]) @ a_ref < 0:
            run = run[::-1]
        res.append(run)
    return res


class _Line:
    pass


def _build_lines(panels, bg, sep, wind, U_ref, pr, ds_sheet, h0, core):
    terrain = panels.terrain
    ds = panels.ds_min
    ridges = find_ridges(terrain, wind, ds)
    pts = sep["points"]
    lines = []
    for run in _sep_lines(sep, wind):
        L = _Line()
        L.idx = run
        L.k = int(pts["k"][run[0]])
        xy = np.array([[pts["x"][q], pts["y"][q]] for q in run])
        us = np.abs(np.array([pts["u_s"][q] for q in run], float))
        L.gamma0 = float(us.mean())
        L.us = us
        # высота хребта: ближайший по поперечной координате хребет из find_ridges, иначе разброс высот вдоль ветра
        cx_, cy_ = -wind[1], wind[0]
        cm = float((xy[:, 0] * cx_ + xy[:, 1] * cy_).mean())
        H = None
        for r in ridges:
            c = r["pts"][:, 0] * cx_ + r["pts"][:, 1] * cy_
            if c.min() - 2 * ds <= cm <= c.max() + 2 * ds:
                H = _ridge_height(terrain, r, wind)
                break
        if H is None:
            ss = np.linspace(-600.0, 600.0, 49)
            zz = terrain.height(xy[:, 0].mean() + ss * wind[0], xy[:, 1].mean() + ss * wind[1])
            H = float(zz.max() - zz.min())
        L.H = max(H, 2.0 * ds)
        L.L_max = (10.0 * L.H) if pr["L_max"] is None else float(pr["L_max"])
        L.nr = int(L.L_max // ds_sheet) + 1
        zg = np.asarray(panels.height(xy[:, 0], xy[:, 1]), float)
        L.X0 = np.column_stack([xy, zg + h0])
        L.sep_xy = xy
        lines.append(L)
    return lines


# ---------- итерации формы ----------
class _Solver:
    def __init__(self, panels, bg, z0, infl, sigma_bg, lines, pr, ds_sheet, core):
        self.panels, self.bg, self.infl = panels, bg, infl
        self.lines, self.pr, self.dsh, self.core = lines, pr, ds_sheet, core
        self.sigma_bg = sigma_bg
        self.n_vel = 0

    # геометрия
    def init_shape(self):
        for L in self.lines:
            X0 = L.X0
            v = np.stack(P.velocity(self.panels, self.sigma_bg, self.bg, X0[:, 0], X0[:, 1], X0[:, 2]), 1)
            d = v / np.maximum(np.linalg.norm(v, axis=1), 1e-9)[:, None]
            d[:, 2] = np.maximum(d[:, 2], 0.0)
            d /= np.linalg.norm(d, axis=1)[:, None]
            i = np.arange(L.nr)[:, None, None]
            L.nodes = X0[None] + i * self.dsh * d[None]
            zg = np.asarray(self.panels.height(L.nodes[..., 0], L.nodes[..., 1]), float)
            L.nodes[..., 2] = np.maximum(L.nodes[..., 2], zg + 2 * self.core)
            L.act = np.ones((L.nr, len(X0)), bool)
            L.Gam = self._gammas(L)

    def _gammas(self, L):
        g = np.full(L.nr, L.gamma0)
        dec = self.pr["gamma_decay"]
        if dec:
            g = g * np.exp(-np.arange(L.nr) * self.dsh / float(dec))
        return g * self.dsh

    def loops(self):
        """Ряды по линиям: {(l, i): Filaments}; пустые — не включаются."""
        out = {}
        for l, L in enumerate(self.lines):
            for i in range(L.nr):
                lp = _row_loops(self.panels, L.nodes[i], L.act[i], L.Gam[i], self.core)
                if lp:
                    out[(l, i)] = _merge(lp)
        return out

    def velocity_free(self, sigma, extra_all, rows, l, i, pts):
        """Скорость в точках pts (n, 3) узлов линии l от фона + панелей + слоя без самоиндукции ряда i этой линии."""
        self.n_vel += 1
        u, v, w = _inf.velocity(self.panels, sigma, self.bg, pts[:, 0], pts[:, 1], pts[:, 2], extra_all)
        own = rows.get((l, i))
        if own is not None:
            ou, ov, ow = F.induced(own, pts[:, 0], pts[:, 1], pts[:, 2])
            u, v, w = u - ou, v - ov, w - ow
        return np.stack([u, v, w], 1)

    def trace(self, sigma, extra_all, rows):
        """Линии тока от точек отрыва: новые узлы и активность. → список (nodes, act) по линиям."""
        panels, core = self.panels, self.core
        out = []
        for l, L in enumerate(self.lines):
            n = len(L.X0)
            nodes = np.empty((L.nr, n, 3))
            act = np.zeros((L.nr, n), bool)
            nodes[0] = L.X0
            act[0] = True
            cur = L.X0.copy()
            alive = np.ones(n, bool)
            for i in range(L.nr - 1):
                if not alive.any():
                    nodes[i + 1:] = nodes[i][None]
                    break
                idx = np.nonzero(alive)[0]
                p = cur[idx]
                v1 = self.velocity_free(sigma, extra_all, rows, l, i, p)
                sp = np.linalg.norm(v1, axis=1)
                u1 = v1 / np.maximum(sp, 1e-12)[:, None]
                pm = p + 0.5 * self.dsh * u1
                zgm = np.asarray(panels.height(pm[:, 0], pm[:, 1]), float)
                pm[:, 2] = np.maximum(pm[:, 2], zgm + 0.5 * core)
                v2 = self.velocity_free(sigma, extra_all, rows, l, i, pm)
                sp2 = np.linalg.norm(v2, axis=1)
                u2 = v2 / np.maximum(sp2, 1e-12)[:, None]
                pn = p + self.dsh * u2
                zg = np.asarray(panels.height(pn[:, 0], pn[:, 1]), float)
                hit = (pn[:, 2] - zg < core) | (sp < 1e-3) | ~np.isfinite(pn).all(1)
                pn[:, 2] = np.maximum(pn[:, 2], zg + core)
                pn = np.where(np.isfinite(pn), pn, p)
                cur[idx] = pn
                nodes[i + 1] = cur
                act[i + 1, idx] = ~hit
                alive[idx[hit]] = False
            out.append((nodes, act))
        return out

    def run(self):
        pr = self.pr
        self.init_shape()
        sigma = self.sigma_bg
        resid, it = np.inf, 0
        rows = self.loops()
        for it in range(1, int(pr["n_iter"]) + 1):
            fil = _merge(list(rows.values()))
            extra = _induced_fn(fil)
            sigma, _ = P.solve(self.panels, self.bg, extra, self.infl)
            new = self.trace(sigma, extra, rows)
            resid = 0.0
            r = float(pr["relax"])
            for L, (nn, aa) in zip(self.lines, new):
                both = L.act & aa
                shift = np.linalg.norm(nn - L.nodes, axis=2)
                flips = (L.act != aa)
                if both.any():
                    resid = max(resid, float(shift[both].max()))
                if flips.any():
                    resid = max(resid, self.dsh)
                upd = both[..., None]
                L.nodes = np.where(upd, L.nodes + r * (nn - L.nodes), np.where(aa[..., None], nn, L.nodes))
                L.act = aa
            rows = self.loops()
            if resid < pr["tol_rel"] * self.dsh:
                break
        fil = _merge(list(rows.values()))
        sigma, _ = P.solve(self.panels, self.bg, _induced_fn(fil), self.infl)
        return sigma, rows, it, resid


def _finish_line(L, panels, wind, dsh):
    """Присоединение и длина зоны по линии: узлы, ушедшие к земле раньше конца слоя."""
    nr, n = L.act.shape
    last = np.zeros(n, int)       # номер последнего активного ряда столбца
    for j in range(n):
        a = np.nonzero(L.act[:, j])[0]
        # первый неактивный ряд после начала = присоединение
        bad = np.nonzero(~L.act[:, j])[0]
        last[j] = (bad[0] - 1) if bad.size else nr - 1
    hit = last < nr - 1
    L.n_reattached = int(hit.sum())
    if hit.any():
        pts = np.array([L.nodes[last[j] + 1, j] for j in np.nonzero(hit)[0]])
        zg = np.asarray(panels.height(pts[:, 0], pts[:, 1]), float)
        L.reattach = dict(x=float(pts[:, 0].mean()), y=float(pts[:, 1].mean()), z=float(zg.mean()))
        along = (pts[:, 0] - L.sep_xy[hit, 0].mean()) * wind[0] + (pts[:, 1] - L.sep_xy[hit, 1].mean()) * wind[1]
        L.L_b = float(np.mean(along))
    else:
        L.reattach = None
        L.L_b = float("nan")
    L.last = last


def build_sheet(panels, bg, z0, infl=None, params=None):
    """Слой за линиями отрыва Хеда (контракт SWD6 v4). → (sheet, sigma, info)."""
    t_start = time.time()
    pr = dict(DEFAULTS)
    pr.update(params or {})
    ds = panels.ds_min
    dsh = 2.0 * ds if pr["ds_sheet"] is None else float(pr["ds_sheet"])
    h0 = 0.5 * ds if pr["h0"] is None else float(pr["h0"])
    core = 0.5 * ds if pr["core"] is None else float(pr["core"])
    if infl is None:
        infl = P.assemble(panels, "auto")
    sigma_bg, _ = P.solve(panels, bg, None, infl)
    from panels3d.terrain import u_ref_of, wind_of
    U_ref, _ = u_ref_of(bg, panels.terrain)
    wind = wind_of(bg, panels.terrain)
    sep = P.separation3d(panels, sigma_bg, bg, z0, None, "head", True)
    lines = _build_lines(panels, bg, sep, wind, U_ref, pr, dsh, h0, core)
    lines = [L for L in lines if L.gamma0 > 1e-6]
    sh = Sheet(params=dict(pr, ds_sheet=dsh, h0=h0, core=core))
    info = dict(t_s=0.0, iters=0, residual=0.0, N=int(panels.N), n_nodes=0, n_lines=len(lines), n_vel=0)
    if not lines:
        info["t_s"] = time.time() - t_start
        sh.stats = dict(info)
        return sh, sigma_bg, info
    sol = _Solver(panels, bg, z0, infl, sigma_bg, lines, pr, dsh, core)
    sigma, rows, it, resid = sol.run()
    sh.filaments = _merge(list(rows.values())) if rows else F.Filaments()
    for l, L in enumerate(lines):
        _finish_line(L, panels, wind, dsh)
        for i in range(L.nr):
            na = int(L.act[i].sum())
            if (l, i) in rows:
                sh.rows.append(dict(line=l, i=i, s=float(i * dsh), Gamma=float(L.Gam[i]), n_active=na))
        sh.reattach.append(L.reattach)
        sh.lines.append(dict(nodes=L.nodes, active=L.act, gamma0=L.gamma0, Gamma=L.Gam, H=L.H, L_b=L.L_b,
                             L_b_over_H=L.L_b / L.H if np.isfinite(L.L_b) else float("nan"), last=L.last,
                             n_reattached=L.n_reattached, X0=L.X0, k=L.k, n_cols=len(L.X0),
                             wind=wind, L_max=L.L_max))
    sh.iters, sh.residual = it, float(resid)
    info.update(t_s=time.time() - t_start, iters=it, residual=float(resid), n_nodes=int(len(sh.filaments.x)),
                n_vel=sol.n_vel)
    sh.stats = dict(info, ds_sheet=dsh, tol=pr["tol_rel"] * dsh)
    return sh, sigma, info


def velocity_sheet(panels, sigma, bg, sheet, x, y, z, z0, U_ref=None, infl=None):
    """(u, v, w) = velocity_jh(..., extra=induced слоя, couple=True); без слоя — velocity_jh без extra."""
    return P.velocity_jh(panels, sigma, bg, x, y, z, z0, U_ref=U_ref, extra=_induced_fn(sheet.filaments),
                         infl=infl, couple=True)
