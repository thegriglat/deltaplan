"""Клеточный автомат тепла и массы на 2D-разрезе хребта (прототип).

Идея пользователя: горячая клетка отдаёт тепло соседям, а вверх больше; теряя массу, она
подсасывает массу у холодных соседей. Честно записанная, это локальная форма конвекции
Буссинеска на сетке «клетки + грани» (MAC):

  * в клетке хранятся масса m (номинал 1) и тепло H = m·(θ − θ0) (θ — потенциальная температура);
  * на грани между парой клеток — поток (скорость) u или w: что ушло из одной клетки, то пришло
    в соседнюю (обмен парами → сохранение точное);
  * правила за шаг:
      1. «Тёплое вверх»: вертикальный поток через грань ускоряется подъёмной силой
         g·θ′/θ0, где θ′ — насколько клетки у грани теплее ФОНА на своей высоте. На инверсии
         поднятый воздух быстро оказывается холоднее фона → подъём гаснет сам.
      2. Потоки переносят сами себя (инерция), вязкость сглаживает их между соседями,
         у земли — трение; сверху — губка (поглощение волн).
      3. «Недостача массы подсасывает соседей»: клетка, где потоки дают недостачу/избыток
         массы, понижает/повышает «давление» p, и потоки с соседями поправляются на −dt·∇p.
         Итерации «каждая клетка смотрит на соседей» — это Якоби/Гаусс–Зейдель для уравнения
         Пуассона; многосеточный режим ускоряет то же самое. Недорешённая часть остаётся
         как избыток/недостача массы в клетке (сохраняется точно) и выравнивается на
         следующих шагах.
      4. Масса и тепло переходят через грани по потокам (тепло — с температурой клетки
         «откуда дует»), плюс теплопроводность между соседями, плюс нагрев от земли,
         плюс слабое выхолаживание к фону (явный сток, в балансе).

Массивы: [k, i] — k по высоте, i по X. xp — numpy или cupy.
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field, asdict

import numpy as np

G = 9.81
THETA0 = 300.0
RHO_CP = 1.2 * 1005.0  # Дж/(м³·К)


# ---------------------------------------------------------------- сценарии
@dataclass
class Scenario:
    name: str
    title: str
    heating: str = "sun_left"      # sun_left | both
    sun_elev_deg: float = 25.0
    q0_wm2: float = 250.0          # поток тепла при нормальном падении, Вт/м²
    q_diffuse: float = 0.05        # доля рассеянного (тень)
    wind_ms: float = 0.0           # фоновый ветер слева направо
    dtheta_dz: float = 1.0         # К/км, устойчивость фона (T падает на ~8,8 К/км — почти безразлично, день)
    inversion_z: float | None = None   # м над подножием
    inversion_dz: float = 300.0        # толщина слоя инверсии, м
    inversion_dtheta_dz: float = 18.0  # К/км в слое (T растёт ≈ +8 К/км)
    lx: float | None = None            # своя ширина разреза (с ветром — запас по ветру)
    ridge_x: float | None = None       # свой рельеф (проверка симметрии)
    segments: tuple | None = None      # heating="sun_segments": греть только эти отрезки x (м)
    point_x: float | None = None       # heating="point": один столбец (точечный источник)
    half_right: float | None = None


SCENARIOS = {
    "s1_sun_one_slope": Scenario("s1_sun_one_slope", "1. Солнце на крутой склон, второй в тени, штиль",
                                 heating="sun_left"),
    "s2_both_slopes": Scenario("s2_both_slopes", "2. Оба склона прогреты одинаково, штиль",
                               heating="both"),
    "s2_sym": Scenario("s2_sym", "2б. Симметричный хребет, оба склона прогреты, штиль (проверка симметрии)",
                       heating="both", ridge_x=3200.0, half_right=1200.0),
    "s3_wind": Scenario("s3_wind", "3. Оба склона прогреты, фоновый ветер 3 м/с слева направо",
                        heating="both", wind_ms=3.0, lx=9600.0),
    "s4_inversion": Scenario("s4_inversion", "4. Оба склона прогреты, инверсия на 1,5 км над подножием",
                             heating="both", inversion_z=1500.0),
}


@dataclass
class Params:
    cell: float = 50.0          # м, клетка (dx = dz)
    lx: float = 6400.0
    lz: float = 3200.0
    ridge_x: float = 2800.0     # гребень
    ridge_h: float = 500.0
    half_left: float = 1200.0   # крутой склон (слева)
    half_right: float = 2800.0  # пологий склон (справа)
    nu: float = 30.0            # м²/с, турбулентная вязкость
    kappa: float = 30.0         # м²/с, турбулентная теплопроводность
    tau_cool: float = 7200.0    # с, выхолаживание к фону (явный сток)
    edge_taper: float = 800.0   # м, нагрев сходит на нет к бокам
    sponge_m: float = 800.0     # толщина губки у потолка
    sponge_rate: float = 1 / 300.0
    side_sponge_m: float = 1000.0
    cfl: float = 0.35
    u_assumed: float = 8.0      # м/с для выбора шага (проверяется по ходу)
    dt_max: float = 20.0
    t_max: float = 4 * 3600.0
    check_s: float = 600.0      # раз в столько секунд — проверка установления
    frame_s: float = 120.0
    steady_dv: float = 0.02     # м/с за check_s (макс. изменение скорости)
    steady_dT: float = 0.03     # К за check_s
    pressure: str = "mg"        # mg | jacobi | gs (красно-чёрный Гаусс–Зейдель) | acoustic (локально)
    p_iters: int = 2            # V-циклов (mg) или итераций (jacobi/gs) на шаг
    mass_relax: float = 1.0     # какую долю накопленного избытка массы клетки снимать за шаг
    sound_c: float = 60.0       # м/с, «медленный звук» локального режима (acoustic)
    div_damp: float = 0.05      # гашение дивергенции (доля от устойчивого предела)
    dtype: str = "float32"
    device: str = "gpu"
    graph: bool = True          # GPU: шаг как CUDA Graph


# ---------------------------------------------------------------- GPU-ядра
_KERNELS = {}


def _gpu_kernels(cp, ctype):
    if ctype in _KERNELS:
        return _KERNELS[ctype]
    src = ("typedef %s real;\n" % ctype) + r'''
extern "C" __global__ void gs(real* p, const real* rhs, const real* cx, const real* cz, const real* diag,
                              int nz, int nx, int color, real omega) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= nz * nx) return;
    int k = idx / nx, i = idx % nx;
    if (((k + i) & 1) != color) return;
    real d = diag[idx];
    if (d == (real)0) return;
    real pE = (i + 1 < nx) ? p[idx + 1] : (real)0;
    real pW = (i > 0) ? p[idx - 1] : (real)0;
    real pN = (k + 1 < nz) ? p[idx + nx] : (real)0;
    real pS = (k > 0) ? p[idx - nx] : (real)0;
    int ix = k * (nx + 1) + i;
    real s = cx[ix + 1] * pE + cx[ix] * pW + cz[idx + nx] * pN + cz[idx] * pS;
    real pn = (s - rhs[idx]) / d;
    p[idx] = p[idx] + omega * (pn - p[idx]);
}
extern "C" __global__ void jac(const real* p, real* pout, const real* rhs, const real* cx, const real* cz,
                               const real* diag, int nz, int nx) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= nz * nx) return;
    int k = idx / nx, i = idx % nx;
    real d = diag[idx];
    if (d == (real)0) { pout[idx] = (real)0; return; }
    real pE = (i + 1 < nx) ? p[idx + 1] : (real)0;
    real pW = (i > 0) ? p[idx - 1] : (real)0;
    real pN = (k + 1 < nz) ? p[idx + nx] : (real)0;
    real pS = (k > 0) ? p[idx - nx] : (real)0;
    int ix = k * (nx + 1) + i;
    real s = cx[ix + 1] * pE + cx[ix] * pW + cz[idx + nx] * pN + cz[idx] * pS;
    pout[idx] = (s - rhs[idx]) / d;
}
extern "C" __global__ void resid(const real* p, real* r, const real* rhs, const real* cx, const real* cz,
                                 const real* diag, int nz, int nx) {
    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= nz * nx) return;
    int k = idx / nx, i = idx % nx;
    real d = diag[idx];
    if (d == (real)0) { r[idx] = (real)0; return; }
    real pE = (i + 1 < nx) ? p[idx + 1] : (real)0;
    real pW = (i > 0) ? p[idx - 1] : (real)0;
    real pN = (k + 1 < nz) ? p[idx + nx] : (real)0;
    real pS = (k > 0) ? p[idx - nx] : (real)0;
    int ix = k * (nx + 1) + i;
    real s = cx[ix + 1] * pE + cx[ix] * pW + cz[idx + nx] * pN + cz[idx] * pS;
    r[idx] = rhs[idx] - (s - d * p[idx]);
}
'''
    mod = cp.RawModule(code=src)
    k = {n: mod.get_function(n) for n in ("gs", "jac", "resid")}
    _KERNELS[ctype] = k
    return k


# ---------------------------------------------------------------- решатель давления
class PoissonLevel:
    """Уровень сетки: проводимости граней cx (nz, nx+1), cz (nz+1, nx); 0 — закрытая грань."""

    def __init__(self, xp, cx, cz):
        self.xp = xp
        self.cx, self.cz = cx, cz
        self.nz, self.nx = cz.shape[0] - 1, cx.shape[1] - 1
        self.diag = cx[:, 1:] + cx[:, :-1] + cz[1:, :] + cz[:-1, :]
        self.fluid = self.diag > 0
        self.inv = xp.where(self.fluid, 1.0 / xp.where(self.fluid, self.diag, 1.0), 0.0).astype(cx.dtype)
        # маски цветов для CPU
        kk, ii = np.indices((self.nz, self.nx))
        self.red = xp.asarray(((kk + ii) % 2 == 0)) & self.fluid
        self.black = xp.asarray(((kk + ii) % 2 == 1)) & self.fluid

    def neigh_sum(self, p):
        xp = self.xp
        pp = xp.pad(p, 1)
        return (self.cx[:, 1:] * pp[1:-1, 2:] + self.cx[:, :-1] * pp[1:-1, :-2]
                + self.cz[1:, :] * pp[2:, 1:-1] + self.cz[:-1, :] * pp[:-2, 1:-1])

    def coarsen(self):
        xp = self.xp
        if self.nx % 2 or self.nz % 2 or self.nx < 4 or self.nz < 4:
            return None
        cx, cz = self.cx, self.cz
        cxc = (cx[0::2, 0::2] + cx[1::2, 0::2]) / 8.0
        czc = (cz[0::2, 0::2] + cz[0::2, 1::2]) / 8.0
        return PoissonLevel(xp, xp.ascontiguousarray(cxc), xp.ascontiguousarray(czc))


class Poisson:
    def __init__(self, xp, cx, cz, gpu: bool, ctype: str):
        self.xp, self.gpu = xp, gpu
        self.levels = [PoissonLevel(xp, cx, cz)]
        while True:
            c = self.levels[-1].coarsen()
            if c is None:
                break
            self.levels.append(c)
        if gpu:
            import cupy as cp
            self.k = _gpu_kernels(cp, ctype)
            self.real = np.float32 if ctype == "float" else np.float64
        self.work = {}

    # --- элементарные операции
    def _launch(self, name, lvl, *args):
        n = lvl.nz * lvl.nx
        for a in args:
            if hasattr(a, "dtype") and a.ndim > 0:
                assert a.dtype == self.real, (name, a.dtype)
        self.k[name](((n + 255) // 256,), (256,), args)

    def smooth(self, lvl, p, rhs, sweeps, omega=1.0):
        xp = self.xp
        for _ in range(sweeps):
            for color in (0, 1):
                if self.gpu:
                    self._launch("gs", lvl, p, rhs, lvl.cx, lvl.cz, lvl.diag,
                                 np.int32(lvl.nz), np.int32(lvl.nx), np.int32(color), self.real(omega))
                else:
                    m = lvl.red if color == 0 else lvl.black
                    pn = (lvl.neigh_sum(p) - rhs) * lvl.inv
                    p[m] = p[m] + omega * (pn[m] - p[m])
        return p

    def jacobi(self, lvl, p, rhs, iters):
        xp = self.xp
        for _ in range(iters):
            if self.gpu:
                out = xp.empty_like(p)
                self._launch("jac", lvl, p, out, rhs, lvl.cx, lvl.cz, lvl.diag,
                             np.int32(lvl.nz), np.int32(lvl.nx))
                p = out
            else:
                p = (lvl.neigh_sum(p) - rhs) * lvl.inv
        return p

    def residual(self, lvl, p, rhs):
        xp = self.xp
        if self.gpu:
            r = xp.empty_like(p)
            self._launch("resid", lvl, p, r, rhs, lvl.cx, lvl.cz, lvl.diag,
                         np.int32(lvl.nz), np.int32(lvl.nx))
            return r
        return xp.where(lvl.fluid, rhs - (lvl.neigh_sum(p) - lvl.diag * p), 0.0)

    def vcycle(self, li, p, rhs):
        lvl = self.levels[li]
        if li == len(self.levels) - 1:
            return self.smooth(lvl, p, rhs, 40, 1.0)
        p = self.smooth(lvl, p, rhs, 2)
        r = self.residual(lvl, p, rhs)
        c = self.levels[li + 1]
        rc = r.reshape(c.nz, 2, c.nx, 2).mean(axis=(1, 3))
        ec = self.vcycle(li + 1, self.xp.zeros_like(rc), rc)
        p += self.xp.repeat(self.xp.repeat(ec, 2, axis=0), 2, axis=1) * lvl.fluid
        p = self.smooth(lvl, p, rhs, 2)
        return p

    def solve(self, p, rhs, method, iters):
        lvl = self.levels[0]
        if method == "mg":
            for _ in range(iters):
                p = self.vcycle(0, p, rhs)
        elif method == "jacobi":
            p = self.jacobi(lvl, p, rhs, iters)
        elif method == "gs":
            p = self.smooth(lvl, p, rhs, iters, 1.0)
        else:
            raise ValueError(method)
        return p


# ---------------------------------------------------------------- модель
class HeatCA:
    def __init__(self, sc: Scenario, pr: Params):
        import dataclasses
        for k in ("lx", "ridge_x", "half_right"):
            if getattr(sc, k):
                pr = dataclasses.replace(pr, **{k: getattr(sc, k)})
        self.sc, self.pr = sc, pr
        gpu = pr.device == "gpu"
        if gpu:
            import cupy as cp
            self.xp = cp
            self.stream = cp.cuda.Stream(non_blocking=True)
            self.stream.use()
        else:
            self.xp = np
        xp = self.xp
        self.gpu = gpu
        self.dtype = np.float32 if pr.dtype == "float32" else np.float64
        ctype = "float" if pr.dtype == "float32" else "double"
        d = pr.cell
        self.dx = self.dz = d
        self.nx = int(round(pr.lx / d))
        self.nz = int(round(pr.lz / d))
        nx, nz = self.nx, self.nz
        self.xc = (np.arange(nx) + 0.5) * d
        self.zc = (np.arange(nz) + 0.5) * d

        # рельеф
        self.h = self.terrain(self.xc)
        self.hx = self.terrain_slope(self.xc)
        solid = self.zc[:, None] < self.h[None, :]
        self.solid_np = solid
        fluid = ~solid
        self.kb = np.argmax(fluid, axis=0)            # первая воздушная клетка столбца
        self.ground_stair = self.kb * d               # верх «лесенки»

        # грани: открыта, если обе клетки воздух; боковые — если прилегающая воздух
        ux_open = np.zeros((nz, nx + 1), bool)
        ux_open[:, 1:-1] = fluid[:, 1:] & fluid[:, :-1]
        # бока: в штиль — стенки (замкнутая долина между хребтами: всё, что поднялось,
        # опускается внутри разреза); с ветром — слева заданный приток, справа открытый выход
        self.open_sides = sc.wind_ms > 0
        if self.open_sides:
            ux_open[:, 0] = fluid[:, 0]
            ux_open[:, -1] = fluid[:, -1]
        wz_open = np.zeros((nz + 1, nx), bool)
        wz_open[1:-1, :] = fluid[1:, :] & fluid[:-1, :]
        self.ux_open_np, self.wz_open_np = ux_open, wz_open

        # проводимости для давления: 1/d² на внутренних открытых гранях. Боковые грани —
        # всегда Нейман: стенки (штиль) или заданный приток слева и «сносовый» выход справа
        # (скорость выхода = скорость в последней клетке, подогнанная под приток) — без
        # «давления снаружи = 0», которое у тёплого столба у края давало ложный подсос.
        cx = ux_open.astype(float) / d**2
        cx[:, 0] = 0.0
        cx[:, -1] = 0.0
        cz = wz_open.astype(float) / d**2
        self.cx_np = cx
        self.poisson = Poisson(xp, xp.asarray(cx, self.dtype), xp.asarray(cz, self.dtype), gpu, ctype)

        # фон
        self.theta_bar_np = self.background(self.zc)              # θ − θ0 по высоте
        tb = np.repeat(self.theta_bar_np[:, None], nx, axis=1)
        self.tb = xp.asarray(tb, self.dtype)
        self.tb_col = xp.asarray(self.theta_bar_np, self.dtype)
        self.ubg_np = self.wind_profile(self.zc)
        self.ubg = xp.asarray(np.repeat(self.ubg_np[:, None], nx + 1, axis=1), self.dtype)

        # нагрев: кинематический поток, К·м/с, на горизонтальную площадь
        q = self.heating_flux(self.xc, self.hx)
        self.q_np = q
        heat = np.zeros((nz, nx))
        heat[self.kb, np.arange(nx)] = q / d
        self.heat_src = xp.asarray(heat, self.dtype)                 # К/с в клетке

        # губка
        zs = pr.lz - pr.sponge_m
        rz = np.clip((self.zc - zs) / pr.sponge_m, 0, 1) ** 2 * pr.sponge_rate
        rzw = np.clip((np.arange(nz + 1) * d - zs) / pr.sponge_m, 0, 1) ** 2 * pr.sponge_rate
        spu = np.repeat(rz[:, None], nx + 1, 1)
        spw = np.repeat(rzw[:, None], nx, 1)
        if sc.wind_ms > 0:
            # с ветром — боковые губки (только скорость): горные волны уходят, а не отражаются
            # от заданного притока слева и выхода справа
            def side(x):
                e = np.clip(1 - np.minimum(x, pr.lx - x) / pr.side_sponge_m, 0, 1)
                return e ** 2 * pr.sponge_rate
            spu = np.maximum(spu, side(np.arange(nx + 1) * d)[None, :])
            spw = np.maximum(spw, side(self.xc)[None, :])
        self.sp_u = xp.asarray(spu, self.dtype)
        self.sp_w = xp.asarray(spw, self.dtype)
        # губка для тепла (θ → фон) — только с ветром, где нужны уходящие волны; в балансе отдельно
        spc = np.repeat(rz[:, None], nx, 1)
        if sc.wind_ms > 0:
            # только слева (набегающий поток) и сверху; справа тёплый воздух просто уходит с потоком
            xl = np.clip(1 - self.xc / pr.side_sponge_m, 0, 1) ** 2 * pr.sponge_rate
            spc = np.maximum(spc, xl[None, :])
            self.sp_c = xp.asarray(spc, self.dtype)
        else:
            self.sp_c = None

        self.fluid = xp.asarray(fluid)
        self.fluidf = xp.asarray(fluid, self.dtype)
        self.n_fluid = float(fluid.sum())
        self.ux_open = xp.asarray(ux_open)
        self.wz_open = xp.asarray(wz_open)
        self.uxf = xp.asarray(ux_open, self.dtype)
        self.wzf = xp.asarray(wz_open, self.dtype)

        # состояние
        # масса клетки m = 1 + mu (mu — избыток/недостача, храним отдельно ради точности fp32)
        self.mu = xp.zeros((nz, nx), self.dtype)
        self.H = self.fluidf * self.tb
        self.u = xp.asarray(np.repeat(self.ubg_np[:, None], nx + 1, 1) * ux_open, self.dtype)
        self.w = xp.zeros((nz + 1, nx), self.dtype)
        self.p = xp.zeros((nz, nx), self.dtype)
        self.t = 0.0
        self.steps = 0

        # шаг по времени
        dt_adv = pr.cfl * d / max(pr.u_assumed, sc.wind_ms * 1.6)
        dt_dif = 0.2 * d * d / max(pr.nu, pr.kappa)
        self.dt = min(dt_adv, dt_dif, pr.dt_max)
        self.n_sub = max(1, int(math.ceil(pr.sound_c * self.dt / (0.5 * d))))

        # бюджеты (накапливаем на устройстве, float64)
        z = lambda: xp.zeros((), np.float64)
        self.acc = dict(m_in=z(), h_in=z(), h_heat=z(), h_cool=z(), h_sponge=z())
        self.M0 = float((~solid).sum()) * d * d
        self.H0 = float(xp.sum(self.H, dtype=np.float64)) * d * d
        # начальная проекция (ветер обтекает хребет)
        self.project(first=True)

    # --------------------------------------------------- геометрия и фон
    def terrain(self, x):
        pr = self.pr
        dxr = x - pr.ridge_x
        L = np.where(dxr < 0, pr.half_left, pr.half_right)
        s = np.clip(np.abs(dxr) / L, 0, 1)
        return pr.ridge_h * np.cos(0.5 * np.pi * s) ** 2

    def terrain_slope(self, x):
        pr = self.pr
        dxr = x - pr.ridge_x
        L = np.where(dxr < 0, pr.half_left, pr.half_right)
        s = np.clip(np.abs(dxr) / L, 0, 1)
        dh = -pr.ridge_h * np.pi / (2 * L) * np.sin(np.pi * s) * np.sign(dxr)
        return np.where(s < 1, dh, 0.0)

    def background(self, z):
        sc = self.sc
        th = sc.dtheta_dz * z / 1000.0
        if sc.inversion_z is not None:
            zi = np.clip(z - sc.inversion_z, 0, sc.inversion_dz)
            th = th + (sc.inversion_dtheta_dz - sc.dtheta_dz) * zi / 1000.0
        return th

    def wind_profile(self, z):
        U = self.sc.wind_ms
        if U <= 0:
            return np.zeros_like(z)
        return U * np.clip(z / 300.0, 0.05, 1.0) ** 0.2

    def heating_flux(self, x, hx):
        sc = self.sc
        q0 = sc.q0_wm2 / RHO_CP
        if sc.heating == "sun_left":
            e = math.radians(sc.sun_elev_deg)
            # солнце слева: на единицу горизонтальной площади ∝ h'·cos e + sin e
            f = np.clip(hx * math.cos(e) + math.sin(e), 0, None)
        elif sc.heating == "sun_segments":
            e = math.radians(sc.sun_elev_deg)
            f = np.clip(hx * math.cos(e) + math.sin(e), 0, None)
            mask = np.zeros_like(x, dtype=bool)
            for a, b in sc.segments:
                mask |= (x >= a) & (x < b)
            return q0 * f * mask
        elif sc.heating == "point":
            f = np.zeros_like(x)
            f[int(np.argmin(np.abs(x - sc.point_x)))] = 1.0
            return q0 * f
        elif sc.heating == "both":
            f = 0.35 + 0.65 * np.clip(np.abs(hx) / 0.25, 0, 1)
        else:
            raise ValueError(sc.heating)
        # у краёв разреза нагрев плавно сходит на нет (край — не склон, а условная граница)
        edge = np.clip(np.minimum(x, self.pr.lx - x) / self.pr.edge_taper, 0, 1)
        return q0 * (f + sc.q_diffuse) * np.sin(0.5 * np.pi * edge) ** 2

    # --------------------------------------------------- вспомогательные
    def theta(self):
        xp = self.xp
        return xp.where(self.fluid, self.H / (1.0 + self.mu), self.tb)

    def _sample(self, f, fx, fz):
        """Билинейная выборка f по дробным индексам (с зажимом к краю)."""
        xp = self.xp
        nzf, nxf = f.shape
        fx = xp.clip(fx, 0, nxf - 1.0001)
        fz = xp.clip(fz, 0, nzf - 1.0001)
        i0 = fx.astype(np.int32)
        k0 = fz.astype(np.int32)
        a = fx - i0.astype(fx.dtype)
        b = fz - k0.astype(fz.dtype)
        return ((1 - b) * ((1 - a) * f[k0, i0] + a * f[k0, i0 + 1])
                + b * ((1 - a) * f[k0 + 1, i0] + a * f[k0 + 1, i0 + 1])).astype(self.dtype, copy=False)

    def _lap(self, f, bottom_zero=True):
        xp = self.xp
        fp = xp.pad(f, 1, mode="edge")
        if bottom_zero:
            fp[0, :] = 0
        return (fp[1:-1, 2:] + fp[1:-1, :-2] + fp[2:, 1:-1] + fp[:-2, 1:-1] - 4 * f) / self.dx**2

    def div(self, u, w):
        return ((u[:, 1:] - u[:, :-1]) + (w[1:, :] - w[:-1, :])) / self.dx

    # --------------------------------------------------- шаг
    def acoustic(self):
        """Чисто локальное выравнивание массы — буквально идея «недостача подсасывает соседей»:
        избыток массы клетки mu даёт «давление» c²·mu, потоки через грани разгоняются перепадом
        между соседями, масса сразу переносится этими потоками. Это «медленный звук»
        (искусственная сжимаемость): c ≫ скорости ветра, подшаги по условию c·dts/dx ≤ 0,5,
        плюс гашение дивергенции (иначе звенит). Глобального решателя нет.
        Возвращает средние за шаг потоки — ими же переносится тепло (масса уже перенесена)."""
        xp, pr, dt, d = self.xp, self.pr, self.dt, self.dx
        c2 = pr.sound_c ** 2
        n = self.n_sub
        dts = dt / n
        kd = pr.div_damp * d * d / dts
        ua = xp.zeros_like(self.u)
        wa = xp.zeros_like(self.w)
        u, w, mu = self.u, self.w, self.mu
        for _ in range(n):
            pe = c2 * mu - kd * self.div(u, w) * self.fluidf   # «давление» + гашение
            u[:, 1:-1] -= dts * (pe[:, 1:] - pe[:, :-1]) / d * self.uxf[:, 1:-1]
            w[1:-1] -= dts * (pe[1:] - pe[:-1]) / d * self.wzf[1:-1]
            mu -= dts * self.div(u, w) * self.fluidf
            ua += u
            wa += w
        return ua / n, wa / n

    def project(self, first=False):
        xp, pr, dt = self.xp, self.pr, self.dt
        if pr.pressure == "acoustic" and not first:
            return self.acoustic()
        s = pr.mass_relax * self.mu / dt * self.fluidf     # вернуть недостачу/избыток массы
        rhs = (self.div(self.u, self.w) - s) / dt * self.fluidf
        # чистый Нейман: правая часть должна давать ноль в сумме (убираем ошибку округления
        # и суммарный избыток массы, который уходит через выход)
        rhs -= xp.sum(rhs) / self.n_fluid * self.fluidf
        iters = pr.p_iters if not first else 30
        method = pr.pressure if not first else "mg"
        if first:
            self.p[...] = 0
        p = self.poisson.solve(self.p, rhs, method, iters)
        if p is not self.p:
            self.p[...] = p
        self.p -= xp.sum(self.p) / self.n_fluid * self.fluidf
        p = self.p
        d = self.dx
        gx = xp.zeros_like(self.u)
        gx[:, 1:-1] = (p[:, 1:] - p[:, :-1]) / d
        if self.sc.wind_ms > 0:
            gx[:, 0] = 0
        gz = xp.zeros_like(self.w)
        gz[1:-1, :] = (p[1:, :] - p[:-1, :]) / d
        self.u -= dt * gx * self.uxf
        self.w -= dt * gz * self.wzf
        if first:
            self.p[...] = 0
        return None

    def step(self):
        if getattr(self, "graph", None) is not None:
            self.graph.launch(self.stream)
        else:
            self._step_impl()
        self.t += self.dt
        self.steps += 1

    def capture_graph(self):
        """GPU: записать один шаг в CUDA Graph (сотни мелких ядер → один запуск).
        Временные массивы шага живут в отдельном пуле, который больше никто не трогает."""
        import cupy as cp
        self.stream.use()           # to_np() мог сбросить текущий поток
        self._step_impl()           # прогрев: ленивые массивы, компиляция ядер
        self.t += self.dt
        self.steps += 1
        self.stream.synchronize()
        self._graph_pool = cp.cuda.MemoryPool()
        old = cp.get_default_memory_pool()
        cp.cuda.set_allocator(self._graph_pool.malloc)
        try:
            self.stream.begin_capture()
            self._step_impl()
            self.graph = self.stream.end_capture()
        finally:
            cp.cuda.set_allocator(old.malloc)
        # захват не исполняет шаг — исполним его сейчас
        self.graph.launch(self.stream)
        self.t += self.dt
        self.steps += 1

    def _step_impl(self):
        xp, pr, dt, d = self.xp, self.pr, self.dt, self.dx
        nz, nx = self.nz, self.nx
        th = self.theta()
        thp = (th - self.tb) * self.fluidf

        u, w = self.u, self.w
        # --- 1. инерция: полулагранжев перенос потоков
        wp = xp.pad(w, ((0, 0), (1, 1)), mode="edge")         # (nz+1, nx+2)
        w_at_u = 0.25 * (wp[:-1, :-1] + wp[:-1, 1:] + wp[1:, :-1] + wp[1:, 1:])  # (nz, nx+1)
        up = xp.pad(u, ((1, 1), (0, 0)), mode="edge")         # (nz+2, nx+1)
        u_at_w = 0.25 * (up[:-1, :-1] + up[:-1, 1:] + up[1:, :-1] + up[1:, 1:])  # (nz+1, nx)
        if not hasattr(self, "_iu"):
            ku, iu = np.indices(u.shape)
            kw, iw = np.indices(w.shape)
            self._iu, self._ku = xp.asarray(iu, self.dtype), xp.asarray(ku, self.dtype)
            self._iw, self._kw = xp.asarray(iw, self.dtype), xp.asarray(kw, self.dtype)
        un = self._sample(u, self._iu - u * dt / d, self._ku - w_at_u * dt / d)
        wn = self._sample(w, self._iw - u_at_w * dt / d, self._kw - w * dt / d)

        # --- 2. вязкость, плавучесть, губка
        # вязкость и трение — по отклонению от фонового ветра: фон считаем уравновешенным
        # крупномасштабным перепадом давления (иначе трение тормозит набегающий поток ещё в долине)
        un = un + dt * pr.nu * self._lap(u - self.ubg * self.uxf)
        wn = wn + dt * pr.nu * self._lap(w)
        b = xp.zeros_like(w)
        b[1:-1, :] = G / THETA0 * 0.5 * (thp[1:, :] + thp[:-1, :])
        wn = wn + dt * b
        un = (un + dt * self.sp_u * self.ubg) / (1 + dt * self.sp_u)
        wn = wn / (1 + dt * self.sp_w)
        un *= self.uxf
        wn *= self.wzf
        if self.sc.wind_ms > 0:
            un[:, 0] = self.ubg[:, 0] * self.uxf[:, 0]
            out = xp.maximum(un[:, -2], 0.0) * self.uxf[:, -1]
            un[:, -1] = out * (xp.sum(un[:, 0]) / xp.maximum(xp.sum(out), 1e-6))
        self.u[...] = un
        self.w[...] = wn

        # --- 3. выравнивание массы (давление)
        avg = self.project()
        u, w = self.u, self.w
        if avg is not None:     # локальный режим: масса уже перенесена подшагами
            u, w = avg

        # --- 4. перенос массы и тепла парными потоками
        tbc = self.tb_col
        thx = xp.empty_like(u)
        thx[:, 1:-1] = xp.where(u[:, 1:-1] > 0, th[:, :-1], th[:, 1:])
        thx[:, 0] = xp.where(u[:, 0] > 0, tbc, th[:, 0])
        thx[:, -1] = xp.where(u[:, -1] > 0, th[:, -1], tbc)
        thz = xp.zeros_like(w)
        thz[1:-1] = xp.where(w[1:-1] > 0, th[:-1], th[1:])
        Fx = u * thx                    # К·м/с
        Fz = w * thz
        # теплопроводность между соседями (только внутренние открытые грани)
        # теплопроводность между соседями — по отклонению от фона: равновесный поток фона
        # (K·dθ̄/dz) считаем уравновешенным излучением, иначе он «выкачивает» тепло из-под потолка
        Fx[:, 1:-1] -= pr.kappa * (thp[:, 1:] - thp[:, :-1]) / d * self.uxf[:, 1:-1]
        Fz[1:-1] -= pr.kappa * (thp[1:] - thp[:-1]) / d * self.wzf[1:-1]

        dm = -dt * self.div(u, w) if avg is None else 0.0 * self.mu
        dH = -dt * ((Fx[:, 1:] - Fx[:, :-1]) + (Fz[1:] - Fz[:-1])) / d
        heat = dt * self.heat_src
        cool = -dt * (1.0 + self.mu) * (th - self.tb) / pr.tau_cool * self.fluidf
        if self.sp_c is not None:
            spg = -dt * (1.0 + self.mu) * (th - self.tb) * self.sp_c * self.fluidf
        else:
            spg = 0.0 * cool
        self.mu += dm * self.fluidf
        self.H += (dH + heat + cool + spg) * self.fluidf

        # бюджеты (в К·м² и м² на единицу ширины)
        A = d
        f64 = np.float64
        self.acc["m_in"] += dt * A * (xp.sum(u[:, 0], dtype=f64) - xp.sum(u[:, -1], dtype=f64))
        self.acc["h_in"] += dt * A * (xp.sum(Fx[:, 0], dtype=f64) - xp.sum(Fx[:, -1], dtype=f64))
        self.acc["h_heat"] += d * d * xp.sum(heat, dtype=f64)
        self.acc["h_cool"] += d * d * xp.sum(cool, dtype=f64)
        self.acc["h_sponge"] += d * d * xp.sum(spg, dtype=f64)

    # --------------------------------------------------- диагностика
    def to_np(self, a):
        return a.get() if self.gpu else np.asarray(a)

    def centers(self):
        """Скорость в центрах клеток (м/с), θ′ (К), numpy."""
        u, w = self.to_np(self.u), self.to_np(self.w)
        uc = 0.5 * (u[:, 1:] + u[:, :-1])
        wc = 0.5 * (w[1:, :] + w[:-1, :])
        th = self.to_np(self.theta())
        thp = th - self.theta_bar_np[:, None]
        s = self.solid_np
        return (np.where(s, np.nan, uc), np.where(s, np.nan, wc), np.where(s, np.nan, thp))

    def budget(self):
        xp, d = self.xp, self.dx
        M = self.M0 + float(xp.sum(self.mu, dtype=np.float64)) * d * d
        Hs = float(xp.sum(self.H, dtype=np.float64)) * d * d
        a = {k: float(v) for k, v in self.acc.items()}
        mres = (M - self.M0 - a["m_in"])
        hres = (Hs - self.H0 - a["h_in"] - a["h_heat"] - a["h_cool"] - a["h_sponge"])
        mm = self.to_np(self.mu).astype(np.float64)[~self.solid_np]
        return dict(t=self.t, M=M - self.M0, m_in=a["m_in"], m_res=mres / self.M0,
                    H=Hs - self.H0, h_in=a["h_in"], h_heat=a["h_heat"], h_cool=a["h_cool"],
                    h_sponge=a["h_sponge"],
                    h_res=hres / max(a["h_heat"], 1e-30),
                    m_anom=float(np.max(np.abs(mm))))

    def peak_mem_mb(self):
        if not self.gpu:
            return float("nan")
        import cupy as cp
        tot = cp.get_default_memory_pool().total_bytes()
        if getattr(self, "_graph_pool", None) is not None:
            tot += self._graph_pool.total_bytes()
        return tot / 2**20

    def sync(self):
        if self.gpu:
            import cupy as cp
            cp.cuda.Device().synchronize()


def run(sc: Scenario, pr: Params, record=True, verbose=True):
    """Прогон до установления. Возвращает модель, историю кадров, ряд бюджетов, итоги."""
    model = HeatCA(sc, pr)
    if model.gpu and pr.graph:
        model.capture_graph()
    frames, series = [], []
    check_every = max(1, int(round(pr.check_s / model.dt)))
    frame_every = max(1, int(round(pr.frame_s / model.dt)))
    bud_every = max(1, frame_every // 2)
    max_steps = int(math.ceil(pr.t_max / model.dt))
    prev = None
    steady_step = None
    steady_t = None
    steady_wall = None
    t_solver = 0.0
    model.sync()
    t0 = time.perf_counter()
    for n in range(1, max_steps + 1):
        model.step()
        if n % bud_every == 0 or n == 1:
            series.append(model.budget())
        if record and n % frame_every == 0:
            frames.append((model.t,) + model.centers())
        if n % check_every == 0:
            u, w = model.to_np(model.u), model.to_np(model.w)
            th = model.to_np(model.H) / (1.0 + model.to_np(model.mu))
            vmax = max(np.abs(u).max(), np.abs(w).max())
            if not np.isfinite(vmax) or vmax > 50:
                raise RuntimeError(f"расходимость: |v|max={vmax} на шаге {n}")
            if vmax > pr.u_assumed * 1.05 and verbose:
                print(f"  ! |v|max={vmax:.1f} > u_assumed — шаг по CFL на грани")
            if prev is not None:
                dv = max(np.abs(u - prev[0]).max(), np.abs(w - prev[1]).max())
                dT = np.abs(np.where(model.solid_np, 0, th - prev[2])).max()
                if verbose:
                    b = series[-1]
                    print(f"  t={model.t/60:6.1f} мин  шаг {n:6d}  |v|max={vmax:5.2f}  "
                          f"Δv={dv:.3f} м/с  Δθ={dT:.3f} К  масса(лок)={b['m_anom']:.1e}")
                if steady_step is None and dv < pr.steady_dv and dT < pr.steady_dT:
                    model.sync()
                    steady_step, steady_t = n, model.t
                    steady_wall = time.perf_counter() - t0
                    # досчитываем ещё немного, чтобы кадры показали установившееся
                    max_steps = min(max_steps, n + 2 * check_every)
            prev = (u, w, th)
        if n >= max_steps:
            break
    model.sync()
    wall = time.perf_counter() - t0
    series.append(model.budget())
    info = dict(steps=model.steps, t_model=model.t, wall=wall, dt=model.dt,
                steady_step=steady_step, steady_t=steady_t, steady_wall=steady_wall,
                nx=model.nx, nz=model.nz, cells=int((~model.solid_np).sum()),
                mg_levels=len(model.poisson.levels), peak_mem_mb=model.peak_mem_mb(),
                params=asdict(model.pr), scenario=asdict(sc))
    return model, frames, series, info
