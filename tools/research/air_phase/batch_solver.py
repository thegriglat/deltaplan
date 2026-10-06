"""P4 v3 (docs/contracts/air-phase.md): пакетный счёт решателя P2 (tools/research/air3d) с опциями опытов фаз.

Пакет — B решателей в одном процессе, у каждого свой поток CUDA и свой граф итерации; графы ставятся в очередь
вперемешку, и ядра разных случаев идут на GPU одновременно. Ядра решателя мелкие и упираются в задержку памяти
(прогонки Томаса вдоль линий: один поток — одна линия, ~2–18 тыс. потоков на запуск), поэтому одновременные случаи
заполняют простаивающий GPU. Замер (`bench_batch.py`, `out/bench.json`): несколько процессов на GPU выигрыша не дают
(разделение по времени), «ось случаев в массивах» (случаи, сложенные по z) даёт на прогонках x/y те же ~1,9×, что и
потоки, и проигрывает при B ≥ 16 (кэш); поэтому пакет — потоки, а не перепись ядер. Плюсы: каждый случай считается
ровно той же последовательностью ядер, что одиночный, — пакет побитно равен одиночному счёту (инварианты 1, 2 — Δ = 0);
сошедшийся случай просто перестаёт ставиться в очередь, на его место встаёт следующий из списка (скользящее окно B).

Итерация и проверка — как `air.Air.solve` / `airlite_gen.solve_late` (граф: 1 шаг вне графа + захват, затем пачки по 10
итераций и проверка невязок после каждой; цель «среднее поздних» для несошедшихся).

Критерий сходимости (метрика — невязки установившихся уравнений `Air.residuals`, rms по воздуху):
  * abs (по умолчанию, tol None) — как решатель: mom_rms < 2e-5 м/с², th_rms < 5e-7 К/с, div_rms < 1e-6 1/с;
    tol = t — порог импульса t м/с², пороги θ и ∇·u — в том же отношении (×5e-7/2e-5, ×1e-6/2e-5).
  * rel — порог импульса масштабируется на U_sat²/a: mom_rms < tol·U_sat²/a, θ и ∇·u — в том же отношении;
    a — перепад рельефа (max − min g100; для идеальных форм — h), U_sat = U10·max_profile; tol по умолчанию
    REL_TOL = 4e-4 (= 2e-5 м/с² при U_sat = 5 м/с, a = 500 м).
  Записывается метрика resid = max(mom_rms, th_rms·40, div_rms·20) (м/с², «эквивалент невязки импульса»: < 2e-5 ⇔ abs)
  и resid_rel = resid·a/U_sat² (< 4e-4 ⇔ rel при пороге по умолчанию).

Опции (Numerics): top_above_m — верх области над max рельефа (как real.TOP_ABOVE, своя grid_domain), sponge_top_m —
толщина губки у верха (Params.sponge_top_m), P4 v4; lam_m — асимптотическая длина перемешивания Блэкадара λ (Params.lam,
λ = max(lam_m, lam_frac·h_bl) как в air3d; 40 м по умолчанию — побитно как v4), P4 v5; omega_u — u ← u + ω(u* − u) после проекции (Params.omega_u); omega_k — K ← K + ω(K* − K), где K* —
обновление замыкания с его собственной нижней релаксацией k_relax = 0,1 (эффективно k_relax·ω; ω = 1 — как было);
k_floor_m2s — Params.k_fa (K свободной атмосферы и нижний предел K в kloc); advection_order 2 — Params.adv2 (ван Лир).

Огибающая (P4 v2): h_eff = max(h, линия тени) — см. `envelope`. Объём под h_eff — твёрдое тело маской клеток решателя
(Air строится на h_eff: клетки ниже h_eff — земля, высоты срезов — над h_eff). Верхняя грань: ground — закон
сопротивления с z0 решателя; low_z0 — C_d по envelope_z0_m в столбцах тени; slip — C_d = 0 (касательное напряжение
на стенке у решателя только законом сопротивления, вязкого потока к стенке нет — так что slip точен). Поток тепла —
от настоящего рельефа (air.solar_flux по уклону g400), решатель кладёт его в первую воздушную клетку столбца, т. е. на
верх огибающей. Сетка по высоте (z_bot, nz) — от настоящего рельефа.

Окно 100 м (dx_m = 100): вложенное окно (`init_nest`, границы и губки от родителя), перенос 2-го порядка с ограничителем
ван Лира, решается после области от её конечного состояния; положение — `window_geometry` (бровка — точка наибольшей
выпуклости профиля по ветру выше по потоку от самого крутого подветренного склона; окно от бровки: −3 км … 15h + 1,5 км
по ветру, ±4 км поперёк).
"""
from __future__ import annotations

import copy
import hashlib
import math
import sys
import time
from collections import deque
from dataclasses import dataclass, field, replace
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
for _p in (RESEARCH / "air_synth/solver", RESEARCH / "air_synth/corpus"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import model_place as M        # noqa: E402  (S4: рельеф → место; пути air3d и air_nn_pilot)
import s5_io as S5             # noqa: E402
import airlite_gen as G        # noqa: E402
import air as A                # noqa: E402
import real as R               # noqa: E402
import ref_study as RS         # noqa: E402
import synth as SY             # noqa: E402
import weather as W            # noqa: E402
import conditions as CN        # noqa: E402

B_DEFAULT = 4                  # размер пакета по умолчанию (bench.json → best_batch)
REL_TOL = 4e-4                 # порог относительного критерия (= 2e-5 м/с² при U_sat = 5 м/с, a = 500 м)
TOL_MOM, TOL_TH, TOL_DIV = RS.TOL["tol_mom"], RS.TOL["tol_th"], RS.TOL["tol_div"]
AGL = G.AGL
SNAP_AGL = (25, 600)
CHECK_EVERY = 10
WINDOW_DX = 100.0
WINDOW_UP_M, WINDOW_DOWN_EXTRA_M, WINDOW_HALF_M = 3000.0, 1500.0, 4000.0
WINDOW_TOP_ABOVE = 2000.0
WALLS = ("none", "ground", "low_z0", "slip")
SKY = {0: "clear", 1: "partly", 2: "overcast"}


@dataclass
class CaseSpec:
    g100: np.ndarray
    ctx: dict
    u10: float
    wdir_from_deg: float
    alpha: float | None
    max_profile: float | None
    n_bv_s: float | None = None
    z_i_agl_m: float | None = None
    heat_flux_wm2: float | None = None
    dx_m: float = 400.0
    cond_row: dict | None = None


@dataclass
class Numerics:
    advection_order: int = 1
    omega_u: float = 1.0
    omega_k: float = 1.0
    k_floor_m2s: float | None = None
    criterion: str = "abs"
    tol: float | None = None
    max_outer: int = 1000
    snap_from: int = 100
    snap_step: int = 50
    late_from: int = 500
    late_step: int = 50
    envelope_angle_deg: float = 0.0
    envelope_wall: str = "none"
    envelope_z0_m: float | None = None
    top_above_m: float = 3000.0        # P4 v4: верх области над max рельефа, м (air3d/real.TOP_ABOVE)
    sponge_top_m: float = 1000.0       # P4 v4: толщина губки у верха, м (Params.sponge_top_m)
    lam_m: float = 40.0                # P4 v5: асимптотическая длина перемешивания λ, м (Params.lam; λ = max(lam_m, lam_frac·h_bl))


@dataclass
class CaseResult:
    status: str
    iters: int
    target: str
    late_n: int
    late_spread60_p90: float
    resid_final: float
    resid_rel_final: float
    fields: np.ndarray
    hc: np.ndarray
    heat_flux: np.ndarray
    hbl: np.ndarray
    trace: dict
    state: dict
    window: dict | None
    seconds: float
    froude_table: float
    zi_over_L: float
    h_eff: np.ndarray | None = None
    u_sat: float = 0.0
    n_bv: float = 0.0
    z_i_agl_m: float = 0.0
    heat_flux_wm2: float = 0.0
    wall_own: float = 0.0
    meta: dict = field(default_factory=dict)


LAST_STATS: dict = {}


# ============================================================================== версия
def solver_version():
    """s1-<7 знаков sha1> от air3d/*.py и этого модуля (P3)."""
    h = hashlib.sha1()
    for p in sorted(M.AIR3D.glob("*.py")) + [Path(__file__).resolve()]:
        h.update(p.name.encode() + b"\0" + p.read_bytes() + b"\0")
    return "s1-" + h.hexdigest()[:7]


# ============================================================================== огибающая
def wind_vector(wdir_from_deg):
    """Куда дует (ex — восток, ey — север), как Air: (−sin φ, −cos φ)."""
    a = math.radians(wdir_from_deg)
    return -math.sin(a), -math.cos(a)


def _bilinear(F, fi, fj, fill):
    ny, nx = F.shape
    out = np.full(fi.shape, fill, float)
    ok = (fi >= 0) & (fi <= nx - 1) & (fj >= 0) & (fj <= ny - 1)
    i0 = np.clip(np.floor(fi).astype(int), 0, nx - 2)
    j0 = np.clip(np.floor(fj).astype(int), 0, ny - 2)
    a, b = fi - i0, fj - j0
    v = (1 - b) * ((1 - a) * F[j0, i0] + a * F[j0, i0 + 1]) + b * ((1 - a) * F[j0 + 1, i0] + a * F[j0 + 1, i0 + 1])
    out[ok] = v[ok]
    return out


def envelope(hc, wdir_from_deg, angle_deg, dx=400.0):
    """h_eff = max(h, линия тени) на сетке клеток hc (ny, nx), м н. у. м. Линия тени — от каждой бровки по ветру вниз под углом
    angle_deg к горизонту: марш по направлению ветра шагом dx, h_eff(p) = max(h(p), h_eff(p − e·dx) − dx·tg угла)
    (полулагранжево, билинейно; итерации Якоби до неподвижной точки). Бровка — клетка, за которой рельеф по ветру опускается
    круче угла: там h(p) < h_eff(p − e·dx) − dx·tg, и линия тени продолжается; где склон положе угла, h_eff = h.
    Вверх по потоку от края области тени нет. angle_deg ≤ 0 — h как есть."""
    hc = np.asarray(hc, float)
    if angle_deg <= 0:
        return hc.copy()
    ex, ey = wind_vector(wdir_from_deg)
    drop = dx * math.tan(math.radians(angle_deg))
    J, I = np.indices(hc.shape).astype(float)
    he = hc.copy()
    for _ in range(4 * max(hc.shape)):
        up = _bilinear(he, I - ex, J - ey, -np.inf)
        new = np.maximum(hc, up - drop)
        if np.array_equal(new, he):
            break
        he = new
    return he


# ============================================================================== окно 100 м
def window_geometry(g100, wdir_from_deg, h_rel):
    """Окно 100 м вокруг подветренной бровки: (x0, y0, nx, ny, meta). Бровка — минимум второй производной профиля g100 по ветру
    (наибольшая выпуклость) выше по потоку от самого крутого подветренного склона (−∇z·e, при равенстве — ближе к центру)."""
    g100 = np.asarray(g100, float)
    ex, ey = wind_vector(wdir_from_deg)
    gy, gx = np.gradient(g100, M.DX100)
    xc = M.X0 + 50.0 + M.DX100 * np.arange(M.N100)
    X, Y = np.meshgrid(xc, xc)
    lee = -(gx * ex + gy * ey) - 1e-12 * (X ** 2 + Y ** 2)
    j, i = np.unravel_index(np.argmax(lee), lee.shape)
    px, py = xc[i], xc[j]
    t = np.arange(-15000.0, 2000.0 + 1, 50.0)
    fi = (px + t * ex - M.X0) / M.DX100 - 0.5
    fj = (py + t * ey - M.X0) / M.DX100 - 0.5
    prof = _bilinear(g100, fi, fj, np.nan)
    prof = np.where(np.isfinite(prof), prof, np.nanmin(prof))
    k = np.ones(5) / 5
    d2 = np.gradient(np.gradient(np.convolve(prof, k, mode="same"), 50.0), 50.0)
    sel = (t <= 0) & (t >= -12000.0)
    tb = t[sel][np.argmin(d2[sel])]
    bx, by = px + tb * ex, py + tb * ey
    down = 15.0 * h_rel + WINDOW_DOWN_EXTRA_M
    corners = [(bx + s * ex - q * ey, by + s * ey + q * ex) for s in (-WINDOW_UP_M, down) for q in (-WINDOW_HALF_M, WINDOW_HALF_M)]
    cx = np.array([c[0] for c in corners]); cy = np.array([c[1] for c in corners])
    lo_lim, hi_lim = M.X0 + 2400.0, -M.X0 - 2400.0          # губки области (2 км) не входят
    x0 = max(lo_lim, math.floor((cx.min() - M.X0) / 100.0) * 100.0 + M.X0)
    y0 = max(lo_lim, math.floor((cy.min() - M.X0) / 100.0) * 100.0 + M.X0)
    nx = int(math.ceil((min(cx.max(), hi_lim) - x0) / WINDOW_DX / 8.0) * 8)
    ny = int(math.ceil((min(cy.max(), hi_lim) - y0) / WINDOW_DX / 8.0) * 8)
    nx = min(nx, int((hi_lim - x0) // WINDOW_DX) // 2 * 2); ny = min(ny, int((hi_lim - y0) // WINDOW_DX) // 2 * 2)
    # расстояние по ветру от бровки до края окна без зоны релаксации окна (nest_sponge_cells)
    sp = A.Params().nest_sponge_cells * WINDOW_DX
    lims = []
    for e, b, a0, n in ((ex, bx, x0, nx), (ey, by, y0, ny)):
        if abs(e) > 1e-9:
            edge = (a0 + n * WINDOW_DX - sp) if e > 0 else (a0 + sp)
            lims.append((edge - b) / e)
    fit = float(min(lims))
    meta = dict(brink_x_m=float(bx), brink_y_m=float(by), steepest_x_m=float(px), steepest_y_m=float(py), x0_m=float(x0), y0_m=float(y0),
                nx=nx, ny=ny, dx_m=WINDOW_DX, downwind_fit_m=fit, downwind_fit_over_h=fit / max(h_rel, 1.0), fits_15h=bool(fit >= 15.0 * h_rel))
    return x0, y0, nx, ny, meta


def grid_domain(loc, dx, dz=None, top_above=R.TOP_ABOVE):
    """= real.grid_domain с верхом области `top_above` м над max рельефа (P4 v4); по умолчанию — та же сетка."""
    n = int(round(R.DOMAIN_L / dx))
    x0 = y0 = -R.DOMAIN_L / 2
    hc = R.block_mean(loc, x0, y0, dx, n, n)
    dz = dz or (105.0 if dx >= 200 else dx / 2)
    zb = math.floor(hc.min() / dz) * dz - dz
    nz = int(math.ceil((hc.max() + float(top_above) - zb) / dz)); nz += nz % 2
    return A.Grid(dx, n, n, dz, zb, nz, x0, y0), hc


def window_grid(loc, x0, y0, nx, ny, dx=WINDOW_DX, top_above=WINDOW_TOP_ABOVE):
    dz = dx / 2
    hw = R.block_mean(loc, x0, y0, dx, nx, ny)
    zb = math.floor(hw.min() / dz) * dz - dz
    nz = int(math.ceil((hw.max() + top_above - zb) / dz)); nz += nz % 2
    return A.Grid(dx, nx, ny, dz, zb, nz, x0, y0), hw


# ============================================================================== постановка случая
def _ctx_of(spec):
    c = spec.ctx
    return dict(month=int(c["month"]), day=int(c["day"]), lat=float(c["lat"]), lon=float(c["lon"]),
                utc_offset_h=float(c.get("utc_offset", c.get("utc_offset_h"))))


class _Setup:
    """Всё, что нужно для решателя случая: место, условия, параметры (одна постановка — для области и окна)."""

    def __init__(self, idx, spec: CaseSpec, num: Numerics):
        self.spec, self.num = spec, num
        if num.envelope_wall not in WALLS or ((num.envelope_angle_deg > 0) != (num.envelope_wall != "none")):
            raise ValueError(f"огибающая: angle {num.envelope_angle_deg}, wall {num.envelope_wall!r}")
        self.loc = f"ap1_{idx}_{id(spec):x}"
        g100 = np.asarray(spec.g100, np.float64)
        M.register(self.loc, g100, 0.0)
        self.relief_m = max(float(g100.max() - g100.min()), 1.0)
        ctx = M.context(self.loc)          # горные поправки по рельефу; остальное — контекст случая (как solve_corpus)
        row = spec.cond_row
        if row is not None:
            if spec.n_bv_s is not None or spec.z_i_agl_m is not None or (spec.heat_flux_wm2 not in (None, 0.0)):
                raise ValueError("cond_row: override не задаётся (heat_flux_wm2 только None — «h» или 0 — «m»)")
            ctx.update(month=int(row["month"]), day=int(row["day"]), lat=float(row["lat_deg"]), lon=float(row["lon_deg"]),
                       utc_offset_h=float(row["utc_offset_h"]))
            self.cfg = S5.cfg_from_row(row)
            self.hour, self.u10, self.wdir = float(row["hour_local"]), float(row["u10_m_s"]), float(row["wind_from_deg"])
            self.t_max = float(row["t_max_c"])
            self.sky = SKY[int(row["sky"])] if self.cfg is None else S5.HG_SKY
            self.heat = spec.heat_flux_wm2 is None
            self.ov = dict()
            self.alpha = self.max_profile = None
        else:
            ctx.update(_ctx_of(spec))
            self.cfg = spec.ctx.get("weather_cfg")
            self.hour, self.u10, self.wdir = float(spec.ctx["hour_local"]), float(spec.u10), float(spec.wdir_from_deg)
            self.t_max = float(spec.ctx.get("t_max_c", W.typical_max_c(ctx["month"], ctx["day"])))
            self.sky = spec.ctx.get("sky", "clear")
            self.heat = True
            self.ov = dict(n_bv_s=spec.n_bv_s, z_i_agl_m=spec.z_i_agl_m, heat_flux_wm2=spec.heat_flux_wm2)
            self.alpha, self.max_profile = spec.alpha, spec.max_profile
        self.ctx = ctx
        prm = A.Params()
        if num.k_floor_m2s is not None:
            prm = replace(prm, k_fa=float(num.k_floor_m2s))
        if num.omega_k != 1.0:
            prm = replace(prm, k_relax=prm.k_relax * float(num.omega_k))
        if num.omega_u != 1.0:
            prm = replace(prm, omega_u=float(num.omega_u))
        if num.sponge_top_m != prm.sponge_top_m:
            prm = replace(prm, sponge_top_m=float(num.sponge_top_m))
        if num.lam_m != prm.lam:                         # P4 v5: λ K-замыкания (область и окно)
            prm = replace(prm, lam=float(num.lam_m))
        if num.advection_order == 2:
            prm = replace(prm, adv2=True, limiter=1)
        elif num.advection_order != 1:
            raise ValueError(f"advection_order {num.advection_order}")
        self.prm = prm

    def case(self, g, hc):
        with S5.weather_override(self.cfg):
            c = R.case(self.loc, g, hc, self.hour, self.u10, self.wdir, self.t_max, self.sky, self.heat)
        S5.apply_strat(c, hc, self.ov.get("n_bv_s"), self.ov.get("z_i_agl_m"), self.ov.get("heat_flux_wm2"))
        if self.alpha is not None:
            c.alpha, c.max_profile = float(self.alpha), float(self.max_profile)
        return c

    def air(self, g, hc_solid, cond, prm, nest=None, cd_map=None):
        """Как real.make (α и max_profile случая в Params) + C_d по столбцам; погода подменена на время построения."""
        if getattr(cond, "alpha", None) is not None:
            prm = replace(prm, alpha=cond.alpha, max_profile=cond.max_profile)
        with S5.weather_override(self.cfg):
            S = A.Air(g, hc_solid, cond, prm, nest=nest, dtype=np.float32, cd_map=cd_map)
        S.loc = self.loc
        return S

    def domain(self):
        num = self.num
        g, hc = grid_domain(self.loc, 400, top_above=num.top_above_m)
        cond = self.case(g, hc)                         # солнце и нагрев — по настоящему рельефу
        h_eff, cd_map = None, None
        hs = hc
        if num.envelope_angle_deg > 0:
            h_eff = envelope(hc, self.wdir, num.envelope_angle_deg, g.dx)
            hs = h_eff
            shadow = h_eff > hc + 1e-6
            cd0 = (A.KAPPA / math.log(0.5 * g.dz / self.prm.z0)) ** 2
            if num.envelope_wall == "low_z0":
                z0 = float(num.envelope_z0_m)
                cd_map = np.where(shadow, (A.KAPPA / math.log(0.5 * g.dz / z0)) ** 2, cd0)
            elif num.envelope_wall == "slip":
                cd_map = np.where(shadow, 0.0, cd0)
        D = self.air(g, hs, cond, self.prm, cd_map=cd_map)
        self.g, self.hc, self.h_eff, self.cond = g, hc, h_eff, cond
        return D

    def window(self, D):
        x0, y0, nx, ny, meta = window_geometry(self.spec.g100, self.wdir, self.relief_m)
        gw, hw = window_grid(self.loc, x0, y0, nx, ny)
        cw = self.case(gw, hw)
        prm = replace(self.prm, adv2=True, limiter=1)
        Wn = self.air(gw, hw, cw, prm, nest=dict(parent=D))
        meta.update(nz=gw.nz, dz_m=gw.dz, z_bot_m=gw.z_bot, advection_order=2, limiter="van Leer")
        return Wn, meta

    def derived(self, D):
        """froude_table (conditions.derive с override), N, z_i над базой, H, −z_i/L."""
        raw = dict(hour=self.hour, U10=self.u10, t_max=self.t_max, sky=self.sky)
        ov = dict(self.ov)
        if self.alpha is not None:
            ov.update(alpha=self.alpha, max_profile=self.max_profile)
        with S5.weather_override(self.cfg):
            d = CN.derive(raw, self.ctx, self.hc, self.relief_m, ov)
        z_i_agl = float(D.case.z_i - CN.override_base(self.hc)) if D.case.z_i is not None else 0.0
        H = float(self.ov["heat_flux_wm2"]) if self.ov.get("heat_flux_wm2") is not None else float(np.mean(np.maximum(D.H, 0)))
        hk = H / A.RHO_CP
        us = D.ustar
        zil = (z_i_agl * A.KAPPA * A.G * hk / (A.THETA0 * us ** 3)) if us > 0 else (1e6 if hk > 0 else 0.0)
        return dict(froude_table=float(d["froude"]), n_bv=float(d["n_bv_s"]), z_i_agl_m=z_i_agl, heat_flux_wm2=H, zi_over_L=float(zil),
                    u_sat=float(D.U_a))


# ============================================================================== решение одного случая на своём потоке
def _slices_from(S, cen):
    """= airlite_gen.slices(S), но по уже снятым центрам (u, v, w, θ′)."""
    return np.stack([np.stack([SY.agl(S, F, a) for a in AGL]) for F in cen])


class _Job:
    def __init__(self, idx, spec, num, init):
        import cupy as cp
        self.cp = cp
        self.idx, self.spec, self.num, self.init = idx, spec, num, init
        self.t0 = time.perf_counter()
        self.stream = cp.cuda.Stream(non_blocking=True)
        self.set = _Setup(idx, spec, num)
        self.phase = "domain"
        self.window = None
        self.result = None
        with self.stream:
            self.D = self.set.domain()
            self._start(self.D, cold=init is None)
        self.late_pts = G.late_points(num.late_from, num.late_step, num.max_outer)
        self.late_todo = list(self.late_pts)
        self.late_snaps = []
        self.snap_t = list(range(int(num.snap_from), int(num.max_outer) + 1, int(num.snap_step)))
        self.trace = dict(iter=[], resid=[], resid_rel=[], du_max=[], fields=[])
        self.prev = None
        self.last = None

    # --- как Air.solve до цикла + capture, на своём потоке
    def _start(self, S, cold, nest=False):
        cp = self.cp
        if nest:
            S.init_nest()
        elif cold:
            S.init_background()
        else:
            S.init_from(self.init, with_p=True, with_k=True)
        S.t_check = 0.0
        no_thd = not bool(cp.any(S.Q != 0)) and not bool(cp.any(S.thbd != 0))
        if no_thd:
            S.thd[...] = 0
        S.no_thd = no_thd
        S.stream = self.stream
        S.outer_step()
        S.outer += 1
        self.stream.synchronize()
        S._pool = cp.cuda.MemoryPool()
        old = cp.get_default_memory_pool()
        cp.cuda.set_allocator(S._pool.malloc)
        try:
            self.stream.begin_capture()
            S.outer_step()
            S.graph = self.stream.end_capture()
        finally:
            cp.cuda.set_allocator(old.malloc)
        self.S = S
        self.S.launch(CHECK_EVERY)

    def _thresholds(self, S):
        num = self.num
        if num.criterion == "abs":
            if num.tol is None:
                return TOL_MOM, TOL_TH, TOL_DIV
            t = float(num.tol)
        elif num.criterion == "rel":
            t = (REL_TOL if num.tol is None else float(num.tol)) * max(S.U_a, 0.1) ** 2 / self.set.relief_m
        else:
            raise ValueError(f"criterion {num.criterion!r}")
        return t, t * TOL_TH / TOL_MOM, t * TOL_DIV / TOL_MOM

    def _metric(self, S, r):
        res = max(r["mom_rms"], r["th_rms"] * TOL_MOM / TOL_TH, r["div_rms"] * TOL_MOM / TOL_DIV)
        return res, res * self.set.relief_m / max(S.U_a, 0.1) ** 2

    def step(self):
        """Проверка после очередной пачки; → True, если случай закончен (иначе поставлена следующая пачка)."""
        cp = self.cp
        S = self.S
        with self.stream:
            self.stream.synchronize()
            r = S.residuals()
            r["it"] = S.outer
            self.last = r
            if self.phase == "domain":
                self._callbacks(S, r)
            tm, tt, td = self._thresholds(S)
            status = None
            if not all(math.isfinite(v) for v in r.values()) or r["mom_max"] > 50.0:
                status = "diverged"
            elif r["mom_rms"] < tm and r["th_rms"] < tt and r["div_rms"] < td:
                status = "ok"
            elif S.outer >= self.num.max_outer:
                status = "max"
            if status is None:
                S.launch(CHECK_EVERY)
                return False
            S.status = status
            if self.phase == "domain":
                self._finish_domain(status)
                if self.spec.dx_m == WINDOW_DX:
                    Wn, meta = self.set.window(self.D)
                    self.window = dict(meta=meta)
                    self.phase = "window"
                    self._start(Wn, cold=True, nest=True)
                    RS.free(self.D)
                    self.D = None
                    return False
            else:
                self._finish_window(status)
            RS.free(S)
            self.S = None
            self.wall_own = time.perf_counter() - self.t0
            return True

    def _callbacks(self, S, r):
        it = r["it"]
        need_late = bool(self.late_todo) and it >= self.late_todo[0]
        need_snap = bool(self.snap_t) and it >= self.snap_t[0]
        need_prev = self.snap_t and it >= self.snap_t[0] - self.num.snap_step and self.prev is None
        cen = S.centers() if (need_late or need_snap) else None
        if need_late:
            while self.late_todo and it >= self.late_todo[0]:
                self.late_todo.pop(0)
                self.late_snaps.append(_slices_from(S, cen))
        if need_snap:
            while self.snap_t and it >= self.snap_t[0]:
                self.snap_t.pop(0)
            cp = self.cp
            du = float(max(cp.max(cp.abs(S.u - self.prev[0])), cp.max(cp.abs(S.v - self.prev[1])), cp.max(cp.abs(S.w - self.prev[2])))) \
                if self.prev is not None else float("nan")
            res, rel = self._metric(S, r)
            self.trace["iter"].append(it); self.trace["resid"].append(res); self.trace["resid_rel"].append(rel)
            self.trace["du_max"].append(du)
            self.trace["fields"].append(np.stack([np.stack([SY.agl(S, F, a) for a in SNAP_AGL]) for F in cen[:3]]).astype(np.float32))
            self.prev = (S.u.copy(), S.v.copy(), S.w.copy())
        elif need_prev:
            self.prev = (S.u.copy(), S.v.copy(), S.w.copy())

    def _finish_domain(self, status):
        S = self.S
        num = self.num
        if status == "max":
            snaps = self.late_snaps
            assert len(snaps) == len(self.late_pts), (len(snaps), self.late_pts)
            mean = np.zeros_like(snaps[0])
            for s in snaps:
                mean += s
            mean /= len(snaps)
            out, target, late_n = mean, "late_mean", len(snaps)
            spread = float(f"{G.late_spread60_p90(snaps, mean, 5):.4g}")
        else:
            out, target, late_n, spread = G.slices(S), "final", 1, 0.0
        if status == "diverged":
            out = np.nan_to_num(out, nan=0.0, posinf=0.0, neginf=0.0)
        res, rel = self._metric(S, self.last)
        T = max(0, (int(num.max_outer) - int(num.snap_from)) // int(num.snap_step) + 1)
        n = len(self.trace["iter"])
        tr = dict(iter=np.full(T, -1, np.int32), resid=np.full(T, np.nan, np.float32), resid_rel=np.full(T, np.nan, np.float32),
                  du_max=np.full(T, np.nan, np.float32), fields=np.zeros((T, 3, len(SNAP_AGL), S.g.ny, S.g.nx), np.float32))
        for k in range(min(n, T)):
            tr["iter"][k] = self.trace["iter"][k]; tr["resid"][k] = self.trace["resid"][k]
            tr["resid_rel"][k] = self.trace["resid_rel"][k]; tr["du_max"][k] = self.trace["du_max"][k]
            tr["fields"][k] = self.trace["fields"][k]
        tr["fields"] = np.nan_to_num(tr["fields"], nan=0.0)
        st = {k: v.get().astype(np.float32) for k, v in S.state().items()}
        d = self.set.derived(S)
        self.result = CaseResult(status=status, iters=int(S.outer), target=target, late_n=late_n, late_spread60_p90=spread,
                                 resid_final=float(res), resid_rel_final=float(rel), fields=out.astype(np.float32),
                                 hc=np.asarray(self.set.hc, np.float32), heat_flux=np.asarray(S.H, np.float32),
                                 hbl=np.asarray(S.h_bl, np.float32), trace=tr, state=st, window=None, seconds=0.0,
                                 froude_table=d["froude_table"], zi_over_L=d["zi_over_L"],
                                 h_eff=None if self.set.h_eff is None else np.asarray(self.set.h_eff, np.float32),
                                 u_sat=d["u_sat"], n_bv=d["n_bv"], z_i_agl_m=d["z_i_agl_m"], heat_flux_wm2=d["heat_flux_wm2"],
                                 meta=dict(nz=S.g.nz, z_bot_m=S.g.z_bot, alpha=S.prm.alpha, max_profile=S.prm.max_profile,
                                           relief_m=self.set.relief_m))

    def _finish_window(self, status):
        S = self.S
        out = G.slices(S)
        if status == "diverged":
            out = np.nan_to_num(out, nan=0.0, posinf=0.0, neginf=0.0)
        self.window.update(fields=out.astype(np.float32), status=status, iters=int(S.outer), agl_m=list(AGL),
                           hc=np.asarray(S.hc, np.float32))
        self.result.window = self.window


# ============================================================================== пакет
def solve_batch(specs, num, init=None, batch=None):
    """P4: случаи specs (список CaseSpec) с Numerics (один на все или список), init — список State (dict float32 u, v, w, th,
    thd, p, nuf, nuh; от CaseResult.state случая на том же рельефе) или None (холодный старт). Одновременно считается до batch
    (по умолчанию B_DEFAULT) случаев; сошедшийся освобождает место следующему. → список CaseResult в порядке specs;
    seconds = стенное время всего вызова / число случаев, wall_own — от постановки до конца случая."""
    import cupy as cp
    n = len(specs)
    nums = list(num) if isinstance(num, (list, tuple)) else [num] * n
    inits = list(init) if init is not None else [None] * n
    assert len(nums) == n and len(inits) == n
    B = int(batch or B_DEFAULT)
    pend = deque(range(n))
    active: list[_Job] = []
    res: list = [None] * n
    pool = cp.get_default_memory_pool()
    peak = 0
    t0 = time.perf_counter()
    while pend or active:
        while pend and len(active) < B:
            i = pend.popleft()
            active.append(_Job(i, specs[i], nums[i], inits[i]))
        still = []
        for j in active:
            if j.step():
                res[j.idx] = j.result
                j.result.wall_own = j.wall_own
            else:
                still.append(j)
        peak = max(peak, pool.total_bytes() + sum(getattr(j.S, "_pool").total_bytes() for j in still if j.S is not None and j.S._pool))
        active = still
    wall = time.perf_counter() - t0
    for r in res:
        r.seconds = wall / max(n, 1)
    LAST_STATS.update(wall=wall, n=n, batch=B, peak_mem_mb=peak / 2 ** 20)
    return res


# ============================================================================== эталон: одиночный путь airlite_gen (для тестов)
def solve_single_reference(spec, max_outer=1000, late_from=500, late_step=50):
    """Решение «h» тем же кодом, что airlite_gen.solve_case/solve_corpus (R.case → R.make → solve_late), float64 срезы."""
    s = _Setup(0, spec, Numerics(max_outer=max_outer, late_from=late_from, late_step=late_step))
    g, hc = R.grid_domain(s.loc, 400)
    with S5.weather_override(s.cfg):
        cond = R.case(s.loc, g, hc, s.hour, s.u10, s.wdir, s.t_max, s.sky, s.heat)
        D = R.make(s.loc, g, hc, cond)
        r, out, _ = G.solve_late(D, max_outer, dict(**{"from": late_from, "step": late_step}, edge_cells=5), True)
    RS.free(D)
    return r, out
