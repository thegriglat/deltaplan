"""Прототип A: вихревые частицы (ядро Лэмба - Озеена) с плавучестью, 2D, прямая сумма O(N^2) на GPU (RawKernel).

Знаки: w = d psi/dx, u = -d psi/dz, omega = dw/dx - du/dz (против часовой стрелки при z вверх).
Dω/Dt = ∂b/∂x; частица несёт (x, z, Γ=ω·A, b, A); b не меняется (без перемешивания).
Скорость в точке r от вихря Γ: (u, w) = Γ (1 - exp(-r²/σ²)) / (2π r²) · (-dz, dx).
Баро­клинный источник: ∂b/∂x(x_i) = Σ_j A_j b_j ∂_x ζ_σ(x_i - x_j), ζ_σ = exp(-r²/σ²)/(πσ²).
"""
import numpy as np
import cupy as cp

_SRC = r'''
#define PI 3.14159265358979323846
extern "C" __global__ void vel(const double* tx, const double* tz, int nt,
    const double* sx, const double* sz, const double* sg, const double* sab, int ns,
    const double* ix, const double* isg, const double* iz, const double* ig, const double* ib, int nim,
    double sig2, double* u, double* w, double* dbdx)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nt) return;
    double xi = tx[i], zi = tz[i];
    double uu = 0, ww = 0, gb = 0;
    for (int m = 0; m < nim; m++) {
        double sxm = ix[m], sgn = isg[m], szm = iz[m], gm = ig[m]; int bm = ib[m] > 0.5;
        for (int j = 0; j < ns; j++) {
            double dx = xi - (sx[j] + sxm);
            double dz = zi - (sgn * sz[j] + szm);
            double r2 = dx * dx + dz * dz;
            if (r2 < 1e-12) continue;
            double e = exp(-r2 / sig2);
            double f = gm * sg[j] * (1.0 - e) / (2.0 * PI * r2);
            uu -= f * dz; ww += f * dx;
            if (bm) gb += sab[j] * (-2.0 * dx / sig2) * e / (PI * sig2);
        }
    }
    u[i] = uu; w[i] = ww; dbdx[i] = gb;
}
'''
_K = cp.RawKernel(_SRC, 'vel')


def make_images(L=None, H=None, nx=0, kz=0):
    """Список изображений: (сдвиг x, знак z, сдвиг z, знак Γ, учитывать в ∂b/∂x).
    L — период по x (nx копий в каждую сторону); H — высота крышки (стенки z=0 и z=H), kz отражений."""
    ims = []
    xs = [k * L for k in range(-nx, nx + 1)] if L else [0.0]
    for sx in xs:
        if H is None:
            ims.append((sx, 1, 0.0, 1, 1))
        else:
            for k in range(-kz, kz + 1):
                ims.append((sx, 1, 2 * k * H, 1, 1 if k == 0 else 0))
                ims.append((sx, -1, 2 * k * H, -1, 0))
    return np.array(ims, dtype=np.float64)


class Sim:
    def __init__(self, sigma, images):
        self.sig2 = float(sigma) ** 2
        im = cp.asarray(images)
        self.ix, self.isg, self.iz, self.ig, self.ib = [cp.ascontiguousarray(im[:, c]) for c in range(5)]
        self.nim = im.shape[0]

    def eval(self, tx, tz, sx, sz, sg, sab):
        nt = tx.size
        u = cp.empty(nt); w = cp.empty(nt); g = cp.empty(nt)
        blk = 128
        _K(((nt + blk - 1) // blk,), (blk,),
           (tx, tz, np.int32(nt), sx, sz, sg, sab, np.int32(sx.size),
            self.ix, self.isg, self.iz, self.ig, self.ib, np.int32(self.nim),
            np.float64(self.sig2), u, w, g))
        return u, w, g

    def step(self, st, dt, baro=True):
        """Heun (RK2). st: dict x,z,G,A,b (cupy). Возвращает u,w в начале шага."""
        x, z, G, A, b = st['x'], st['z'], st['G'], st['A'], st['b']
        sab = A * b
        u1, w1, g1 = self.eval(x, z, x, z, G, sab)
        dG1 = A * g1 if baro else 0 * g1
        xp, zp, Gp = x + dt * u1, z + dt * w1, G + dt * dG1
        u2, w2, g2 = self.eval(xp, zp, xp, zp, Gp, sab)
        dG2 = A * g2 if baro else 0 * g2
        st['x'] = x + 0.5 * dt * (u1 + u2)
        st['z'] = z + 0.5 * dt * (w1 + w2)
        st['G'] = G + 0.5 * dt * (dG1 + dG2)
        return u1, w1


def disk_lattice(R, n_target, pad=0.0):
    """Гексагональная решётка; ≈ n_target точек внутри круга радиуса R плюс «пояс» до R+pad (там b=0, но частицы
    несут завихрённость: без пояса половина сглаженного градиента b падает туда, где нет частиц, и источник ω вдвое слабее).
    Возвращает x, z (центр 0), A на точку, h, маска «внутри R»."""
    h = R * np.sqrt(2 * np.pi / (np.sqrt(3) * n_target))
    pts = []
    Ro = R + pad
    nr = int(Ro / h) + 2
    for j in range(-nr, nr + 1):
        for i in range(-nr, nr + 1):
            x = h * (i + 0.5 * (j % 2)); z = h * j * np.sqrt(3) / 2
            if x * x + z * z <= Ro * Ro:
                pts.append((x, z))
    p = np.array(pts)
    inside = p[:, 0] ** 2 + p[:, 1] ** 2 <= R * R
    A = np.sqrt(3) / 2 * h * h
    return p[:, 0], p[:, 1], A, h, inside


def blocked_cupy(tx, tz, sx, sz, sg, sig2, blk=1024):
    """Эталон на CuPy без RawKernel: блоками по целям (свободное пространство, без b)."""
    u = cp.empty_like(tx); w = cp.empty_like(tx)
    for a in range(0, tx.size, blk):
        dx = tx[a:a + blk, None] - sx[None, :]
        dz = tz[a:a + blk, None] - sz[None, :]
        r2 = dx * dx + dz * dz
        r2 = cp.where(r2 < 1e-12, cp.inf, r2)
        f = sg[None, :] * (1 - cp.exp(-r2 / sig2)) / (2 * np.pi * r2)
        u[a:a + blk] = -(f * dz).sum(1); w[a:a + blk] = (f * dx).sum(1)
    return u, w
