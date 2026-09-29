"""Установившееся состояние автомата без шагов по времени: итерации Пикара с неявными
линейными решениями (опыт 2).

Что решаем. Неподвижная точка автомата (model.HeatCA._step_impl, режим давления mg) — это
стационарные уравнения в ТОЙ ЖЕ дискретизации:

  импульс (грани u, w):  D⁻¹·[(S_a·u − u)/dt + ν·Δ(u − u_фон) + b(θ′) + sp·(u_фон − u)] − ∇p = 0,
  неразрывность:          ∇·u = 0,
  тепло (клетки θ′):      ∇·(u·θ_«откуда дует») − κ·Δθ′ = Q − θ′/τ − sp_c·θ′,

где S_a — полулагранжев оператор автомата (билинейная выборка в точке отправления, посчитанной по
скорости a за шаг dt эталона), D = 1 + dt·sp (губка у автомата неявная), b = g·θ′/θ0. Проверено
выкладкой: шаг автомата оставляет поле на месте тогда и только тогда, когда эти уравнения
выполнены, и p здесь совпадает с давлением автомата. Поэтому сошедшиеся итерации дают ТОТ ЖЕ
ответ, что шаги по времени (с точностью до критерия остановки), без подгоночных параметров.

Внешняя итерация (Пикар; всё на GPU, одна итерация — один CUDA Graph; псевдошаги Δτ — это
недорелаксация, в неподвижной точке они выпадают):
  1. заморозить скорость a = u (от неё — точки отправления S_a и направления «откуда дует»);
  2. импульс: линейное уравнение Озеена (перенос замороженной скоростью, вязкость, губка) с
     плавучестью от текущего θ′, псевдошаг Δτ_u, давление с прошлой итерации (инкрементная
     проекция) — «зебра»-прогонки по строкам и столбцам (RawKernel: блок потоков на линию,
     циклическая редукция в разделяемой памяти). Плавучесть полунеявная: w «знает», что θ′
     откликнется на подъём через фон dθ̄/dz (гравитационные волны не раскачивают итерации);
  3. проекция (SIMPLE): ∇·(K∇φ) = ∇·u*, K = Δτ по x и 1/(1/Δτ + связь) по z — многосеточный
     V-цикл (тот же тип решателя, что в плане поля ветра; сглаживание — те же прогонки),
     u ← u* − K∇φ, p ← p + φ;
  4. тепло новым ветром: линейное уравнение (неявно, псевдошаг Δτ_θ) — те же прогонки.
Неточные внутренние решения не сдвигают неподвижную точку (все решения — в форме невязки), только
скорость сходимости.
"""
from __future__ import annotations

import math
import time

import numpy as np

from model import HeatCA, G, THETA0

_LINE_SRC = r'''
typedef float real;
// 9-точечный шаблон C[o][idx], o = (dk+1)*3 + (di+1). Линия (строка или столбец) решается
// блоком потоков циклической редукцией (PCR) в разделяемой памяти: log2(n) параллельных шагов
// вместо последовательной прогонки (та зависела от задержки памяти — ~0,2 мс на запуск).
// Соседние линии — текущие значения x (зебра: линии одной чётности независимы).
// dir = 0: строка k (по i); dir = 1: столбец i (по k).
extern "C" __global__ void line_pcr(const real* C, real* x, const real* b, int nz, int nx, int parity,
                                    int dir) {
    extern __shared__ real sh[];
    int npad = blockDim.x;
    real* A = sh; real* B = sh + npad; real* Cc = sh + 2 * npad; real* D = sh + 3 * npad;
    int line = 2 * blockIdx.x + parity;
    int n = dir == 0 ? nx : nz;
    if (line >= (dir == 0 ? nz : nx)) return;
    int t = threadIdx.x;
    long N = (long)nz * nx;
    long idx = 0;
    if (t < n) {
        int k = dir == 0 ? line : t;
        int i = dir == 0 ? t : line;
        idx = (long)k * nx + i;
        real r = b[idx];
        for (int dk = -1; dk <= 1; ++dk) {
            int kk = k + dk;
            if (kk < 0 || kk >= nz) continue;
            for (int di = -1; di <= 1; ++di) {
                if (dir == 0 ? (dk == 0) : (di == 0)) continue;
                int ii = i + di;
                if (ii < 0 || ii >= nx) continue;
                r -= C[((dk + 1) * 3 + di + 1) * N + idx] * x[(long)kk * nx + ii];
            }
        }
        int om = dir == 0 ? 3 : 1, op = dir == 0 ? 5 : 7;
        A[t] = (t > 0) ? C[om * N + idx] : (real)0;
        B[t] = C[4 * N + idx];
        Cc[t] = (t < n - 1) ? C[op * N + idx] : (real)0;
        D[t] = r;
    } else {
        A[t] = 0; B[t] = 1; Cc[t] = 0; D[t] = 0;
    }
    __syncthreads();
    for (int s = 1; s < npad; s <<= 1) {
        real a = A[t], bb = B[t], c = Cc[t], d = D[t];
        real an = 0, cn = 0;
        if (t - s >= 0) {
            real al = -a / B[t - s];
            an = al * A[t - s];
            bb += al * Cc[t - s];
            d += al * D[t - s];
        }
        if (t + s < npad) {
            real ga = -c / B[t + s];
            cn = ga * Cc[t + s];
            bb += ga * A[t + s];
            d += ga * D[t + s];
        }
        __syncthreads();
        A[t] = an; B[t] = bb; Cc[t] = cn; D[t] = d;
        __syncthreads();
    }
    if (t < n) x[idx] = D[t] / B[t];
}
// y = C·x (9 точек)
extern "C" __global__ void apply9(const real* C, const real* x, real* y, int nz, int nx) {
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    long N = (long)nz * nx;
    if (idx >= N) return;
    int k = idx / nx, i = idx % nx;
    real s = 0;
    for (int dk = -1; dk <= 1; ++dk) {
        int kk = k + dk;
        if (kk < 0 || kk >= nz) continue;
        for (int di = -1; di <= 1; ++di) {
            int ii = i + di;
            if (ii < 0 || ii >= nx) continue;
            s += C[((dk + 1) * 3 + di + 1) * N + idx] * x[(long)kk * nx + ii];
        }
    }
    y[idx] = s;
}
'''
_K = {}


def kernels():
    if not _K:
        import cupy as cp
        mod = cp.RawModule(code=_LINE_SRC)
        for n in ("line_pcr", "apply9"):
            _K[n] = mod.get_function(n)
    return _K


class LineSolver:
    """Зебра-прогонки для поля (nz, nx) с 9-точечным шаблоном C (9, nz, nx)."""

    def __init__(self, xp, nz, nx):
        self.xp, self.nz, self.nx = xp, nz, nx
        self.k = kernels()

    def sweep(self, C, x, b, dirs="xz"):
        nz, nx = np.int32(self.nz), np.int32(self.nx)
        for d in dirs:
            n = self.nx if d == "x" else self.nz          # длина линии
            nl = self.nz if d == "x" else self.nx         # число линий
            npad = 1 << max(5, (n - 1).bit_length())
            for par in (0, 1):
                self.k["line_pcr"](((nl + 1 - par) // 2,), (npad,),
                                   (C, x, b, nz, nx, np.int32(par), np.int32(0 if d == "x" else 1)),
                                   shared_mem=16 * npad)

    def apply(self, C, x, y):
        n = self.nz * self.nx
        self.k["apply9"](((n + 255) // 256,), (256,), (C, x, y, np.int32(self.nz), np.int32(self.nx)))


def _off(dk, di):
    return (dk + 1) * 3 + (di + 1)


def var_poisson(xp, ux_open, wz_open, d, kx, kz):
    """Многосеточный Пуассон ∇·(K∇φ) = f с K = kx по x (число) и kz(z) по высоте (профиль).
    Огрубление: открытость граней — как у автомата, профиль kz — последовательным сложением
    сопротивлений вдоль потока (иначе тонкий слой малой проводимости «теряется» на грубой
    сетке и V-цикл расходится)."""
    from model import Poisson, PoissonLevel, _gpu_kernels
    ox = ux_open.astype(float) / d ** 2
    ox[:, 0] = 0
    ox[:, -1] = 0
    oz = wz_open.astype(float) / d ** 2
    kz = np.asarray(kz, float)
    levels = []
    while True:
        lvl = PoissonLevel(xp, xp.asarray(ox * kx, np.float32), xp.asarray(oz * kz[:, None], np.float32))
        levels.append(lvl)
        nz, nx = oz.shape[0] - 1, ox.shape[1] - 1
        if nx % 2 or nz % 2 or nx < 4 or nz < 4:
            break
        ox = (ox[0::2, 0::2] + ox[1::2, 0::2]) / 8.0
        oz = (oz[0::2, 0::2] + oz[0::2, 1::2]) / 8.0
        kc = kz[0::2].copy()
        K = np.arange(1, nz // 2)
        kc[K] = 2.0 / (0.5 / kz[2 * K - 1] + 1.0 / kz[2 * K] + 0.5 / kz[2 * K + 1])
        kz = kc
    P = LinePoisson.__new__(LinePoisson)
    P.xp, P.gpu, P.levels, P.work = xp, True, levels, {}
    import cupy as cp
    P.k = _gpu_kernels(cp, "float")
    P.real = np.float32
    P.setup_lines()
    return P


def _line_poisson_cls():
    from model import Poisson

    class _LP(Poisson):
        """V-цикл автомата, но сглаживание — зебра-прогонки по строкам и столбцам (устойчиво к
        сильной анизотропии K, которую даёт неявная плавучесть в инверсии)."""

        def setup_lines(self):
            xp = self.xp
            self.lines = []
            for lvl in self.levels:
                C = xp.zeros((9, lvl.nz, lvl.nx), np.float32)
                fl = lvl.fluid.astype(np.float32)
                C[4] = -lvl.diag * fl + (1 - fl)
                C[3] = lvl.cx[:, :-1] * fl
                C[5] = lvl.cx[:, 1:] * fl
                C[1] = lvl.cz[:-1, :] * fl
                C[7] = lvl.cz[1:, :] * fl
                self.lines.append((C, fl, LineSolver(xp, lvl.nz, lvl.nx)))

        def smooth(self, lvl, p, rhs, sweeps, omega=1.0):
            li = next(i for i, l in enumerate(self.levels) if l is lvl)
            C, fl, ls = self.lines[li]
            r = rhs * fl
            for _ in range(4 if sweeps > 4 else sweeps):     # грубейший уровень: прогонки почти точны
                ls.sweep(C, p, r)
            return p
    return _LP



LinePoisson = _line_poisson_cls()


class Picard:
    def __init__(self, sc, pr, dtau_u=120.0, dtau_th=1200.0, heat_sweeps=8, mom_sweeps=2, p_cycles=1,
                 semi=True, couple=0.3):
        self.m = HeatCA(sc, pr)
        m = self.m
        assert m.gpu, "только GPU (CuPy)"
        xp = self.xp = m.xp
        self.f32 = np.float32
        self.d = m.dx
        self.dt = m.dt                    # шаг эталона — задаёт полулагранжев оператор S_a
        self.nz, self.nx = m.nz, m.nx
        self.heat_sweeps, self.mom_sweeps, self.p_cycles = heat_sweeps, mom_sweeps, p_cycles
        self.semi = semi
        self.wind = sc.wind_ms > 0
        pr = m.pr
        nz, nx = self.nz, self.nx
        f = lambda a: xp.asarray(a, np.float32)
        # псевдошаги — 0-мерные массивы на устройстве (меняем между запусками графа)
        self.inv_dtau_u = xp.asarray(1.0 / dtau_u if dtau_u else 0.0, np.float32)
        self.dtau_u = xp.asarray(dtau_u if dtau_u else 1e30, np.float32)
        self.inv_dtau_th = xp.asarray(1.0 / dtau_th if dtau_th else 0.0, np.float32)

        self.Du = 1.0 + self.dt * m.sp_u
        self.Dw = 1.0 + self.dt * m.sp_w
        self.iDu, self.iDw = 1.0 / self.Du, 1.0 / self.Dw
        # строки-«неизвестные»: открытые грани; с ветром боковые грани заданы (приток/выход)
        self.row_u = m.uxf.copy()
        if self.wind:
            self.row_u[:, 0] = 0
            self.row_u[:, -1] = 0
        self.row_w = m.wzf.copy()
        # индексы для точек отправления
        ku, iu = np.indices((nz, nx + 1))
        kw, iw = np.indices((nz + 1, nx))
        self.iu, self.ku = f(iu), f(ku)
        self.iw, self.kw = f(iw), f(kw)
        self._idx = {}
        self.lin_u = xp.arange((nz) * (nx + 1))
        self.lin_w = xp.arange((nz + 1) * nx)
        # постоянная часть шаблонов импульса: −D⁻¹(νΔ − sp) (Δ — _lap автомата), зондированием
        self.Cfix_u = self._probe(lambda x: -self.iDu * (pr.nu * m._lap(x) - m.sp_u * x), (nz, nx + 1))
        self.Cfix_w = self._probe(lambda x: -self.iDw * (pr.nu * m._lap(x) - m.sp_w * x), (nz + 1, nx))
        # постоянная правая часть импульса: D⁻¹(−νΔu_фон + sp·u_фон)
        ubg = m.ubg * m.uxf
        self.rhs_u0 = self.iDu * (-pr.nu * m._lap(ubg) + m.sp_u * m.ubg)
        # тепло
        ox = m.uxf.copy()
        ox[:, 0] = 0
        ox[:, -1] = 0
        self.oe, self.ow = ox[:, 1:], ox[:, :-1]
        self.on, self.os_ = m.wzf[1:], m.wzf[:-1]
        self.kd = pr.kappa / self.d ** 2
        self.sink = 1.0 / pr.tau_cool + (m.sp_c if m.sp_c is not None else 0.0)
        # градиент фона на гранях w (для неявной связи w ↔ θ′)
        tbn = m.theta_bar_np
        gam = np.zeros(nz + 1)
        gam[1:-1] = (tbn[1:] - tbn[:-1]) / self.d
        self.gam_w = f(np.repeat(gam[:, None], nx, 1))
        # неявная плавучесть (полунеявно, как в атмосферных моделях для гравитационных волн):
        # за псевдошаг тепла Δτ_θ крупное возмущение θ′ откликается на w как −dθ̄/dz·w·s,
        # s = Δτ_θ/(1 + Δτ_θ/τ) (перенос и диффузия его почти не гасят). couple — множитель.
        # Профиль по высоте (одинаков по x), чтобы многосеточный огрублял его честно.
        s_th = (dtau_th / (1 + dtau_th / pr.tau_cool)) if dtau_th else pr.tau_cool
        dtu = dtau_u if dtau_u else 1e30
        idw_mid = 1.0 / (1.0 + self.dt * m.to_np(m.sp_w)[:, nx // 2])
        cpl_z = (couple or 0.0) * G / THETA0 * gam * s_th * idw_mid          # (nz+1,)
        self.cpl = f(cpl_z[:, None] * np.ones((1, nx))) * self.row_w if couple else None
        # проекция с «проводимостями» K: по x — Δτ, по z — 1/(1/Δτ + cpl) (SIMPLE с диагональю
        # импульса, в которой учтена неявная плавучесть)
        kz = 1.0 / (1.0 / dtu + cpl_z)
        self.Kx = m.uxf * dtu
        self.Kz = m.wzf * f(kz[:, None])
        self.poisson = var_poisson(xp, m.ux_open_np, m.wz_open_np, self.d, dtu, kz)

        # состояние
        self.u = m.u.copy()
        self.w = xp.zeros_like(m.w)
        self.th = xp.zeros((nz, nx), np.float32)
        self.p = xp.zeros((nz, nx), np.float32)
        self.phi = xp.zeros((nz, nx), np.float32)
        self.Cu = xp.zeros((9, nz, nx + 1), np.float32)
        self.Cw = xp.zeros((9, nz + 1, nx), np.float32)
        self.Ct = xp.zeros((9, nz, nx), np.float32)
        self.ls_u = LineSolver(xp, nz, nx + 1)
        self.ls_w = LineSolver(xp, nz + 1, nx)
        self.ls_t = LineSolver(xp, nz, nx)
        self.du = xp.zeros((), np.float32)     # max |Δu| за итерацию (на устройстве)
        self.graph = None
        self.outer = 0

    # ------------------------------------------------------------------ шаблоны
    def _probe(self, op, shape):
        """Шаблон линейного оператора (≤ 9 точек) зондированием 9 «гребёнками» (раз при старте)."""
        xp = self.xp
        C = xp.zeros((9,) + shape, np.float32)
        kk, ii = np.indices(shape)
        for ck in range(3):
            for ci in range(3):
                e = xp.asarray(((kk % 3 == ck) & (ii % 3 == ci)).astype(np.float32))
                y = op(e)
                dk = (ck - kk + 1) % 3 - 1
                di = (ci - ii + 1) % 3 - 1
                o = xp.asarray((dk + 1) * 3 + (di + 1))
                for oo in range(9):
                    C[oo] += xp.where(o == oo, y, 0.0)
        return C

    def _sl_stencil(self, fx, fz, shape, lin):
        """Шаблон полулагранжевой выборки S_a (билинейно, как model._sample) по точкам отправления."""
        xp = self.xp
        nzf, nxf = shape
        fx = xp.clip(fx, 0, nxf - 1.0001)
        fz = xp.clip(fz, 0, nzf - 1.0001)
        i0 = fx.astype(np.int32)
        k0 = fz.astype(np.int32)
        a = fx - i0.astype(np.float32)
        b = fz - k0.astype(np.float32)
        if shape not in self._idx:
            kk, ii = np.indices(shape)
            self._idx[shape] = (xp.asarray(kk, np.int32), xp.asarray(ii, np.int32))
        kk, ii = self._idx[shape]
        di0 = i0 - ii
        dk0 = k0 - kk
        S = xp.zeros((9, nzf * nxf), np.float32)
        for ck in (0, 1):
            for ci in (0, 1):
                wgt = (b if ck else 1 - b) * (a if ci else 1 - a)
                o = (dk0 + ck + 1) * 3 + (di0 + ci + 1)
                S[o.ravel(), lin] = wgt.ravel()
        return S.reshape((9,) + shape)

    def build_momentum(self):
        xp, m, d, dt = self.xp, self.m, self.d, self.dt
        u, w = self.u, self.w
        wp = xp.pad(w, ((0, 0), (1, 1)), mode="edge")
        w_at_u = 0.25 * (wp[:-1, :-1] + wp[:-1, 1:] + wp[1:, :-1] + wp[1:, 1:])
        up = xp.pad(u, ((1, 1), (0, 0)), mode="edge")
        u_at_w = 0.25 * (up[:-1, :-1] + up[:-1, 1:] + up[1:, :-1] + up[1:, 1:])
        Su = self._sl_stencil(self.iu - u * dt / d, self.ku - w_at_u * dt / d, u.shape, self.lin_u)
        Sw = self._sl_stencil(self.iw - u_at_w * dt / d, self.kw - w * dt / d, w.shape, self.lin_w)
        Cu = self.Cfix_u - Su * (self.iDu / dt)
        Cu[4] += self.iDu / dt + self.inv_dtau_u
        Cw = self.Cfix_w - Sw * (self.iDw / dt)
        Cw[4] += self.iDw / dt + self.inv_dtau_u
        # строки заданных/закрытых граней — тождество
        for C, row in ((Cu, self.row_u), (Cw, self.row_w)):
            C *= row
            C[4] += 1.0 - row
        self.Cu[...] = Cu
        self.Cw[...] = Cw

    def build_heat(self):
        """Шаблон стационарного тепла при замороженном ветре (как в автомате)."""
        xp, m, d = self.xp, self.m, self.d
        u, w = self.u, self.w
        pos = lambda a: xp.maximum(a, 0.0)
        neg = lambda a: xp.maximum(-a, 0.0)
        ue, uw = u[:, 1:], u[:, :-1]
        wn, ws = w[1:], w[:-1]
        kd = self.kd
        C = self.Ct
        C[...] = 0
        C[4] = ((pos(ue) + neg(uw) + pos(wn) + neg(ws)) / d
                + kd * (self.oe + self.ow + self.on + self.os_) + self.sink + self.inv_dtau_th)
        C[5] = -neg(ue) / d - kd * self.oe
        C[3] = -pos(uw) / d - kd * self.ow
        C[7] = -neg(wn) / d - kd * self.on
        C[1] = -pos(ws) / d - kd * self.os_
        fl = m.fluidf
        C *= fl
        C[4] += 1.0 - fl

    def heat_rhs(self, u, w, th_old):
        """Правая часть тепла: нагрев − перенос фона («откуда дует») текущим ветром + псевдошаг."""
        xp, m, d = self.xp, self.m, self.d
        tb = m.tb
        tbx = xp.zeros_like(u)
        tbx[:, 1:-1] = xp.where(u[:, 1:-1] > 0, tb[:, :-1], tb[:, 1:])
        tbx[:, 0] = m.tb_col
        tbx[:, -1] = m.tb_col
        tbz = xp.zeros_like(w)
        tbz[1:-1] = xp.where(w[1:-1] > 0, tb[:-1], tb[1:])
        Fx, Fz = u * tbx, w * tbz
        divb = ((Fx[:, 1:] - Fx[:, :-1]) + (Fz[1:] - Fz[:-1])) / d
        # минус θ̄·∇·u: недорешённая дивергенция (пока итерации не сошлись) не должна давать
        # ложного нагрева; в неподвижной точке ∇·u = 0 и это ровно поток автомата
        divb -= tb * m.div(u, w)
        return (m.heat_src - divb + th_old * self.inv_dtau_th) * m.fluidf

    # ------------------------------------------------------------------ внешняя итерация
    def outer_step(self):
        """Одна внешняя итерация Пикара (без синхронизаций — пишется в CUDA Graph).
        semi=True: сначала импульс+давление с неявной плавучестью, потом тепло новым ветром;
        иначе — сначала тепло старым ветром, потом импульс (явная связь, нужна малая Δτ)."""
        xp, m, d, dt = self.xp, self.m, self.d, self.dt
        # 1. заморозить ветер a = u: шаблоны тепла и импульса (Озеен)
        self.build_heat()
        self.build_momentum()
        u0, w0 = self.u.copy(), self.w.copy()
        if not self.semi:
            self.heat_solve()
        p = self.p
        gx = xp.zeros_like(self.u)
        gx[:, 1:-1] = (p[:, 1:] - p[:, :-1]) / d
        gz = xp.zeros_like(self.w)
        gz[1:-1] = (p[1:] - p[:-1]) / d
        b = xp.zeros_like(self.w)
        b[1:-1] = G / THETA0 * 0.5 * (self.th[1:] + self.th[:-1])
        ru = (self.rhs_u0 + u0 * self.inv_dtau_u - gx) * self.row_u
        rw = (self.iDw * b + w0 * self.inv_dtau_u - gz) * self.row_w
        if self.cpl is not None:
            # неявная плавучесть: θ′ откликнется на δw через фон (−dθ̄/dz·δw за псевдошаг тепла),
            # в уравнении w это «сопротивление» cpl·(w − w⁰); в неподвижной точке — ноль
            self.Cw[4] += self.cpl
            rw += self.cpl * w0
        if self.wind:
            u0[:, 0] = m.ubg[:, 0] * m.uxf[:, 0]
            out = xp.maximum(u0[:, -2] + dt * (p[:, -1] - p[:, -2]) / d, 0.0) * m.uxf[:, -1]
            u0[:, -1] = out * (xp.sum(u0[:, 0]) / xp.maximum(xp.sum(out), 1e-6))
            ru[:, 0] = u0[:, 0]
            ru[:, -1] = u0[:, -1]
            self.u[:, 0] = u0[:, 0]
            self.u[:, -1] = u0[:, -1]
        for _ in range(self.mom_sweeps):
            self.ls_u.sweep(self.Cu, self.u, ru)
            self.ls_w.sweep(self.Cw, self.w, rw)
        # проекция: ∇·(K∇φ) = ∇·u*, u = u* − K∇φ, p += φ; K = Δτ по x, 1/(1/Δτ + cpl) по z
        rhs = m.div(self.u, self.w) * m.fluidf
        rhs -= xp.sum(rhs) / m.n_fluid * m.fluidf
        phi = self.phi
        phi[...] = 0
        for _ in range(self.p_cycles):
            phi = self.poisson.vcycle(0, phi, rhs)
        phi -= xp.sum(phi) / m.n_fluid * m.fluidf
        self.u[:, 1:-1] -= self.Kx[:, 1:-1] * (phi[:, 1:] - phi[:, :-1]) / d
        self.w[1:-1] -= self.Kz[1:-1] * (phi[1:] - phi[:-1]) / d
        self.p += phi
        if self.semi:
            self.heat_solve()
        self.du[...] = xp.maximum(xp.abs(self.u - u0).max(), xp.abs(self.w - w0).max())

    def heat_solve(self):
        """Тепло: шаблон — от замороженного ветра, перенос фона — текущим ветром."""
        rhs_t = self.heat_rhs(self.u, self.w, self.th)
        for _ in range(self.heat_sweeps):
            self.ls_t.sweep(self.Ct, self.th, rhs_t)
        self.th *= self.m.fluidf

    def capture(self):
        import cupy as cp
        m = self.m
        m.stream.use()
        self.outer_step()          # прогрев (компиляция, ленивые массивы) — считается итерацией
        self.outer += 1
        m.stream.synchronize()
        self._pool = cp.cuda.MemoryPool()
        old = cp.get_default_memory_pool()
        cp.cuda.set_allocator(self._pool.malloc)
        try:
            m.stream.begin_capture()
            self.outer_step()
            self.graph = m.stream.end_capture()
        finally:
            cp.cuda.set_allocator(old.malloc)

    def launch(self, n):
        for _ in range(n):
            if self.graph is not None:
                self.graph.launch(self.m.stream)
            else:
                self.outer_step()
            self.outer += 1

    # ------------------------------------------------------------------ проверка: шаг эталона
    def ref_residual(self):
        """Один шаг автомата из текущего состояния: насколько он его сдвигает (м/с² и К/с).
        Ноль ⇔ неподвижная точка автомата. Меняет только копию состояния в self.m."""
        m, xp = self.m, self.xp
        m.u[...] = self.u
        m.w[...] = self.w
        m.mu[...] = 0
        m.H[...] = (m.tb + self.th) * m.fluidf
        m.p[...] = self.p
        if getattr(m, "graph", None) is None:
            m.capture_graph()          # шаг автомата — тоже CUDA Graph (раз; дальше только запуск)
            m.u[...] = self.u
            m.w[...] = self.w
            m.mu[...] = 0
            m.H[...] = (m.tb + self.th) * m.fluidf
            m.p[...] = self.p
        m.graph.launch(m.stream)
        du = float(xp.maximum(xp.abs(m.u - self.u).max(), xp.abs(m.w - self.w).max())) / m.dt
        th1 = (m.H / (1 + m.mu) - m.tb) * m.fluidf
        dth = float(xp.abs(th1 - self.th).max()) / m.dt
        m.stream.use()
        return du, dth

    def solve(self, tol_u=3.3e-6, tol_th=5e-6, max_outer=3000, check_every=10, verbose=False,
              graph=True):
        """Итерации до «шаг эталона сдвигает состояние медленнее tol» (по умолчанию в 10 раз строже
        критерия эталона: 0,02 м/с и 0,03 К за 10 мин)."""
        m = self.m
        hist = []
        m.sync()
        t0 = time.perf_counter()
        if graph:
            self.capture()
        status = "max"
        while self.outer < max_outer:
            self.launch(check_every)
            ru, rt = self.ref_residual()
            hist.append((self.outer, ru, rt, float(self.du)))
            if verbose:
                print(f"  it {self.outer:5d}  шаг эталона: |Δu|/dt={ru:.2e} м/с², |Δθ|/dt={rt:.2e} К/с  "
                      f"|Δu| итерации {float(self.du):.2e}", flush=True)
            if not (math.isfinite(ru) and math.isfinite(rt)) or ru > 1.0:
                status = "diverged"
                break
            if ru < tol_u and rt < tol_th:
                status = "ok"
                break
        m.sync()
        self.wall = time.perf_counter() - t0
        self.hist = hist
        self.status = status
        return hist

    def centers(self):
        m = self.m
        u, w, th = m.to_np(self.u), m.to_np(self.w), m.to_np(self.th)
        uc = 0.5 * (u[:, 1:] + u[:, :-1])
        wc = 0.5 * (w[1:] + w[:-1])
        s = m.solid_np
        return (np.where(s, np.nan, uc), np.where(s, np.nan, wc), np.where(s, np.nan, th))
