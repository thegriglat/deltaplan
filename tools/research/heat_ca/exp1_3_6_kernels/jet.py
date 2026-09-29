"""Опыт 6. «Ядро струи»: установившееся поле тепла и ветра без шагов по времени — как обработка изображения.

Вход — «картинки» земли: карта нагрева q(x) (К·м/с), рельеф h(x); профили фона θ̄(z) и ветра U(z).
Выход — θ′, u, w на той же MAC-сетке, что у автомата. Каждый проход — либо свёртка/фильтр, либо
короткий 1D-проход, либо многосеточный Пуассон (неразрывность). Всё на GPU (CuPy RawKernel +
CUDA Graph — те же приёмы, что пойдут в вычислительный шейдер Vulkan).

Физика по шагам (подробно — summary.md):

1. **Где стоит струя** — размытие карты «нагрев × (высота над дном долины + a)» гауссом L = 700 м, a = 250 м
   (L и a подобраны по положению струи в сценариях 1 и 2)
   (разделимый фильтр; в 3D — по x и y), максимум — основание струи. Смысл: давление у земли ниже
   всего там, где тепло подводится выше всего над долиной (приподнятый источник тепла), туда сходятся
   склоновые ветры. Тепло «течёт» к основанию струи вдоль склона (вверх по «картине» S), сквозь хребет
   не проходит: это направляемый рельефом фильтр.
2. **Тёплый «бассейн»** (почти всё θ′): закон сохранения тепла в установившемся состоянии —
   весь подведённый поток уходит в выхолаживание τ: ∬θ′ dA = τ·∫q dx. Форма по высоте —
   частично перемешанный слой в координатах фона: θ′ = max(0, θs − β·(θ̄(z) − θ̄(дна))),
   θs — из закона сохранения (бисекция, один поток GPU). β = 1 — полностью перемешанный слой
   (классическое «вторжение» конвективного слоя); у автомата слой перемешан частично, β — калибровка.
   Инверсия обрезает бассейн сама: θ̄ там растёт в 18 раз быстрее. С ветром — тот же закон
   сохранения вдоль ветра: U·dC/dx = q − C/τ (одномерный проход по ветру — «наклонённое по ветру»
   экспоненциальное ядро длиной U·τ), слой свой в каждом столбце.
3. **Струя** — уравнения плавучей струи (как Мортон–Тейлор–Тёрнер, но ширина — из диффузии автомата):
   поперечник гауссов, σ² = σ0² + 2K·t (t — время подъёма, K = 30 м²/с — перемешивание автомата);
   поток тепла F = ∫w·θ′dx: dF/dz = −M·dθ̄/dz + θ′бассейна·dM/dz (подъём в устойчивом фоне
   охлаждает, вовлечённый воздух бассейна несёт своё тепло); поток импульса P = √π·σ·w²:
   dP/dz = Cb·(g/θ0)·√(2π)·σ·(θц − θ′бассейна) — плавучесть относительно окружения;
   Cb — множитель эффективной плавучести; оставлен Cb = 1 (теория без подгонки). Старт — «ленивый»:
   σ0 = 50 м, w0 = 0,05 м/с (вариант со стартом от потоков Прандтля, m0frac = 1, хуже — отброшен). Струя кончается, где P = 0 (перебег над бассейном/инверсией
   → холодная «шапка» сама). Снос ветром: dx/dz = U/w. Стартовый поток тепла — нагрев склонов
   (тепло равнин уходит в бассейн напрямую).
4. **Ядро струи на сетку** — гаусс вокруг оси (узко у земли, шире с высотой, наклон по ветру).
5. **Неразрывность** — w* струи + фоновый ветер + линейная горная волна (для ветра; ядро Фурье,
   считается один раз на смену ветра) → проекция: ∇²φ = ∇·v*, v = v* − ∇φ (многосеточный Пуассон
   на той же пирамиде, что у автомата; рельеф — закрытые грани). Отсюда приток снизу к основанию
   струи (склоновый ветер), растекание наверху и компенсирующее опускание.
"""
from __future__ import annotations

import math
import time

import numpy as np

from model import HeatCA, Params, G, THETA0

SRC = r'''
typedef float real;
#define SQPI 1.7724539f
#define SQ2PI 2.5066283f

// 1. разделимый гаусс карты «нагрев × (высота + a)»; в 3D — два таких прохода
extern "C" __global__ void blur_qh(const real* q, const real* h, real* S, int nx, real sig, real ah) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nx) return;
    int r = (int)ceilf(3.0f * sig);
    real s = 0;
    for (int j = max(0, i - r); j <= min(nx - 1, i + r); j++) {
        real a = (j - i) / sig;
        real g = expf(-0.5f * a * a);
        s += g * q[j] * (h[j] + ah);
    }
    S[i] = s;   // без нормировки у краёв: иначе у края области ложный максимум
}

// 2а. бассейн в штиль: один θs на всю область; бисекция по закону сохранения тепла
extern "C" __global__ void pool_calm(const real* thb, const real* nfl, int nz, real d, const real* qsum,
                                     real tau, real beta, real* ths) {
    real target = tau * qsum[0] * d;          // К·м²: ∬θ′dA = τ·∫q dx
    real lo = 0, hi = 60;
    for (int it = 0; it < 40; it++) {
        real mid = 0.5f * (lo + hi), c = 0;
        for (int k = 0; k < nz; k++) c += nfl[k] * fmaxf(0.0f, mid - beta * (thb[k] - thb[0]));
        c *= d * d;
        if (c > target) hi = mid; else lo = mid;
    }
    ths[0] = 0.5f * (lo + hi);
}

// 2б. бассейн с ветром: проход по ветру U·dC/dx = q − C/τ (слева губка тепла), один поток
extern "C" __global__ void pool_wind_march(const real* q, const real* xc, int nx, real d, real U, real tau,
                                           real xs, real* C) {
    real c = 0, a = expf(-d / (U * tau));
    for (int i = 0; i < nx; i++) {
        c = c * a + q[i] * d / U;
        if (xc[i] < xs) c = 0;
        C[i] = c;
    }
}
// ... и в каждом столбце свой слой: бисекция θs(i)
extern "C" __global__ void pool_wind_col(const real* C, const real* thb, const int* kb, int nz, int nx, real d,
                                         real beta, real* ths) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nx) return;
    real lo = 0, hi = 60;
    real t0 = thb[kb[i]];
    for (int it = 0; it < 40; it++) {
        real mid = 0.5f * (lo + hi), c = 0;
        for (int k = kb[i]; k < nz; k++) c += fmaxf(0.0f, mid - beta * (thb[k] - t0));
        c *= d;
        if (c > C[i]) hi = mid; else lo = mid;
    }
    ths[i] = 0.5f * (lo + hi);
}

// поле бассейна
extern "C" __global__ void pool_field(const real* ths, const real* thb, const int* kb, const unsigned char* fluid,
                                      int nz, int nx, int calm, real beta, real* thp) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= nz * nx) return;
    int k = idx / nx, i = idx % nx;
    real s = calm ? ths[0] : ths[i];
    real t0 = calm ? thb[0] : thb[kb[i]];
    thp[idx] = fluid[idx] ? fmaxf(0.0f, s - beta * (thb[k] - t0)) : (real)0;
}

// 3б. склоновый ветер — решение Прандтля (стационарный слой над равномерно прогретым склоном,
// линейный Буссинеск): θ′ = C·e^{−n/l}·cos(n/l), u = C·√(g·κ/(θ0·γ·ν))·e^{−n/l}·sin(n/l) вверх по склону,
// l = (4νκ/(N²·sin²α))^{1/4}, C = q⊥·l/κ; n — расстояние от склона по нормали, γ — устойчивость
// фона dθ̄/dz; ни одного подгоночного числа (lmax — только предел для почти плоских мест). Ядро вдоль склона: живёт только у прогретой земли и не проходит сквозь хребет.
__device__ void prandtl(real q, real hx, real n, real K, real Cb, real gam, real lmax,
                        real* th, real* us, real* ca, real* sa) {
    real c = rsqrtf(1 + hx * hx);
    *ca = c; *sa = fabsf(hx) * c;
    *th = 0; *us = 0;
    if (q <= 0 || *sa < 0.02f || n < 0) return;
    real tp = fminf((*sa - 0.02f) / 0.08f, 1.0f);
    q *= tp * tp;      // плавно у подножия и гребня (без «ступеньки» нагрева)
    const real gb = 9.81f / 300.0f;
    real N2 = gb * gam;
    real l = fminf(sqrtf(sqrtf(4 * K * K / (N2 * (*sa) * (*sa)))), lmax);
    real C = q * c * l / K;          // q на горизонтальную площадь → на площадь склона: ×cos α
    real e = expf(-n / l);
    *th = C * e * cosf(n / l);
    *us = C * sqrtf(gb / gam) * e * sinf(n / l);
}
// 3. уравнения струи: один поток, марш по высоте (nsub подшагов на клетку).
// calm = 1: поток тепла струи на высоте z = выхолаживание всего бассейна выше z (баланс тепла слоя
// над z в установившемся состоянии); выше верха бассейна — подъём без обмена (dF/dz = −M·dθ̄/dz) →
// перебег и холодная «шапка». calm = 0 (ветер): F от нагрева склонов, dF/dz = −M·dθ̄/dz + θ′б·dM/dz.
extern "C" __global__ void plume(const long long* i0p, const int* kb, const real* xc, const real* thb,
                                 const real* thp, const real* nfl, const real* Ucol, const real* Fp, int nz, int nx,
                                 real d, real K, real Cb, int nsub, int calm, real tau,
                                 const real* q, const real* hx, real gam0, real lmax, real m0frac, real sig_min,
                                 real* wf, real* sgf, real* xf, real* thc, real* sgc, real* xcc, real* Fabove) {
    int i0 = (int)i0p[0];
    int k0 = kb[i0];
    for (int k = 0; k <= nz; k++) { wf[k] = 0; sgf[k] = 1; xf[k] = xc[i0]; }
    for (int k = 0; k < nz; k++) { thc[k] = 0; sgc[k] = 0; xcc[k] = xc[i0]; }
    // выхолаживание выше грани k (К·м²/с на единицу ширины): суффиксная сумма по уровням
    real acc = 0;
    Fabove[nz] = 0;
    for (int k = nz - 1; k >= 0; k--) {
        acc += thp[k * nx + 0] * nfl[k] * d * d / tau;   // бассейн в штиль однороден по горизонтали
        Fabove[k] = acc;
    }
    // старт струи — сходящиеся склоновые ветры: масса M0 = сумма наибольших потоков Прандтля слева и
    // справа от основания (∫u dn = C·√(g/(θ0γ))·l/2), скорость — их средняя наибольшая скорость
    real ML = 0, MR = 0, uL = 0, uR = 0;
    const real gb0 = 9.81f / 300.0f;
    for (int i = 0; i < nx; i++) {
        real th_, us_, ca_, sa_;
        prandtl(q[i], hx[i], 0.7854f * lmax, K, Cb, gam0, lmax, &th_, &us_, &ca_, &sa_);
        if (q[i] <= 0 || sa_ < 0.02f) continue;
        real tp = fminf((sa_ - 0.02f) / 0.08f, 1.0f);
        real l = fminf(sqrtf(sqrtf(4 * K * K / (gb0 * gam0 * sa_ * sa_))), lmax);
        real C = q[i] * tp * tp * ca_ * l / K;
        real um = C * sqrtf(gb0 / gam0);
        real Mi = um * l * 0.5f;
        um *= 0.3224f;
        if (i < i0 && Mi > ML) { ML = Mi; uL = um; }
        if (i > i0 && Mi > MR) { MR = Mi; uR = um; }
    }
    real M0 = fmaxf(m0frac * (ML + MR), 1.0f);
    real w0 = fmaxf((ML * uL + MR * uR) / fmaxf(ML + MR, 1.0f), 0.05f);
    real sig0 = fmaxf(M0 / (SQ2PI * w0), sig_min);
    real w = w0, sg = sig0, t = 0, x = xc[i0];
    real F = calm ? Fabove[k0] : Fp[0];
    // с ветром: струя «стоит», только если её собственная скорость (g·F/θ0)^{1/3} больше ветра у
    // гребня; иначе её кладёт ветер — тепло уходит тёплым слоем по ветру (бассейн с ветром)
    if (!calm && cbrtf(9.81f / 300.0f * F) < Ucol[min(nz - 1, k0 + 2)]) return;
    real P = SQPI * sg * w * w;
    real dz = d / nsub;
    const real gb = 9.81f / 300.0f;
    int above = 0;
    for (int k = k0; k < nz; k++) {
        wf[k] = w; sgf[k] = sg; xf[k] = x;
        for (int s = 0; s < nsub; s++) {
            real z = (k + (s + 0.5f) / nsub) * d;              // абсолютная высота
            real fk = z / d - 0.5f;
            int ka = max(0, min(nz - 2, (int)floorf(fk)));
            real a = fminf(fmaxf(fk - ka, 0.0f), 1.0f);
            real pool = (1 - a) * thp[ka * nx + i0] + a * thp[(ka + 1) * nx + i0];
            real gam = (thb[ka + 1] - thb[ka]) / d;
            real U = (1 - a) * Ucol[ka] + a * Ucol[ka + 1];
            real M = SQ2PI * sg * w;
            if (calm && !above) {
                real zf = (k + (s + 0.5f) / nsub);
                int kf = min(nz, (int)floorf(zf));
                real b = zf - kf;
                F = (1 - b) * Fabove[kf] + b * Fabove[min(nz, kf + 1)];
                if (pool <= 0) above = 1;
            }
            real th_c = F / (SQPI * sg * w);
            if (s == nsub / 2) { thc[k] = th_c; sgc[k] = sg; xcc[k] = x; }
            P += Cb * gb * SQ2PI * sg * (th_c - pool) * dz;
            if (P <= 0) { wf[k + 1] = 0; return; }
            t += dz / w;
            sg = sqrtf(sig0 * sig0 + 2 * K * t);
            w = sqrtf(P / (SQPI * sg));
            real Mn = SQ2PI * sg * w;
            if (!calm || above) F += -M * gam * dz + (calm ? 0 : pool * (Mn - M));
            x += fminf(fmaxf(U / w, -3.0f), 3.0f) * dz;
        }
    }
}

extern "C" __global__ void slope_flow(const real* q, const real* h, const real* hx, const real* zc, const real* xc,
                                      const real* uxf, const real* wzf, const unsigned char* fluid, int nz, int nx,
                                      real d, real K, real Cb, real gam, real lmax,
                                      real* th, real* us, real* ws) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    real t, u, ca, sa;
    if (idx < nz * nx) {                                   // центры: θ′
        int k = idx / nx, i = idx % nx;
        prandtl(q[i], hx[i], (zc[k] - h[i]) * rsqrtf(1 + hx[i] * hx[i]), K, Cb, gam, lmax, &t, &u, &ca, &sa);
        if (fluid[idx]) th[idx] += t;
    }
    if (idx < nz * (nx + 1)) {                             // грани u: среднее двух столбцов
        int k = idx / (nx + 1), i = idx % (nx + 1);
        real acc = 0;
        for (int j = max(0, i - 1); j <= min(nx - 1, i); j++) {
            prandtl(q[j], hx[j], (zc[k] - h[j]) * rsqrtf(1 + hx[j] * hx[j]), K, Cb, gam, lmax, &t, &u, &ca, &sa);
            acc += 0.5f * u * ca * (hx[j] > 0 ? 1.0f : -1.0f);
        }
        us[idx] += acc * uxf[idx];
    }
    if (idx < (nz + 1) * nx) {                             // грани w
        int k = idx / nx, i = idx % nx;
        prandtl(q[i], hx[i], (k * d - h[i]) * rsqrtf(1 + hx[i] * hx[i]), K, Cb, gam, lmax, &t, &u, &ca, &sa);
        ws[idx] += u * sa * wzf[idx];
    }
}

// 4. ядро струи на сетку: θ′ = бассейн + избыток струи; w* на гранях; + горная волна (готовая)
extern "C" __global__ void raster(const real* thp_pool, const real* xc, const real* thc, const real* sgc,
                                  const real* xcc, const real* wf, const real* sgf, const real* xf,
                                  const real* wzf, const real* th_wave, const real* w_wave,
                                  int nz, int nx, real* th, real* ws) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < nz * nx) {
        int k = idx / nx, i = idx % nx;
        real ex = 0;
        if (sgc[k] > 0) {
            real a = (xc[i] - xcc[k]) / sgc[k];
            // избыток струи над бассейном на её оси: thc − бассейн в столбце оси
            int ic = max(0, min(nx - 1, (int)floorf(xcc[k] / (xc[1] - xc[0]))));
            ex = (thc[k] - thp_pool[k * nx + ic]) * expf(-0.5f * a * a);
        }
        th[idx] = thp_pool[idx] + ex + th_wave[idx];
    }
    if (idx < (nz + 1) * nx) {
        int k = idx / nx, i = idx % nx;
        real a = (xc[i] - xf[k]) / sgf[k];
        ws[idx] = (wf[k] * expf(-0.5f * a * a) + w_wave[idx]) * wzf[idx];
    }
}
'''

_K = {}


def kernels(cp):
    if "k" not in _K:
        mod = cp.RawModule(code=SRC, options=("--use_fast_math",))
        _K["k"] = {n: mod.get_function(n) for n in
                   ("blur_qh", "pool_calm", "pool_wind_march", "pool_wind_col", "pool_field", "plume", "raster", "slope_flow")}
    return _K["k"]


def mountain_wave(m, U, gamma_K_per_m, pad=4):
    """Линейная горная волна (2D, негидростатическая, излучение вверх) — ядро Фурье от рельефа.
    Возвращает u′ (на гранях u), w′ (на гранях w), θ′ = −η·dθ̄/dz (центры)."""
    N2 = G / THETA0 * gamma_K_per_m
    d = m.dx
    n = m.nx * pad
    x = (np.arange(n) + 0.5) * d
    hp = np.zeros(n)
    hp[:m.nx] = m.h
    hk = np.fft.fft(hp)
    k = 2 * np.pi * np.fft.fftfreq(n, d)
    l2 = N2 / U**2
    m_ = np.where(k**2 < l2, np.sign(k) * np.sqrt(np.clip(l2 - k**2, 0, None)), 0) + \
        1j * np.where(k**2 >= l2, np.sqrt(np.clip(k**2 - l2, 0, None)), 0)

    def fields(z):
        eta_k = hk[None, :] * np.exp(1j * m_[None, :] * z[:, None])
        eta = np.fft.ifft(eta_k, axis=1).real[:, :m.nx]
        w = np.fft.ifft(1j * k[None, :] * U * eta_k, axis=1).real[:, :m.nx]
        u = np.fft.ifft(-1j * m_[None, :] * U * eta_k, axis=1).real[:, :m.nx]
        return eta, w, u
    eta_c, _, u_c = fields(m.zc)
    _, w_f, _ = fields(np.arange(m.nz + 1) * d)
    # u′ на грани — среднее соседних центров
    u_f = np.zeros((m.nz, m.nx + 1))
    u_f[:, 1:-1] = 0.5 * (u_c[:, 1:] + u_c[:, :-1])
    th = -eta_c * gamma_K_per_m
    th = np.where(m.solid_np, 0.0, th)
    return u_f, w_f, th


class Jet:
    def __init__(self, sc, cell, Cb=1.0, beta=0.6, L_blur=700.0, ah=250.0, sig0=50.0, m0frac=0.0, nsub=4, n_vcycles=8,
                 wave=True, slope=True, lmax=150.0):
        import cupy as cp
        self.cp = cp
        pr = Params(cell=cell)
        self.m = m = HeatCA(sc, pr)
        self.stream = m.stream
        self.sc, self.pr = sc, m.pr
        self.Cb, self.beta, self.L, self.sig0, self.m0frac, self.nsub, self.nv = Cb, beta, L_blur, sig0, m0frac, nsub, n_vcycles
        d = m.dx
        f32 = np.float32
        self.k = kernels(cp)
        self.calm = sc.wind_ms <= 0
        self.q = cp.asarray(m.q_np, f32)
        self.h = cp.asarray(m.h, f32)
        self.xc = cp.asarray(m.xc, f32)
        self.kb = cp.asarray(m.kb, np.int32)
        self.thb = cp.asarray(m.theta_bar_np, f32)
        self.nfl = cp.asarray((~m.solid_np).sum(axis=1), f32)
        self.fluid8 = cp.asarray((~m.solid_np).astype(np.uint8))
        self.Ucol = cp.asarray(m.ubg_np, f32)
        self.hx = cp.asarray(m.hx, f32)
        self.zc = cp.asarray(m.zc, f32)
        self.slope, self.lmax, self.ah = slope, lmax, ah
        self.gam_pool = sc.dtheta_dz / 1000.0   # устойчивость фона для склонового слоя Прандтля
        # вес «склон»: тепло склонов идёт в струю, тепло равнин — в бассейн напрямую
        sw = np.clip(np.abs(m.hx) / 0.05, 0, 1)
        self.qslope = cp.asarray(m.q_np * sw, f32)
        # горная волна (только с ветром) — считается один раз при смене ветра
        nz, nx = m.nz, m.nx
        if wave and not self.calm:
            U = sc.wind_ms
            uf, wf, th = mountain_wave(m, U, sc.dtheta_dz / 1000.0)
            self.u_wave = cp.asarray(uf, f32)
            self.w_wave = cp.asarray(wf, f32)
            self.th_wave = cp.asarray(th, f32)
        else:
            self.u_wave = cp.zeros((nz, nx + 1), f32)
            self.w_wave = cp.zeros((nz + 1, nx), f32)
            self.th_wave = cp.zeros((nz, nx), f32)
        # скорость переноса бассейна ветром — средний U нижних 500 м
        zz = m.zc < 500
        self.U_bl = float(m.ubg_np[zz].mean()) if not self.calm else 0.0
        # выходы
        self.S = cp.zeros(nx, f32)
        self.ths = cp.zeros(nx, f32)
        self.C = cp.zeros(nx, f32)
        self.thp = cp.zeros((nz, nx), f32)
        self.th = cp.zeros((nz, nx), f32)
        self.ws = cp.zeros((nz + 1, nx), f32)
        self.us = cp.zeros((nz, nx + 1), f32)
        self.wf = cp.zeros(nz + 1, f32)
        self.sgf = cp.ones(nz + 1, f32)
        self.xf = cp.zeros(nz + 1, f32)
        self.thc = cp.zeros(nz, f32)
        self.sgc = cp.zeros(nz, f32)
        self.xcc = cp.zeros(nz, f32)
        self.p = cp.zeros((nz, nx), f32)
        self.Fab = cp.zeros(nz + 1, f32)
        self.graph = None

    # --------------------------------------------------------------- один расчёт
    def _compute(self):
        cp, m, k = self.cp, self.m, self.k
        nz, nx, d = m.nz, m.nx, np.float32(m.dx)
        f = np.float32
        B = 128
        g1 = ((nx + B - 1) // B,)
        k["blur_qh"](g1, (B,), (self.q, self.h, self.S, np.int32(nx), f(self.L / m.dx), f(self.ah)))
        i0 = cp.argmax(self.S)
        # --- бассейн
        if self.calm:
            qsum = cp.sum(self.q)
            k["pool_calm"]((1,), (1,), (self.thb, self.nfl, np.int32(nz), d, qsum, f(self.pr.tau_cool),
                                        f(self.beta), self.ths))
        else:
            k["pool_wind_march"]((1,), (1,), (self.q, self.xc, np.int32(nx), d, f(self.U_bl),
                                              f(self.pr.tau_cool), f(self.pr.side_sponge_m), self.C))
            k["pool_wind_col"](g1, (B,), (self.C, self.thb, self.kb, np.int32(nz), np.int32(nx), d,
                                          f(self.beta), self.ths))
        n = nz * nx
        k["pool_field"](((n + 255) // 256,), (256,), (self.ths, self.thb, self.kb, self.fluid8, np.int32(nz),
                                                       np.int32(nx), np.int32(1 if self.calm else 0),
                                                       f(self.beta), self.thp))
        # --- струя
        Fp = cp.sum(self.qslope) * d
        k["plume"]((1,), (1,), (i0, self.kb, self.xc, self.thb, self.thp, self.nfl, self.Ucol, Fp, np.int32(nz),
                                np.int32(nx), d, f(self.pr.kappa), f(self.Cb),
                                np.int32(self.nsub), np.int32(1 if self.calm else 0), f(self.pr.tau_cool),
                                self.q, self.hx, f(self.gam_pool), f(self.lmax), f(self.m0frac), f(self.sig0),
                                self.wf, self.sgf, self.xf, self.thc, self.sgc, self.xcc, self.Fab))
        # --- на сетку
        n2 = (nz + 1) * nx
        k["raster"](((n2 + 255) // 256,), (256,), (self.thp, self.xc, self.thc, self.sgc, self.xcc, self.wf,
                                                   self.sgf, self.xf, m.wzf, self.th_wave, self.w_wave,
                                                   np.int32(nz), np.int32(nx), self.th, self.ws))
        # --- неразрывность: фоновый ветер + волна + струя → проекция
        self.us[...] = (m.ubg + self.u_wave) * m.uxf
        if self.slope:
            n3 = (nz + 1) * (nx + 1)
            k["slope_flow"](((n3 + 255) // 256,), (256,), (self.q, self.h, self.hx, self.zc, self.xc, m.uxf, m.wzf,
                                                           self.fluid8, np.int32(nz), np.int32(nx), d,
                                                           f(self.pr.kappa), f(self.Cb), f(self.gam_pool),
                                                           f(self.lmax), self.th, self.us, self.ws))
        if not self.calm:
            self.us[:, 0] = m.ubg[:, 0] * m.uxf[:, 0]
            self.us[:, -1] = m.ubg[:, -1] * m.uxf[:, -1]
        rhs = m.div(self.us, self.ws) * m.fluidf
        rhs -= cp.sum(rhs) / m.n_fluid * m.fluidf
        self.p[...] = 0
        p = m.poisson.solve(self.p, rhs, "mg", self.nv)
        gx = cp.zeros_like(self.us)
        gx[:, 1:-1] = (p[:, 1:] - p[:, :-1]) / d
        gz = cp.zeros_like(self.ws)
        gz[1:-1, :] = (p[1:, :] - p[:-1, :]) / d
        self.us -= gx * m.uxf
        self.ws -= gz * m.wzf

    def capture(self):
        import cupy as cp
        self.stream.use()
        self._compute()
        self.stream.synchronize()
        self._pool = cp.cuda.MemoryPool()
        old = cp.get_default_memory_pool()
        cp.cuda.set_allocator(self._pool.malloc)
        try:
            self.stream.begin_capture()
            self._compute()
            self.graph = self.stream.end_capture()
        finally:
            cp.cuda.set_allocator(old.malloc)

    def compute(self):
        if self.graph is not None:
            self.graph.launch(self.stream)
        else:
            self.stream.use()
            self._compute()

    def timeit(self, reps=200):
        cp = self.cp
        if self.graph is None:
            self.capture()
        for _ in range(5):
            self.compute()
        self.stream.synchronize()
        t0 = time.perf_counter()
        for _ in range(reps):
            self.compute()
        self.stream.synchronize()
        return (time.perf_counter() - t0) / reps * 1e3

    def centers(self):
        m = self.m
        u, w = self.us.get(), self.ws.get()
        uc = 0.5 * (u[:, 1:] + u[:, :-1])
        wc = 0.5 * (w[1:, :] + w[:-1, :])
        th = self.th.get()
        s = m.solid_np
        return np.where(s, np.nan, uc), np.where(s, np.nan, wc), np.where(s, np.nan, th)

    def div_residual(self):
        m = self.m
        dv = m.div(self.us, self.ws) * m.fluidf
        sp = float(self.cp.abs(self.ws).max())
        return float(self.cp.abs(dv).max()) * m.dx / max(sp, 1e-9)

    def plume_info(self):
        wf, sgf, xf = self.wf.get(), self.sgf.get(), self.xf.get()
        top = np.nonzero(wf > 0)[0]
        return dict(w_c=float(wf.max()), z_wmax=float(np.argmax(wf) * self.m.dx),
                    z_top=float(top.max() * self.m.dx) if len(top) else float("nan"),
                    x0=float(xf[top.min()]) if len(top) else float("nan"),
                    ths=float(self.ths.get()[0]) if self.calm else float(self.ths.get().max()))
