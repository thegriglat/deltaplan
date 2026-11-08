"""Тесты sheet3d (SWD6 v2): нить Фёппля за гребнем. Тяжёлые (N ~ 10⁴, плотная матрица) — только с GPU (CuPy)."""
import time

import numpy as np
import pytest
from scipy.optimize import root

import filaments3d as F
import panels3d as P
import sheet3d
from sheet3d import foppl

try:
    import cupy as _cp
    _cp.cuda.runtime.getDeviceCount()
    HAS_GPU = True
except Exception:
    HAS_GPU = False
gpu = pytest.mark.skipif(not HAS_GPU, reason="нужен CuPy и GPU")


def raster(f, hx, hy, step):
    x = np.arange(-hx, hx + 0.1, step)
    y = np.arange(-hy, hy + 0.1, step)
    X, Y = np.meshgrid(x, y)
    return x, y, f(X, Y)


# ---------- 2D-эталон: равновесие вихря за полуцилиндром на стенке (Föppl 1913) ----------
def foppl_semicylinder_2d(theta_deg, R=1.0, U=1.0, guess=(2.2, 1.0, -12.0)):
    """Вихрь Γ в z0 над стенкой, цилиндр |z| = R: изображения — в стенке (−Γ в z̄0) и в окружности (−Γ в R²/z̄0,
    +Γ в R²/z0, теорема о круге Милн-Томсона). Три уравнения: u = v = 0 в z0 без собственного члена и нулевая
    касательная скорость в точке R·e^{iθ} (θ от оси +x, по ветру). → (x0/R, y0/R, |Γ|/(U·R))."""
    th = np.radians(theta_deg)

    def W(z, z0, G, own=True):
        zs, q = [z0, np.conj(z0), R ** 2 / np.conj(z0), R ** 2 / z0], [1, -1, -1, 1]
        if not own:
            zs, q = zs[1:], q[1:]
        return U * (1 - R ** 2 / z ** 2) + G / (2j * np.pi) * sum(qi / (z - zi) for qi, zi in zip(q, zs))

    def f(p):
        x0, y0, G = p
        z0 = x0 + 1j * y0
        v = W(z0, z0, G, own=False)
        zt = R * np.exp(1j * th)
        return [v.real, v.imag, (W(zt, z0, G) * zt).imag]
    s = root(f, guess, method="hybr", tol=1e-13)
    assert s.success
    return s.x[0], s.x[1], abs(s.x[2])


def test_2d_reference_crest_has_no_finite_root():
    """Условие отрыва в вершине (θ = 90°) для полуцилиндра: касательная скорость в вершине вдоль кривой равновесия
    Фёппля остаётся положительной и стремится к нулю только при уходе вихря в бесконечность — конечного корня нет."""
    R = U = 1.0

    def top_on_curve(y0):
        def parts(x0):
            z0 = x0 + 1j * y0
            a = U * (1 - R ** 2 / z0 ** 2)
            b = sum(q / (z0 - zi) for q, zi in zip((-1, -1, 1), (np.conj(z0), R ** 2 / np.conj(z0), R ** 2 / z0))) / (2j * np.pi)
            return a, b
        xs = np.linspace(1.05, 12, 4000)
        im = np.array([(-parts(x)[0] / parts(x)[1]).imag for x in xs])
        k = np.nonzero((im[:-1] * im[1:] < 0) & (np.abs(im[:-1]) < 5))[0]
        out = []
        for i in k:
            from scipy.optimize import brentq
            x = brentq(lambda t: (-parts(t)[0] / parts(t)[1]).imag, xs[i], xs[i + 1])
            G = (-parts(x)[0] / parts(x)[1]).real
            if G < 0:
                z0 = x + 1j * y0
                zt = 1j * R
                zs, q = [z0, np.conj(z0), R ** 2 / np.conj(z0), R ** 2 / z0], [1, -1, -1, 1]
                w = U * (1 - R ** 2 / zt ** 2) + G / (2j * np.pi) * sum(qi / (zt - zi) for qi, zi in zip(q, zs))
                out.append(w.real)
        return out
    vals = [top_on_curve(y0) for y0 in (1.0, 1.6, 2.4, 3.2)]
    assert all(len(v) == 1 and v[0] > 0.1 for v in vals)
    assert vals[0][0] > vals[1][0] > vals[2][0] > vals[3][0]       # убывает, но не доходит до нуля


# ---------- ровная земля и гаусс ----------
def test_flat_and_gauss_no_filaments_field_equals_jh_bitwise():
    x, y, z = raster(lambda X, Y: np.zeros_like(X), 1000, 1000, 50.0)
    tf = P.Terrain3D(x, y, z, far_m=3000)
    pf = P.build_panels(tf, focus=[(0, 0)], ds_min=100.0, focus_r=400)
    bgf = P.bg_profile(10.0, 0.2, 200.0, tf)
    fil, sig, info = sheet3d.foppl_vortex(pf, bgf, 0.1)
    assert len(fil.seg) == 0 and info["n_ridges"] == 0 and F.imbalance(fil) == 0.0
    pts = (np.array([0.0, 100.0]), np.array([0.0, 50.0]), np.array([10.0, 40.0]))
    a = sheet3d.velocity_foppl(pf, sig, bgf, fil, *pts, 0.1)
    b = P.velocity_jh(pf, sig, bgf, *pts, 0.1)
    assert all(np.array_equal(u, v) for u, v in zip(a, b))

    # гаусс H/L = 0,1 (L — наветренная полуширина на половине высоты = 1,177σ): гребень есть, отрыва по Хеду нет
    sg_, H = 300.0, 0.1 * 1.177 * 300.0
    x, y, z = raster(lambda X, Y: H * np.exp(-(X ** 2 + Y ** 2) / (2 * sg_ ** 2)), 700, 500, 16.0)
    tg = P.Terrain3D(x, y, z, far_m=3000)
    foc = [(a_, b_) for a_ in np.arange(-300, 301, 100.0) for b_ in np.arange(-300, 301, 100.0)]
    pg = P.build_panels(tg, focus=foc, ds_min=16.0, focus_r=60, ds_max=500, growth=1.5)
    assert pg.N < 9000
    bgg = P.bg_profile(10.0, 0.2, 200.0, tg)
    fil, sig, info = sheet3d.foppl_vortex(pg, bgg, 0.1)
    assert info["n_ridges"] >= 1 and info["n_rejected"] == info["n_ridges"] and len(fil.seg) == 0
    pts = (np.array([0.0, 150.0]), np.array([0.0, 20.0]), np.array([H + 10.0, H + 40.0]))
    a = sheet3d.velocity_foppl(pg, sig, bgg, fil, *pts, 0.1)
    b = P.velocity_jh(pg, sig, bgg, *pts, 0.1)
    assert all(np.array_equal(u, v) for u, v in zip(a, b))


# ---------- полуцилиндр: 2D-предел ----------
R_CYL, DS_CYL, TH_SEP = 100.0, 15.0, 60.0


@pytest.fixture(scope="module")
def cyl():
    """Длинный полуцилиндр R = 100 м, длина 20R, ds_min R/6,7, однородный ветер 10 м/с."""
    R, ds, Len = R_CYL, DS_CYL, 20 * R_CYL
    st = ds / 2
    x = np.arange(-6 * R, 6 * R + 0.1, st)
    y = np.arange(-Len / 2 - 4 * ds, Len / 2 + 4 * ds + 0.1, st)
    X, Y = np.meshgrid(x, y)
    z = np.where((np.abs(X) < R) & (np.abs(Y) <= Len / 2), np.sqrt(np.maximum(R ** 2 - X ** 2, 0)), 0.0)
    t = P.Terrain3D(x, y, z, far_m=8 * R)
    foc = [(a, b) for a in np.arange(-1.5 * R, 3.5 * R, 2 * ds) for b in np.arange(-Len / 2 - 2 * ds, Len / 2 + 2 * ds + 1, 3 * ds)]
    p = P.build_panels(t, focus=foc, ds_min=ds, focus_r=1.6 * ds, ds_max=600, growth=1.5)
    bg = P.bg_uniform(10.0)
    t0 = time.time()
    infl = P.assemble(p)
    sg, inf0 = P.solve(p, bg, None, infl)
    t_cold = time.time() - t0            # холодное решение панелей: сборка + LU + решение
    prm = dict(gate="none", sep_point=(R * np.cos(np.radians(TH_SEP)), 0.0))
    fil, sig, info = sheet3d.foppl_vortex(p, bg, 0.1, infl, prm)
    return dict(t=t, p=p, bg=bg, infl=infl, fil=fil, sig=sig, info=info, t_cold=t_cold)


@gpu
def test_semicylinder_2d_limit(cyl):
    """Середина нити против 2D-решения Фёппля (полуцилиндр на стенке, отрыв при θ = 60° от оси по ветру): ± 10 %."""
    info = cyl["info"]
    r = info["ridges"][0]
    assert r["converged"] and r["residual"] < 1e-3
    x0, y0, G = foppl_semicylinder_2d(TH_SEP)
    U = 10.0
    s3, h3 = r["s"] / R_CYL, r["h"] / R_CYL
    ground = 0.0 if x0 * R_CYL > R_CYL else np.sqrt(R_CYL ** 2 - (x0 * R_CYL) ** 2) / R_CYL
    assert abs(s3 / x0 - 1) < 0.10 and abs(h3 / (y0 - ground) - 1) < 0.10 and abs(r["Gamma"] / (U * R_CYL) / G - 1) < 0.10
    print(f"\n2D: s={x0:.3f}R h={y0 - ground:.3f}R Γ={G:.2f}UR; 3D: s={s3:.3f} h={h3:.3f} Γ={r['Gamma'] / (U * R_CYL):.2f}")


@gpu
def test_semicylinder_closed_and_reverse_flow(cyl):
    fil = cyl["fil"]
    assert len(fil.seg) > 0 and F.imbalance(fil) <= 1e-12 and fil.anchored.sum() == 2
    assert np.all(fil.gamma > 0) and np.allclose(fil.gamma, fil.gamma[0])
    p, bg, sig = cyl["p"], cyl["bg"], cyl["sig"]
    x = np.array([R_CYL + 40.0, R_CYL + 80.0])
    y = np.zeros(2)
    z = np.array([10.0, 10.0])
    u, v, w = sheet3d.velocity_foppl(p, sig, bg, fil, x, y, z, 0.1, infl=cyl["infl"])
    sg0, _ = P.solve(p, bg, None, cyl["infl"])
    u0 = P.velocity_jh(p, sg0, bg, x, y, z, 0.1)[0]
    assert np.all(u < 0) and np.all(u0 > 0)          # обратный u∥ у земли за склоном: есть с нитью, нет без неё


@gpu
def test_semicylinder_crest_separation_has_no_root(cyl):
    """Отрыв в вершине (sep = "crest"): конечного корня нет (см. 2D-тест), нить не ставится, счётчик."""
    t0 = time.time()
    fil, sig, info = sheet3d.foppl_vortex(cyl["p"], cyl["bg"], 0.1, cyl["infl"], dict(gate="none", maxfev=40))
    assert len(fil.seg) == 0 and info["n_unconverged"] == 1 and not info["ridges"][0]["converged"]
    sg0, _ = P.solve(cyl["p"], cyl["bg"], None, cyl["infl"])
    assert np.array_equal(sig, sg0)


@gpu
def test_cost_vs_cold_panel_solve(cyl):
    """Цена foppl_vortex (infl готов) ≤ 20 холодных решений панелей того же N (сборка + LU + решение)."""
    t_f = cyl["info"]["t_s"]
    ratio = t_f / cyl["t_cold"]
    print(f"\nN={cyl['p'].N} нить {t_f:.1f} с, холодное решение {cyl['t_cold']:.1f} с, отношение {ratio:.1f}, вычислений невязки {cyl['info']['nfev']}")
    assert ratio <= 20.0


# ---------- хребет Agnesi ----------
@gpu
def test_agnesi_ridge_report():
    """Длинный хребет Agnesi H/L 0,5 (a = 250 м, H = 125 м, длина 1500 м) + bg_profile: гребень найден, отрыв по Хеду
    за ним есть (хребет принят), корня Фёппля с s > 0 нет (для sep = crest и separation3d) → нить не ставится,
    поле = velocity_jh побитно. Числа безуспешных стартов — в README."""
    a, H, ds = 250.0, 125.0, 25.0
    x, y, z = raster(lambda X, Y: H / (1 + (X / a) ** 2), 1500, 750, ds)
    t = P.Terrain3D(x, y, z, far_m=4000)
    foc = [(xx, yy) for xx in np.arange(-100, 700, 50.0) for yy in np.arange(-750, 751, 75.0)]
    p = P.build_panels(t, focus=foc, ds_min=ds, focus_r=70, ds_max=500, growth=1.5)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    infl = P.assemble(p)
    fil, sig, info = sheet3d.foppl_vortex(p, bg, 0.1, infl, dict(sep="separation3d", maxfev=30))
    assert info["n_ridges"] == 1 and info["n_rejected"] == 0
    r = info["ridges"][0]
    assert abs(r["x_c"]) < 1.0 and abs(r["L_axis"] - 1500.0) <= 2 * ds
    assert r["p_sep"][0] > 100.0                    # точка отрыва по Хеду на подветренном склоне
    assert not r["converged"] and len(fil.seg) == 0
    pts = (np.array([300.0, 400.0]), np.zeros(2), np.array([80.0, 100.0]))
    a_ = sheet3d.velocity_foppl(p, sig, bg, fil, *pts, 0.1, infl=infl)
    b_ = P.velocity_jh(p, sig, bg, *pts, 0.1, infl=infl)
    assert all(np.array_equal(u, v) for u, v in zip(a_, b_))
    print(f"\nAgnesi N={p.N}: ridge H={r['H']:.0f} м, p_sep=({r['p_sep'][0]:.0f},{r['p_sep'][1]:.0f}), "
          f"невязок {info['nfev']}, стартов {r['starts']}, {info['t_s']:.0f} с")


# ---------- установившийся вихревой слой (SWD6 v4/v5) ----------
def test_sheet_flat_and_gauss_no_sheet_field_equals_jh_bitwise():
    x, y, z = raster(lambda X, Y: np.zeros_like(X), 1000, 1000, 50.0)
    tf = P.Terrain3D(x, y, z, far_m=3000)
    pf = P.build_panels(tf, focus=[(0, 0)], ds_min=100.0, focus_r=400)
    bgf = P.bg_profile(10.0, 0.2, 200.0, tf)
    sh, sig, info = sheet3d.build_sheet(pf, bgf, 0.1)
    assert len(sh.filaments.seg) == 0 and sh.rows == [] and info["n_lines"] == 0 and F.imbalance(sh.filaments) == 0.0
    pts = (np.array([0.0, 100.0]), np.array([0.0, 50.0]), np.array([10.0, 40.0]))
    a = sheet3d.velocity_sheet(pf, sig, bgf, sh, *pts, 0.1)
    b = P.velocity_jh(pf, sig, bgf, *pts, 0.1)
    assert all(np.array_equal(u, v) for u, v in zip(a, b))
    sg_, H = 300.0, 0.1 * 1.177 * 300.0
    x, y, z = raster(lambda X, Y: H * np.exp(-(X ** 2 + Y ** 2) / (2 * sg_ ** 2)), 700, 500, 16.0)
    tg = P.Terrain3D(x, y, z, far_m=3000)
    foc = [(a_, b_) for a_ in np.arange(-300, 301, 100.0) for b_ in np.arange(-300, 301, 100.0)]
    pg = P.build_panels(tg, focus=foc, ds_min=16.0, focus_r=60, ds_max=500, growth=1.5)
    bgg = P.bg_profile(10.0, 0.2, 200.0, tg)
    sh, sig, info = sheet3d.build_sheet(pg, bgg, 0.1)
    assert len(sh.filaments.seg) == 0 and info["n_lines"] == 0
    pts = (np.array([0.0, 150.0]), np.array([0.0, 20.0]), np.array([H + 10.0, H + 40.0]))
    a = sheet3d.velocity_sheet(pg, sig, bgg, sh, *pts, 0.1)
    b = P.velocity_jh(pg, sig, bgg, *pts, 0.1)
    assert all(np.array_equal(u, v) for u, v in zip(a, b))


def agnesi_case(x_c=(0.0,), xmax=1500.0, foc_x=((-100.0, 700.0),)):
    a, H, ds = 250.0, 125.0, 25.0
    x = np.arange(-1500.0, xmax + 0.1, ds)
    y = np.arange(-750.0, 750.1, ds)
    X, Y = np.meshgrid(x, y)
    z = sum(H / (1 + ((X - c) / a) ** 2) for c in x_c)
    t = P.Terrain3D(x, y, z, far_m=4000)
    foc = [(xx, yy) for lo, hi in foc_x for xx in np.arange(lo, hi, 50.0) for yy in np.arange(-750, 751, 75.0)]
    p = P.build_panels(t, focus=foc, ds_min=ds, focus_r=70, ds_max=500, growth=1.5)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    t0 = time.time()
    infl = P.assemble(p)
    sg, _ = P.solve(p, bg, None, infl)
    return dict(p=p, bg=bg, infl=infl, sg=sg, t_cold=time.time() - t0, H=H, ds=ds)


@pytest.fixture(scope="module")
def agn():
    c = agnesi_case()
    c["dec"] = sheet3d.build_sheet(c["p"], c["bg"], 0.1, c["infl"], dict(gamma_decay=250.0))
    c["const"] = sheet3d.build_sheet(c["p"], c["bg"], 0.1, c["infl"])
    return c


@gpu
def test_sheet_agnesi_closed_rows_and_gamma(agn):
    sh, sig, info = agn["dec"]
    fil = sh.filaments
    assert info["n_lines"] == 1 and len(sh.rows) > 5 and len(fil.seg) > 0
    assert F.imbalance(fil) <= 1e-12
    n_loops = len(np.unique(fil.fid))
    assert n_loops == len(sh.rows) and int(fil.anchored.sum()) == 2 * n_loops      # каждый ряд — замкнутая петля с 2 якорями
    ln = sh.lines[0]
    dsh = sh.params["ds_sheet"]
    # Γ ряда = γ0·exp(−s/decay)·Δs, γ0 = среднее |u_s| в точке отрыва; Γ > 0 (вдоль оси ẑ × ŵ)
    for r in sh.rows:
        assert abs(r["Gamma"] - ln["gamma0"] * np.exp(-r["s"] / 250.0) * dsh) < 1e-9 * ln["gamma0"] * dsh
    assert 0.5 < ln["gamma0"] < 30.0
    # ось ряда у точки отрыва — вдоль +y (ẑ × ŵ при ветре на +x); отрыв за гребнем
    assert np.all(fil.gamma > 0) and np.all(ln["X0"][:, 0] > 100.0)


@gpu
def test_sheet_agnesi_field_and_report(agn):
    sh, sig, info = agn["dec"]
    p, bg, infl = agn["p"], agn["bg"], agn["infl"]
    xs = np.array([300.0, 400.0, 500.0, 700.0])
    zz = p.height(xs, np.zeros(4)) + 10.0
    u1 = sheet3d.velocity_sheet(p, sig, bg, sh, xs, np.zeros(4), zz, 0.1, infl=infl)[0]
    u0 = P.velocity_jh(p, agn["sg"], bg, xs, np.zeros(4), zz, 0.1, infl=infl)[0]
    assert np.all(np.isfinite(u1)) and np.all(u1 < u0)       # слой тормозит течение у земли за гребнем
    ln = sh.lines[0]
    print(f"\nAgnesi gamma_decay=250: iters={info['iters']} residual={info['residual']:.2f} м (tol {sh.stats['tol']:.1f}), "
          f"присоединений {ln['n_reattached']}/{ln['n_cols']}, u∥(10 м) со слоем {np.round(u1, 2)}, без {np.round(u0, 2)}")


@gpu
def test_sheet_agnesi_iterations_converge_with_decay(agn):
    sh, sig, info = agn["dec"]
    assert info["iters"] <= 10 and info["residual"] < 0.05 * sh.params["ds_sheet"]


def stream_height(p, sg, bg, x0, h0, ds=50.0, n=24):
    """Высота над землёй конца линии тока (фон + панели, без слоя) от точки (x0, 0, земля + h0), шаг ds, RK2."""
    from panels3d import influence as I
    pt = np.array([x0, 0.0, float(p.height(np.array([x0]), np.array([0.0]))[0]) + h0])
    for _ in range(n):
        v = np.array([float(a) for a in I.velocity(p, sg, bg, *pt)])
        pm = pt + 0.5 * ds * v / np.linalg.norm(v)
        v2 = np.array([float(a) for a in I.velocity(p, sg, bg, *pm)])
        pt = pt + ds * v2 / np.linalg.norm(v2)
    return float(pt[2] - p.height(np.array([pt[0]]), np.array([0.0]))[0])


@gpu
def test_sheet_agnesi_constant_gamma_report(agn):
    """γ постоянна (контракт v4 по умолчанию): числа итераций и формы слоя — в печать и README; проверяются только
    инварианты (конечность, замкнутость)."""
    sh, sig, info = agn["const"]
    ln = sh.lines[0]
    assert np.all(np.isfinite(ln["nodes"])) and F.imbalance(sh.filaments) <= 1e-12
    print(f"\nAgnesi γ=const (bg_profile): iters={info['iters']} residual={info['residual']:.1f} м, присоединений {ln['n_reattached']}, "
          f"h слоя на 1200 м = {(ln['nodes'][-1, 14, 2] - agn['p'].height(ln['nodes'][-1, 14, 0], 0.0)) / agn['H']:.2f}·H")


@gpu
def test_sheet_streamline_lift_is_bg_profile_not_sheet(agn):
    """Линия тока без слоя от точки Хеда (x = 192 м, h0 = ds/2): при сдвиговом фоне bg_profile поднимается (≈ 58 м на
    x ≈ 1300 м, не зависит от разрешения и фокуса панелей), при bg_uniform идёт за землёй (≈ 13 м). Подъём слоя при
    bg_profile частично свойство фона; при bg_uniform слой с γ = const поднимается сам (нет давления в зоне)."""
    p, bg, infl, sg = agn["p"], agn["bg"], agn["infl"], agn["sg"]
    h_prof = stream_height(p, sg, bg, 192.0, 12.5)
    bu = P.bg_uniform(10.0)
    su, _ = P.solve(p, bu, None, infl)
    h_uni = stream_height(p, su, bu, 192.0, 12.5)
    assert h_prof > 40.0 and h_uni < 25.0
    xs = np.array([300.0, 400.0, 500.0, 700.0])
    zz = p.height(xs, np.zeros(4)) + 10.0
    u0 = P.velocity_jh(p, su, bu, xs, np.zeros(4), zz, 0.1, infl=infl)[0]
    out = {}
    for name, prm in (("const", {}), ("decay250", dict(gamma_decay=250.0))):
        sh, sig, info = sheet3d.build_sheet(p, bu, 0.1, infl, prm)
        ln = sh.lines[0]
        j = ln["nodes"].shape[1] // 2
        h = float(ln["nodes"][20, j, 2] - p.height(ln["nodes"][20, j, 0], ln["nodes"][20, j, 1]))
        u1 = sheet3d.velocity_sheet(p, sig, bu, sh, xs, np.zeros(4), zz, 0.1, infl=infl)[0]
        out[name] = (info["iters"], info["residual"], h, u1)
        assert np.all(u1 < u0)
    assert out["const"][2] > 100.0 and out["decay250"][0] <= 10 and out["decay250"][1] < 0.05 * 50.0
    print(f"\nбез слоя: h(x=1200) bg_profile {h_prof:.0f} м, bg_uniform {h_uni:.0f} м; u∥ без слоя (uniform) {np.round(u0, 2)}")
    for k, (it, rs, h, u1) in out.items():
        print(f"bg_uniform, слой {k}: iters={it} residual={rs:.1f} м, h на ряду 20 {h:.0f} м, u∥(10 м) {np.round(u1, 2)}")


@gpu
def test_sheet_cost_vs_cold_panel_solves(agn):
    """Цена build_sheet (infl готов) ≤ 10 холодных решений панелей того же N."""
    for key in ("dec", "const"):
        t_s = agn[key][2]["t_s"]
        print(f"\n{key}: N={agn['p'].N} слой {t_s:.1f} с, холодное решение {agn['t_cold']:.1f} с, отношение {t_s / agn['t_cold']:.1f}")
        assert t_s / agn["t_cold"] <= 10.0


@gpu
def test_sheet_double_ridge_two_sheets():
    """Два хребта Agnesi через 1500 м (6a): слой за первым и за вторым гребнем."""
    c = agnesi_case(x_c=(0.0, 1500.0), xmax=3000.0, foc_x=((-100.0, 700.0), (1400.0, 2200.0)))
    sh, sig, info = sheet3d.build_sheet(c["p"], c["bg"], 0.1, c["infl"], dict(gamma_decay=250.0))
    xs = sorted(float(ln["X0"][:, 0].mean()) for ln in sh.lines)
    assert info["n_lines"] >= 2
    assert any(100 < v < 700 for v in xs) and any(1600 < v < 2200 for v in xs)
    assert F.imbalance(sh.filaments) <= 1e-12
    print(f"\nдвойной хребет: N={c['p'].N}, линии отрыва x = {np.round(xs)}, iters={info['iters']}, residual={info['residual']:.2f}")
