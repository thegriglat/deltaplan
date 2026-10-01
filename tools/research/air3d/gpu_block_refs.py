"""Эталоны строительных блоков модели воздуха на GPU (AM-02) — numpy, float64.

Входы — float32 (как на GPU), эталон считается в float64 по тем же формулам, что ядра
scripts/atmosphere/air_model/*.glsl (и прикидка tools/research/air3d/solver.py: Lines, MG).
Выход — tests/atmosphere/fixtures/air_model/blocks/<случай>.bin (float32 little-endian, массивы
подряд) + <случай>.json (размеры, смещения массивов, параметры).

    python3 tools/research/air3d/gpu_block_refs.py            # все случаи
    python3 tools/research/air3d/gpu_block_refs.py --check    # только самопроверка эталона

Раскладка поля: (NZ, NY, NX), индекс (k·NY + j)·NX + i. Шаблон C (7, NZ, NY, NX): 0 центр,
1 −x, 2 +x, 3 −y, 4 +y, 5 −z, 6 +z; сосед за краем массива отсутствует.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tests/atmosphere/fixtures/air_model/blocks"

# (ось массива, сдвиг) для плоскостей 1..6: соседа берём x[idx + сдвиг по оси]
OFFS = {1: (2, -1), 2: (2, 1), 3: (1, -1), 4: (1, 1), 5: (0, -1), 6: (0, 1)}


def f32(a):
    return np.asarray(a, dtype=np.float32)


def neighbor(x, axis, s):
    """x в соседней клетке (idx + s по оси), 0 за краем."""
    out = np.zeros_like(x)
    src = [slice(None)] * 3
    dst = [slice(None)] * 3
    if s < 0:
        dst[axis] = slice(1, None)
        src[axis] = slice(None, -1)
    else:
        dst[axis] = slice(None, -1)
        src[axis] = slice(1, None)
    out[tuple(dst)] = x[tuple(src)]
    return out


def apply7(C, x):
    acc = C[0] * x
    for o, (ax, s) in OFFS.items():
        acc = acc + C[o] * neighbor(x, ax, s)
    return acc


# ---------------------------------------------------------------- прогонки
AXIS = {0: 2, 1: 1, 2: 0}  # направление линии → ось массива (z, y, x)


def line_parity_mask(shape, d):
    """Чётность линии: сумма двух других индексов (как в ядре и прикидке)."""
    nz, ny, nx = shape
    k, j, i = np.meshgrid(np.arange(nz), np.arange(ny), np.arange(nx), indexing="ij")
    if d == 0:
        s = j + k
    elif d == 1:
        s = i + k
    else:
        s = i + j
    return s & 1


def thomas(a, b, c, d):
    """Томас по последней оси (линии — по остальным), float64."""
    n = b.shape[-1]
    cp = np.zeros_like(b)
    dp = np.zeros_like(b)
    cp[..., 0] = c[..., 0] / b[..., 0]
    dp[..., 0] = d[..., 0] / b[..., 0]
    for m in range(1, n):
        den = b[..., m] - a[..., m] * cp[..., m - 1]
        cp[..., m] = c[..., m] / den
        dp[..., m] = (d[..., m] - a[..., m] * dp[..., m - 1]) / den
    x = np.zeros_like(b)
    x[..., -1] = dp[..., -1]
    for m in range(n - 2, -1, -1):
        x[..., m] = dp[..., m] - cp[..., m] * x[..., m + 1]
    return x


def line_solve(C, x, b, d, parity):
    """Одна прогонка линий направления d (0 x, 1 y, 2 z) чётности parity (−1 — все, Якоби).
    Возвращает новое x (для зебры обновлены только линии чётности)."""
    ax = AXIS[d]
    lo, hi = 1 + 2 * d, 2 + 2 * d
    r = b.copy()
    for o, (oax, s) in OFFS.items():
        if o in (lo, hi):
            continue
        r = r - C[o] * neighbor(x, oax, s)
    a = C[lo].copy()
    c = C[hi].copy()
    # на концах линии связи нет
    idx0 = [slice(None)] * 3
    idx0[ax] = 0
    a[tuple(idx0)] = 0
    idx1 = [slice(None)] * 3
    idx1[ax] = -1
    c[tuple(idx1)] = 0
    mv = lambda q: np.moveaxis(q, ax, -1)
    sol = np.moveaxis(thomas(mv(a), mv(C[0]), mv(c), mv(r)), -1, ax)
    if parity < 0:
        return sol
    m = line_parity_mask(x.shape, d) == parity
    out = x.copy()
    out[m] = sol[m]
    return out


def zebra(C, x, b, dirs):
    for d in dirs:
        x = line_solve(C, x, b, d, 0)
        x = line_solve(C, x, b, d, 1)
    return x


def random_stencil(rng, shape, margin=(0.05, 0.5), scale=(0.2, 1.0)):
    """Диагонально преобладающий шаблон: соседи отрицательны, центр = Σ|соседей|·(1 + margin)."""
    C = np.zeros((7,) + shape)
    for o in range(1, 7):
        C[o] = -rng.uniform(*scale, size=shape)
    C[0] = -C[1:].sum(axis=0) * (1 + rng.uniform(*margin, size=shape))
    return f32(C).astype(np.float64)


# ---------------------------------------------------------------- многосеточный (как прикидка MG)
class MG64:
    def __init__(self, cx, cy, cz, active, xy_div=8.0, corr=1.0):
        self.levels = []
        self.corr = corr
        while True:
            nz, ny, nx = active.shape
            self.levels.append(dict(C=self.stencil(cx, cy, cz, active), act=active.astype(np.float64),
                                    shape=active.shape))
            if nx % 2 or ny % 2 or nx < 6 or ny < 6:
                break
            cx = (cx[:, 0::2, 0::2] + cx[:, 1::2, 0::2]) / xy_div
            cy = (cy[:, 0::2, 0::2] + cy[:, 0::2, 1::2]) / xy_div
            cz = (cz[:, 0::2, 0::2] + cz[:, 0::2, 1::2] + cz[:, 1::2, 0::2] + cz[:, 1::2, 1::2]) / 4.0
            active = active.reshape(nz, ny // 2, 2, nx // 2, 2).any(axis=(2, 4))
            a = active
            cx = cx * np.concatenate([a[:, :, :1], a[:, :, 1:] & a[:, :, :-1], a[:, :, -1:]], axis=2)
            cy = cy * np.concatenate([a[:, :1], a[:, 1:] & a[:, :-1], a[:, -1:]], axis=1)
            cz = cz * np.concatenate([a[:1], a[1:] & a[:-1], a[-1:]], axis=0)

    @staticmethod
    def stencil(cx, cy, cz, active):
        C = np.zeros((7,) + active.shape)
        C[1] = cx[:, :, :-1]
        C[2] = cx[:, :, 1:]
        C[3] = cy[:, :-1, :]
        C[4] = cy[:, 1:, :]
        C[5] = cz[:-1]
        C[6] = cz[1:]
        C[0] = -(C[1] + C[2] + C[3] + C[4] + C[5] + C[6])
        C[1][:, :, 0] = 0
        C[2][:, :, -1] = 0
        C[3][:, 0, :] = 0
        C[4][:, -1, :] = 0
        C[5][0] = 0
        C[6][-1] = 0
        dead = ~active | (C[0] == 0)
        C[:, dead] = 0
        C[0][dead] = 1.0
        return C

    def vcycle(self, li, x, f, pre=2, post=2, coarse=20):
        L = self.levels[li]
        C = L["C"]
        if li == len(self.levels) - 1:
            for _ in range(coarse):
                x = zebra(C, x, f, (2, 0, 1))
            return x
        for _ in range(pre):
            x = zebra(C, x, f, (2,))
        r = f - apply7(C, x)
        nz, ny, nx = L["shape"]
        rc = r.reshape(nz, ny // 2, 2, nx // 2, 2).mean(axis=(2, 4)) * self.levels[li + 1]["act"]
        ec = self.vcycle(li + 1, np.zeros_like(rc), rc, pre, post, coarse)
        x = x + np.repeat(np.repeat(ec, 2, axis=1), 2, axis=2) * (L["act"] * self.corr)
        for _ in range(post):
            x = zebra(C, x, f, (2,))
        return x


def mg_case(rng, nx, ny, nz, dx=100.0, dz=50.0):
    """Сетка с маской: «гора» по центру, все грани области закрыты (жёсткие границы, Нейман)."""
    X, Y = np.meshgrid((np.arange(nx) + 0.5) / nx, (np.arange(ny) + 0.5) / ny)
    h = 0.45 * nz * np.exp(-((X - 0.5) ** 2 + (Y - 0.45) ** 2) / 0.04) + 1.2 * X  # в уровнях
    k = np.arange(nz)[:, None, None]
    active = k + 0.5 >= h[None]
    active[:, :, :] &= True
    # K на гранях ~ 1/(1/Δτ + губка), неоднородный
    K = 1.0 / (1.0 / 120.0 + rng.uniform(0, 2e-3, size=(nz, ny, nx)))
    cx = np.zeros((nz, ny, nx + 1))
    cx[:, :, 1:-1] = 0.5 * (K[:, :, 1:] + K[:, :, :-1]) * active[:, :, 1:] * active[:, :, :-1]
    cy = np.zeros((nz, ny + 1, nx))
    cy[:, 1:-1, :] = 0.5 * (K[:, 1:, :] + K[:, :-1, :]) * active[:, 1:, :] * active[:, :-1, :]
    cz = np.zeros((nz + 1, ny, nx))
    cz[1:-1] = 0.5 * (K[1:] + K[:-1]) * active[1:] * active[:-1]
    cx, cy, cz = f32(cx / dx ** 2), f32(cy / dx ** 2), f32(cz / dz ** 2)
    f = rng.standard_normal((nz, ny, nx)) * 1e-3 * active
    f = f - f.sum() / active.sum() * active  # центрирована по активным (Нейман)
    return (cx.astype(np.float64), cy.astype(np.float64), cz.astype(np.float64), active,
            f32(f).astype(np.float64))


# ---------------------------------------------------------------- запись
def write_case(name, dims, arrays, meta=None):
    OUT.mkdir(parents=True, exist_ok=True)
    blob = bytearray()
    index = {}
    off = 0
    for k, v in arrays.items():
        a = f32(v).ravel()
        index[k] = [off, int(a.size)]
        off += a.size
        blob += a.astype("<f4").tobytes()
    (OUT / f"{name}.bin").write_bytes(bytes(blob))
    info = dict(dims=list(dims), arrays=index)
    info.update(meta or {})
    (OUT / f"{name}.json").write_text(json.dumps(info, ensure_ascii=False, indent=1) + "\n")
    print(f"{name}: {len(blob) / 1024:.0f} КБ")


def gen_vec(rng):
    nx, ny, nz = 32, 24, 20
    n = nx * ny * nz
    x = f32(rng.uniform(-2, 2, n)).astype(np.float64)
    y = f32(rng.uniform(-2, 2, n)).astype(np.float64)
    p = f32(rng.uniform(0.1, 3.0, n)).astype(np.float64)  # положительные — для суммы
    a, b = 0.37, -0.8
    arr = dict(x=x, y=y, p=p,
               axpy=y + a * x, xpay=x + b * y, axpby=1.3 * x + (-0.4) * y, scale=2.5 * y, mul=x * y)
    n2 = 12345  # не кратно 256
    red = dict(sum_p=p.sum(), sum_x=x.sum(), sumabs_x=np.abs(x).sum(), maxabs_x=np.abs(x).max(),
               dot_xy=(x * y).sum(), sumabs_xy=np.abs(x * y).sum(),
               sum_p_n2=p[:n2].sum(), dot_xy_n2=(x[:n2] * y[:n2]).sum(),
               sumabs_xy_n2=np.abs(x[:n2] * y[:n2]).sum())
    write_case("vec", (nx, ny, nz), arr, dict(a=a, b=b, n2=n2, reductions={k: float(v) for k, v in red.items()}))


def gen_stencil_lines(rng, name, dims):
    nx, ny, nz = dims
    shape = (nz, ny, nx)
    C = random_stencil(rng, shape)
    x0 = f32(rng.uniform(-1, 1, shape)).astype(np.float64)
    b = f32(rng.uniform(-1, 1, shape)).astype(np.float64)
    arr = dict(C=C, x0=x0, b=b)
    if name == "lines":
        arr["resid"] = b - apply7(C, x0)
        arr["apply"] = apply7(C, x0)
    for d, nm in ((0, "x"), (1, "y"), (2, "z")):
        if dims[d] < 2:
            continue
        arr[f"zebra_{nm}"] = zebra(C, x0, b, (d,))
        arr[f"all_{nm}"] = line_solve(C, x0, b, d, -1)
    write_case(name, dims, arr)


def gen_mg(rng):
    nx, ny, nz = 32, 32, 16
    cx, cy, cz, active, f = mg_case(rng, nx, ny, nz)
    mg = MG64(cx, cy, cz, active)
    x1 = mg.vcycle(0, np.zeros_like(f), f)
    x = np.zeros_like(f)
    res = []
    C0 = mg.levels[0]["C"]
    fn = np.abs(f).max()
    for _ in range(5):
        x = mg.vcycle(0, x, f)
        res.append(float(np.abs(f - apply7(C0, x)).max() / fn))
    arr = dict(cx=cx, cy=cy, cz=cz, act=active.astype(np.float64), f=f,
               C0=C0, C1=mg.levels[1]["C"], x1=x1, x5=x)
    write_case("mg", (nx, ny, nz), arr, dict(levels=[list(L["shape"])[::-1] for L in mg.levels],
                                            residual_per_cycle=res))


def self_check(rng):
    """Эталон прогонки: решение линии удовлетворяет своему уравнению."""
    shape = (5, 6, 7)
    C = random_stencil(rng, shape)
    x0 = rng.uniform(-1, 1, shape)
    b = rng.uniform(-1, 1, shape)
    xa = line_solve(C, x0, b, 2, -1)
    # проверка: для всех линий по z уравнение с соседями из x0 по x, y
    r = b.copy()
    for o in (1, 2, 3, 4):
        ax, s = OFFS[o]
        r -= C[o] * neighbor(x0, ax, s)
    lhs = C[0] * xa + C[5] * neighbor(xa, 0, -1) + C[6] * neighbor(xa, 0, 1)
    err = np.abs(lhs - r).max()
    print(f"self-check line z: {err:.2e}")
    assert err < 1e-12


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    rng = np.random.default_rng(20260929)
    self_check(rng)
    if args.check:
        return
    gen_vec(rng)
    gen_stencil_lines(rng, "lines", (23, 20, 17))
    gen_stencil_lines(rng, "lines_long", (1000, 2, 1))    # одна группа на линию, TPL 256
    gen_stencil_lines(rng, "lines_mp_x", (2500, 2, 1))    # многопроходная по x
    gen_stencil_lines(rng, "lines_mp_y", (2, 1300, 1))    # многопроходная по y
    gen_mg(rng)


if __name__ == "__main__":
    main()
