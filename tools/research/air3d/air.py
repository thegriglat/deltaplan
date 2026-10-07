"""Эталон масштаба 1 (AM-01): установившийся 3D-Буссинеск Пикаром на декартовой сетке с маской.

Спецификация дискретизации — `reference.md` (этот файл — её исполнение; при расхождении прав
документ, а код исправить). Прикидка, от которой всё пошло, — `solver.py` (оставлен как был, для
воспроизведения чисел `summary.md`).

Уравнения (установившиеся; u — скорость, p — кинематическое давление-возмущение, θ′ — отклонение
потенциальной температуры от фона θ̄(z)):

  (u·∇)u = −∇p + ∇·(K_m ∇u) − [земля] C_d |u_h| u_h / Δz + ẑ g θ′/θ0 − s(x)(u − U_b)
  ∇·u = 0
  ∇·(u θ′) + w dθ̄/dz = ∇·(K_θ ∇θ′) + Q − θ′_d/τ − s_θ(x) (θ′ − θ_b),   K_θ = K_m/Pr_t
  ∇·(u θ′_d)         = ∇·(K_θ ∇θ′_d) + Q − θ′_d/τ − s_θ(x) (θ′_d − θ_b,d)
  (θ′_d — диабатическая часть θ′ от нагрева Q; выхолаживание τ — только её; θ′ − θ′_d — адиабатическая)

Отличия от прикидки (все — ради физики, не подгонки):
  * вязкость — на полную скорость u (не на отклонение от фона), турбулентное напряжение у земли —
    только законом сопротивления (стенка не даёт вязкого потока, кроме нормальной компоненты = 0);
    логарифмический слой с K = κ u* z и сопротивлением C_d(Δz/2) — равновесный;
  * K(z) — замыкание Троена–Марта / Холтслага–Бовилля (u*, w*, L, h) + фон свободной атмосферы;
    K на гранях контрольного объёма — среднее соседних клеток (не одно на весь шаблон);
  * фоновый ветер — профиль (степенной, как WindModel игры: U(z) = U10·min((z/10)^0,14, 1,8));
  * фон θ̄(z), z_i и поток тепла — из погоды игры (`weather.py`);
  * перенос — противопоточный 1-го порядка неявно + отложенная поправка до 2-го порядка
    (MUSCL с ограничителем ван Лира) — опция `adv2`;
  * счёт в float32 или float64 (эталон для тестов GPU — float64).
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field, replace

import numpy as np

import wind_prof as WP

G = 9.81
THETA0 = 300.0
RHO_CP = 1.2 * 1005.0
KAPPA = 0.4

_SRC = r'''
#define IDX(k,j,i) (((long)(k) * NY + (j)) * NX + (i))

// ------------------------------------------------ прогонка по линии (Томас), зебра по чётности
// Шаблон C[7][N]: 0 центр, 1 −x, 2 +x, 3 −y, 4 +y, 5 −z, 6 +z. Уравнение Σ C·x = b.
extern "C" __global__ void line_thomas(const real* C, real* x, const real* b, real* cp_, real* dp_,
                                       int NZ, int NY, int NX, int dir, int parity) {
    long N = (long)NZ * NY * NX;
    int t = blockDim.x * blockIdx.x + threadIdx.x;
    int n, a1, a2;
    long stride, base;
    if (dir == 0) { n = NX; stride = 1; a1 = t % NY; a2 = t / NY; if (a2 >= NZ) return; base = IDX(a2, a1, 0); }
    else if (dir == 1) { n = NY; stride = NX; a1 = t % NX; a2 = t / NX; if (a2 >= NZ) return; base = IDX(a2, 0, a1); }
    else { n = NZ; stride = (long)NX * NY; a1 = t % NX; a2 = t / NX; if (a2 >= NY) return; base = IDX(0, a2, a1); }
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
            if (c != (real)0) { long q = idx + off[o]; if (q >= 0 && q < N) r -= c * x[q]; }
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
extern "C" __global__ void resid7(const real* C, const real* x, const real* b, real* r, int NZ, int NY, int NX) {
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

// наклон по двум разностям a (против потока) и b (по потоку); LIM задаётся при компиляции:
// 0 — линейная противопоточная 2-го порядка (наклон = a), 1 — ван Лир 2ab/(a+b) при ab > 0,
// 2 — ван Альбада (гладкий): a·(b² + ε) + b·(a² + ε) / (a² + b² + 2ε) при ab > 0
__device__ inline real vleer(real a, real b) {
#if LIM == 0
    return a;
#elif LIM == 1
    real ab = a * b;
    return ab > (real)0 ? (real)2 * ab / (a + b) : (real)0;
#else
    real ab = a * b;
    const real eps = (real)1e-12;
    return ab > (real)0 ? (a * (b * b + eps) + b * (a * a + eps)) / (a * a + b * b + (real)2 * eps) : (real)0;
#endif
}

// ------------------------------------------------ шаблон импульса (comp: 0 — u, 1 — v, 2 — w)
extern "C" __global__ void build_mom(int comp, const real* u, const real* v, const real* w,
        const unsigned char* tu, const unsigned char* tv, const unsigned char* tw,
        const real* p, const real* th, const real* sp, const real* ubg, const real* cplz,
        const real* nu, const real* nuh, const real* corr, real* C, real* b,
        int NZ, int NY, int NX, real dx, real dz, real inv_dtau, const real* cdp) {
    long N = (long)NZ * NY * NX;
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= N) return;
    int k = idx / ((long)NX * NY);
    const real* f = comp == 0 ? u : (comp == 1 ? v : w);
    const unsigned char* tt = comp == 0 ? tu : (comp == 1 ? tv : tw);
    if (tt[idx] != 1) {
        C[idx] = 1; for (int o = 1; o < 7; ++o) C[o * N + idx] = 0;
        b[idx] = f[idx];
        return;
    }
    const long st[3] = {1, NX, (long)NX * NY};
    const real h[3] = {dx, dx, dz};
    const long sc = st[comp];
    const long c0 = idx - sc, c1 = idx;            // клетки по сторонам грани
    real a3[3];
    a3[comp] = f[idx];
    for (int d = 0; d < 3; ++d) {
        if (d == comp) continue;
        const real* g = d == 0 ? u : (d == 1 ? v : w);
        a3[d] = (real)0.25 * (g[c0] + g[c0 + st[d]] + g[c1] + g[c1 + st[d]]);
    }
    real diag = inv_dtau + sp[idx];
    real rhs = f[idx] * inv_dtau + sp[idx] * ubg[idx] - corr[idx];
    real cc[7] = {0, 0, 0, 0, 0, 0, 0};
    for (int d = 0; d < 3; ++d) {
        real ih = (real)1 / h[d];
        real a = a3[d];
        for (int s = 0; s < 2; ++s) {
            int o = 1 + 2 * d + s;
            long q = idx + (s ? st[d] : -st[d]);
            real K;
            const real* KK = d == 2 ? nu : nuh;      // по вертикали — K, по горизонтали — K_h
            if (d == comp) K = KK[s ? c1 : c0];
            else {
                long sh = s ? st[d] : -st[d];
                K = (real)0.25 * (KK[c0] + KK[c1] + KK[c0 + sh] + KK[c1 + sh]);
            }
            real vis = K * ih * ih;
            bool up = (s == 0 && a > 0) || (s == 1 && a < 0);
            real aa = a > 0 ? a : -a;
            if (tt[q] == 0) {
                if (d == comp) {                  // нормальная компонента у стенки: значение 0
                    diag += vis;
                    if (up) diag += aa * ih;
                }
                // касательная у стенки: вязкого потока нет (у земли — закон сопротивления ниже),
                // перенос — нулевой градиент
            } else {
                diag += vis; real cn = -vis;
                if (up) { diag += aa * ih; cn -= aa * ih; }
                cc[o] = cn;
            }
        }
    }
    rhs -= (p[c1] - p[c0]) / h[comp];
    if (comp < 2) {
        if (tt[idx - st[2]] == 0) {             // первая грань над землёй: сопротивление
            real sp2 = a3[0] * a3[0] + a3[1] * a3[1];
            diag += cdp[idx % ((long)NX * NY)] * sqrt(sp2) / dz;   // C_d столбца (огибающая: low_z0 / slip)
        }
    } else {
        rhs += (real)(9.81 / 300.0) * (real)0.5 * (th[c0] + th[c1]);
        diag += cplz[k];
        rhs += cplz[k] * w[idx];
    }
    C[idx] = diag;
    for (int o = 1; o < 7; ++o) C[o * N + idx] = cc[o];
    b[idx] = rhs;
}

// ------------------------------------------------ поправка переноса до 2-го порядка (импульс)
// corr = a·(D_2 f − D_1 f) по трём осям, D_1 — против потока 1-го порядка, D_2 — MUSCL/ван Лир.
extern "C" __global__ void adv2_mom(int comp, const real* u, const real* v, const real* w,
        const unsigned char* tu, const unsigned char* tv, const unsigned char* tw, real* corr,
        int NZ, int NY, int NX, real dx, real dz) {
    long N = (long)NZ * NY * NX;
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= N) return;
    const real* f = comp == 0 ? u : (comp == 1 ? v : w);
    const unsigned char* tt = comp == 0 ? tu : (comp == 1 ? tv : tw);
    if (tt[idx] != 1) { corr[idx] = 0; return; }
    int i = idx % NX, j = (idx / NX) % NY, k = idx / ((long)NX * NY);
    const int pos[3] = {i, j, k};
    const int len[3] = {NX, NY, NZ};
    const long st[3] = {1, NX, (long)NX * NY};
    const real h[3] = {dx, dx, dz};
    const long sc = st[comp];
    const long c0 = idx - sc, c1 = idx;
    real out = 0;
    for (int d = 0; d < 3; ++d) {
        real a;
        if (d == comp) a = f[idx];
        else {
            const real* g = d == 0 ? u : (d == 1 ? v : w);
            a = (real)0.25 * (g[c0] + g[c0 + st[d]] + g[c1] + g[c1 + st[d]]);
        }
        if (a == (real)0) continue;
        int sgn = a > 0 ? 1 : -1;
        // нужны f[−2s], f[−s], f[+s] вдоль оси против потока (s = sgn)
        int pm2 = pos[d] - 2 * sgn, pp1 = pos[d] + sgn;
        if (pm2 < 0 || pm2 >= len[d] || pp1 < 0 || pp1 >= len[d]) continue;
        long qm1 = idx - sgn * st[d], qm2 = idx - 2 * sgn * st[d], qp1 = idx + sgn * st[d];
        if (tt[qm1] == 0 || tt[qm2] == 0 || tt[qp1] == 0) continue;
        real f0 = f[idx], fm1 = f[qm1], fm2 = f[qm2], fp1 = f[qp1];
        // в координате вдоль потока: D_2 − D_1 = 0,5·[vl(f0−fm1, fp1−f0) − vl(fm1−fm2, f0−fm1)]/h
        real dd = (real)0.5 * (vleer(f0 - fm1, fp1 - f0) - vleer(fm1 - fm2, f0 - fm1)) / h[d];
        out += (a > 0 ? a : -a) * dd;
    }
    corr[idx] = out;
}

// ------------------------------------------------ шаблон тепла
extern "C" __global__ void build_heat(const real* u, const real* v, const real* w, const unsigned char* cell,
        const real* th, const real* Q, const real* spc, const real* thbg, const real* gam, const real* kf, const real* kh,
        const real* corr, real* C, real* b, int NZ, int NY, int NX, real dx, real dz, real inv_dtau, real inv_tau,
        real inv_prt) {
    long N = (long)NZ * NY * NX;
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= N) return;
    int k = idx / ((long)NX * NY);
    if (cell[idx] != 1) {
        C[idx] = 1; for (int o = 1; o < 7; ++o) C[o * N + idx] = 0;
        b[idx] = th[idx];
        return;
    }
    const long st[3] = {1, NX, (long)NX * NY};
    const real fm[3] = {u[idx], v[idx], w[idx]};
    const real fp[3] = {u[idx + st[0]], v[idx + st[1]], w[idx + st[2]]};
    const real h[3] = {dx, dx, dz};
    real diag = inv_dtau + inv_tau + spc[idx];
    real rhs = th[idx] * inv_dtau + Q[idx] + spc[idx] * thbg[idx] - gam[k] * (real)0.5 * (w[idx] + w[idx + st[2]]) - corr[idx];
    real cc[7] = {0, 0, 0, 0, 0, 0, 0};
    for (int d = 0; d < 3; ++d) {
        real ih = (real)1 / h[d];
        for (int s = 0; s < 2; ++s) {
            real vo = s ? fp[d] : -fm[d];       // наружу
            long q = idx + (s ? st[d] : -st[d]);
            real cn = 0;
            if (vo > 0) diag += vo * ih; else cn += vo * ih;
            const real* KK = d == 2 ? kf : kh;
            if (cell[q] != 0) { real dif = (real)0.5 * (KK[idx] + KK[q]) * ih * ih * inv_prt; diag += dif; cn -= dif; }
            cc[1 + 2 * d + s] = cn;
        }
    }
    C[idx] = diag;
    for (int o = 1; o < 7; ++o) C[o * N + idx] = cc[o];
    b[idx] = rhs;
}

// ------------------------------------------------ поправка переноса до 2-го порядка (тепло, потоковая форма)
extern "C" __global__ void adv2_heat(const real* u, const real* v, const real* w, const unsigned char* cell,
        const real* th, real* corr, int NZ, int NY, int NX, real dx, real dz) {
    long N = (long)NZ * NY * NX;
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= N) return;
    if (cell[idx] != 1) { corr[idx] = 0; return; }
    int i = idx % NX, j = (idx / NX) % NY, k = idx / ((long)NX * NY);
    const int pos[3] = {i, j, k};
    const int len[3] = {NX, NY, NZ};
    const long st[3] = {1, NX, (long)NX * NY};
    const real h[3] = {dx, dx, dz};
    const real* vel[3] = {u, v, w};
    real out = 0;
    for (int d = 0; d < 3; ++d) {
        for (int s = 0; s < 2; ++s) {
            // грань между L и R (R = L + 1 вдоль d); наша клетка — R при s = 0, L при s = 1
            long L = s ? idx : idx - st[d];
            long R = L + st[d];
            int pL = s ? pos[d] : pos[d] - 1;
            real vf = vel[d][R];                       // скорость на грани (индекс грани = R)
            if (vf == (real)0) continue;
            long U1, U2, D1; int pU2;
            if (vf > 0) { U1 = L; U2 = L - st[d]; D1 = R; pU2 = pL - 1; }
            else        { U1 = R; U2 = R + st[d]; D1 = L; pU2 = pL + 2; }
            if (pU2 < 0 || pU2 >= len[d]) continue;
            if (cell[U1] == 0 || cell[U2] == 0 || cell[D1] == 0) continue;
            real fho = th[U1] + (real)0.5 * vleer(th[U1] - th[U2], th[D1] - th[U1]);
            real fc = vf * (fho - th[U1]);            // поправка потока через грань (вдоль +d)
            out += (s ? fc : -fc) / h[d];
        }
    }
    corr[idx] = out;
}

// ------------------------------------------------ местная длина перемешивания (Прандтль–Блэкадар)
// K = max(K_фон, l²·|S|·F(Ri)), 1/l = 1/(κ z) + 1/λ; |S|² = 2 S_ij S_ij; Ri = N²/|S|²,
// N² = g/θ0 (dθ̄/dz + ∂θ′/∂z); F = 1/(1 + 5 Ri)² при Ri > 0, √(1 − 16 Ri) при Ri < 0.
// Новое K — с нижней релаксацией: nu = nu + relax·(K − nu). Градиенты — центральные по клеткам,
// сосед-земля → односторонняя разность (или 0, если с обеих сторон земля).
__device__ inline real cval(const real* f, long a, long b) { return (real)0.5 * (f[a] + f[b]); }

extern "C" __global__ void kloc(const real* u, const real* v, const real* w, const real* th,
        const unsigned char* cell, const real* gam, const real* hcp, const real* lamc, const real* kbg, real* nu,
        real* nuh, int NZ, int NY, int NX, real dx, real dz, real z_bot, real relax, real csdx2) {
    long N = (long)NZ * NY * NX;
    long idx = (long)blockDim.x * blockIdx.x + threadIdx.x;
    if (idx >= N) return;
    if (cell[idx] != 1) return;
    int i = idx % NX, j = (idx / NX) % NY, k = idx / ((long)NX * NY);
    const long st[3] = {1, NX, (long)NX * NY};
    const real h[3] = {dx, dx, dz};
    // скорости в центрах клеток
    real c[3];
    c[0] = cval(u, idx, idx + st[0]); c[1] = cval(v, idx, idx + st[1]); c[2] = cval(w, idx, idx + st[2]);
    real g[3][3];   // g[a][d] = ∂c_a/∂x_d
    const real* F[3] = {u, v, w};
    for (int a = 0; a < 3; ++a) {
        for (int d = 0; d < 3; ++d) {
            if (a == d) { g[a][d] = (F[a][idx + st[a]] - F[a][idx]) / h[d]; continue; }
            long qm = idx - st[d], qp = idx + st[d];
            bool okm = cell[qm] != 0, okp = cell[qp] != 0;
            real cm = okm ? cval(F[a], qm, qm + st[a]) : (real)0;
            real cpv = okp ? cval(F[a], qp, qp + st[a]) : (real)0;
            if (okm && okp) g[a][d] = (cpv - cm) / ((real)2 * h[d]);
            else if (okp) g[a][d] = (cpv - c[a]) / h[d];
            else if (okm) g[a][d] = (c[a] - cm) / h[d];
            else g[a][d] = 0;
        }
    }
    real S2 = (real)2 * (g[0][0] * g[0][0] + g[1][1] * g[1][1] + g[2][2] * g[2][2])
            + (g[0][1] + g[1][0]) * (g[0][1] + g[1][0]) + (g[0][2] + g[2][0]) * (g[0][2] + g[2][0])
            + (g[1][2] + g[2][1]) * (g[1][2] + g[2][1]);
    real dth;
    bool dm = cell[idx - st[2]] != 0, dp = cell[idx + st[2]] != 0;
    if (dm && dp) dth = (th[idx + st[2]] - th[idx - st[2]]) / ((real)2 * dz);
    else if (dp) dth = (th[idx + st[2]] - th[idx]) / dz;
    else if (dm) dth = (th[idx] - th[idx - st[2]]) / dz;
    else dth = 0;
    real N2 = (real)(9.81 / 300.0) * (gam[k] + dth);
    real S = sqrt(S2);
    real Ri = N2 / (S2 > (real)1e-12 ? S2 : (real)1e-12);
    real Fr = Ri > 0 ? (real)1 / (((real)1 + (real)5 * Ri) * ((real)1 + (real)5 * Ri)) : sqrt((real)1 - (real)16 * Ri);
    real z = z_bot + ((real)k - (real)0.5) * dz - hcp[(long)j * NX + i];
    if (z < (real)0.5 * dz) z = (real)0.5 * dz;
    real l = (real)1 / ((real)1 / ((real)0.4 * z) + (real)1 / lamc[(long)j * NX + i]);
    real K = l * l * S * Fr;
    real kb = kbg[idx];
    if (K < kb) K = kb;
    nu[idx] = nu[idx] + relax * (K - nu[idx]);
    // горизонтальная подсеточная диффузия (Смагоринский по горизонтальной деформации, как в мезомасштабных моделях)
    real D2 = (g[0][0] - g[1][1]) * (g[0][0] - g[1][1]) + (g[0][1] + g[1][0]) * (g[0][1] + g[1][0]);
    real Kh = csdx2 * sqrt(D2);
    if (Kh < K) Kh = K;
    nuh[idx] = nuh[idx] + relax * (Kh - nuh[idx]);
}
'''
_MODS = {}


def kernels(dtype, lim=0):
    """Ядра для float32 или float64 (эталон); lim — наклон поправки 2-го порядка (см. vleer)."""
    key = (np.dtype(dtype).name, lim)
    if key not in _MODS:
        import cupy as cp
        pre = ("typedef double real;\n" if key[0] == "float64" else "typedef float real;\n") + f"#define LIM {lim}\n"
        opts = () if key[0] == "float64" else ("--use_fast_math",)
        mod = cp.RawModule(code=pre + _SRC, options=opts)
        _MODS[key] = {n: mod.get_function(n) for n in
                      ("line_thomas", "resid7", "build_mom", "adv2_mom", "build_heat", "adv2_heat", "kloc")}
    return _MODS[key]


class Lines:
    """Зебра-прогонки 7-точечного шаблона на массиве (NZ, NY, NX)."""

    def __init__(self, shape, dtype):
        import cupy as cp
        self.shape = shape
        self.dt = np.dtype(dtype)
        self.cp_ = cp.zeros(shape, self.dt)
        self.dp_ = cp.zeros(shape, self.dt)
        self.k = kernels(self.dt)

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
    """Многосеточный V-цикл для ∇·(K∇φ) = f на клетках (nz, ny, nx) без ореола.
    cx (nz, ny, nx+1), cy (nz, ny+1, nx), cz (nz+1, ny, nx) — проводимости граней K/h² (0 — закрыто).
    Огрубление только по x, y (×2), z не огрубляется; сглаживание — зебра-прогонки по вертикали."""

    def __init__(self, cx, cy, cz, active, dtype):
        import cupy as cp
        self.dt = np.dtype(dtype)
        self.levels = []
        while True:
            nz, ny, nx = active.shape
            C = self._stencil(cx, cy, cz, active)
            self.levels.append(dict(C=cp.asarray(C, self.dt), act=cp.asarray(active, self.dt), shape=active.shape,
                                    lines=Lines(active.shape, self.dt), r=cp.zeros(active.shape, self.dt),
                                    C_np=C, act_np=active.copy()))
            if nx % 2 or ny % 2 or nx < 6 or ny < 6:
                break
            # проводимость грубой грани: среднее двух тонких граней (по поперечной оси) / 4 (h → 2h)
            cx = (cx[:, 0::2, 0::2] + cx[:, 1::2, 0::2]) / 8.0
            cy = (cy[:, 0::2, 0::2] + cy[:, 0::2, 1::2]) / 8.0
            cz = (cz[:, 0::2, 0::2] + cz[:, 0::2, 1::2] + cz[:, 1::2, 0::2] + cz[:, 1::2, 1::2]) / 4.0
            active = active.reshape(nz, ny // 2, 2, nx // 2, 2).any(axis=(2, 4))
            a = active
            cx = cx * np.concatenate([a[:, :, :1], a[:, :, 1:] & a[:, :, :-1], a[:, :, -1:]], axis=2)
            cy = cy * np.concatenate([a[:, :1], a[:, 1:] & a[:, :-1], a[:, -1:]], axis=1)
            cz = cz * np.concatenate([a[:1], a[1:] & a[:-1], a[-1:]], axis=0)

    @staticmethod
    def _stencil(cx, cy, cz, active):
        nz, ny, nx = active.shape
        C = np.zeros((7, nz, ny, nx), np.float64)
        C[1] = cx[:, :, :-1]
        C[2] = cx[:, :, 1:]
        C[3] = cy[:, :-1, :]
        C[4] = cy[:, 1:, :]
        C[5] = cz[:-1]
        C[6] = cz[1:]
        C[0] = -(C[1] + C[2] + C[3] + C[4] + C[5] + C[6])
        # грань на краю массива: сосед вне массива отсутствует (проводимость там уже 0 при жёстких
        # границах; если нет — остаётся в диагонали, т. е. Дирихле φ = 0 снаружи)
        C[1][:, :, 0] = 0; C[2][:, :, -1] = 0
        C[3][:, 0, :] = 0; C[4][:, -1, :] = 0
        C[5][0] = 0; C[6][-1] = 0
        dead = ~active | (C[0] == 0)
        C[:, dead] = 0
        C[0][dead] = 1.0
        return C

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
        x += cp.repeat(cp.repeat(ec, 2, axis=1), 2, axis=2) * L["act"]
        for _ in range(post):
            lines.sweep(C, x, f, dirs=(2,))
        return x


# ============================================================================== физика
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


def wind_profile(agl, prm):
    """Доля ветра на высоте над землёй: степенной профиль WindModel, нормирован на ветер на высоте:
    min((agl/z_sat)^α, 1), z_sat = 10·max_f^(1/α) — выше профиль постоянный (WindProfile, C2 v4)."""
    z_sat = 10.0 * prm.max_profile ** (1.0 / prm.alpha)
    return np.minimum((np.maximum(agl, prm.z0) / z_sat) ** prm.alpha, 1.0)


@dataclass
class Params:
    """Параметры модели. Числа — физические (источник в комментарии) или численные (помечены)."""
    tau_cool: float = 7200.0          # выхолаживание θ′ к фону (излучение, перемешивание с фоном), с
    z0: float = 0.1                   # шероховатость, м (луг/кустарник; лес не учтён)
    alpha: float = 0.24               # показатель профиля притока; по умолчанию α_N (нейтраль, atmosphere.json →
                                      # wind.shear_exponent_neutral, Б1); у случая игры — по устойчивости на час
                                      # (wind_prof.for_hour, real.case; C2 v4)
    max_profile: float | None = None  # ветер на высоте / U10 = (z_sat/10)^α; None — по правилу z_sat (wind_prof, C10 v3)
    f_cor: float = 1.13e-4            # параметр Кориолиса 51° с. ш., 1/с — только для высоты слоя h
    k_fa: float = 1.0                 # K свободной атмосферы (выше h), м²/с (0,1–1 — порядок в тропосфере)
    k_smooth_m: float = 1500.0        # сглаживание потока тепла для w* (площадь конвективной ячейки ~ z_i)
    zi_min: float = 300.0             # мин. толщина слоя перемешивания над прогретым склоном, м
    pr_t: float = 0.85                # турбулентное число Прандтля, K_θ = K/Pr_t на всех трёх осях (Kays 1994: 0,85).
                                      # Решение пользователя 30.09.2026 (варианты 1,0/0,74/0,95 —
                                      # docs/archive/plan/air-model-a1.md §1)
    heat_mode: str = "cbl"            # cbl — нагрев по толщине слоя перемешивания (нелокальный перенос), surface — в первую клетку
    # численные
    dtau_u: float | None = None       # псевдошаг импульса, с; None — dtau_per_m·Δx (по уровню клипмапа)
    dtau_per_m: float = 0.3           # 0,3 с/м: 400 м → 120 с, 100 м → 30 с, 50 м → 15 с (замер ref_study)
    dtau_th: float = 1200.0           # псевдошаг тепла, с
    couple: float = 1.0               # полунеявная плавучесть (1 — полностью, правка 2 прикидки)
    mom_sweeps: int = 2
    heat_sweeps: int = 4
    vcycles: int = 1                  # V-циклов проекции на итерацию
    sponge_top_m: float = 1000.0
    sponge_side_m: float = 2000.0
    sponge_rate: float = 1 / 300.0
    sponge_axes: str = "xy"           # "x" — квази-2D разрез (стенки по y без губок)
    heat_taper_m: float = 2000.0      # нагрев у края области гасится (граница «жёсткая»)
    adv2: bool = False                # поправка переноса до 2-го порядка (отложенная; см. reference.md → «Перенос»)
    limiter: int = 0                  # 0 — линейная 2-го порядка, 1 — ван Лир, 2 — ван Альбада
    closure: str = "hb"               # hb | const
    local_k: bool = True              # добавка длины перемешивания по местному сдвигу (Прандтль–Блэкадар)
    lam: float = 40.0                 # асимптотическая длина перемешивания λ, м (Блэкадар; HB93 — 30 м)
    lam_frac: float = 0.0158          # λ = max(lam, lam_frac·h) (0 — выкл.). Б1 (docs/archive/plan/air-model-b1.md, совместная
                                      # калибровка Askervein + Perdigão): общий λ ≈ 27 м, перевод (б) К2 — lam 40 м (пол),
                                      # λ/h = 27/1713 (h_нейтр); до Б1 — 0,25 (AM-09, один Askervein с α 0,17)
    k_relax: float = 0.1              # нижняя релаксация обновления K (численная). А2 (docs/archive/plan/air-model-a2.md): 0,5 → 0,1 —
                                      # гасит предельный цикл K(Ri) ↔ θ′ ↔ w у верха слоя перемешивания при λ/h 0,031;
                                      # неподвижная точка та же (подъём у старта ±0,01 м/с), итераций цепочки столько же
    cs_h: float = 0.25                # Смагоринский по горизонтали: K_h ≥ (c_s Δx)² |D_h| (WRF km_opt 4: 0,25); 0 — выкл.
                                      # AM-09: фиксирован, не подгоняется — мезомасштабная горизонтальная подсеточная
                                      # диффузия (Δx 50–400 м ≫ l), не LES (Лилли 0,17 — для Δx в инерционном интервале);
                                      # на Askervein 0 / 0,17 / 0,25 меняют разгон ≤ 0,01
    nest_sponge_cells: float = 4.0    # окно: зона релаксации к родителю у боковых граней, клеток
    nest_sponge_top_m: float = 1000.0 # окно: зона релаксации у потолка, м
    nu_const: float = 30.0
    omega_u: float = 1.0              # недорелаксирование скорости u ← u + ω(u* − u) после проекции (AP-1, P4); 1 — выкл.


@dataclass
class Case:
    """Условия: ветер (U10 — прогноз на 10 м, откуда дует), фон θ̄, z_i, поток тепла."""
    U10: float = 0.0
    wdir: float = 270.0
    gam: object = None                # функция z (м над морем) → dθ̄/dz, К/м; None — 3 К/км
    z_i: float | None = None          # верх слоя перемешивания, м над морем (None — нет конвекции)
    H: object = None                  # поток тепла (ny, nx), Вт/м² на горизонтальную площадь; None — 0
    label: str = ""


class Air:
    """Решатель. grid: объект с dx, nx, ny, dz, nz, z_bot, x0, y0; hc (ny, nx) — высоты рельефа."""

    def __init__(self, grid, hc, case: Case, prm: Params = Params(), nest=None, dtype=np.float32,
                 taper=True, cd_map=None):
        import cupy as cp
        self.cp = cp
        self.dt = np.dtype(dtype)
        self.g, self.case, self.prm, self.nest = grid, case, prm, nest
        nx, ny, nz = grid.nx, grid.ny, grid.nz
        self.NX, self.NY, self.NZ = nx + 2, ny + 2, nz + 2
        NX, NY, NZ = self.NX, self.NY, self.NZ
        shape = (NZ, NY, NX)
        self.shape = shape
        dx, dz = grid.dx, grid.dz
        self.dx, self.dz = dx, dz
        if prm.max_profile is None:   # правило z_sat при α случая (как WindProfile / AirCase.max_profile_used)
            prm = replace(prm, max_profile=WP.max_profile(prm.alpha, case.U10, prm.z0, prm.f_cor))
            self.prm = prm
        self.dtau_u = prm.dtau_u if prm.dtau_u is not None else prm.dtau_per_m * dx
        self.hc = np.asarray(hc, float)
        hp = np.pad(self.hc, 1, mode="edge")
        self.hp = hp
        zc = grid.z_bot + (np.arange(NZ) - 0.5) * dz
        self.zc = zc
        # --- клетки: 0 — земля, 1 — воздух, 2 — ореол (значение задано)
        solid = zc[:, None, None] < hp[None]
        solid[0] = True
        cell = np.where(solid, 0, 1).astype(np.uint8)
        for sl in ((slice(None), 0, slice(None)), (slice(None), -1, slice(None)),
                   (slice(None), slice(None), 0), (slice(None), slice(None), -1), (-1,)):
            cell[sl] = np.where(solid[sl], 0, 2)
        self.cell_np = cell
        self.fluid_np = cell == 1

        def ftype(c0, c1):
            t = np.full(c0.shape, 3, np.uint8)
            t[(c0 == 0) | (c1 == 0)] = 0
            t[(c0 == 1) & (c1 == 1)] = 1
            t[((c0 == 1) & (c1 == 2)) | ((c0 == 2) & (c1 == 1))] = 2
            return t
        tu = np.full(shape, 3, np.uint8); tu[:, :, 1:] = ftype(cell[:, :, :-1], cell[:, :, 1:])
        tv = np.full(shape, 3, np.uint8); tv[:, 1:, :] = ftype(cell[:, :-1, :], cell[:, 1:, :])
        tw = np.full(shape, 3, np.uint8); tw[1:] = ftype(cell[:-1], cell[1:]); tw[0] = 0
        self.tu_np, self.tv_np, self.tw_np = tu, tv, tw
        self.kb = np.argmax(self.fluid_np[:, 1:-1, 1:-1], axis=0)   # первая воздушная клетка столбца
        # --- фон: ветер
        U10 = case.U10
        ang = math.radians(case.wdir)
        self.U_a = U10 * prm.max_profile                         # ветер на высоте
        ex, ey = (-math.sin(ang), -math.cos(ang)) if U10 > 0 else (0.0, 0.0)
        self.ex, self.ey = ex, ey
        hu = np.zeros((NY, NX)); hu[:, 1:] = 0.5 * (hp[:, 1:] + hp[:, :-1]); hu[:, 0] = hp[:, 0]
        hv = np.zeros((NY, NX)); hv[1:, :] = 0.5 * (hp[1:, :] + hp[:-1, :]); hv[0, :] = hp[0, :]
        prof_u = wind_profile(zc[:, None, None] - hu[None], prm)
        prof_v = wind_profile(zc[:, None, None] - hv[None], prm)
        self.ubg_np = self.U_a * ex * prof_u * (tu != 0)
        self.vbg_np = self.U_a * ey * prof_v * (tv != 0)
        # --- фон: θ̄
        if case.gam is None:
            gam_c = np.full(NZ, 3.0e-3)
        else:
            gam_c = np.asarray(case.gam(zc), float)
        self.gam_np = gam_c
        # --- губки
        ztop = grid.z_bot + nz * dz
        ramp = lambda d, L: np.clip(1 - d / L, 0, 1) ** 2 * prm.sponge_rate
        spz = ramp(ztop - zc, prm.sponge_top_m)
        spz_w = ramp(ztop - (zc - 0.5 * dz), prm.sponge_top_m)
        xi = (np.arange(NX) - 0.5) * dx
        yj = (np.arange(NY) - 0.5) * dx
        Lx, Ly = nx * dx, ny * dx
        side = np.zeros((NY, NX)); sc_ = np.zeros((NY, NX))
        if nest is None and U10 > 0:
            L = prm.sponge_side_m
            rx0, rx1 = ramp(xi, L)[None, :] + 0 * yj[:, None], ramp(Lx - xi, L)[None, :] + 0 * yj[:, None]
            ry0, ry1 = ramp(yj, L)[:, None] + 0 * xi[None, :], ramp(Ly - yj, L)[:, None] + 0 * xi[None, :]
            if prm.sponge_axes == "x":
                ry0 = ry1 = np.zeros((NY, NX))
            side = np.maximum.reduce([rx0, rx1, ry0, ry1])
            if ex > 1e-9: sc_ = np.maximum(sc_, rx0)
            if ex < -1e-9: sc_ = np.maximum(sc_, rx1)
            if ey > 1e-9: sc_ = np.maximum(sc_, ry0)
            if ey < -1e-9: sc_ = np.maximum(sc_, ry1)
        if nest is not None:
            # окно: зона релаксации к полю родителя (Дэвис 1976) у боковых граней и у потолка
            spz = ramp(ztop - zc, prm.nest_sponge_top_m)
            spz_w = ramp(ztop - (zc - 0.5 * dz), prm.nest_sponge_top_m)
            Ls = prm.nest_sponge_cells * dx
            side = np.maximum.reduce([ramp(xi, Ls)[None, :] + 0 * yj[:, None], ramp(Lx - xi, Ls)[None, :] + 0 * yj[:, None],
                                      ramp(yj, Ls)[:, None] + 0 * xi[None, :], ramp(Ly - yj, Ls)[:, None] + 0 * xi[None, :]])
            sc_ = side
        sp_c = np.maximum(spz[:, None, None], side[None])
        sp_w = np.maximum(spz_w[:, None, None], side[None])
        spc = np.maximum(spz[:, None, None], sc_[None])
        self.sp_np, self.spw_np, self.spc_np = sp_c, sp_w, spc
        # --- нагрев (Вт/м² → К·м/с), у края области гасится
        H = np.zeros((ny, nx)) if case.H is None else np.asarray(case.H, float).copy()
        if nest is None and taper and np.any(H != 0):
            xe = (np.arange(nx) + 0.5) * dx; ye = (np.arange(ny) + 0.5) * dx
            exx = np.clip(np.minimum(xe, Lx - xe) / prm.heat_taper_m, 0, 1)
            eyy = np.clip(np.minimum(ye, Ly - ye) / prm.heat_taper_m, 0, 1)
            H = H * (np.sin(0.5 * np.pi * eyy)[:, None] * np.sin(0.5 * np.pi * exx)[None, :]) ** 2
        self.H = H
        Hk = H / RHO_CP
        self.Hk = Hk
        # --- турбулентная вязкость (нужна h для распределения нагрева)
        self.nu_np, self.closure_info = self._closure()
        Q = np.zeros(shape)
        jj, ii = np.indices((ny, nx))
        Q[self.kb, jj + 1, ii + 1] = Hk / dz
        if prm.heat_mode == "cbl" and np.any(Hk > 0):
            # нелокальный перенос (Холтслаг–Бовилль): поток H(z) = H0·(1 − z/h) — нагрев H0/h равномерно
            # по толщине слоя перемешивания столба; охлаждение (H < 0) — у земли
            zagl = self.zc[:, None, None] - self.hc[None]
            fl = self.fluid_np[:, 1:-1, 1:-1]
            inside = fl & (zagl < self.h_bl[None]) & (zagl > -dz)
            n_in = np.maximum(inside.sum(axis=0), 1)
            Qc = np.where(inside, (Hk / (n_in * dz))[None], 0.0)
            pos = (Hk > 0)[None]
            Qi = Q[:, 1:-1, 1:-1]
            Q[:, 1:-1, 1:-1] = np.where(pos, Qc, Qi)
        self.Q_np = Q
        self.cd = (KAPPA / math.log(0.5 * dz / prm.z0)) ** 2
        # C_d по столбцам (ny, nx): None — везде self.cd; огибающая (AP-1, P4 v2) — свой z0 или 0 (slip) на её верхней грани
        cdm = np.full((ny, nx), self.cd) if cd_map is None else np.asarray(cd_map, float)
        self.cd_np = np.pad(cdm, 1, mode="edge")
        s_th = prm.dtau_th                       # у полного θ′ нет 1/τ в диагонали (τ — только θ′_d)
        gam_w = np.zeros(NZ); gam_w[1:] = 0.5 * (gam_c[1:] + gam_c[:-1])
        cplz = prm.couple * G / THETA0 * np.maximum(gam_w, 0) * s_th
        self.cplz_np = cplz
        # --- на устройство
        dt = self.dt
        A = lambda a: cp.asarray(np.ascontiguousarray(a), dt)   # C-порядок: ядра читают [k][j][i]
        self.cell = cp.asarray(cell)
        self.tu, self.tv, self.tw = cp.asarray(tu), cp.asarray(tv), cp.asarray(tw)
        self.fluid = A(self.fluid_np)
        self.n_fluid = float(self.fluid_np.sum())
        self.mu_u, self.mu_v, self.mu_w = A(tu == 1), A(tv == 1), A(tw == 1)
        self.sp_u, self.sp_w, self.spc = A(sp_c), A(sp_w), A(spc)
        self.ubg, self.vbg, self.wbg = A(self.ubg_np), A(self.vbg_np), cp.zeros(shape, dt)
        self.Q = A(Q)
        self.gam = A(gam_c)
        self.nuf = A(self.nu_np)
        self.kbg = A(self.nu_np)
        self.hcp = A(hp)
        lamc = np.maximum(prm.lam, prm.lam_frac * np.pad(self.h_bl, 1, mode="edge"))
        self.lam_np = lamc
        self.lamc = A(lamc)
        for name_, arr_ in vars(self).items():
            if isinstance(arr_, cp.ndarray) and not arr_.flags.c_contiguous:
                raise AssertionError(f"массив {name_} не C-непрерывен")
        self.inv_prt = 1.0 / prm.pr_t           # K_θ = K/Pr_t (шаблон тепла, баланс)
        self.nuh = A(self.nu_np)                 # горизонтальное K_h
        self.thbg = cp.zeros(shape, dt)          # к чему губка тянет θ′ (0; в окне — родитель)
        self.cplz = A(cplz)
        self.cdp = A(self.cd_np)
        self.u = cp.zeros(shape, dt); self.v = cp.zeros(shape, dt); self.w = cp.zeros(shape, dt)
        self.th = cp.zeros(shape, dt); self.p = cp.zeros(shape, dt)
        # θ′_d — диабатическая часть θ′ (второй переносимый скаляр): поле, цель губки/ореол, шаблон,
        # поправка 2-го порядка; Q_eff = Q − θ′_d/τ — источник полного θ′
        self.thd = cp.zeros(shape, dt)
        self.thbd = cp.zeros(shape, dt)
        self.Ctd = cp.zeros((7,) + shape, dt)
        self.btd = cp.zeros(shape, dt)
        self.ctd = cp.zeros(shape, dt)
        self.Qeff = cp.zeros(shape, dt)
        self.gam0 = cp.zeros(NZ, dt)
        self.inv_tau = 1.0 / prm.tau_cool
        self.Cu, self.Cv, self.Cw, self.Ct = (cp.zeros((7,) + shape, dt) for _ in range(4))
        self.bu, self.bv, self.bw, self.bt = (cp.zeros(shape, dt) for _ in range(4))
        self.cu, self.cv, self.cw, self.ct = (cp.zeros(shape, dt) for _ in range(4))   # поправки 2-го порядка
        self.rr = cp.zeros(shape, dt)
        if prm.omega_u != 1.0:
            self.u_old, self.v_old, self.w_old = (cp.zeros(shape, dt) for _ in range(3))
        self.lines = Lines(shape, dt)
        self.k = kernels(dt, prm.limiter)
        # --- проекция: K_x,y = 1/(1/Δτ + sp), K_z = 1/(1/Δτ + sp_w + cpl) на гранях
        idt = 1.0 / self.dtau_u
        Kc = 1.0 / (idt + sp_c)
        Kx = np.zeros(shape); Kx[:, :, 1:] = 0.5 * (Kc[:, :, 1:] + Kc[:, :, :-1])
        Ky = np.zeros(shape); Ky[:, 1:, :] = 0.5 * (Kc[:, 1:, :] + Kc[:, :-1, :])
        Kz = 1.0 / (idt + sp_w + cplz[:, None, None])
        Kx *= (tu == 1); Ky *= (tv == 1); Kz = Kz * (tw == 1)
        self.Kx_np, self.Ky_np, self.Kz_np = Kx, Ky, Kz
        self.Kx, self.Ky, self.Kz = A(Kx), A(Ky), A(Kz)
        cx = Kx[1:-1, 1:-1, 1:] / dx ** 2
        cy = Ky[1:-1, 1:, 1:-1] / dx ** 2
        cz = Kz[1:, 1:-1, 1:-1] / dz ** 2
        self.mg = MG(cx, cy, cz, self.fluid_np[1:-1, 1:-1, 1:-1], dt)
        self.phi = cp.zeros((nz, ny, nx), dt)
        self._setup_boundary()
        self.outer = 0
        self.graph = None
        self.no_thd = False                         # шаг θ′_d пропускается (нет нагрева, решает solve)
        self.hist = []
        self.status = None

    # ------------------------------------------------------------------ толщина слоя
    def _bl_depth(self):
        """Толщина слоя h, w*, L (Троен–Март 1986 / Холтслаг–Бовилль 1993) — свойство слоя, не
        замыкания: считается всегда (и при closure = "const" — для нагрева cbl и λ).
          u* = κ U10 / ln(10/z0) — по фону (без ускорения над рельефом);
          H — поток тепла, сглаженный гауссом σ = k_smooth_m (конвективная ячейка ~ z_i);
          L = −u*³ θ0 / (κ g H_kin);  w* = (g/θ0 · H_kin · h)^(1/3) при H > 0;
          h: неустойчиво — max(z_i − h_s, zi_min) (h_s — сглаженный рельеф), и не ниже
             механической 0,3 u*/f; нейтрально/устойчиво — 0,3 u*/f и 0,4 √(u* L / f) (Зилитинкевич).
        Пишет self.ustar, h_mech, wstar, h_bl, Lmo, unst (по внутренним столбцам)."""
        prm, case, g = self.prm, self.case, self.g
        ny, nx = self.hc.shape
        ustar = KAPPA * case.U10 / math.log(10.0 / prm.z0) if case.U10 > 0 else 0.0
        Hs = gauss2d(self.Hk, prm.k_smooth_m / g.dx) if np.any(self.Hk != 0) else np.zeros((ny, nx))
        hs = gauss2d(self.hc, prm.k_smooth_m / g.dx)
        h_mech = 0.3 * ustar / prm.f_cor
        unst = Hs > 1e-6
        # неустойчиво
        if case.z_i is not None:
            h_c = np.maximum(case.z_i - hs, prm.zi_min)
        else:
            h_c = np.full((ny, nx), prm.zi_min)
        h_u = np.maximum(h_c, h_mech)
        wstar = np.where(unst, (G / THETA0 * np.maximum(Hs, 0) * h_u) ** (1 / 3), 0.0)
        # устойчиво/нейтрально
        with np.errstate(divide="ignore", invalid="ignore"):
            Lmo = np.where(Hs < -1e-6, -ustar ** 3 * THETA0 / (KAPPA * G * Hs), np.inf)
        h_s = np.where(np.isfinite(Lmo), np.minimum(h_mech, 0.4 * np.sqrt(ustar * np.where(np.isfinite(Lmo), Lmo, 0) / prm.f_cor)), h_mech)
        h = np.where(unst, h_u, h_s)
        h = np.maximum(h, 1.0)
        self.ustar, self.h_mech, self.wstar, self.h_bl, self.Lmo, self.unst = ustar, h_mech, wstar, h, Lmo, unst

    # ------------------------------------------------------------------ замыкание K(z)
    def _closure(self):
        """K_m в клетках (с ореолом). Троен–Март (1986) / Холтслаг–Бовилль (1993), первый порядок
        с профилем: K = κ w_m z (1 − z/h)² при z < h, выше — k_fa; h, w*, L — _bl_depth().
          w_m: неустойчиво — u*·(1 − 7 z_s/L)^(1/3) = (u*³ + 7κ (z_s/h) w*³)^(1/3), z_s = min(z, 0,1 h)
               устойчиво — u* / (1 + 5 z/L); нейтрально — u*.
        Постоянная (прикидка) — closure = "const": K = nu_const, h слоя — как в hb."""
        prm = self.prm
        NZ, NY, NX = self.shape
        self._bl_depth()
        if prm.closure == "const":
            return np.full(self.shape, prm.nu_const), dict(kind="const", nu=prm.nu_const, h_max=float(self.h_bl.max()))
        ny, nx = self.hc.shape
        ustar, wstar, h, Lmo, unst = self.ustar, self.wstar, self.h_bl, self.Lmo, self.unst
        K = np.full((NZ, ny, nx), prm.k_fa)
        zagl = self.zc[:, None, None] - self.hc[None]
        z = np.clip(zagl, 0, None)
        zs = np.minimum(z, 0.1 * h[None])
        wm_u = (ustar ** 3 + 7 * KAPPA * (zs / h[None]) * wstar[None] ** 3) ** (1 / 3)
        with np.errstate(divide="ignore", invalid="ignore"):
            wm_s = ustar / (1 + 5 * z / np.where(np.isfinite(Lmo), Lmo, np.inf)[None])
        wm = np.where(unst[None], wm_u, wm_s)
        Kbl = KAPPA * wm * z * np.clip(1 - z / h[None], 0, 1) ** 2
        K = np.maximum(K, np.where(z < h[None], Kbl, 0))
        Kp = np.zeros(self.shape)
        Kp[:, 1:-1, 1:-1] = K
        Kp[:, 0, :] = Kp[:, 1, :]; Kp[:, -1, :] = Kp[:, -2, :]
        Kp[:, :, 0] = Kp[:, :, 1]; Kp[:, :, -1] = Kp[:, :, -2]
        info = dict(kind="hb", ustar=ustar, h_mech=self.h_mech, wstar_max=float(wstar.max()),
                    h_max=float(h.max()), K_max=float(K[self.fluid_np[:, 1:-1, 1:-1]].max()),
                    K_p50=float(np.median(K[self.fluid_np[:, 1:-1, 1:-1]])))
        return Kp, info

    # ------------------------------------------------------------------ границы
    def _setup_boundary(self):
        cp = self.cp
        tu, tv, tw = self.tu_np, self.tv_np, self.tw_np
        bu = np.argwhere(tu == 2); su = np.where(self.cell_np[tuple(bu.T)] == 1, -1, 1)
        bv = np.argwhere(tv == 2); sv = np.where(self.cell_np[tuple(bv.T)] == 1, -1, 1)
        bw = np.argwhere(tw == 2); sw = np.where(self.cell_np[tuple(bw.T)] == 1, -1, 1)
        flat = lambda a: np.ravel_multi_index(a.T, self.shape)
        self.b_u, self.b_v, self.b_w = cp.asarray(flat(bu)), cp.asarray(flat(bv)), cp.asarray(flat(bw))
        self.s_u, self.s_v, self.s_w = (cp.asarray(s.astype(self.dt)) for s in (su, sv, sw))
        self.b_np = dict(u=bu, v=bv, w=bw, su=su, sv=sv, sw=sw)
        # «жёсткие» границы: приток — фон (профиль), выход — фон × множитель (баланс потоков)
        ub = self.ubg_np[tuple(bu.T)]; vb = self.vbg_np[tuple(bv.T)]
        nu_, nv_ = su * ub, sv * vb
        fin = -(np.sum(np.minimum(nu_, 0)) + np.sum(np.minimum(nv_, 0)))
        fout = np.sum(np.maximum(nu_, 0)) + np.sum(np.maximum(nv_, 0))
        sc = fin / fout if fout > 0 else 1.0
        self.fixed_scale = sc
        self.fixed_u = cp.asarray(np.where(nu_ > 0, ub * sc, np.where(nu_ < 0, ub, 0.0)).astype(self.dt))
        self.fixed_v = cp.asarray(np.where(nv_ > 0, vb * sc, np.where(nv_ < 0, vb, 0.0)).astype(self.dt))

    def set_ghosts_background(self):
        cp = self.cp
        self.u[...] = cp.where(self.tu == 3, self.ubg, self.u); self.u[...] = cp.where(self.tu == 0, 0, self.u)
        self.v[...] = cp.where(self.tv == 3, self.vbg, self.v); self.v[...] = cp.where(self.tv == 0, 0, self.v)
        self.w[...] = cp.where(self.tw == 1, self.w, 0)
        self.th[...] = cp.where(self.cell == 1, self.th, 0)
        self.thd[...] = cp.where(self.cell == 1, self.thd, 0)
        self.apply_bc()

    def apply_bc(self):
        if self.nest is not None:
            return
        u, v = self.u.ravel(), self.v.ravel()
        if self.case.U10 <= 0:
            u[self.b_u] = 0; v[self.b_v] = 0
            return
        u[self.b_u] = self.fixed_u
        v[self.b_v] = self.fixed_v

    # ------------------------------------------------------------------ начальные поля
    def init_background(self):
        cp = self.cp
        self.u[...] = cp.where(self.tu == 1, self.ubg, 0)
        self.v[...] = cp.where(self.tv == 1, self.vbg, 0)
        self.w[...] = 0; self.th[...] = 0; self.thd[...] = 0; self.p[...] = 0
        self.set_ghosts_background()
        self.project(cycles=30)
        self.p[...] = 0

    def init_from(self, st, with_p=True, cycles=4, with_k=False):
        if with_k and "nuf" in st:          # тёплый старт с состоянием замыкания K (AP-1): K — часть состояния Пикара
            self.nuf[...] = self.cp.asarray(st["nuf"], self.dt)
            self.nuh[...] = self.cp.asarray(st["nuh"], self.dt)
        for a in ("u", "v", "w", "th"):
            getattr(self, a)[...] = self.cp.asarray(st[a], self.dt)
        self.thd[...] = self.cp.asarray(st["thd"], self.dt) if "thd" in st else 0   # нет — θ′_d с нуля
        self.p[...] = self.cp.asarray(st["p"], self.dt) if with_p else 0
        if self.nest is None:
            self.set_ghosts_background()
        else:
            self.set_nest_bc()
        self.project(cycles=cycles, update_p=False)

    def state(self):
        return {k: getattr(self, k).copy() for k in ("u", "v", "w", "th", "thd", "p", "nuf", "nuh")}

    # ------------------------------------------------------------------ окно: границы от родителя
    def set_nest_bc(self, init=False):
        cp = self.cp
        P = self.nest["parent"]
        g, gp = self.g, P.g
        NZ, NY, NX = self.shape
        U, V, W, T = P.centers(full=True)

        def sample(F, X, Y, Z):
            return trilinear(F, (Z - gp.z_bot) / gp.dz + 0.5, (Y - gp.y0) / gp.dx + 0.5, (X - gp.x0) / gp.dx + 0.5)
        xc = g.x0 + (np.arange(NX) - 0.5) * g.dx; yc = g.y0 + (np.arange(NY) - 0.5) * g.dx
        zc = g.z_bot + (np.arange(NZ) - 0.5) * g.dz
        xf = g.x0 + (np.arange(NX) - 1.0) * g.dx; yf = g.y0 + (np.arange(NY) - 1.0) * g.dx
        zf = g.z_bot + (np.arange(NZ) - 1.0) * g.dz
        Zc, Yc, Xu = np.meshgrid(zc, yc, xf, indexing="ij"); uu = sample(U, Xu, Yc, Zc)
        Zc, Yv, Xc = np.meshgrid(zc, yf, xc, indexing="ij"); vv = sample(V, Xc, Yv, Zc)
        Zw, Yc2, Xc2 = np.meshgrid(zf, yc, xc, indexing="ij"); ww = sample(W, Xc2, Yc2, Zw)
        Zc, Yc, Xc = np.meshgrid(zc, yc, xc, indexing="ij"); tt = sample(T, Xc, Yc, Zc)
        Td = (P.thd * (P.cell != 0).astype(P.dt)).get().astype(np.float64)   # θ′_d родителя в центрах
        td = np.where(self.cell_np == 0, 0, sample(Td, Xc, Yc, Zc))
        tu, tv, tw = self.tu_np, self.tv_np, self.tw_np
        uu = np.where(tu == 0, 0, uu); vv = np.where(tv == 0, 0, vv); ww = np.where(tw == 0, 0, ww)
        b = self.b_np
        fu = uu[tuple(b["u"].T)] * b["su"]; fv = vv[tuple(b["v"].T)] * b["sv"]; fw = ww[tuple(b["w"].T)] * b["sw"]
        A_side, A_top = g.dx * g.dz, g.dx * g.dx
        net = A_side * (fu.sum() + fv.sum()) + A_top * fw.sum()
        area = A_side * (len(fu) + len(fv)) + A_top * len(fw)
        corr = net / area
        uu[tuple(b["u"].T)] -= corr * b["su"]; vv[tuple(b["v"].T)] -= corr * b["sv"]; ww[tuple(b["w"].T)] -= corr * b["sw"]
        self.nest_corr = corr
        A = lambda a: cp.asarray(a, self.dt)
        fix = lambda t: cp.asarray((t == 2) | (t == 3))
        # к чему тянут губки окна — поле родителя
        self.ubg[...] = A(uu); self.vbg[...] = A(vv); self.wbg[...] = A(ww)
        self.thbg[...] = A(np.where(self.cell_np == 0, 0, tt))
        self.thbd[...] = A(td)
        if init:
            self.u[...] = A(uu); self.v[...] = A(vv); self.w[...] = A(ww)
            self.th[...] = A(np.where(self.cell_np == 0, 0, tt))
            self.thd[...] = A(td)
        else:
            self.u[...] = cp.where(fix(tu), A(uu), self.u)
            self.v[...] = cp.where(fix(tv), A(vv), self.v)
            self.w[...] = cp.where(fix(tw), A(ww), self.w)
            self.th[...] = cp.where(self.cell == 2, A(tt), self.th)
            self.thd[...] = cp.where(self.cell == 2, A(td), self.thd)
        # фон для губок/профиля в окне не используется

    def init_nest(self):
        self.set_nest_bc(init=True)
        self.p[...] = 0
        self.project(cycles=30)
        self.p[...] = 0

    # ------------------------------------------------------------------ проекция
    def divergence(self):
        u, v, w = self.u, self.v, self.w
        du = (u[1:-1, 1:-1, 2:] - u[1:-1, 1:-1, 1:-1]) / self.dx
        dv = (v[1:-1, 2:, 1:-1] - v[1:-1, 1:-1, 1:-1]) / self.dx
        dw = (w[2:, 1:-1, 1:-1] - w[1:-1, 1:-1, 1:-1]) / self.dz
        return (du + dv + dw) * self.fluid[1:-1, 1:-1, 1:-1]

    def project(self, cycles=1, update_p=True):
        cp = self.cp
        f = self.fluid[1:-1, 1:-1, 1:-1]
        rhs = self.divergence()
        rhs -= cp.sum(rhs) / self.n_fluid * f
        phi = self.phi
        phi[...] = 0
        for _ in range(cycles):
            phi = self.mg.vcycle(0, phi, rhs)
        phi -= cp.sum(phi * f) / self.n_fluid * f
        P = cp.zeros(self.shape, self.dt)
        P[1:-1, 1:-1, 1:-1] = phi
        self.u[:, :, 1:] -= self.Kx[:, :, 1:] * (P[:, :, 1:] - P[:, :, :-1]) / self.dx
        self.v[:, 1:, :] -= self.Ky[:, 1:, :] * (P[:, 1:, :] - P[:, :-1, :]) / self.dx
        self.w[1:] -= self.Kz[1:] * (P[1:] - P[:-1]) / self.dz
        if update_p:
            self.p += P
        return P

    # ------------------------------------------------------------------ итерация Пикара
    def _grid1(self):
        n = self.NZ * self.NY * self.NX
        return ((n + 255) // 256,), (256,)

    def adv2_mom(self):
        gr, bl = self._grid1()
        R = self.dt.type
        for comp, c in enumerate((self.cu, self.cv, self.cw)):
            if self.prm.adv2:
                self.k["adv2_mom"](gr, bl, (np.int32(comp), self.u, self.v, self.w, self.tu, self.tv, self.tw, c,
                                            np.int32(self.NZ), np.int32(self.NY), np.int32(self.NX), R(self.dx), R(self.dz)))
            else:
                c[...] = 0

    def build_mom(self):
        gr, bl = self._grid1()
        R = self.dt.type
        prm = self.prm
        for comp, (C, b, sp, bg, corr) in enumerate(((self.Cu, self.bu, self.sp_u, self.ubg, self.cu),
                                                      (self.Cv, self.bv, self.sp_u, self.vbg, self.cv),
                                                      (self.Cw, self.bw, self.sp_w, self.wbg, self.cw))):
            self.k["build_mom"](gr, bl, (np.int32(comp), self.u, self.v, self.w, self.tu, self.tv, self.tw,
                                         self.p, self.th, sp, bg, self.cplz, self.nuf, self.nuh, corr, C, b,
                                         np.int32(self.NZ), np.int32(self.NY), np.int32(self.NX),
                                         R(self.dx), R(self.dz), R(1.0 / self.dtau_u), self.cdp))

    def adv2_heat(self):
        gr, bl = self._grid1()
        R = self.dt.type
        for x, c in ((self.th, self.ct), (self.thd, self.ctd)):
            if self.prm.adv2 and not (self.no_thd and x is self.thd):
                self.k["adv2_heat"](gr, bl, (self.u, self.v, self.w, self.cell, x, c,
                                             np.int32(self.NZ), np.int32(self.NY), np.int32(self.NX), R(self.dx), R(self.dz)))
            else:
                c[...] = 0

    def _heat_kernel(self, x, Q, xb, gam, corr, C, b, inv_tau):
        gr, bl = self._grid1()
        R = self.dt.type
        self.k["build_heat"](gr, bl, (self.u, self.v, self.w, self.cell, x, Q, self.spc, xb, gam,
                                      self.nuf, self.nuh, corr, C, b, np.int32(self.NZ), np.int32(self.NY),
                                      np.int32(self.NX), R(self.dx), R(self.dz), R(1.0 / self.prm.dtau_th),
                                      R(inv_tau), R(self.inv_prt)))

    def build_heat_d(self):
        """Шаблон θ′_d: L θ′_d = Q − θ′_d/τ − s_θ (θ′_d − θ_b,d) (без фона dθ̄/dz)."""
        self._heat_kernel(self.thd, self.Q, self.thbd, self.gam0, self.ctd, self.Ctd, self.btd, self.inv_tau)

    def build_heat_t(self):
        """Шаблон полного θ′: L θ′ = Q − θ′_d/τ − w dθ̄/dz − s_θ (θ′ − θ_b); τ — явный источник от θ′_d."""
        R = self.dt.type
        self.cp.multiply(self.thd, R(self.inv_tau), out=self.Qeff)
        self.cp.subtract(self.Q, self.Qeff, out=self.Qeff)
        self._heat_kernel(self.th, self.Qeff, self.thbg, self.gam, self.ct, self.Ct, self.bt, 0.0)

    def build_heat(self):
        """Оба шаблона от текущего состояния (невязка, фикстуры)."""
        self.build_heat_d()
        self.build_heat_t()

    def mom_step(self):
        for _ in range(self.prm.mom_sweeps):
            self.lines.sweep(self.Cu, self.u, self.bu)
            self.lines.sweep(self.Cv, self.v, self.bv)
            self.lines.sweep(self.Cw, self.w, self.bw)

    def heat_step(self):
        """Шаг тепла (после adv2_heat): шаблон θ′_d → прогонки θ′_d → шаблон θ′ (от нового θ′_d) → прогонки θ′.
        Без нагрева (Q ≡ 0 и θ_b,d ≡ 0, флаг no_thd — solve) θ′_d ≡ 0 точно: его проход пропускается (А2)."""
        if not self.no_thd:
            self.build_heat_d()
            for _ in range(self.prm.heat_sweeps):
                self.lines.sweep(self.Ctd, self.thd, self.btd)
        self.build_heat_t()
        for _ in range(self.prm.heat_sweeps):
            self.lines.sweep(self.Ct, self.th, self.bt)

    def update_k(self):
        if not self.prm.local_k:
            return
        gr, bl = self._grid1()
        R = self.dt.type
        self.k["kloc"](gr, bl, (self.u, self.v, self.w, self.th, self.cell, self.gam, self.hcp, self.lamc, self.kbg, self.nuf,
                                self.nuh, np.int32(self.NZ), np.int32(self.NY), np.int32(self.NX), R(self.dx), R(self.dz),
                                R(self.g.z_bot), R(self.prm.k_relax), R((self.prm.cs_h * self.dx) ** 2)))

    def outer_step(self):
        """Одна итерация Пикара (порядок — reference.md → «Итерация»)."""
        self.apply_bc()
        self.update_k()
        om = self.prm.omega_u != 1.0
        if om:
            for a, b in ((self.u, self.u_old), (self.v, self.v_old), (self.w, self.w_old)):
                self.cp.copyto(b, a)
        self.adv2_mom()
        self.build_mom()
        self.mom_step()
        self.project(cycles=self.prm.vcycles)
        if om:                              # u ← u_old + ω(u* − u_old): оба поля бездивергентны, сумма тоже
            R = self.dt.type
            for a, b in ((self.u, self.u_old), (self.v, self.v_old), (self.w, self.w_old)):
                a -= b
                a *= R(self.prm.omega_u)
                a += b
        self.adv2_heat()
        self.heat_step()

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
        """Невязка установившихся уравнений (м/с², К/с) в текущем состоянии и ∇·u (1/с)."""
        cp = self.cp
        self.apply_bc()
        self.adv2_mom()
        self.build_mom()
        out = {}
        for name, C, x, b, m in (("u", self.Cu, self.u, self.bu, self.mu_u), ("v", self.Cv, self.v, self.bv, self.mu_v),
                                 ("w", self.Cw, self.w, self.bw, self.mu_w)):
            self.lines.resid(C, x, b, self.rr)
            r = cp.abs(self.rr) * m
            out[name] = (r.max(), cp.sqrt(cp.sum(r * r) / cp.sum(m)))
        self.adv2_heat()
        self.build_heat()
        self.lines.resid(self.Ct, self.th, self.bt, self.rr)
        r = cp.abs(self.rr) * self.fluid
        out["th"] = (r.max(), cp.sqrt(cp.sum(r * r) / self.n_fluid))
        self.lines.resid(self.Ctd, self.thd, self.btd, self.rr)
        r = cp.abs(self.rr) * self.fluid
        out["thd"] = (r.max(), cp.sqrt(cp.sum(r * r) / self.n_fluid))
        d = cp.abs(self.divergence())
        out["div"] = (d.max(), cp.sqrt(cp.sum(d * d) / self.n_fluid))
        vals = {k: (float(a), float(b)) for k, (a, b) in out.items()}
        return dict(mom_max=max(vals["u"][0], vals["v"][0], vals["w"][0]),
                    mom_rms=math.sqrt((vals["u"][1] ** 2 + vals["v"][1] ** 2 + vals["w"][1] ** 2) / 3),
                    # критерий тепла — по обоим скалярам (θ′ и θ′_d)
                    th_max=max(vals["th"][0], vals["thd"][0]), th_rms=max(vals["th"][1], vals["thd"][1]),
                    thd_max=vals["thd"][0], thd_rms=vals["thd"][1],
                    div_max=vals["div"][0], div_rms=vals["div"][1])

    def solve(self, tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6, max_outer=2000, check_every=10, verbose=False,
              graph=True, cb=None):
        cp = self.cp
        cp.cuda.Device().synchronize()
        t0 = time.perf_counter()
        self.t_check = 0.0
        # без нагрева и без θ′_d у родителя уравнение θ′_d однородно: решение θ′_d ≡ 0 (тёплое θ′_d — обнулить)
        no_thd = not bool(cp.any(self.Q != 0)) and not bool(cp.any(self.thbd != 0))
        if no_thd:
            self.thd[...] = 0
        if no_thd != self.no_thd:
            self.no_thd = no_thd
            self.graph = None                       # граф записан с другим шагом тепла
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
            if not all(math.isfinite(v) for v in r.values()) or r["mom_max"] > 50.0:
                status = "diverged"
                break
            if r["mom_rms"] < tol_mom and r["th_rms"] < tol_th and r["div_rms"] < tol_div:
                status = "ok"
                break
        cp.cuda.Device().synchronize()
        self.wall = time.perf_counter() - t0
        self.hist = hist
        self.status = status
        return status

    def finalize(self, cycles=10):
        """После сходимости: проекция до точной дивергенции (без изменения p) — поле для игры."""
        self.apply_bc()
        self.project(cycles=cycles, update_p=False)

    # ------------------------------------------------------------------ выход
    def centers(self, full=False):
        """u, v, w, θ′ в центрах клеток (numpy float64). full — с ореолом; иначе (nz, ny, nx), NaN в земле."""
        cp = self.cp
        u, v, w, th = self.u, self.v, self.w, self.th
        uc = cp.zeros(self.shape, self.dt); vc = cp.zeros_like(uc); wc = cp.zeros_like(uc)
        uc[:, :, :-1] = 0.5 * (u[:, :, :-1] + u[:, :, 1:])
        vc[:, :-1, :] = 0.5 * (v[:, :-1, :] + v[:, 1:, :])
        wc[:-1] = 0.5 * (w[:-1] + w[1:])
        m = (self.cell != 0).astype(self.dt)
        out = [a.get().astype(np.float64) for a in (uc * m, vc * m, wc * m, th * m)]
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
        """Баланс полного θ′ (К·м³/с): нагрев + (−w dθ̄/dz) = выхолаживание (Σ θ′_d/τ) + губка + вынос."""
        cp = self.cp
        V = self.dx * self.dx * self.dz
        f = self.fluid
        th = self.th * f
        q_in = float(cp.sum(self.Q * f, dtype=np.float64)) * V
        cool = float(cp.sum(self.thd * f, dtype=np.float64)) * V / self.prm.tau_cool
        spg = float(cp.sum((th - self.thbg * f) * self.spc, dtype=np.float64)) * V   # губка тянет к θ_b
        wc = 0.5 * (self.w[:-1] + self.w[1:])
        bg = -float(cp.sum(self.gam[:-1, None, None] * wc * f[:-1], dtype=np.float64)) * V
        out = 0.0
        for fld, b, s, area, sh in ((self.u, self.b_u, self.s_u, self.dx * self.dz, 1),
                                    (self.v, self.b_v, self.s_v, self.dx * self.dz, self.NX),
                                    (self.w, self.b_w, self.s_w, self.dx * self.dx, self.NX * self.NY)):
            if len(b) == 0:
                continue
            un = fld.ravel()[b] * s
            inner = cp.where(s < 0, b, b - sh)
            outer = cp.where(s < 0, b - sh, b)
            thb = cp.where(un > 0, self.th.ravel()[inner], self.th.ravel()[outer])
            out += float(cp.sum(un * thb, dtype=np.float64)) * area
        cell = self.cell_np
        T = self.th.get().astype(np.float64)
        K = self.nuf.get().astype(np.float64) * self.inv_prt
        dif = 0.0
        for ax, hh, A in ((2, self.dx, self.dx * self.dz), (1, self.dx, self.dx * self.dz), (0, self.dz, self.dx * self.dx)):
            for sh in (1, -1):
                cn = np.roll(cell, sh, axis=ax); Tn = np.roll(T, sh, axis=ax); Kn = np.roll(K, sh, axis=ax)
                m = (cell == 1) & (cn == 2)
                dif += float(np.sum((0.5 * (K + Kn) * (T - Tn) / hh)[m])) * A
        out += dif
        res = q_in + bg - cool - spg - out
        scale = abs(q_in) + abs(bg) + abs(cool) + abs(spg) + abs(out)
        return dict(q_in=q_in, bg=bg, cool=cool, sponge=spg, outflow=out, residual=res,
                    rel=res / scale if scale > 0 else None)

    def release(self):
        """Освободить граф и его пул памяти (для серий решений в одном процессе)."""
        self.graph = None
        if getattr(self, "_pool", None) is not None:
            self._pool.free_all_blocks()
            self._pool = None

    def mem_mb(self):
        cp = self.cp
        tot = cp.get_default_memory_pool().total_bytes()
        if getattr(self, "_pool", None) is not None:
            tot += self._pool.total_bytes()
        return tot / 2 ** 20


def trilinear(F, fk, fj, fi):
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


class Grid:
    """Сетка: клетка dx по горизонтали, dz по высоте, nx × ny × nz; (x0, y0) — угол области."""

    def __init__(self, dx, nx, ny, dz, z_bot, nz, x0=0.0, y0=0.0):
        self.dx, self.nx, self.ny, self.dz, self.nz, self.z_bot = dx, nx, ny, dz, nz, z_bot
        self.x0, self.y0 = x0, y0
        self.x = x0 + (np.arange(nx) + 0.5) * dx
        self.y = y0 + (np.arange(ny) + 0.5) * dx
        self.z = z_bot + (np.arange(nz) + 0.5) * dz


# ============================================================================== нагрев от солнца
def solar_flux(hc, dx, day, lat, lon, utc, doy, water=None, lag_h=0.3):
    """Поток тепла (Вт/м² на горизонтальную площадь) на рельефе hc в час day.hour: солнце с
    запаздыванием прогрева, косинус угла к склону, рассеянная доля, выхолаживание (weather.Day)."""
    import weather as W
    az, el = W.solar_position(lat, lon, doy, day.hour - lag_h, utc)
    gy, gx = np.gradient(hc, dx)
    if el > 0:
        e, a = math.radians(el), math.radians(az)
        sx, sy, sz = math.cos(e) * math.sin(a), math.cos(e) * math.cos(a), math.sin(e)
        cos_inc = -gx * sx - gy * sy + sz
        sin_el = sz
    else:
        cos_inc = np.zeros_like(hc)
        sin_el = 0.0
    H = day.heat_flux(cos_inc, sin_el)
    if water is not None:
        H = H * (1 - water)
    return H, (az, el)
