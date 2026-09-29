"""3D-Пикар на CuPy для реального рельефа (оценка для библиотеки опорных полей, air_model.md).

Уравнения (установившиеся, Буссинеск, приближение «среднее поле на час»):
  (u·∇)u = −∇p + ν∇²(u − U) − C_d|u|u/Δz·[у земли] + b·ẑ − sp·(u − U),   b = g·θ′/θ0
  ∇·u = 0
  (u·∇)θ′ + w·dθ̄/dz = κ∇²θ′ + Q/Δz·[нижняя клетка] − θ′/τ − sp_θ·θ′

Упрощения против плана (записаны в summary.md):
  * декартова сетка MAC с маской «клетки под землёй не участвуют» (как 2D-прототип), не σ-сетка;
    рельеф — «лесенка» с шагом Δz;
  * перенос — противопоточная схема 1-го порядка (Озеен: скорость переноса заморожена на итерации);
  * ν = κ = const (30 м²/с, как в прототипе), трение о землю — объёмное сопротивление в первом
    слое воздуха с C_d = (0,4/ln(Δz/2/z0))², z0 = 0,1 м;
  * вязкость — по отклонению от фонового ветра U (фон считаем уравновешенным крупномасштабным
    перепадом давления, как в прототипе), поэтому «призрак» под землёй для вязкости = U;
  * без вращения Земли, влаги, излучения кроме τ-выхолаживания.

Итерация Пикара (как опыт 2 heat_ca/exp2_picard):
  1. заморозить скорость, собрать 7-точечные шаблоны импульса (u, v, w) и тепла;
  2. импульс: псевдошаг Δτ_u, давление с прошлой итерации, плавучесть полунеявно (w «знает»,
     что θ′ ответит на подъём через dθ̄/dz), зебра-прогонки по линиям z, x, y;
  3. проекция SIMPLEC: ∇·(K∇φ) = ∇·u*, один V-цикл (полуогрубление по x, y; сглаживание —
     прогонки по вертикальным линиям), u −= K∇φ, p += φ;
  4. тепло новым ветром: псевдошаг Δτ_θ, прогонки.
Остановка — по невязке самих установившихся уравнений (м/с², К/с) и ∇·u.

Массивы (nz+2, ny+2, nx+2) с ореолом: k = 0 — земля (всегда твёрдая), k = nz+1 — над потолком,
i, j = 0 и n+1 — за боковыми границами. u[k,j,i] — грань x между клетками (i−1, i); v — грань y
между (j−1, j); w — грань z между (k−1, k).
Тип грани: 0 — закрыта землёй (значение 0), 1 — неизвестная, 2 — граница области (задаётся
граничными условиями), 3 — ореол (призрачное значение, задано).
Тип клетки: 0 — земля, 1 — воздух внутри, 2 — ореол.
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field

import numpy as np

G = 9.81
THETA0 = 300.0
RHO_CP = 1.2 * 1005.0

_SRC = r'''
typedef float real;
#define IDX(k,j,i) (((long)(k) * NY + (j)) * NX + (i))

// ---------------------------------------------------------------- прогонка по линии (Томас)
// Шаблон C[7][N]: 0 центр, 1 −x, 2 +x, 3 −y, 4 +y, 5 −z, 6 +z. Уравнение Σ C·x = b.
// dir: 0 — x, 1 — y, 2 — z. Поток на линию; зебра по чётности суммы двух других индексов.
extern "C" __global__ void line_thomas(const real* C, real* x, const real* b, real* cp_, real* dp_,
                                       int NZ, int NY, int NX, int dir, int parity) {
    long N = (long)NZ * NY * NX;
    int t = blockDim.x * blockIdx.x + threadIdx.x;
    int n, a1, a2, n1;   // длина линии и два других индекса
    long stride;
    long base;
    if (dir == 0) { n = NX; n1 = NY; stride = 1; a1 = t % NY; a2 = t / NY; if (a2 >= NZ) return;
                    base = IDX(a2, a1, 0); }
    else if (dir == 1) { n = NY; n1 = NX; stride = NX; a1 = t % NX; a2 = t / NX; if (a2 >= NZ) return;
                    base = IDX(a2, 0, a1); }
    else { n = NZ; n1 = NX; stride = (long)NX * NY; a1 = t % NX; a2 = t / NX; if (a2 >= NY) return;
                    base = IDX(0, a2, a1); }
    if (((a1 + a2) & 1) != parity) return;
    const long off[7] = {0, -1, 1, -(long)NX, (long)NX, -(long)NX * NY, (long)NX * NY};
    int lo = 1 + 2 * dir, hi = 2 + 2 * dir;
    real cprev = 0, dprev = 0;
    for (int m = 0; m < n; ++m) {
        long idx = base + m * stride;
        real r = b[idx];
        for (int o = 1; o < 7; ++o) {
            if (o == lo || o == hi) continue;
            real c = C[o * N + idx];
            if (c != (real)0) {
                long q = idx + off[o];
                if (q >= 0 && q < N) r -= c * x[q];
            }
        }
        real a = (m > 0) ? C[lo * N + idx] : (real)0;
        real bb = C[idx];
        real cc = (m < n - 1) ? C[hi * N + idx] : (real)0;
        real den = bb - a * cprev;
        real cpv = cc / den;
        real dpv = (r - a * dprev) / den;
        cp_[idx] = cpv; dp_[idx] = dpv;
        cprev = cpv; dprev = dpv;
    }
    real xn = 0;
    for (int m = n - 1; m >= 0; --m) {
        long idx = base + m * stride;
        real v = dp_[idx] - cp_[idx] * xn;
        x[idx] = v;
        xn = v;
    }
}

// r = b − C·x
extern "C" __global__ void resid7(const real* C, const real* x, const real* b, real* r,
                                  int NZ, int NY, int NX) {
    long N = (long)NZ * NY * NX;
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= N) return;
    const long off[7] = {0, -1, 1, -(long)NX, (long)NX, -(long)NX * NY, (long)NX * NY};
    real s = 0;
    for (int o = 0; o < 7; ++o) {
        real c = C[o * N + idx];
        if (c != (real)0) { long q = idx + off[o]; if (q >= 0 && q < N) s += c * x[q]; }
    }
    r[idx] = b[idx] - s;
}

// ---------------------------------------------------------------- шаблон импульса
// comp: 0 — u, 1 — v, 2 — w. Все поля (NZ, NY, NX).
extern "C" __global__ void build_mom(int comp, const real* u, const real* v, const real* w,
        const unsigned char* tf, const unsigned char* tu, const unsigned char* tv, const unsigned char* tw,
        const unsigned char* cell, const real* p, const real* th,
        const real* sp, const real* cplz, real* C, real* b,
        int NZ, int NY, int NX, real dx, real dz, const real* nuf, real inv_dtau, real ubg, real cd,
        const real* pres_on) {
    long N = (long)NZ * NY * NX;
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= N) return;
    int i = idx % NX; int j = (idx / NX) % NY; int k = idx / ((long)NX * NY);
    const real* f = comp == 0 ? u : (comp == 1 ? v : w);
    if (tf[idx] != 1) {
        C[idx] = 1; for (int o = 1; o < 7; ++o) C[o * N + idx] = 0;
        b[idx] = f[idx];
        return;
    }
    const long sx = 1, sy = NX, sz = (long)NX * NY;
    real ax, ay, az;
    long c0, c1;     // две клетки по сторонам грани
    if (comp == 0) {
        ax = u[idx];
        ay = 0.25f * (v[idx - sx] + v[idx - sx + sy] + v[idx] + v[idx + sy]);
        az = 0.25f * (w[idx - sx] + w[idx - sx + sz] + w[idx] + w[idx + sz]);
        c0 = idx - sx; c1 = idx;
    } else if (comp == 1) {
        ay = v[idx];
        ax = 0.25f * (u[idx - sy] + u[idx - sy + sx] + u[idx] + u[idx + sx]);
        az = 0.25f * (w[idx - sy] + w[idx - sy + sz] + w[idx] + w[idx + sz]);
        c0 = idx - sy; c1 = idx;
    } else {
        az = w[idx];
        ax = 0.25f * (u[idx - sz] + u[idx - sz + sx] + u[idx] + u[idx + sx]);
        ay = 0.25f * (v[idx - sz] + v[idx - sz + sy] + v[idx] + v[idx + sy]);
        c0 = idx - sz; c1 = idx;
    }
    const unsigned char* tt = comp == 0 ? tu : (comp == 1 ? tv : tw);
    real a3[3] = {ax, ay, az};
    real h[3] = {dx, dx, dz};
    long st[3] = {sx, sy, sz};
    real nu = 0.5f * (nuf[c0] + nuf[c1]);
    real diag = inv_dtau + sp[idx];
    real rhs = f[idx] * inv_dtau + sp[idx] * ubg;
    real cc[7] = {0, 0, 0, 0, 0, 0, 0};
    for (int d = 0; d < 3; ++d) {
        real ih = 1.0f / h[d], vis = nu * ih * ih;
        real a = a3[d];
        for (int s = 0; s < 2; ++s) {
            int o = 1 + 2 * d + s;
            long q = idx + (s ? st[d] : -st[d]);
            real cn = 0;
            if (s == 0 && a > 0) { diag += a * ih; cn -= a * ih; }
            if (s == 1 && a < 0) { diag -= a * ih; cn += a * ih; }
            diag += vis;
            if (tt[q] == 0) rhs += vis * ubg;      // под землёй: отклонение от фона = 0
            else cn -= vis;
            cc[o] = cn;
        }
    }
    // давление
    real pgrad = (p[c1] - p[c0]) / (comp == 2 ? dz : dx);
    rhs -= pres_on[0] * pgrad;
    if (comp < 2) {
        // трение о землю: первая над землёй грань (клетка под одной из соседних — земля)
        if (cell[c0 - sz] == 0 || cell[c1 - sz] == 0) {
            real sp2 = ax * ax + ay * ay;
            diag += cd * sqrtf(sp2) / dz;
        }
    } else {
        real bu = 9.81f / 300.0f * 0.5f * (th[c0] + th[c1]);
        rhs += bu;
        diag += cplz[k];
        rhs += cplz[k] * w[idx];
    }
    C[idx] = diag;
    for (int o = 1; o < 7; ++o) C[o * N + idx] = cc[o];
    b[idx] = rhs;
}

// ---------------------------------------------------------------- шаблон тепла
extern "C" __global__ void build_heat(const real* u, const real* v, const real* w, const unsigned char* cell,
        const real* th, const real* Q, const real* spc, const real* gam, real* C, real* b,
        int NZ, int NY, int NX, real dx, real dz, const real* kf, real inv_dtau, real inv_tau) {
    long N = (long)NZ * NY * NX;
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= N) return;
    int k = idx / ((long)NX * NY);
    if (cell[idx] != 1) {
        C[idx] = 1; for (int o = 1; o < 7; ++o) C[o * N + idx] = 0;
        b[idx] = th[idx];
        return;
    }
    const long sx = 1, sy = NX, sz = (long)NX * NY;
    // скорости на гранях: минус-грань (индекс idx) и плюс-грань (idx + s)
    real fm[3] = {u[idx], v[idx], w[idx]};
    real fp[3] = {u[idx + sx], v[idx + sy], w[idx + sz]};
    real h[3] = {dx, dx, dz};
    long st[3] = {sx, sy, sz};
    real diag = inv_dtau + inv_tau + spc[idx];
    real rhs = th[idx] * inv_dtau + Q[idx] - gam[k] * 0.5f * (w[idx] + w[idx + sz]);
    real cc[7] = {0, 0, 0, 0, 0, 0, 0};
    for (int d = 0; d < 3; ++d) {
        real ih = 1.0f / h[d];
        // минус-грань: наружу — это −fm
        {
            real vo = -fm[d]; long q = idx - st[d]; real cn = 0;
            real dif = 0.5f * (kf[idx] + kf[q]) * ih * ih;
            if (vo > 0) diag += vo * ih; else cn += vo * ih;
            if (cell[q] != 0) { diag += dif; cn -= dif; }
            cc[1 + 2 * d] = cn;
        }
        {
            real vo = fp[d]; long q = idx + st[d]; real cn = 0;
            real dif = 0.5f * (kf[idx] + kf[q]) * ih * ih;
            if (vo > 0) diag += vo * ih; else cn += vo * ih;
            if (cell[q] != 0) { diag += dif; cn -= dif; }
            cc[2 + 2 * d] = cn;
        }
    }
    C[idx] = diag;
    for (int o = 1; o < 7; ++o) C[o * N + idx] = cc[o];
    b[idx] = rhs;
}
'''
_K = {}


def kernels():
    if not _K:
        import cupy as cp
        mod = cp.RawModule(code=_SRC, options=("--use_fast_math",))
        for n in ("line_thomas", "resid7", "build_mom", "build_heat"):
            _K[n] = mod.get_function(n)
    return _K


class Lines:
    """Зебра-прогонки 7-точечного шаблона на массиве (NZ, NY, NX)."""

    def __init__(self, shape):
        import cupy as cp
        self.shape = shape
        self.cp_ = cp.zeros(shape, np.float32)
        self.dp_ = cp.zeros(shape, np.float32)
        self.k = kernels()

    def sweep(self, C, x, b, dirs=(2, 0, 1)):
        NZ, NY, NX = self.shape
        for d in dirs:
            nl = NY * NZ if d == 0 else (NX * NZ if d == 1 else NX * NY)
            for par in (0, 1):
                self.k["line_thomas"](((nl + 127) // 128,), (128,),
                                      (C, x, b, self.cp_, self.dp_, np.int32(NZ), np.int32(NY),
                                       np.int32(NX), np.int32(d), np.int32(par)))

    def resid(self, C, x, b, r):
        NZ, NY, NX = self.shape
        n = NZ * NY * NX
        self.k["resid7"](((n + 255) // 256,), (256,), (C, x, b, r, np.int32(NZ), np.int32(NY), np.int32(NX)))


class MG:
    """Многосеточный Пуассон ∇·(K∇φ) = f на клетках (nz, ny, nx) без ореола.
    cx (nz, ny, nx+1), cy (nz, ny+1, nx), cz (nz+1, ny, nx) — проводимости граней (K/h², 0 — закрыто).
    Полуогрубление по x, y (z не огрубляется), сглаживание — прогонки по вертикали (зебра)."""

    def __init__(self, cx, cy, cz, active, xy_div=8.0, corr=1.0):
        import cupy as cp
        self.levels = []
        self.corr = corr
        while True:
            nz, ny, nx = active.shape
            C = self._stencil(cx, cy, cz, active)
            self.levels.append(dict(C=C, act=cp.asarray(active, np.float32), shape=active.shape,
                                    lines=Lines(active.shape), r=cp.zeros(active.shape, np.float32)))
            if nx % 2 or ny % 2 or nx < 6 or ny < 6:
                break
            cx = (cx[:, 0::2, 0::2] + cx[:, 1::2, 0::2]) / xy_div
            cy = (cy[:, 0::2, 0::2] + cy[:, 0::2, 1::2]) / xy_div
            cz = (cz[:, 0::2, 0::2] + cz[:, 0::2, 1::2] + cz[:, 1::2, 0::2] + cz[:, 1::2, 1::2]) / 4.0
            active = active.reshape(nz, ny // 2, 2, nx // 2, 2).any(axis=(2, 4))
            # закрыть грани у неактивных клеток
            # закрыть грани у неактивных клеток (граничные — по активности крайней клетки)
            a = active
            cx = cx * np.concatenate([a[:, :, :1], a[:, :, 1:] & a[:, :, :-1], a[:, :, -1:]], axis=2)
            cy = cy * np.concatenate([a[:, :1], a[:, 1:] & a[:, :-1], a[:, -1:]], axis=1)
            cz = cz * np.concatenate([a[:1], a[1:] & a[:-1], a[-1:]], axis=0)

    @staticmethod
    def _stencil(cx, cy, cz, active):
        import cupy as cp
        nz, ny, nx = active.shape
        C = np.zeros((7, nz, ny, nx), np.float32)
        C[1] = cx[:, :, :-1]
        C[2] = cx[:, :, 1:]
        C[3] = cy[:, :-1, :]
        C[4] = cy[:, 1:, :]
        C[5] = cz[:-1]
        C[6] = cz[1:]
        C[0] = -(C[1] + C[2] + C[3] + C[4] + C[5] + C[6])
        # грани на краю массива — Дирихле φ = 0 снаружи: в диагонали остаются, соседа нет
        C[1][:, :, 0] = 0; C[2][:, :, -1] = 0
        C[3][:, 0, :] = 0; C[4][:, -1, :] = 0
        C[5][0] = 0; C[6][-1] = 0
        dead = ~active | (C[0] == 0)
        C[:, dead] = 0
        C[0][dead] = 1.0
        return cp.asarray(C)

    def vcycle(self, li, x, f, pre=2, post=2):
        import cupy as cp
        L = self.levels[li]
        C, lines = L["C"], L["lines"]
        if li == len(self.levels) - 1:
            for _ in range(20):
                lines.sweep(C, x, f, dirs=(2, 0, 1))
            return x
        for _ in range(pre):
            lines.sweep(C, x, f, dirs=(2,))
        r = L["r"]
        lines.resid(C, x, f, r)
        nz, ny, nx = L["shape"]
        rc = r.reshape(nz, ny // 2, 2, nx // 2, 2).mean(axis=(2, 4))
        rc *= self.levels[li + 1]["act"]
        ec = self.vcycle(li + 1, cp.zeros_like(rc), rc, pre, post)
        x += cp.repeat(cp.repeat(ec, 2, axis=1), 2, axis=2) * (L["act"] * np.float32(self.corr))
        for _ in range(post):
            lines.sweep(C, x, f, dirs=(2,))
        return x


def solar_position(lat, lon, doy, hour_local, utc_offset):
    """Высота и азимут солнца (град; азимут от севера по часовой), NOAA упрощённо."""
    g = 2 * math.pi / 365.0 * (doy - 1 + (hour_local - 12) / 24.0)
    eqt = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g)
                    - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
    decl = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g) - 0.006758 * math.cos(2 * g)
            + 0.000907 * math.sin(2 * g) - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    tst = hour_local * 60 + eqt + 4 * lon - 60 * utc_offset
    ha = math.radians(tst / 4 - 180)
    la = math.radians(lat)
    cz = math.sin(la) * math.sin(decl) + math.cos(la) * math.cos(decl) * math.cos(ha)
    zen = math.acos(max(-1, min(1, cz)))
    el = 90 - math.degrees(zen)
    az = math.degrees(math.atan2(math.sin(ha), math.cos(ha) * math.sin(la) - math.tan(decl) * math.cos(la))) + 180
    return el, az % 360


@dataclass
class Cond:
    """Условия расчёта."""
    hour: float | None = 13.0       # часы места (UTC+7); None — без нагрева
    wind: float = 0.0               # м/с, фон на высоте
    wdir: float = 270.0             # откуда дует, град (метеорологически: 270 — западный)
    heat_wm2: float = 330.0         # явный поток тепла при нормальном падении солнца, Вт/м²
    diffuse: float = 0.10           # рассеянная доля (× sin высоты солнца)
    lag_h: float = 0.3              # запаздывание прогрева (луг, configs/weather_model.json → heating)
    doy: int = 196                  # 15 июля
    gam_low: float = 3.0            # dθ̄/dz ниже z_break, К/км (T падает на 6,8 К/км)
    gam_high: float = 6.0           # выше (воздух над слоем перемешивания, lapse 4 К/км)
    z_break: float = 3500.0         # м над морем

    def key(self):
        h = "noheat" if self.hour is None else f"h{self.hour:g}"
        return f"{h}_U{self.wind:g}_d{int(self.wdir) if self.wind > 0 else 0}"


@dataclass
class Params:
    nu: float = 30.0
    kappa: float = 30.0
    tau_cool: float = 7200.0
    z0: float = 0.1
    dtau_u: float = 120.0
    dtau_th: float = 1200.0
    couple: float = 0.3
    mom_sweeps: int = 2
    heat_sweeps: int = 4
    sponge_top_m: float = 1000.0
    sponge_side_m: float = 2000.0
    sponge_rate: float = 1 / 300.0
    heat_taper_m: float = 2000.0
    outflow: str = "fixed"          # fixed (приток/выход заданы фоном, губки 2 км) | scaled (снос изнутри +
                                    # масштаб; медленная мода 0,989/итер.) | dirichlet (φ = 0 за выходом; V-цикл расходится)
    closure: str = "cbl"            # const | cbl (см. Air3D.__init__)
    k_smooth_m: float = 1500.0
    zi_min: float = 500.0


class Air3D:
    def __init__(self, grid, hc, cond: Cond, prm: Params = Params(), water=None, nest=None, lat=50.79,
                 lon=86.13, utc=7.0):
        """grid — terrain.Grid, hc (ny, nx) — высота рельефа в клетках (м над морем).
        nest — None (вся область) или dict(parent=Air3D) для окна с границами от грубого."""
        import cupy as cp
        self.cp = cp
        self.g, self.cond, self.prm = grid, cond, prm
        self.nest = nest
        self.lat, self.lon, self.utc = lat, lon, utc
        nx, ny, nz = grid.nx, grid.ny, grid.nz
        self.NX, self.NY, self.NZ = nx + 2, ny + 2, nz + 2
        NX, NY, NZ = self.NX, self.NY, self.NZ
        shape = (NZ, NY, NX)
        self.shape = shape
        dx, dz = grid.dx, grid.dz
        self.dx, self.dz = dx, dz
        # --- клетки: рельеф с ореолом (края продлены)
        hp = np.pad(hc, 1, mode="edge")
        self.hc = hc
        zc = grid.z_bot + (np.arange(NZ) - 0.5) * dz          # центры, k = 0 — под дном
        self.zc_full = zc
        solid = zc[:, None, None] < hp[None]
        solid[0] = True
        cell = np.where(solid, 0, 1).astype(np.uint8)
        cell[:, 0, :] = np.where(solid[:, 0, :], 0, 2)
        cell[:, -1, :] = np.where(solid[:, -1, :], 0, 2)
        cell[:, :, 0] = np.where(solid[:, :, 0], 0, 2)
        cell[:, :, -1] = np.where(solid[:, :, -1], 0, 2)
        cell[-1] = np.where(solid[-1], 0, 2)
        self.cell_np = cell
        self.fluid_np = cell == 1
        # --- грани
        def ftype(c0, c1):
            t = np.full(c0.shape, 3, np.uint8)
            t[(c0 == 0) | (c1 == 0)] = 0
            t[(c0 == 1) & (c1 == 1)] = 1
            t[((c0 == 1) & (c1 == 2)) | ((c0 == 2) & (c1 == 1))] = 2
            return t
        tu = np.full(shape, 3, np.uint8)
        tu[:, :, 1:] = ftype(cell[:, :, :-1], cell[:, :, 1:])
        tv = np.full(shape, 3, np.uint8)
        tv[:, 1:, :] = ftype(cell[:, :-1, :], cell[:, 1:, :])
        tw = np.full(shape, 3, np.uint8)
        tw[1:] = ftype(cell[:-1], cell[1:])
        tw[0] = 0
        self.tu_np, self.tv_np, self.tw_np = tu, tv, tw
        # --- фон
        ang = math.radians(cond.wdir)
        U = cond.wind
        self.Ux, self.Uy = (round(-U * math.sin(ang), 6), round(-U * math.cos(ang), 6)) if U > 0 else (0.0, 0.0)
        gam_c = np.where(zc < cond.z_break, cond.gam_low, cond.gam_high) / 1000.0
        self.gam_np = gam_c
        self.theta_bar = np.cumsum(gam_c) * dz
        # --- губки (скорость — к фону; θ′ — к нулю у потолка и на притоке)
        ztop = grid.z_bot + nz * dz
        spz = np.clip((zc - (ztop - prm.sponge_top_m)) / prm.sponge_top_m, 0, 1) ** 2 * prm.sponge_rate
        spz_w = np.clip((zc - 0.5 * dz - (ztop - prm.sponge_top_m)) / prm.sponge_top_m, 0, 1) ** 2 * prm.sponge_rate
        xi = (np.arange(NX) - 0.5) * dx     # расстояние центра клетки от западного края
        yj = (np.arange(NY) - 0.5) * dx
        Lx, Ly = nx * dx, ny * dx
        if nest is None:
            if U > 0:
                def ramp(dist):
                    return np.clip(1 - dist / prm.sponge_side_m, 0, 1) ** 2 * prm.sponge_rate
                side = np.maximum.reduce([ramp(xi)[None, :] + 0 * yj[:, None], ramp(Lx - xi)[None, :] + 0 * yj[:, None],
                                          ramp(yj)[:, None] + 0 * xi[None, :], ramp(Ly - yj)[:, None] + 0 * xi[None, :]])
                # θ′ — только на притоке
                sc = np.zeros((NY, NX))
                if self.Ux > 0:
                    sc = np.maximum(sc, ramp(xi)[None, :] + 0 * yj[:, None])
                if self.Ux < 0:
                    sc = np.maximum(sc, ramp(Lx - xi)[None, :] + 0 * yj[:, None])
                if self.Uy > 0:
                    sc = np.maximum(sc, ramp(yj)[:, None] + 0 * xi[None, :])
                if self.Uy < 0:
                    sc = np.maximum(sc, ramp(Ly - yj)[:, None] + 0 * xi[None, :])
                # доля по компоненте (для заметного фона — полная)
                sc = sc * 1.0
            else:
                side = np.zeros((NY, NX))
                sc = np.zeros((NY, NX))
        else:
            side = np.zeros((NY, NX))
            sc = np.zeros((NY, NX))
        if nest is not None:
            spz = spz * 0            # окно: потолок задан родителем, губки нет
            spz_w = spz_w * 0
        sp_c = np.maximum(spz[:, None, None], side[None])
        sp_w = np.maximum(spz_w[:, None, None], side[None])
        spc = np.maximum(spz[:, None, None], sc[None])
        # --- нагрев
        self.sun = None
        Qh = np.zeros((ny, nx))
        if cond.hour is not None:
            el, az = solar_position(lat, lon, cond.doy, cond.hour - cond.lag_h, utc)
            self.sun = (el, az)
            if el > 0:
                e, a = math.radians(el), math.radians(az)
                sx, sy, sz = math.cos(e) * math.sin(a), math.cos(e) * math.cos(a), math.sin(e)
                gy, gx = np.gradient(hc, dx)
                f = np.clip(-gx * sx - gy * sy + sz, 0, None) + cond.diffuse * sz
                Qh = cond.heat_wm2 / RHO_CP * f                 # К·м/с на горизонтальную площадь
                if water is not None:
                    Qh = Qh * (1 - water)
                if nest is None:
                    xe = (np.arange(nx) + 0.5) * dx
                    ye = (np.arange(ny) + 0.5) * dx
                    ex = np.clip(np.minimum(xe, Lx - xe) / prm.heat_taper_m, 0, 1)
                    ey = np.clip(np.minimum(ye, Ly - ye) / prm.heat_taper_m, 0, 1)
                    Qh = Qh * (np.sin(0.5 * np.pi * ey)[:, None] * np.sin(0.5 * np.pi * ex)[None, :]) ** 2
        self.Qh = Qh
        # --- турбулентная вязкость/теплопроводность (Pr_t = 1)
        #   const: ν = κ = ν0;
        #   cbl:   ν = max(ν0, K_conv), K_conv = 0,4·w_m·z·(1 − z/z_i)² (профиль Троена–Марта /
        #          Холтслага–Бовилля для слоя перемешивания), w_m = 0,65·w*, w* = (g/θ0·Q·z_i)^(1/3),
        #          Q — поток тепла, сглаженный по площади (σ = prm.k_smooth_m), z_i — верх слоя
        #          перемешивания (θ̄ излом z_break над морем), z — высота центра клетки над землёй.
        nu = np.full(shape, prm.nu, np.float64)
        self.wstar = np.zeros((ny, nx))
        if prm.closure == "cbl" and Qh.max() > 0:
            Qs = gauss2d(Qh, prm.k_smooth_m / dx)
            hs = gauss2d(hc, prm.k_smooth_m / dx)
            zi = np.clip(cond.z_break - hs, prm.zi_min, None)
            ws = (G / THETA0 * Qs * zi) ** (1 / 3)
            self.wstar = ws
            zagl = zc[:, None, None] - hc[None]
            zz = np.clip(zagl / zi[None], 0, 1)
            K = 0.4 * 0.65 * ws[None] * np.clip(zagl, 0, None) * (1 - zz) ** 2
            nu[:, 1:-1, 1:-1] = np.maximum(prm.nu, K)
            nu[:, 0, :] = nu[:, 1, :]; nu[:, -1, :] = nu[:, -2, :]
            nu[:, :, 0] = nu[:, :, 1]; nu[:, :, -1] = nu[:, :, -2]
        self.nu_np = nu
        Q = np.zeros(shape)
        kb = np.argmax(self.fluid_np[:, 1:-1, 1:-1], axis=0)   # первая воздушная клетка столбца
        self.kb = kb
        jj, ii = np.indices((ny, nx))
        Q[kb, jj + 1, ii + 1] = Qh / dz
        # --- на устройство
        f32 = lambda a: cp.asarray(a, np.float32)
        self.cell = cp.asarray(cell)
        self.tu, self.tv, self.tw = cp.asarray(tu), cp.asarray(tv), cp.asarray(tw)
        self.fluid = f32(self.fluid_np)
        self.n_fluid = float(self.fluid_np.sum())
        self.mu_u, self.mu_v, self.mu_w = f32(tu == 1), f32(tv == 1), f32(tw == 1)
        self.sp_u = f32(sp_c)
        self.sp_w = f32(sp_w)
        self.spc = f32(spc)
        self.Q = f32(Q)
        self.gam = f32(gam_c)
        self.nuf = f32(nu)
        self.cd = (0.4 / math.log(0.5 * dz / prm.z0)) ** 2
        # полунеявная плавучесть (как опыт 2): cpl = couple·g/θ0·dθ̄/dz·s_θ по граням w
        s_th = prm.dtau_th / (1 + prm.dtau_th / prm.tau_cool)
        gam_w = np.zeros(NZ)
        gam_w[1:] = 0.5 * (gam_c[1:] + gam_c[:-1])
        cplz = prm.couple * G / THETA0 * gam_w * s_th
        self.cplz = f32(cplz)
        # --- состояние
        self.u = cp.zeros(shape, np.float32)
        self.v = cp.zeros(shape, np.float32)
        self.w = cp.zeros(shape, np.float32)
        self.th = cp.zeros(shape, np.float32)
        self.p = cp.zeros(shape, np.float32)
        self.Cu = cp.zeros((7,) + shape, np.float32)
        self.Cv = cp.zeros((7,) + shape, np.float32)
        self.Cw = cp.zeros((7,) + shape, np.float32)
        self.Ct = cp.zeros((7,) + shape, np.float32)
        self.bu = cp.zeros(shape, np.float32)
        self.bv = cp.zeros(shape, np.float32)
        self.bw = cp.zeros(shape, np.float32)
        self.bt = cp.zeros(shape, np.float32)
        self.rr = cp.zeros(shape, np.float32)
        self.lines = Lines(shape)
        self.k = kernels()
        self.pres_on = cp.ones((1,), np.float32)
        # --- проекция: K по x, y = 1/(1/Δτ + sp), по z = 1/(1/Δτ + sp + cpl)
        idt = 1.0 / prm.dtau_u
        Kx = 1.0 / (idt + sp_c)                  # (NZ, NY, NX) у центров; для граней — среднее
        Kx_face = np.zeros(shape)
        Kx_face[:, :, 1:] = 0.5 * (Kx[:, :, 1:] + Kx[:, :, :-1])
        Ky_face = np.zeros(shape)
        Ky_face[:, 1:, :] = 0.5 * (Kx[:, 1:, :] + Kx[:, :-1, :])
        Kz_face = 1.0 / (idt + sp_w + cplz[:, None, None])
        # выход (боковые грани без притока) при ветре: в проекции φ = 0 снаружи (Дирихле) —
        # нормальная скорость выхода поправляется давлением вместе с внутренними гранями
        self.p_dirichlet = (prm.outflow == "dirichlet" and nest is None and U > 0)
        opx = (tu == 1)
        opy = (tv == 1)
        if self.p_dirichlet:
            su_all = np.where(cell == 1, -1.0, 1.0)             # внешняя нормаль грани u[i] (если граничная)
            opx = opx | ((tu == 2) & (su_all * self.Ux >= 0))
            opy = opy | ((tv == 2) & (su_all * self.Uy >= 0))
        Kx_face *= opx
        Ky_face *= opy
        Kz_face = Kz_face * (tw == 1)
        self.Kx, self.Ky, self.Kz = f32(Kx_face), f32(Ky_face), f32(Kz_face)
        I = (slice(1, -1), slice(1, -1), slice(1, -1))
        cx = Kx_face[1:-1, 1:-1, 1:] / dx ** 2          # (nz, ny, nx+1)
        cy = Ky_face[1:-1, 1:, 1:-1] / dx ** 2
        cz = Kz_face[1:, 1:-1, 1:-1] / dz ** 2
        self.mg = MG(cx, cy, cz, self.fluid_np[I])
        self.phi = cp.zeros((nz, ny, nx), np.float32)
        # --- граничные грани (тип 2): списки для граничных условий
        self._setup_boundary()
        self.outer = 0
        self.graph = None
        self.hist = []

    # ------------------------------------------------------------------ границы
    def _setup_boundary(self):
        cp = self.cp
        tu, tv, tw = self.tu_np, self.tv_np, self.tw_np
        NZ, NY, NX = self.shape
        # u: грань i; внутренняя клетка — i (запад, наружу −x) или i−1 (восток, наружу +x)
        bu = np.argwhere(tu == 2)
        su = np.where(self.cell_np[bu[:, 0], bu[:, 1], bu[:, 2]] == 1, -1, 1)   # внешняя нормаль по x
        bv = np.argwhere(tv == 2)
        sv = np.where(self.cell_np[bv[:, 0], bv[:, 1], bv[:, 2]] == 1, -1, 1)
        bw = np.argwhere(tw == 2)
        sw = np.where(self.cell_np[bw[:, 0], bw[:, 1], bw[:, 2]] == 1, -1, 1)
        flat = lambda a: np.ravel_multi_index(a.T, self.shape)
        self.b_u, self.b_v, self.b_w = cp.asarray(flat(bu)), cp.asarray(flat(bv)), cp.asarray(flat(bw))
        self.s_u, self.s_v, self.s_w = (cp.asarray(s.astype(np.float32)) for s in (su, sv, sw))
        # соседняя внутренняя грань того же направления (для «снос»-выхода)
        in_u = bu.copy(); in_u[:, 2] -= su
        in_v = bv.copy(); in_v[:, 1] -= sv
        self.in_u = cp.asarray(flat(in_u))
        self.in_v = cp.asarray(flat(in_v))
        self.area_u = self.dz * self.dx
        self.area_w = self.dx * self.dx
        self.b_np = dict(u=bu, v=bv, w=bw, su=su, sv=sv, sw=sw)
        # «жёсткие» границы с ветром (outflow = fixed): приток — фон, выход — фон × постоянный
        # множитель (площади притока и выхода разные из-за рельефа), вдоль — 0 по нормали
        nu_ = su * self.Ux
        nv_ = sv * self.Uy
        fin = -(np.sum(np.minimum(nu_, 0)) + np.sum(np.minimum(nv_, 0)))
        fout = np.sum(np.maximum(nu_, 0)) + np.sum(np.maximum(nv_, 0))
        sc = fin / fout if fout > 0 else 1.0
        self.fixed_scale = sc
        fu = np.where(nu_ < 0, self.Ux, np.where(nu_ > 0, self.Ux * sc, 0.0))
        fv = np.where(nv_ < 0, self.Uy, np.where(nv_ > 0, self.Uy * sc, 0.0))
        self.fixed_u = cp.asarray(fu.astype(np.float32))
        self.fixed_v = cp.asarray(fv.astype(np.float32))

    def set_ghosts_background(self):
        """Вся область: ореол и граничные грани от фонового ветра (приток) / стенки (штиль)."""
        cp = self.cp
        for f, t, val in ((self.u, self.tu, self.Ux), (self.v, self.tv, self.Uy)):
            f[...] = cp.where(t == 3, np.float32(val), f)
            f[...] = cp.where(t == 0, np.float32(0), f)
        self.w[...] = cp.where(self.tw == 1, self.w, np.float32(0))
        self.th[...] = cp.where(self.cell == 1, self.th, np.float32(0))
        self.apply_bc()

    def apply_bc(self):
        """Боковые границы всей области: приток — фон, выход — снос из соседней грани, масштаб
        выхода под приток (Σ потоков = 0). Штиль — стенки. На устройстве, без синхронизаций."""
        cp = self.cp
        if self.nest is not None:
            return
        if self.cond.wind <= 0:
            self.u.ravel()[self.b_u] = 0
            self.v.ravel()[self.b_v] = 0
            return
        u, v = self.u.ravel(), self.v.ravel()
        if self.prm.outflow == "fixed":
            u[self.b_u] = self.fixed_u
            v[self.b_v] = self.fixed_v
            return
        # внешняя нормальная компонента фона: s·U
        un_bg_u = self.s_u * np.float32(self.Ux)
        un_bg_v = self.s_v * np.float32(self.Uy)
        # приток (s·U < 0): фон; выход: снос изнутри, не внутрь
        out_u = cp.maximum(u[self.in_u] * self.s_u, 0)
        out_v = cp.maximum(v[self.in_v] * self.s_v, 0)
        inflow = (cp.sum(cp.minimum(un_bg_u, 0)) + cp.sum(cp.minimum(un_bg_v, 0)))    # < 0
        outs = cp.sum(cp.where(un_bg_u >= 0, out_u, 0)) + cp.sum(cp.where(un_bg_v >= 0, out_v, 0))
        scale = -inflow / cp.maximum(outs, 1e-6) if not self.p_dirichlet else np.float32(1.0)
        u[self.b_u] = cp.where(un_bg_u < 0, np.float32(self.Ux), self.s_u * out_u * scale)
        v[self.b_v] = cp.where(un_bg_v < 0, np.float32(self.Uy), self.s_v * out_v * scale)

    # ------------------------------------------------------------------ начальные поля
    def init_background(self):
        cp = self.cp
        self.u[...] = cp.where(self.tu == 1, np.float32(self.Ux), 0)
        self.v[...] = cp.where(self.tv == 1, np.float32(self.Uy), 0)
        self.w[...] = 0
        self.th[...] = 0
        self.p[...] = 0
        self.set_ghosts_background()
        self.project(cycles=30)
        self.p[...] = 0

    def init_from(self, st, with_p=True):
        """Тёплый старт от состояния st (dict u, v, w, th, p) на той же сетке, другие условия."""
        for a in ("u", "v", "w", "th"):
            getattr(self, a)[...] = st[a]
        if with_p:
            self.p[...] = st["p"]
        else:
            self.p[...] = 0
        if self.nest is None:
            self.set_ghosts_background()
        else:
            self.set_nest_bc()
        self.project(cycles=4)

    # ------------------------------------------------------------------ окно: границы от грубого
    def set_nest_bc(self, init=False):
        """Ореол и граничные грани окна — трилинейно из родителя; поправка потока на Σ = 0."""
        cp = self.cp
        P = self.nest["parent"]
        g, gp = self.g, P.g
        NZ, NY, NX = self.shape
        U, V, W, T = P.centers(full=True)          # на центрах клеток родителя (с ореолом), 0 в земле
        def sample(F, X, Y, Z):
            fi = (X - gp.x0) / gp.dx + 0.5            # индекс в массиве с ореолом (центр 1 = x0 + dx/2)
            fj = (Y - gp.y0) / gp.dx + 0.5
            fk = (Z - gp.z_bot) / gp.dz + 0.5
            return trilinear(F, fk, fj, fi)
        xc = g.x0 + (np.arange(NX) - 0.5) * g.dx
        yc = g.y0 + (np.arange(NY) - 0.5) * g.dx
        zc = g.z_bot + (np.arange(NZ) - 0.5) * g.dz
        xf = g.x0 + (np.arange(NX) - 1.0) * g.dx      # грань u[i] — между клетками i−1 и i
        yf = g.y0 + (np.arange(NY) - 1.0) * g.dx
        zf = g.z_bot + (np.arange(NZ) - 1.0) * g.dz
        Zc, Yc, Xu = np.meshgrid(zc, yc, xf, indexing="ij")
        uu = sample(U, Xu, Yc, Zc)
        Zc, Yv, Xc = np.meshgrid(zc, yf, xc, indexing="ij")
        vv = sample(V, Xc, Yv, Zc)
        Zw, Yc2, Xc2 = np.meshgrid(zf, yc, xc, indexing="ij")
        ww = sample(W, Xc2, Yc2, Zw)
        Zc, Yc, Xc = np.meshgrid(zc, yc, xc, indexing="ij")
        tt = sample(T, Xc, Yc, Zc)
        fix = lambda t: (t == 2) | (t == 3)
        tu, tv, tw = self.tu_np, self.tv_np, self.tw_np
        uu = np.where(tu == 0, 0, uu); vv = np.where(tv == 0, 0, vv); ww = np.where(tw == 0, 0, ww)
        # поправка: Σ по граничным граням (внешняя нормаль) = 0
        b = self.b_np
        fu = uu[tuple(b["u"].T)] * b["su"]
        fv = vv[tuple(b["v"].T)] * b["sv"]
        fw = ww[tuple(b["w"].T)] * b["sw"]
        A_side, A_top = g.dx * g.dz, g.dx * g.dx
        net = A_side * (fu.sum() + fv.sum()) + A_top * fw.sum()
        area = A_side * (len(fu) + len(fv)) + A_top * len(fw)
        corr = net / area
        uu[tuple(b["u"].T)] -= corr * b["su"]
        vv[tuple(b["v"].T)] -= corr * b["sv"]
        ww[tuple(b["w"].T)] -= corr * b["sw"]
        self.nest_corr = corr
        f32 = lambda a: cp.asarray(a, np.float32)
        if init:
            self.u[...] = f32(np.where(tu == 0, 0, uu))
            self.v[...] = f32(np.where(tv == 0, 0, vv))
            self.w[...] = f32(np.where(tw == 0, 0, ww))
            self.th[...] = f32(np.where(self.cell_np == 0, 0, tt))
        else:
            self.u[...] = cp.where(cp.asarray(fix(tu)), f32(uu), self.u)
            self.v[...] = cp.where(cp.asarray(fix(tv)), f32(vv), self.v)
            self.w[...] = cp.where(cp.asarray(fix(tw)), f32(ww), self.w)
            self.th[...] = cp.where(self.cell == 2, f32(tt), self.th)
        self.bg_nest = (float(P.Ux), float(P.Uy))

    def init_nest(self):
        self.set_nest_bc(init=True)
        self.p[...] = 0
        self.project(cycles=30)
        self.p[...] = 0

    # ------------------------------------------------------------------ проекция
    def divergence(self):
        """∇·u в клетках (nz, ny, nx) без ореола."""
        u, v, w = self.u, self.v, self.w
        dx, dz = self.dx, self.dz
        du = (u[1:-1, 1:-1, 2:] - u[1:-1, 1:-1, 1:-1]) / dx
        dv = (v[1:-1, 2:, 1:-1] - v[1:-1, 1:-1, 1:-1]) / dx
        dw = (w[2:, 1:-1, 1:-1] - w[1:-1, 1:-1, 1:-1]) / dz
        return (du + dv + dw) * self.fluid[1:-1, 1:-1, 1:-1]

    def project(self, cycles=1, update_p=True):
        cp = self.cp
        f = self.fluid[1:-1, 1:-1, 1:-1]
        rhs = self.divergence()
        if not self.p_dirichlet:
            rhs -= cp.sum(rhs) / self.n_fluid * f
        phi = self.phi
        phi[...] = 0
        for _ in range(cycles):
            phi = self.mg.vcycle(0, phi, rhs)
        if not self.p_dirichlet:
            phi -= cp.sum(phi * f) / self.n_fluid * f
        P = cp.zeros(self.shape, np.float32)
        P[1:-1, 1:-1, 1:-1] = phi
        dx, dz = self.dx, self.dz
        self.u[:, :, 1:] -= self.Kx[:, :, 1:] * (P[:, :, 1:] - P[:, :, :-1]) / dx
        self.v[:, 1:, :] -= self.Ky[:, 1:, :] * (P[:, 1:, :] - P[:, :-1, :]) / dx
        self.w[1:] -= self.Kz[1:] * (P[1:] - P[:-1]) / dz
        if update_p:
            self.p += P

    # ------------------------------------------------------------------ итерация Пикара
    def build(self):
        prm, k = self.prm, self.k
        NZ, NY, NX = self.shape
        n = NZ * NY * NX
        grid = ((n + 255) // 256,)
        f = np.float32
        for comp, (tf, C, b, sp, U) in enumerate(((self.tu, self.Cu, self.bu, self.sp_u, self.Ux),
                                                  (self.tv, self.Cv, self.bv, self.sp_u, self.Uy),
                                                  (self.tw, self.Cw, self.bw, self.sp_w, 0.0))):
            args = (np.int32(comp), self.u, self.v, self.w, tf, self.tu, self.tv, self.tw, self.cell,
                    self.p, self.th, sp, self.cplz, C, b, np.int32(NZ), np.int32(NY), np.int32(NX),
                    f(self.dx), f(self.dz), self.nuf, f(1.0 / prm.dtau_u), f(U), f(self.cd), self.pres_on)
            k["build_mom"](grid, (256,), args)

    def build_heat(self):
        prm = self.prm
        NZ, NY, NX = self.shape
        n = NZ * NY * NX
        f = np.float32
        self.k["build_heat"](((n + 255) // 256,), (256,),
                             (self.u, self.v, self.w, self.cell, self.th, self.Q, self.spc, self.gam, self.Ct,
                              self.bt, np.int32(NZ), np.int32(NY), np.int32(NX), f(self.dx), f(self.dz),
                              self.nuf, f(1.0 / prm.dtau_th), f(1.0 / prm.tau_cool)))

    def outer_step(self):
        self.apply_bc()
        self.build()
        for _ in range(self.prm.mom_sweeps):
            self.lines.sweep(self.Cu, self.u, self.bu)
            self.lines.sweep(self.Cv, self.v, self.bv)
            self.lines.sweep(self.Cw, self.w, self.bw)
        self.project(cycles=1)
        self.build_heat()
        for _ in range(self.prm.heat_sweeps):
            self.lines.sweep(self.Ct, self.th, self.bt)

    def capture(self):
        cp = self.cp
        self.stream = cp.cuda.Stream(non_blocking=True)
        self.stream.use()
        self.outer_step()
        self.outer += 1
        self.stream.synchronize()
        self._pool = cp.cuda.MemoryPool()
        old = cp.get_default_memory_pool()
        cp.cuda.set_allocator(self._pool.malloc)
        try:
            self.stream.begin_capture()
            self.outer_step()
            self.graph = self.stream.end_capture()
        finally:
            cp.cuda.set_allocator(old.malloc)

    def launch(self, n):
        for _ in range(n):
            if self.graph is not None:
                self.graph.launch(self.stream)
            else:
                self.outer_step()
            self.outer += 1

    def residuals(self):
        """Невязка установившихся уравнений в текущем состоянии (псевдочлены сокращаются, т. к.
        строим шаблоны от текущего же состояния): max и СКО по неизвестным, м/с² и К/с; ∇·u."""
        cp = self.cp
        self.apply_bc()
        self.build()
        out = {}
        for name, C, x, b, m in (("u", self.Cu, self.u, self.bu, self.mu_u), ("v", self.Cv, self.v, self.bv, self.mu_v),
                                 ("w", self.Cw, self.w, self.bw, self.mu_w)):
            self.lines.resid(C, x, b, self.rr)
            r = cp.abs(self.rr) * m
            out[name] = (r.max(), cp.sqrt(cp.sum(r * r) / cp.sum(m)))
        self.build_heat()
        self.lines.resid(self.Ct, self.th, self.bt, self.rr)
        r = cp.abs(self.rr) * self.fluid
        out["th"] = (r.max(), cp.sqrt(cp.sum(r * r) / self.n_fluid))
        d = cp.abs(self.divergence())
        out["div"] = (d.max(), cp.sqrt(cp.sum(d * d) / self.n_fluid))
        vals = {k: (float(a), float(b)) for k, (a, b) in out.items()}
        mom_max = max(vals["u"][0], vals["v"][0], vals["w"][0])
        mom_rms = math.sqrt((vals["u"][1] ** 2 + vals["v"][1] ** 2 + vals["w"][1] ** 2) / 3)
        return dict(mom_max=mom_max, mom_rms=mom_rms, th_max=vals["th"][0], th_rms=vals["th"][1],
                    div_max=vals["div"][0], div_rms=vals["div"][1])

    def solve(self, tol_mom=1e-5, tol_th=1e-5, tol_div=1e-5, max_outer=1500, check_every=10,
              verbose=False, graph=True, rms=True, cb=None):
        """До невязки < допуска. rms=True: критерий по СКО (max — в историю)."""
        cp = self.cp
        cp.cuda.Device().synchronize()
        t0 = time.perf_counter()
        self.t_check = 0.0
        if graph and self.graph is None:
            self.capture()
        status = "max"
        hist = []
        while self.outer < max_outer:
            self.launch(check_every)
            cp.cuda.Device().synchronize()
            tc = time.perf_counter()
            r = self.residuals()
            self.t_check += time.perf_counter() - tc
            r["it"] = self.outer
            r["t"] = time.perf_counter() - t0 - self.t_check
            hist.append(r)
            if cb is not None:
                tc = time.perf_counter()
                cb(self, r)
                self.t_check += time.perf_counter() - tc
            if verbose:
                print(f"  it {self.outer:5d} mom {r['mom_rms']:.2e}/{r['mom_max']:.2e}  th {r['th_rms']:.2e}/"
                      f"{r['th_max']:.2e}  div {r['div_rms']:.2e}/{r['div_max']:.2e}", flush=True)
            if not all(math.isfinite(v) for v in r.values()) or r["mom_max"] > 1.0:
                status = "diverged"
                break
            a, b_, c = (r["mom_rms"], r["th_rms"], r["div_rms"]) if rms else (r["mom_max"], r["th_max"], r["div_max"])
            if a < tol_mom and b_ < tol_th and c < tol_div:
                status = "ok"
                break
        cp.cuda.Device().synchronize()
        self.wall = time.perf_counter() - t0
        self.hist = hist
        self.status = status
        return status

    # ------------------------------------------------------------------ выход
    def centers(self, full=False):
        """u, v, w, θ′ в центрах клеток (numpy float32). full — с ореолом; иначе (nz, ny, nx), NaN в земле."""
        cp = self.cp
        u, v, w, th = self.u, self.v, self.w, self.th
        uc = cp.zeros(self.shape, np.float32); vc = cp.zeros_like(uc); wc = cp.zeros_like(uc)
        uc[:, :, :-1] = 0.5 * (u[:, :, :-1] + u[:, :, 1:])
        vc[:, :-1, :] = 0.5 * (v[:, :-1, :] + v[:, 1:, :])
        wc[:-1] = 0.5 * (w[:-1] + w[1:])
        m = (self.cell != 0).astype(np.float32)
        out = [a.get() for a in (uc * m, vc * m, wc * m, th * m)]
        if full:
            return out
        s = ~self.fluid_np[1:-1, 1:-1, 1:-1]
        res = []
        for a in out:
            a = a[1:-1, 1:-1, 1:-1].copy()
            a[s] = np.nan
            res.append(a)
        return res

    def heat_budget(self):
        """Баланс θ′ (К·м³/с): нагрев, выхолаживание, губка, −w·dθ̄/dz, вынос через границы."""
        cp = self.cp
        V = self.dx * self.dx * self.dz
        f = self.fluid
        th = self.th * f
        q_in = float(cp.sum(self.Q * f, dtype=np.float64)) * V
        cool = float(cp.sum(th, dtype=np.float64)) * V / self.prm.tau_cool
        spg = float(cp.sum(th * self.spc, dtype=np.float64)) * V
        wc = 0.5 * (self.w[:-1] + self.w[1:])
        bg = -float(cp.sum(self.gam[:-1, None, None] * wc * f[:-1], dtype=np.float64)) * V
        # адвективный поток θ′ через граничные грани (наружу)
        out = 0.0
        for fld, b, s, area, sh in ((self.u, self.b_u, self.s_u, self.dx * self.dz, 1),
                                    (self.v, self.b_v, self.s_v, self.dx * self.dz, self.NX),
                                    (self.w, self.b_w, self.s_w, self.dx * self.dx, self.NX * self.NY)):
            if len(b) == 0:
                continue
            un = fld.ravel()[b] * s                       # наружу
            inner = cp.where(s < 0, b, b - sh)            # клетка внутри: s<0 → idx, s>0 → idx − сдвиг
            outer = cp.where(s < 0, b - sh, b)
            thb = cp.where(un > 0, self.th.ravel()[inner], self.th.ravel()[outer])
            out += float(cp.sum(un * thb, dtype=np.float64)) * area
        # диффузия θ′ в ореол (боковые границы и потолок; θ′ ореола — фон 0 или родитель)
        cell = self.cell_np
        T = self.th.get()
        K = self.nu_np
        dif = 0.0
        for ax, h, A in ((2, self.dx, self.dx * self.dz), (1, self.dx, self.dx * self.dz), (0, self.dz, self.dx * self.dx)):
            for sh in (1, -1):
                cn = np.roll(cell, sh, axis=ax)
                Tn = np.roll(T, sh, axis=ax)
                Kn = np.roll(K, sh, axis=ax)
                m = (cell == 1) & (cn == 2)
                dif += float(np.sum((0.5 * (K + Kn) * (T - Tn) / h)[m])) * A
        out += dif
        res = q_in + bg - cool - spg - out
        return dict(q_in=q_in, bg=bg, cool=cool, sponge=spg, outflow=out, diff_out=dif, residual=res,
                    rel=res / q_in if q_in > 0 else None)

    def mem_mb(self):
        cp = self.cp
        tot = cp.get_default_memory_pool().total_bytes()
        if getattr(self, "_pool", None) is not None:
            tot += self._pool.total_bytes()
        return tot / 2 ** 20


def gauss2d(a, sigma):
    """Гауссово сглаживание (σ в клетках), края — отражение."""
    if sigma <= 0.3:
        return a.copy()
    r = int(math.ceil(3 * sigma))
    x = np.arange(-r, r + 1)
    k = np.exp(-0.5 * (x / sigma) ** 2)
    k /= k.sum()
    p = np.pad(a, r, mode="reflect")
    p = np.apply_along_axis(lambda v: np.convolve(v, k, mode="valid"), 1, p)
    p = np.apply_along_axis(lambda v: np.convolve(v, k, mode="valid"), 0, p)
    return p


def trilinear(F, fk, fj, fi):
    """Трилинейная выборка F (NZ, NY, NX) по дробным индексам (зажим к краю)."""
    NZ, NY, NX = F.shape
    fk = np.clip(fk, 0, NZ - 1.0001); fj = np.clip(fj, 0, NY - 1.0001); fi = np.clip(fi, 0, NX - 1.0001)
    k0 = fk.astype(int); j0 = fj.astype(int); i0 = fi.astype(int)
    a = fi - i0; b = fj - j0; c = fk - k0
    out = 0
    for dk in (0, 1):
        for dj in (0, 1):
            for di in (0, 1):
                wgt = (c if dk else 1 - c) * (b if dj else 1 - b) * (a if di else 1 - a)
                out = out + wgt * F[k0 + dk, j0 + dj, i0 + di]
    return out
