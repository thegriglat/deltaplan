"""GPU-путь опыта 4: повтор «невязка → два прохода → Андерсон» целиком на устройстве, CUDA Graph.

* два прохода по слоям — одно ядро (поток на гармонику, цикл по слоям внутри: вверх, затем вниз);
* переходы в гармоники и обратно — умножение на матрицы косинусов/синусов (cuBLAS; в 3D — БПФ);
* Андерсон: история в кольцевом буфере на устройстве, маленькая система (≤ 64×64) решается
  своим ядром (один блок, float64) — никаких float()/get() внутри повтора;
* граф захватывается по одному на номер ячейки кольца (mem штук), дальше запускаются по кругу.
Невязка — те же выражения CuPy, что в steady4.SteadyOp.residual (в графе — сотня мелких ядер).
"""
from __future__ import annotations

import time

import numpy as np
import cupy as cp

from steady4 import SteadyOp

_SRC = r'''
#ifdef CPLX
typedef float2 T;
__device__ __forceinline__ T tmul(T a, T b) { return make_float2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x); }
__device__ __forceinline__ T tadd(T a, T b) { return make_float2(a.x + b.x, a.y + b.y); }
__device__ __forceinline__ T tsub(T a, T b) { return make_float2(a.x - b.x, a.y - b.y); }
__device__ __forceinline__ T tzero() { return make_float2(0.f, 0.f); }
#else
typedef float T;
__device__ __forceinline__ T tmul(T a, T b) { return a * b; }
__device__ __forceinline__ T tadd(T a, T b) { return a + b; }
__device__ __forceinline__ T tsub(T a, T b) { return a - b; }
__device__ __forceinline__ T tzero() { return 0.f; }
#endif
// Матрицы [k][16][M], правая часть и ответ [k][4][M] (гармоника m — самая быстрая: чтения слитные).
extern "C" __global__ void two_pass(const T* __restrict__ A, const T* __restrict__ Dinv,
                                    const T* __restrict__ E, const T* __restrict__ rhs,
                                    T* __restrict__ y, int M, int nz) {
    int m = blockIdx.x * blockDim.x + threadIdx.x;
    if (m >= M) return;
    T gp[4] = {tzero(), tzero(), tzero(), tzero()};
    // проход вверх: g_k = Dinv_k (r_k - A_k g_{k-1})
    for (int k = 0; k < nz; ++k) {
        T r[4];
        #pragma unroll
        for (int i = 0; i < 4; ++i) {
            T s = rhs[(k * 4 + i) * M + m];
            #pragma unroll
            for (int j = 0; j < 4; ++j) s = tsub(s, tmul(A[(k * 16 + i * 4 + j) * M + m], gp[j]));
            r[i] = s;
        }
        #pragma unroll
        for (int i = 0; i < 4; ++i) {
            T s = tzero();
            #pragma unroll
            for (int j = 0; j < 4; ++j) s = tadd(s, tmul(Dinv[(k * 16 + i * 4 + j) * M + m], r[j]));
            gp[i] = s;
            y[(k * 4 + i) * M + m] = s;
        }
    }
    // проход вниз: y_k = g_k - E_k y_{k+1}
    for (int k = nz - 2; k >= 0; --k) {
        T yn[4];
        #pragma unroll
        for (int i = 0; i < 4; ++i) {
            T s = y[(k * 4 + i) * M + m];
            #pragma unroll
            for (int j = 0; j < 4; ++j) s = tsub(s, tmul(E[(k * 16 + i * 4 + j) * M + m], gp[j]));
            yn[i] = s;
        }
        #pragma unroll
        for (int i = 0; i < 4; ++i) { gp[i] = yn[i]; y[(k * 4 + i) * M + m] = yn[i]; }
    }
}
'''

_SMALL = r'''
// Андерсон: решить (G + λI) γ = b, G — mem×mem (float64), один блок, метод Гаусса с выбором
// ведущего по столбцу. Нулевые строки (кольцо ещё не заполнено) дают γ = 0 за счёт λ.
extern "C" __global__ void small_solve(const double* G, const double* b, float* gam, int n, double rel) {
    extern __shared__ double sh[];
    double* a = sh;             // n × (n+1)
    int t = threadIdx.x;
    // масштаб Якоби: столбцы истории к единичной норме (иначе float32-история даёт плохую обусловленность)
    double* sc = sh + n * (n + 1);
    for (int i = t; i < n; i += blockDim.x) { double gii = G[i * n + i]; sc[i] = gii > 0 ? 1.0 / sqrt(gii) : 0.0; }
    __syncthreads();
    for (int idx = t; idx < n * (n + 1); idx += blockDim.x) {
        int i = idx / (n + 1), j = idx % (n + 1);
        double v;
        if (j < n) v = (sc[i] > 0 && sc[j] > 0) ? G[i * n + j] * sc[i] * sc[j] + (i == j ? rel : 0.0) : (i == j ? 1.0 : 0.0);
        else v = b[i] * sc[i];
        a[idx] = v;
    }
    __syncthreads();
    for (int c = 0; c < n; ++c) {
        if (t == 0) {
            int p = c; double best = fabs(a[c * (n + 1) + c]);
            for (int r = c + 1; r < n; ++r) { double v = fabs(a[r * (n + 1) + c]); if (v > best) { best = v; p = r; } }
            if (p != c) for (int j = 0; j <= n; ++j) { double tmp = a[c * (n + 1) + j]; a[c * (n + 1) + j] = a[p * (n + 1) + j]; a[p * (n + 1) + j] = tmp; }
        }
        __syncthreads();
        double piv = a[c * (n + 1) + c];
        for (int idx = t; idx < (n - c - 1) * (n + 1 - c); idx += blockDim.x) {
            int r = c + 1 + idx / (n + 1 - c), j = c + idx % (n + 1 - c);
            double f = a[r * (n + 1) + c] / piv;
            if (j > c) a[r * (n + 1) + j] -= f * a[c * (n + 1) + j];
        }
        __syncthreads();
        for (int r = c + 1 + t; r < n; r += blockDim.x) a[r * (n + 1) + c] = 0.0;
        __syncthreads();
    }
    if (t == 0) {
        for (int r = n - 1; r >= 0; --r) {
            double s = a[r * (n + 1) + n];
            for (int j = r + 1; j < n; ++j) s -= a[r * (n + 1) + j] * a[j * (n + 1) + n];
            a[r * (n + 1) + n] = s / a[r * (n + 1) + r];
        }
        for (int r = 0; r < n; ++r) gam[r] = (float)(a[r * (n + 1) + n] * sc[r]);
    }
}
'''

_MM = r'''
#ifdef CPLX
typedef float2 T;
__device__ __forceinline__ T fromr(float a) { return make_float2(a, 0.f); }
__device__ __forceinline__ T tfma(T a, T b, T c) { return make_float2(c.x + a.x*b.x - a.y*b.y, c.y + a.x*b.y + a.y*b.x); }
__device__ __forceinline__ float re(T a) { return a.x; }
__device__ __forceinline__ T tzero() { return make_float2(0.f, 0.f); }
#else
typedef float T;
__device__ __forceinline__ T fromr(float a) { return a; }
__device__ __forceinline__ T tfma(T a, T b, T c) { return c + a * b; }
__device__ __forceinline__ float re(T a) { return a; }
__device__ __forceinline__ T tzero() { return 0.f; }
#endif
#define TS 16
// C[m×n] = A[m×k] · B[k×n]; A вещественная (строка через lda), B и C — T (гармоники)
extern "C" __global__ void mm_r2t(const float* A, int lda, const T* B, T* C, int ldc, int m, int n, int k) {
    __shared__ T As[TS][TS]; __shared__ T Bs[TS][TS];
    int r = blockIdx.y * TS + threadIdx.y, c = blockIdx.x * TS + threadIdx.x;
    T acc = tzero();
    for (int t0 = 0; t0 < k; t0 += TS) {
        int ka = t0 + threadIdx.x, kb = t0 + threadIdx.y;
        As[threadIdx.y][threadIdx.x] = (r < m && ka < k) ? fromr(A[r * lda + ka]) : tzero();
        Bs[threadIdx.y][threadIdx.x] = (kb < k && c < n) ? B[kb * n + c] : tzero();
        __syncthreads();
        #pragma unroll
        for (int q = 0; q < TS; ++q) acc = tfma(As[threadIdx.y][q], Bs[q][threadIdx.x], acc);
        __syncthreads();
    }
    if (r < m && c < n) C[r * ldc + c] = acc;
}
// C[m×n] = Re(A[m×k] · B[k×n]); A — T со строкой lda, B — T, C вещественная (строка ldc)
extern "C" __global__ void mm_t2r(const T* A, int lda, const T* B, float* C, int ldc, int m, int n, int k) {
    __shared__ T As[TS][TS]; __shared__ T Bs[TS][TS];
    int r = blockIdx.y * TS + threadIdx.y, c = blockIdx.x * TS + threadIdx.x;
    T acc = tzero();
    for (int t0 = 0; t0 < k; t0 += TS) {
        int ka = t0 + threadIdx.x, kb = t0 + threadIdx.y;
        As[threadIdx.y][threadIdx.x] = (r < m && ka < k) ? A[r * lda + ka] : tzero();
        Bs[threadIdx.y][threadIdx.x] = (kb < k && c < n) ? B[kb * n + c] : tzero();
        __syncthreads();
        #pragma unroll
        for (int q = 0; q < TS; ++q) acc = tfma(As[threadIdx.y][q], Bs[q][threadIdx.x], acc);
        __syncthreads();
    }
    if (r < m && c < n) C[r * ldc + c] = re(acc);
}
'''

_AA = r'''
// out[r] += Σ_i X[r, i] v[i]  (сетка: r × куски; float64-накопление)
extern "C" __global__ void rows_dot(const float* X, const float* v, double* out, int N) {
    int r = blockIdx.y;
    double s = 0.0;
    for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < N; i += gridDim.x * blockDim.x)
        s += (double)X[(size_t)r * N + i] * (double)v[i];
    __shared__ double sh[256];
    sh[threadIdx.x] = s; __syncthreads();
    for (int o = blockDim.x / 2; o > 0; o >>= 1) { if (threadIdx.x < o) sh[threadIdx.x] += sh[threadIdx.x + o]; __syncthreads(); }
    if (threadIdx.x == 0) atomicAdd(&out[r], sh[0]);
}
// x += β f − Σ_r (dX[r] + β dF[r]) γ[r]
extern "C" __global__ void combo(float* x, const float* f, const float* dX, const float* dF, const float* gam,
                                 int N, int mem, float beta) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= N) return;
    float s = x[i] + beta * f[i];
    for (int r = 0; r < mem; ++r) s -= (dX[(size_t)r * N + i] + beta * dF[(size_t)r * N + i]) * gam[r];
    x[i] = s;
}
'''

_MODS = {}


def _dbl(src):
    """Тот же код в float64 (для проверки: не точность ли float32 мешает сходимости)."""
    return (src.replace("make_float2", "make_double2").replace("float2", "double2").replace("float", "double")
            .replace("0.f", "0.0"))


def _mods(prec="f32"):
    if prec not in _MODS:
        cv = (lambda x: x) if prec == "f32" else _dbl
        k = {}
        k["real"] = cp.RawModule(code=cv(_SRC)).get_function("two_pass")
        k["cplx"] = cp.RawModule(code=cv("#define CPLX\n" + _SRC)).get_function("two_pass")
        k["small"] = cp.RawModule(code=cv(_SMALL)).get_function("small_solve")
        for nm, pre in (("real", ""), ("cplx", "#define CPLX\n")):
            mod = cp.RawModule(code=cv(pre + _MM))
            k["mm_r2t_" + nm] = mod.get_function("mm_r2t")
            k["mm_t2r_" + nm] = mod.get_function("mm_t2r")
        mod = cp.RawModule(code=cv(_AA))
        k["rows_dot"] = mod.get_function("rows_dot")
        k["combo"] = mod.get_function("combo")
        _MODS[prec] = k
    return _MODS[prec]


class GpuSteady:
    """Повторы на GPU. op — SteadyOp(xp=cupy, dtype=float32)."""

    def __init__(self, op: SteadyOp, mem=40, beta=1.0, rel_reg=1e-8, hist64=False):
        """hist64: состояние и история Андерсона в float64 (невязка и проходы — в точности op).
        В float32 целиком Андерсон застревает на ~10⁻³ (плохая обусловленность истории)."""
        self.op, self.mem, self.beta, self.rel_reg = op, mem, beta, rel_reg
        self.f64 = op.dtype == np.float64
        self.rt = np.float64 if self.f64 else np.float32          # невязка, проходы
        self.ht = np.float64 if (hist64 or self.f64) else np.float32   # состояние, история
        k = _mods("f64" if self.f64 else "f32")
        kh = _mods("f64" if self.ht == np.float64 else "f32")
        self.k2 = k["cplx"] if op.cplx else k["real"]
        self.ksmall = kh["small"]
        nm = "cplx" if op.cplx else "real"
        self.kr2t, self.kt2r = k["mm_r2t_" + nm], k["mm_t2r_" + nm]
        self.krows, self.kcombo = kh["rows_dot"], kh["combo"]
        # матрицы перехода в гармоники и обратно — по строкам (для своих ядер умножения)
        self.TfT = cp.ascontiguousarray(op.gTf.T)      # [nx, M]
        self.TcT = cp.ascontiguousarray(op.gTc.T)
        self.IfT = cp.ascontiguousarray(op.gIf.T)      # [M, nx]
        self.IcT = cp.ascontiguousarray(op.gIc.T)
        self.tmp = [cp.zeros((op.nz, op.nx), self.rt) for _ in range(4)]
        nz = op.nz
        M = op.M
        # матрицы перехода: [k][16][M]
        conv = lambda a: cp.ascontiguousarray(a.transpose(1, 2, 3, 0).reshape(nz, 16, M))
        self.A, self.Dinv, self.E = conv(op.gA), conv(op.gDinv), conv(op.gE)
        self.rhs = cp.zeros((nz, 4, M), op.ctype)
        self.y = cp.zeros((nz, 4, M), op.ctype)
        N = op.x0().size
        self.N = N
        self.x = op.x0().astype(self.ht)
        self.x_old = cp.zeros(N, self.ht)
        self.f_old = cp.zeros(N, self.ht)
        self.f = cp.zeros(N, self.ht)
        self.dX = cp.zeros((mem, N), self.ht)
        self.dF = cp.zeros((mem, N), self.ht)
        self.G = cp.zeros((mem, mem), cp.float64)
        self.bvec = cp.zeros(mem, cp.float64)
        self.row = cp.zeros(mem, cp.float64)
        self.gam = cp.zeros(mem, self.ht)
        self.fnorm2 = cp.zeros((), cp.float64)
        self.graphs = {}
        self.n = 0
        self.stream = cp.cuda.Stream(non_blocking=True)

    # --- два прохода на GPU (замена SteadyOp.sweeps)
    def sweeps(self, r):
        """Два прохода на GPU (замена SteadyOp.sweeps): в гармоники → ядро прогонки → обратно."""
        op = self.op
        nz, nx, M = op.nz, op.nx, op.M
        Ru, Rw, Rp, Rt = op.unpack_res(r)
        ru = self.tmp[0]
        ru[...] = Ru[:, :-1]
        if op.wind:
            ru[:, 0] = 0
        # rhs[k, c, m] = Σ_i R_c[k, i] T[m, i]: A = R_c (nz×nx, lda), B = T^T (nx×M), C — срез rhs (ldc = 4M)
        for c, (Rc, lda, TT) in enumerate(((ru, nx, self.TfT), (Rp, nx, self.TcT), (Rt, nx, self.TcT),
                                           (Rw, nx, self.TcT))):
            Cv = self.rhs[:, c, :]
            grid = ((M + 15) // 16, (nz + 15) // 16)
            self.kr2t(grid, (16, 16), (Rc, np.int32(lda), TT, Cv, np.int32(4 * M), np.int32(nz), np.int32(M),
                                       np.int32(nx)))
        self.k2(((M + 127) // 128,), (128,), (self.A, self.Dinv, self.E, self.rhs, self.y,
                                                np.int32(M), np.int32(nz)))
        # обратно: out_c[k, i] = Re Σ_m y[k, c, m] I[i, m]
        outs = []
        for c, IT in enumerate((self.IfT, self.IcT, self.IcT, self.IcT)):
            o = self.tmp[c]
            grid = ((nx + 15) // 16, (nz + 15) // 16)
            self.kt2r(grid, (16, 16), (self.y[:, c, :], np.int32(4 * M), IT, o, np.int32(nx), np.int32(nz),
                                       np.int32(nx), np.int32(M)))
            outs.append(o)
        du = cp.zeros((nz, nx + 1), self.rt)
        du[:, :-1] = outs[0]
        dw = cp.zeros((nz + 1, nx), self.rt)
        dw[:-1] = outs[3]
        dp, dt = outs[1], outs[2]
        if op.wind:
            du[:, 0] = Ru[:, 0] / (-op.cu)
            du[:, -1] = Ru[:, -1] / (-op.cu)
        du *= op.uxf
        dw *= op.wzf
        return -op.pack(du, dw, dp * op.fluidf, dt * op.fluidf)

    def _iter_body(self, j):
        """Повтор с записью в ячейку кольца j (j = None — первый повтор, без истории)."""
        op = self.op
        xr = self.x if self.ht == self.rt else self.x.astype(self.rt)
        self.f[...] = self.sweeps(op.residual(xr))
        f = self.f
        self.fnorm2[...] = cp.sum(f.astype(cp.float64) ** 2)
        if j is None:
            self.x_old[...] = self.x
            self.f_old[...] = f
            self.x += self.beta * f
            return
        self.dX[j] = self.x - self.x_old
        self.dF[j] = f - self.f_old
        self.x_old[...] = self.x
        self.f_old[...] = f
        m, N = self.mem, self.N
        grid = (64, m)
        self.row[...] = 0
        self.krows(grid, (256,), (self.dF, self.dF[j], self.row, np.int32(N)))
        self.G[j, :] = self.row
        self.G[:, j] = self.row
        self.bvec[...] = 0
        self.krows(grid, (256,), (self.dF, self.f, self.bvec, np.int32(N)))
        self.ksmall((1,), (128,), (self.G, self.bvec, self.gam, np.int32(m), np.float64(self.rel_reg)),
                    shared_mem=8 * m * (m + 2))
        self.kcombo(((N + 255) // 256,), (256,), (self.x, self.f, self.dX, self.dF, self.gam, np.int32(N),
                                                  np.int32(m), self.ht(self.beta)))

    def capture(self):
        # SteadyOp (HeatCA) при создании переключает текущий поток на свой — всё, что успели
        # записать туда, должно закончиться до захвата/запусков на нашем потоке
        cp.cuda.Device().synchronize()
        self.stream.use()
        self._pool = cp.cuda.MemoryPool()
        old = cp.get_default_memory_pool()
        # прогрев (компиляция, ленивые массивы) на копии состояния
        save = [a.copy() for a in (self.x, self.x_old, self.f_old, self.dX, self.dF, self.G)]
        self._iter_body(0)
        self.stream.synchronize()
        for a, s in zip((self.x, self.x_old, self.f_old, self.dX, self.dF, self.G), save):
            a[...] = s
        self.stream.synchronize()
        cp.cuda.set_allocator(self._pool.malloc)
        try:
            for j in range(self.mem):
                self.stream.begin_capture()
                self._iter_body(j)
                self.graphs[j] = self.stream.end_capture()
        finally:
            cp.cuda.set_allocator(old.malloc)
        self.stream.synchronize()

    def step(self):
        """Один повтор (невязка + два прохода + Андерсон)."""
        if self.n == 0:
            self._iter_body(None)
        else:
            self.graphs[(self.n - 1) % self.mem].launch(self.stream)
        self.n += 1

    def residual_rms(self):
        return float(np.sqrt(float(self.fnorm2) / self.N))

    def run(self, iters, tol=None, check_every=5, timing=True):
        """iters повторов (или до ‖f‖_rms < tol, проверка раз в check_every). Возвращает время GPU, с
        (события CUDA, без проверок), число повторов и историю ‖f‖_rms."""
        hist = []
        t_gpu = 0.0
        while self.n < iters:
            nb = min(check_every, iters - self.n)
            e0, e1 = cp.cuda.Event(), cp.cuda.Event()
            e0.record(self.stream)
            for _ in range(nb):
                self.step()
            e1.record(self.stream)
            e1.synchronize()
            t_gpu += cp.cuda.get_elapsed_time(e0, e1) * 1e-3
            r = self.residual_rms()
            hist.append((self.n, r))
            if tol is not None and r < tol:
                break
        return t_gpu, self.n, hist

    def time_parts(self, reps=100):
        """Разложение повтора по частям (каждая часть — свой граф): невязка, переход в гармоники + два прохода
        + обратно, только ядро двух проходов. Возвращает мс на одну часть."""
        op = self.op
        self.stream.use()
        pool = cp.cuda.MemoryPool()
        old = cp.get_default_memory_pool()
        xr = self.x.astype(self.rt)
        r = op.residual(xr)
        M = op.M
        parts = {
            "residual": lambda: op.residual(xr),
            "sweeps": lambda: self.sweeps(r),
            "two_pass": lambda: self.k2(((M + 127) // 128,), (128,), (self.A, self.Dinv, self.E, self.rhs, self.y,
                                                                      np.int32(M), np.int32(op.nz))),
        }
        out = {}
        for nm, fn in parts.items():
            fn()
            self.stream.synchronize()
            cp.cuda.set_allocator(pool.malloc)
            try:
                self.stream.begin_capture()
                fn()
                gr = self.stream.end_capture()
            finally:
                cp.cuda.set_allocator(old.malloc)
            e0, e1 = cp.cuda.Event(), cp.cuda.Event()
            e0.record(self.stream)
            for _ in range(reps):
                gr.launch(self.stream)
            e1.record(self.stream)
            e1.synchronize()
            out[nm] = cp.cuda.get_elapsed_time(e0, e1) / reps
        return out
