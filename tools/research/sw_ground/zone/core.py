"""SWG-8 (круг 3 задачи 1): скорость мёртвой зоны под листом + слой смешения конечной толщины.

Исходное — лист SWG-7 (sheet.core: SheetGeom, Sheet «rest», sheet_parts), импортируется без изменений.

(2) Слой смешения. Суммарная Γ узла листа SWG-7 (γ·Δl, замыкание «rest») распределяется по N_LAYERS параллельным листам
    по толщине δ_ω(s) = C_DW·(s − x_s), C_DW = 0,181 (Brown & Roshko 1974, JFM 64:775, dδ_ω/dx при λ = 1 — один поток
    покоится). Профиль скорости слоя смешения u = ½ΔU(1 + tanh(2ζ/δ_ω)) (максимальный наклон ΔU/δ_ω — определение
    толщины по завихренности), ζ = z − h, центр — оболочка (разделяющая линия тока SWG-4/7). Завихренность ∝ sech²(2ζ/δ_ω):
    доля слоя k = ½[tanh(2ζ_{k+1}/δ) − tanh(2ζ_k/δ)] на равных интервалах ζ ∈ [−δ, δ], нормированная на сумму 1 (Γ та же).
    Листы ниже core/2 над землёй поднимаются до core/2 (как узлы SWG-7). Ножки и возврат под землёй — как SWG-7, у каждого
    слоя свои (sheet.core.build_filaments).

(1) Скорость зоны (под оболочкой, z_agl < h). Правило — кинематика + профили из литературы, без констант места:
    * ψ = 0 на полу и на разделяющей линии тока ⇒ в каждом сечении зоны ∫₀ʰ u∥ dz = 0 (замкнутая рециркуляция: прямой
      поток нижней половины слоя смешения возвращается обратным у пола).
    * Профиль: u∥(z) = G·u_h + (1 − G)·u_z(z), G = 1 + tanh(2(z − h)/δ) (нижняя половина профиля слоя смешения,
      нормированная на 1 при z = h), u_h — скорость модели листа на оболочке (z = h) той же колонки (непрерывность при
      z = h), u_z(z) = −u_r·φ(z), φ = ln(z/z0)/ln(h/z0) — пристенный лог-профиль обратного течения от своей
      u*_r = κ·u_r/ln(h/z0) (Kaimal & Finnigan 1994, гл. 5 — по замечанию координатора; Simpson et al. 1981 JFM 113:23
      — профиль обратного течения масштабируется на U_N и N, закон стенки не выполняется — допущение, см. README).
    * u_r — из ∫ u∥ dz = 0: u_r = u_h·∫G dz / ∫(1 − G)·φ dz (квадратура по [z0, h]); ограничение сверху u_r ≤ C_MAX·U_e
      (U_e — скорость модели на h + δ), C_MAX = 0,3 — верх диапазона u_rev/U_e 0,1–0,3 (карточка координатора; в
      доступных текстах проверено только качественно — README). Ограниченные точки — счётчиком.
    * Модуль s = |u∥|, знак u∥ < 0 — обратный поток (ротор). Выше оболочки — модель листа (JH + лист), без разрыва при z = h.
    δ в профиле: zone_jh — max(δ_ω(s), core), zone_jh_thin — core (тонкий лист SWG-7, ядро 12,5 м).

Обрезка γ ≥ 0 (sheet.core.Sheet, «rest»: γ ← max(U_ср + γ/2, 0)) — описана в README; здесь iterate_rest(clip=False)
повторяет цикл без обрезки, чтобы проверить влияние.
"""
from __future__ import annotations

import numpy as np
from scipy.interpolate import RegularGridInterpolator

from ground import model as M  # noqa: F401  (патчи panels3d)
import filaments3d as F
from panels3d.terrain import wind_of
from sheet import core as SH

C_DW = 0.181          # dδ_ω/dx, Brown & Roshko 1974 (λ = 1)
N_LAYERS = 7          # число листов слоя смешения (сходимость на Аньези: N 7 против 9 — max 4 %, README)
C_MAX = 0.3           # верх u_rev/U_e
NQ = 129              # точек квадратуры ∫ dz


# ---------------- расстояние от отрыва s − x_s ----------------
class SepDist:
    """s − x_s на решётке профилей (c × s) геометрии SheetGeom (0 вне зоны); для узлов и точек."""

    def __init__(self, geom):
        g = geom.grid
        self.geom = geom
        D = np.full((g.cvals.size, g.svals.size), np.inf)
        cidx = {float(c): i for i, c in enumerate(g.cvals)}
        for q in geom.segs:
            ic = cidx[q["c"]]
            m = (g.svals >= q["s_s"] - 1e-9) & (g.svals <= q["s_r"] + 1e-9)
            D[ic, m] = np.minimum(D[ic, m], g.svals[m] - q["s_s"])
        D[~np.isfinite(D)] = 0.0
        self.D = D
        self._it = RegularGridInterpolator((g.cvals, g.svals), D, bounds_error=False, fill_value=0.0)

    def at_ca(self, c, a):
        return self._it(np.stack([np.ravel(c), np.ravel(a)], 1)).reshape(np.shape(c))

    def at_xy(self, x, y):
        c, a = self.geom.grid.rot(x, y)
        return self.at_ca(c, a)


def layer_weights(n):
    """Положения ζ_k/δ (центры n равных интервалов на [−1, 1]) и доли Γ по профилю tanh (сумма 1)."""
    e = np.linspace(-1.0, 1.0, n + 1)
    w = 0.5 * (np.tanh(2 * e[1:]) - np.tanh(2 * e[:-1]))
    return 0.5 * (e[1:] + e[:-1]), w / w.sum()


def concat(fs):
    fs = [f for f in fs if len(f.seg)]
    if not fs:
        return F.Filaments()
    xs, segs, G, C = [], [], [], []
    n0 = 0
    for f in fs:
        xs.append(f.x)
        segs.append(f.seg + n0)
        G.append(f.gamma)
        C.append(f.core)
        n0 += len(f.x)
    x = np.concatenate(xs)
    return F.Filaments(x, np.concatenate(segs), np.concatenate(G), np.concatenate(C), np.zeros(len(x), bool),
                       np.zeros(sum(len(s) for s in segs), int))


class MixSheet:
    """Γ узлов тонкого листа sh (SWG-7) по n листам слоя смешения толщины δ_ω(s). Интерфейс как Sheet для sheet_parts."""

    def __init__(self, sh, n=N_LAYERS, c_dw=C_DW, sep=None):
        self.thin, self.geom, self.run, self.n = sh, sh.geom, sh.run, n
        self.core = sh.core
        self.info = dict(n_layers=n, c_dw=c_dw)
        if sh.geom.n_nodes == 0 or len(sh.fil.seg) == 0:
            self.fil, self.sig_ex = F.Filaments(), np.zeros(sh.run.panels.N)
            return
        sep = sep if sep is not None else SepDist(sh.geom)
        g = sh.geom
        ic, ia = sh.idx[:, 0], sh.idx[:, 1]
        self.dw = c_dw * sep.at_ca(g.grid.cvals[ic], g.avals[ia])
        zeta, wk = layer_weights(n)
        zg = sh.X[:, 2] - sh.h
        fs, lifted = [], 0
        for zk, w in zip(zeta, wk):
            hk = sh.h + zk * self.dw
            lifted += int(np.sum(hk < 0.5 * self.core))
            hk = np.maximum(hk, 0.5 * self.core)
            Xk = sh.X.copy()
            Xk[:, 2] = zg + hk
            fs.append(SH.build_filaments(g, Xk, sh.idx, hk, sh.gamma * sh.w * w, self.core, sh.run.panels))
        self.fil = concat(fs)
        self.sig_ex = SH.sigma_extra(sh.run, self.extra)
        self.info.update(n_seg=int(len(self.fil.seg)), lifted_frac=lifted / float(n * len(sh.h)),
                         dw_median=float(np.median(self.dw)), dw_max=float(np.max(self.dw)))

    @property
    def extra(self):
        return SH._extra(self.fil)


def iterate_rest(run, geom, clip=True, tol=SH.TOL, n_iter=SH.N_ITER):
    """Цикл «rest» SWG-7 с флагом обрезки γ ≥ 0. clip=True — тот же результат, что SH.Sheet(run, geom, "rest").
    info: n_clip_last — узлов, где U_ср + γ/2 < 0 на последней итерации; n_neg — узлов с γ < 0 (clip=False)."""
    sh = SH.Sheet(run, geom, "rest", gamma=np.zeros(geom.n_nodes))
    if geom.n_nodes == 0:
        return sh
    g = sh._ut(None, None)
    n_clip0 = int(np.sum(g < 0))
    sh._set(g)                          # γ⁰ = U_e без листа (как SWG-7: без обрезки; обрезка — с первой итерации)
    hist = []
    for it in range(1, n_iter + 1):
        um = sh._ut(sh.extra, sh.sig_ex)
        raw = um + 0.5 * g
        gn = np.maximum(raw, 0.0) if clip else raw
        dg = np.abs(gn - g) / sh.U_ref
        hist.append(float(dg.max()))
        g = gn
        sh._set(g)
        if dg.max() < tol:
            break
    sh.info.update(iters=it, hist=hist, converged=bool(dg.max() < tol), n_unconverged=int(np.sum(dg >= tol)),
                   dgamma_last=float(dg.max()), n_clip_last=int(np.sum(raw < 0)), n_neg0=n_clip0,
                   n_neg=int(np.sum(g < 0)), clip=clip, gamma_mean=float(np.mean(g)), gamma_max=float(np.max(g)),
                   gamma_over_Uref=float(np.mean(g) / sh.U_ref), n_seg=int(len(sh.fil.seg)))
    return sh


def clip_count(sh):
    """Узлов, где обрезка γ ≥ 0 действует на итоговом γ (U_ср + γ/2 < 0) — для листа SH.Sheet SWG-7."""
    if sh.geom.n_nodes == 0:
        return 0
    um = sh._ut(sh.extra, sh.sig_ex)
    return int(np.sum(um + 0.5 * sh.gamma < 0))


# ---------------- скорость зоны ----------------
def _signed(p, ex, ey):
    return p["u"] * ex + p["v"] * ey


def zone_profile(z, h, delta, u_h, U_e, z0, c_max=C_MAX, nq=NQ):
    """Правило зоны в точках под оболочкой (z < h): → u∥ (со знаком), u_r, capped. Векторно по точкам."""
    z = np.asarray(z, float)
    h = np.maximum(np.asarray(h, float), 1.01 * z0)
    t = np.linspace(0.0, 1.0, nq)
    zq = z0 + (h[:, None] - z0) * t[None, :]                                   # (n, nq)
    Gq = 1.0 + np.tanh(2.0 * (zq - h[:, None]) / delta[:, None])
    phq = np.clip(np.log(zq / z0) / np.log(h / z0)[:, None], 0.0, 1.0)
    num = np.trapezoid(Gq, zq, axis=1)
    den = np.trapezoid((1.0 - Gq) * phq, zq, axis=1)
    ur = np.where(den > 1e-12, u_h * num / np.maximum(den, 1e-12), np.inf)
    cap = c_max * np.maximum(U_e, 0.0)
    capped = ur > cap
    ur = np.minimum(ur, cap)
    G = 1.0 + np.tanh(2.0 * (z - h) / delta)
    ph = np.clip(np.log(np.maximum(z, z0) / z0) / np.log(h / z0), 0.0, 1.0)
    u = G * u_h - (1.0 - G) * ur * ph
    return u, ur, capped


def zone_parts(run, x, y, z, sheet, sep, delta_mode, z0=None):
    """Поле модели листа sheet (sheet_parts) + правило зоны. delta_mode: "mix" (max(δ_ω, core)) | "thin" (core).
    → dict(speed_sheet, speed, u_par (со знаком; выше оболочки — проекция модели), under, ur, Ue, capped, delta)."""
    z0 = run.z0 if z0 is None else z0
    x = np.asarray(x, float).ravel()
    y = np.asarray(y, float).ravel()
    z = np.asarray(z, float).ravel()
    ex, ey = wind_of(run.bg, run.panels.terrain)
    p = SH.sheet_parts(run, x, y, z, sheet, z0)
    out = dict(speed_sheet=p["speed"], speed=p["speed"].copy(), u_par=_signed(p, ex, ey), under=p["under"].copy(),
               ur=np.full(x.size, np.nan), Ue=np.full(x.size, np.nan), capped=np.zeros(x.size, bool),
               delta=np.zeros(x.size), zone_h=p["zone_h"], parts=p)
    if sheet is None or len(sheet.fil.seg) == 0:
        return out
    core = 0.5 * run.panels.ds_min
    dw = C_DW * sep.at_xy(x, y)
    delta = np.maximum(dw, core) if delta_mode == "mix" else np.full(x.size, core)
    out["delta"] = delta
    u = p["under"]
    if not np.any(u):
        return out
    iu = np.nonzero(u)[0]
    zg = run.panels.height(x[iu], y[iu])
    h = p["zone_h"][iu]
    ph = SH.sheet_parts(run, x[iu], y[iu], zg + h, sheet, z0)
    pe = SH.sheet_parts(run, x[iu], y[iu], zg + h + delta[iu], sheet, z0)
    u_h, U_e = ph["speed"], pe["speed"]
    upar, ur, capped = zone_profile(z[iu] - zg, h, delta[iu], u_h, U_e, z0)
    out["speed"][iu] = np.abs(upar)
    out["u_par"][iu] = upar
    out["ur"][iu] = ur
    out["Ue"][iu] = U_e
    out["capped"][iu] = capped
    return out
