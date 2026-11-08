"""Ядра SWD-12: скорость и градиент от векторных источников (частицы A, звенья колец C) и градиент плавучести.

Источник j: вектор α_j (м³/с; для звена нити Γ·dl), радиус ядра σ_j. Скорость (Био — Савар, ядро Розенхеда — Мура
в гауссовой форме, 1 − exp(−(r/σ)³)):  u(x) = 1/(4π) Σ α_j × r · f/|r|³,  r = x − x_j.
Градиент ∂u_a/∂x_b нужен для растяжения (α·∇)u частиц A.
Периодичность — перечень сдвигов `shifts` (M_s, 3); зеркало земли на ровной земле — отдельно в вызывающем коде.
GPU, f64, одна нить на цель, прямая сумма O(N·M)."""
import numpy as np
import cupy as cp

_SRC = r"""
extern "C" __global__
void vel(const double* __restrict__ X, const double* __restrict__ S, const double* __restrict__ A,
         const double* __restrict__ SG, const double* __restrict__ SH, int nt, int ns, int nsh, int nch,
         double* __restrict__ U, double* __restrict__ G, int want_grad)
{
  int tid = blockDim.x * blockIdx.x + threadIdx.x;
  if (tid >= nt * nch) return;
  int i = tid / nch, ch = tid % nch;
  double x = X[3*i], y = X[3*i+1], z = X[3*i+2];
  double ux = 0, uy = 0, uz = 0;
  double g[9] = {0,0,0,0,0,0,0,0,0};
  const double c = 0.07957747154594767; // 1/(4 pi)
  for (int h = 0; h < nsh; h++) {
    double hx = SH[3*h], hy = SH[3*h+1], hz = SH[3*h+2];
    for (int j = ch; j < ns; j += nch) {
      double rx = x - S[3*j] - hx, ry = y - S[3*j+1] - hy, rz = z - S[3*j+2] - hz;
      double r2 = rx*rx + ry*ry + rz*rz;
      if (r2 < 1e-24) continue;
      double r = sqrt(r2);
      double s = SG[j];
      double q = r / s;
      double q3 = q*q*q;
      double e = exp(-q3);
      double k = (1.0 - e) / (r2 * r);                 // f/r^3
      double ax = A[3*j], ay = A[3*j+1], az = A[3*j+2];
      // alpha x r
      double cx = ay*rz - az*ry, cy = az*rx - ax*rz, cz = ax*ry - ay*rx;
      ux += c*k*cx; uy += c*k*cy; uz += c*k*cz;
      if (want_grad) {
        // dk/dr = 3 q^2 e/(s r^3) - 3 f / r^4 ;  d(k)/dr_b = (dk/dr) r_b / r
        double dk = (3.0*q*q*e/(s*r2*r) - 3.0*(1.0 - e)/(r2*r2)) / r;  // (dk/dr)/r
        double rr[3] = {rx, ry, rz};
        double aa[3] = {ax, ay, az};
        double cc[3] = {cx, cy, cz};
        // u_a = c eps_{a c d} alpha_c r_d k  ->  du_a/dx_b = c( eps_{a c b} alpha_c k + cross_a * dk * r_b )
        // eps_{a c b} alpha_c: matrix M[a][b] = eps_{acb} alpha_c
        double M[3][3];
        M[0][0] = 0;   M[0][1] = -az; M[0][2] =  ay;
        M[1][0] =  az; M[1][1] = 0; M[1][2] = -ax;
        M[2][0] = -ay; M[2][1] =  ax; M[2][2] = 0;
        for (int a = 0; a < 3; a++)
          for (int b = 0; b < 3; b++)
            g[3*a+b] += c * (M[a][b] * k + cc[a] * dk * rr[b]);
      }
    }
  }
  atomicAdd(&U[3*i], ux); atomicAdd(&U[3*i+1], uy); atomicAdd(&U[3*i+2], uz);
  if (want_grad) for (int m = 0; m < 9; m++) atomicAdd(&G[9*i+m], g[m]);
}

extern "C" __global__
void gradb(const double* __restrict__ X, const double* __restrict__ S, const double* __restrict__ B,
           const double* __restrict__ SG, int nt, int ns, double* __restrict__ GB)
{
  // b(x) = sum_j B_j zeta_sigma(x - x_j), zeta = (2 pi s^2)^(-3/2) exp(-r^2/2s^2); grad b = sum B_j (-r/s^2) zeta
  int i = blockDim.x * blockIdx.x + threadIdx.x;
  if (i >= nt) return;
  double x = X[3*i], y = X[3*i+1], z = X[3*i+2];
  double gx = 0, gy = 0, gz = 0;
  const double c0 = 0.06349363593424097; // (2 pi)^(-3/2)
  for (int j = 0; j < ns; j++) {
    double rx = x - S[3*j], ry = y - S[3*j+1], rz = z - S[3*j+2];
    double s = SG[j];
    double r2 = rx*rx + ry*ry + rz*rz;
    double zt = c0 / (s*s*s) * exp(-0.5*r2/(s*s));
    double f = -B[j] * zt / (s*s);
    gx += f*rx; gy += f*ry; gz += f*rz;
  }
  GB[3*i] = gx; GB[3*i+1] = gy; GB[3*i+2] = gz;
}
"""
_mod = None


def _kernels():
    global _mod
    if _mod is None:
        _mod = cp.RawModule(code=_SRC)
    return _mod.get_function("vel"), _mod.get_function("gradb")


def velocity(X, S, A, SG, shifts=None, grad=False, chunk=4096):
    """X (M,3) цели; S (N,3) источники; A (N,3); SG (N,) → u (M,3) [, G (M,3,3): G[a,b] = ∂u_a/∂x_b]. numpy ↔ cupy."""
    kv, _ = _kernels()
    X = cp.ascontiguousarray(cp.asarray(X, dtype=cp.float64))
    S = cp.ascontiguousarray(cp.asarray(S, dtype=cp.float64))
    A = cp.ascontiguousarray(cp.asarray(A, dtype=cp.float64))
    SG = cp.ascontiguousarray(cp.asarray(SG, dtype=cp.float64))
    sh = cp.zeros((1, 3)) if shifts is None else cp.ascontiguousarray(cp.asarray(shifts, dtype=cp.float64))
    nt, ns = X.shape[0], S.shape[0]
    U = cp.zeros((nt, 3))
    G = cp.zeros((nt, 9)) if grad else cp.zeros(1)
    if ns == 0 or nt == 0:
        return (U, G.reshape(-1, 3, 3)) if grad else U
    thr = 128
    nch = int(max(1, min(ns // 64, 40000 // max(nt, 1))))
    kv(((nt * nch + thr - 1) // thr,), (thr,), (X, S, A, SG, sh, np.int32(nt), np.int32(ns), np.int32(sh.shape[0]),
                                                 np.int32(nch), U, G, np.int32(1 if grad else 0)))
    return (U, G.reshape(-1, 3, 3)) if grad else U


def grad_b(X, S, B, SG):
    """∇b в точках X: b = Σ B_j ζ_σj(x − x_j) (B_j = b_j·V_j, м⁴/с²)."""
    _, kg = _kernels()
    X = cp.ascontiguousarray(cp.asarray(X, dtype=cp.float64))
    S = cp.ascontiguousarray(cp.asarray(S, dtype=cp.float64))
    B = cp.ascontiguousarray(cp.asarray(B, dtype=cp.float64))
    SG = cp.ascontiguousarray(cp.asarray(SG, dtype=cp.float64))
    nt, ns = X.shape[0], S.shape[0]
    GB = cp.zeros((nt, 3))
    if ns == 0 or nt == 0:
        return GB
    thr = 128
    kg(((nt + thr - 1) // thr,), (thr,), (X, S, B, SG, np.int32(nt), np.int32(ns), GB))
    return GB
