"""Шаг связки: solve с нитями → отрыв → сход → шаг нитей (подшаги по устойчивости) → средние в точках.

Порядок шага (SWD4 v2):
  1. σ = solve(bg + extra), extra = induced(нити) (поле в центроидах вычисляется один раз за шаг);
  2. каждые `sep_every` шагов: separation3d(restart, streamlines_from="bg") → shed по `lines` с Γ = ½u_s²·Δt, Δt — время
     с прошлого схода, u_s — вектор ut полного решения в точках линии;
  3. filaments3d.step с flow = bg + панели (σ этого шага, не пересчитывается на подшагах), ground = panels.height;
     подшаги dt_f ≤ cfl·min(core)/max|u в узлах|.
"""
import os
import sys
import time
import numpy as np

import panels3d as P
import filaments3d as F
from panels3d import influence as _inf
from panels3d.sep import _nodal_field, _sigma_bg
from panels3d.terrain import u_ref_of

VARIANTS = ("potential", "potential_jh", "vortex_jh")
PROGRESS = bool(os.environ.get("SIM3D_PROGRESS"))      # печать строки на шаг (долгие счёты SWD-5b)


class Setup:
    """Постановка: terrain, panels, bg, z0, params (fil, core, cfl, couple, restart, U_ref, sep_every). `infl` — один раз."""

    def __init__(self, terrain, panels, bg, z0, params=None):
        p = dict(fil={}, core=None, cfl=0.25, couple=True, restart=True, U_ref=None)
        p.update(params or {})
        self.terrain, self.panels, self.bg, self.z0 = terrain, panels, bg, float(z0)
        self.params = p
        self.core = float(p["core"]) if p["core"] is not None else 0.5 * panels.ds_min
        self.cfl = float(p["cfl"])
        self.couple = bool(p["couple"])
        self.restart = bool(p["restart"])
        self.sep_every = p.get("sep_every")
        self.U_ref = float(p["U_ref"]) if p["U_ref"] is not None else u_ref_of(bg, terrain)[0]
        self.infl = P.assemble(panels, "auto")
        panels._infl_obj = self.infl            # separation3d берёт σ_bg по тому же Influence
        fil = dict(p["fil"])
        # Перезамыкание выключено по умолчанию (r_rec = 0): при непрерывном сходе у стены даже r_rec = 0,08·core даёт лавину
        # (тысячи обменов за десятки шагов, малые остатки Γ размножают отрезки) — README, «Границы»
        fil.setdefault("r_rec", 0.0)
        if "bounds" not in fil:
            zt = float(np.max(terrain.z))
            fil["bounds"] = (terrain.x[0], terrain.x[-1], terrain.y[0], terrain.y[-1], zt + 2000.0)
        self.fil = fil
        self.sigma_bg, _ = P.solve(panels, bg, None, self.infl)


class _Extra:
    """extra(x, y, z) нитей; значения в центроидах панелей считаются один раз (кеш по равенству входа)."""

    def __init__(self, f, panels):
        self.f, self.c = f, panels.c
        self._cache = None

    def __call__(self, x, y, z):
        x = np.asarray(x, float)
        if self._cache is not None and x.shape == self.c[:, 0].shape and np.array_equal(x, self.c[:, 0]) \
                and np.array_equal(y, self.c[:, 1]) and np.array_equal(z, self.c[:, 2]):
            return self._cache
        r = F.induced(self.f, x, y, z)
        if x.shape == self.c[:, 0].shape and np.array_equal(x, self.c[:, 0]) and np.array_equal(y, self.c[:, 1]):
            self._cache = r
        return r


def _flow(setup, sigma):
    panels, bg = setup.panels, setup.bg

    def flow(x, y, z):
        x = np.asarray(x, float)
        Pt = np.stack([x, np.asarray(y, float), np.asarray(z, float)], 1)
        pv = _inf.panel_velocity(panels, sigma, Pt)
        u, v, w = bg(Pt[:, 0], Pt[:, 1], Pt[:, 2])
        return np.asarray(u, float) + pv[:, 0], np.asarray(v, float) + pv[:, 1], np.asarray(w, float) + pv[:, 2]
    return flow


def _line_data(panels, sep):
    """Линии отрыва → список (точки, индексы треугольников, барицентрики, нормали); точки вне сетки (locate → −1)
    отбрасываются, их число возвращается."""
    out, skipped = [], 0
    for line in sep["lines"]:
        t, l1, l2, l3 = panels.locate(line[:, 0], line[:, 1])
        ok = t >= 0
        skipped += int((~ok).sum())
        if ok.sum() < 2:
            continue
        tt = t[ok]
        out.append((line[ok], tt, np.stack([l1[ok], l2[ok], l3[ok]], 1), panels.n[tt]))
    return out, skipped


def _line_ut(panels, ut_node, d):
    _, tt, bc, _ = d
    tr = panels.tris[tt]
    return bc[:, :1] * ut_node[tr[:, 0]] + bc[:, 1:2] * ut_node[tr[:, 1]] + bc[:, 2:] * ut_node[tr[:, 2]]


def _ut_node(setup, sigma, extra):
    return _nodal_field(setup.panels, _inf.tangent_velocity(setup.panels, sigma, setup.bg, extra))


def _shed_all(setup, f, data, ut_node, dt_shed, k_acc=1.0):
    """Сход по линиям; u_s умножается на k_acc = √(период-среднее |u|² / |u|² в конце периода) — накопленная
    Γ = Σ ½|u_s|²·dt за период (решение координатора)."""
    n_lines = 0
    for d in data:
        if len(d[0]) < 2:
            continue
        f = F.shed(f, d[0], k_acc * _line_ut(setup.panels, ut_node, d), dt_shed, setup.core, d[3])
        n_lines += 1
    return f, n_lines


def _probe_variants(setup, sigma, sigma_bg, extra, pts):
    panels, bg = setup.panels, setup.bg
    x, y, z = pts[:, 0], pts[:, 1], pts[:, 2]
    out = {}
    out["potential"] = np.stack(P.velocity(panels, sigma_bg, bg, x, y, z), 1)
    out["potential_jh"] = np.stack(P.velocity_jh(panels, sigma_bg, bg, x, y, z, setup.z0, U_ref=setup.U_ref,
                                                 infl=setup.infl, couple=False), 1)
    out["vortex_jh"] = np.stack(P.velocity_jh(panels, sigma, bg, x, y, z, setup.z0, U_ref=setup.U_ref, extra=extra,
                                              infl=setup.infl, couple=setup.couple), 1)
    return out


def run(setup, t_end, dt, t_avg=None, probes=None, sep_every=None, record_every=None):
    """Интегрирование до t_end шагом dt. sep_every=None — `params["sep_every"]` или правило U_ref·dt·n ≈ 2·core. → dict(t, filaments, stats, probes_mean, probes_std, snapshots, probes, t_avg).
    t_avg=None — средние за вторую половину (t ≥ t_end/2)."""
    panels, bg = setup.panels, setup.bg
    t_avg = 0.5 * t_end if t_avg is None else float(t_avg)
    pr = None if probes is None else np.atleast_2d(np.asarray(probes, float))
    n_steps = int(round(t_end / dt))
    f = F.Filaments()
    stats, snaps = [], []
    acc = {v: [0, None, None] for v in VARIANTS}    # n, mean, M2 (Welford)
    sigma_bg = setup.sigma_bg
    last_shed = 0.0
    if sep_every is None:
        sep_every = setup.sep_every if setup.sep_every else max(1, int(round(2.0 * setup.core / (setup.U_ref * dt))))
    sep_every = max(int(sep_every), 1)
    old, m_hist, skipped_tot = None, [], 0     # линии прошлого схода, средние |u|² на них по шагам периода
    for it in range(n_steps):
        t0 = time.time()
        t = it * dt
        extra = _Extra(f, panels) if len(f.seg) else None
        sigma, info = P.solve(panels, bg, extra, setup.infl)
        n_lines = n_sep = n_rea = 0
        if record_every and it % record_every == 0:
            snaps.append(dict(t=t, filaments=f.copy(), sigma=sigma.copy()))
        n_skip = 0
        shed_now = it % sep_every == 0
        if sep_every > 1 and (shed_now or old is not None):
            utn = _ut_node(setup, sigma, extra)
            if old:
                m_hist.append(float(np.mean(np.concatenate([(_line_ut(panels, utn, d) ** 2).sum(1) for d in old]))))
        if shed_now:
            sep = P.separation3d(panels, sigma, bg, setup.z0, extra=extra, lee_only=True, restart=setup.restart,
                                 streamlines_from="bg")
            n_sep = len(sep["points"]["x"])
            n_rea = sum(r is not None for r in sep["points"]["reattach"])
            data, n_skip = _line_data(panels, sep)
            if sep_every == 1 or not m_hist:
                k_acc, utn = 1.0, (_ut_node(setup, sigma, extra) if sep_every == 1 else utn)
            else:
                # период-среднее |u|² (m_hist: шаги периода, последний — конец) к значению в конце периода
                k_acc = float(np.sqrt(np.mean(m_hist) / max(m_hist[-1], 1e-300)))
            f, n_lines = _shed_all(setup, f, data, utn, t - last_shed if it else dt * sep_every, k_acc)
            last_shed = t
            old, m_hist = data, []
            if sep_every > 1 and data:
                m_hist.append(float(np.mean(np.concatenate([(_line_ut(panels, utn, d) ** 2).sum(1) for d in data]))))
        skipped_tot += n_skip
        if pr is not None and t >= t_avg - 1e-12:
            var = _probe_variants(setup, sigma, sigma_bg, extra, pr)
            for v, a in var.items():
                A = acc[v]
                A[0] += 1
                if A[1] is None:
                    A[1], A[2] = a.copy(), np.zeros_like(a)
                else:
                    d = a - A[1]
                    A[1] += d / A[0]
                    A[2] += d * (a - A[1])
        # шаг нитей с подшагами
        nsub, umax = 1, 0.0
        if len(f.seg):
            flow = _flow(setup, sigma)
            u0 = np.stack(flow(f.x[:, 0], f.x[:, 1], f.x[:, 2]), 1) + F.self_velocity(f)
            umax = float(np.sqrt((u0 ** 2).sum(1)).max())
            cmin = float(f.core.min())
            nsub = max(1, int(np.ceil(dt * umax / (setup.cfl * cmin)))) if umax > 0 else 1
            for _ in range(nsub):
                f = F.step(f, flow, dt / nsub, panels.height, setup.fil)
        stats.append(dict(t=t + dt, n_fil=f.n_filaments, n_nodes=len(f.x), n_seg=len(f.seg),
                          gamma_abs=float(np.abs(f.gamma).sum()), imbalance=F.imbalance(f), max_u=umax,
                          substeps=nsub, t_step=time.time() - t0, residual=info["residual"], n_sep=n_sep,
                          n_reattach=n_rea, n_lines=n_lines, n_skipped=n_skip, **{"f_" + k: v for k, v in f.stats.items()}))
        if PROGRESS:
            s_ = stats[-1]
            print(f"sim3d {it + 1}/{n_steps} t={s_['t']:.0f} nodes={s_['n_nodes']} sub={s_['substeps']} step={s_['t_step']:.1f}s sep={n_sep}", file=sys.stderr, flush=True)
    mean = {v: A[1] for v, A in acc.items() if A[1] is not None}
    std = {v: np.sqrt(A[2] / max(A[0], 1)) for v, A in acc.items() if A[1] is not None}
    return dict(t=n_steps * dt, filaments=f, stats=stats, probes_mean=mean, probes_std=std, snapshots=snaps,
                probes=pr, t_avg=t_avg, setup=setup)


def velocity_mean(result, x, y, z, variant):
    """Среднее (u, v, w) за t ≥ t_avg: из `probes_mean`, если точки совпадают с `probes`, иначе по `snapshots`
    (σ и нити каждого снимка; "potential*" — без нитей)."""
    if variant not in VARIANTS:
        raise ValueError("variant: " + " | ".join(VARIANTS))
    x, y, z = (np.atleast_1d(np.asarray(a, float)) for a in (x, y, z))
    shp = np.broadcast(x, y, z).shape
    pts = np.stack([np.broadcast_to(a, shp).ravel() for a in (x, y, z)], 1)
    pr = result.get("probes")
    if pr is not None and pr.shape == pts.shape and np.allclose(pr, pts) and variant in result["probes_mean"]:
        m = result["probes_mean"][variant]
        return m[:, 0].reshape(shp), m[:, 1].reshape(shp), m[:, 2].reshape(shp)
    setup = result["setup"]
    if variant != "vortex_jh":
        m = _probe_variants(setup, setup.sigma_bg, setup.sigma_bg, None, pts)[variant]
    else:
        sn = [s for s in result["snapshots"] if s["t"] >= result["t_avg"] - 1e-12]
        if not sn:
            raise ValueError("нет снимков за t ≥ t_avg: задайте record_every")
        m = 0.0
        for s in sn:
            ex = _Extra(s["filaments"], setup.panels) if len(s["filaments"].seg) else None
            m = m + _probe_variants(setup, s["sigma"], setup.sigma_bg, ex, pts)[variant]
        m = m / len(sn)
    return m[:, 0].reshape(shp), m[:, 1].reshape(shp), m[:, 2].reshape(shp)
