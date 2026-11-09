"""Замеры panels3d для README (ревью SWD-2): ошибка скорости полусферы у основания по θ и ds_min; время сборки, LU и
память плотной матрицы при N ≈ 5, 10, 20 тыс. Запуск: ./py panels3d/bench.py [hemi|scale]."""
import sys
import time
import numpy as np
import panels3d as P
from panels3d import influence as inf


def hemisphere_table():
    R, U = 100.0, 10.0
    print("| ds_min | N | θ 5–15° | 15–30° | 30–150° (макс) | 150–165° | 165–175° |")
    print("|---|---|---|---|---|---|---|")
    for div in (10, 15, 20, 30):
        ds = R / div
        x = np.arange(-300, 300.1, 2.5)
        X, Y = np.meshgrid(x, x)
        z = np.sqrt(np.maximum(R * R - X ** 2 - Y ** 2, 0.0))
        t = P.Terrain3D(x, x, z, far_m=1500, blend_m=500)
        p = P.build_panels(t, focus=[(0, 0)], ds_min=ds, focus_r=150, growth=1.3)
        bg = P.bg_uniform(U)
        s, _ = P.solve(p, bg)
        fl = P.surface_flow(p, s, bg)
        r = np.linalg.norm(p.c, axis=1)
        m = (np.abs(p.c[:, 1]) < ds) & (r < R + 1) & (p.c[:, 2] > 0.2)
        th = np.degrees(np.arctan2(p.c[m, 2], p.c[m, 0]))
        e = fl["speed"][m] / (1.5 * U * np.sin(np.radians(th))) - 1
        def band(a, b):
            k = (th > a) & (th < b)
            k = k | ((th > 180 - b) & (th < 180 - a)) if a < 90 < b else k
            return "n/a" if k.sum() == 0 else f"{np.abs(e[k]).max() * 100:.1f} %"
        bands = [(5, 15), (15, 30), (30, 150), (150, 165), (165, 175)]
        row = []
        for a, b in bands:
            k = (th > a) & (th < b)
            row.append("n/a" if k.sum() == 0 else f"{np.abs(e[k]).max() * 100:.1f} %")
        print(f"| R/{div} | {p.N} | " + " | ".join(row) + " |")


def _mesh_for(t, target):
    """ds_min, при котором N ≈ target (бисекция по ds_min, фокус — холм 600 м)."""
    foc = [(a, b) for a in np.arange(-900, 901, 300.0) for b in np.arange(-900, 901, 300.0)]
    lo, hi = 10.0, 200.0
    for _ in range(14):
        ds = 0.5 * (lo + hi)
        p = P.build_panels(t, focus=foc, ds_min=ds, focus_r=2.5 * ds + 150, ds_max=800, growth=1.3)
        if p.N > target:
            lo = ds
        else:
            hi = ds
    return p


def scale_table():
    print("| N | backend | сборка, с | LU, с | solve, с | память A+LU, ГБ |")
    print("|---|---|---|---|---|---|")
    x = np.arange(-3000, 3000.1, 100.0)
    X, Y = np.meshgrid(x, x)
    t = P.Terrain3D(x, x, 100 * np.exp(-(X ** 2 + Y ** 2) / (2 * 600.0 ** 2)), far_m=8000)
    for target in (5000, 10000, 20000):
        p = _mesh_for(t, target)
        infl = P.assemble(p)
        ta = infl.t_assemble_s
        t1 = time.time()
        infl.lu()
        if infl.backend == "cupy":
            import cupy as cp
            cp.cuda.Stream.null.synchronize()
        tl = time.time() - t1
        _, info = P.solve(p, P.bg_uniform(10.0), infl=infl)
        print(f"| {p.N} | {infl.backend} | {ta:.1f} | {tl:.1f} | {info['t_solve_s']:.2f} | {infl.mem_bytes / 1e9:.2f} |", flush=True)
        del infl


if __name__ == "__main__":
    w = sys.argv[1] if len(sys.argv) > 1 else "hemi"
    {"hemi": hemisphere_table, "scale": scale_table}[w]()
