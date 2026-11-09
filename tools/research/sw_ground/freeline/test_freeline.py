"""pytest sw_ground/freeline (SWG-12): без зоны = potential_jh побитно; ровная земля — зоны нет; 2D-решение — линия тока
постоянного давления (u' = u_b) с закрытием и касательной у гребня; Аньези H/L 0,5 — форма линии (числом) и профиль
u(z) на 10–100 м за гребнем; баланс ∫u dz = 0."""
import numpy as np
import pytest

from ground import model as M
from sheet import core as SH
from wake import core as W
from wake import synth as S
from zone import core as Z
from freeline import core as FL

XS = np.array([-300.0, 150.0, 300.0, 450.0, 600.0, 1200.0])


@pytest.fixture(scope="module")
def agnesi():
    r = S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0))
    g = W.WakeGrid(r.terrain, (1.0, 0.0), 25.0)
    geo = FL.FreeGeom(g, r.terrain)
    sep = Z.SepDist(geo)
    thin = SH.Sheet(r, geo, "rest")
    geo.set_gamma(thin)
    return r, geo, sep, thin, FL.FreeMix(thin, FL.N_LAYERS, sep=sep)


def test_flat_ground_no_zone():
    import panels3d as P
    x = np.arange(-1000.0, 1000.1, 50.0)
    t = P.Terrain3D(x, x, np.zeros((x.size, x.size)), far_m=3000.0)
    geo = FL.FreeGeom(W.WakeGrid(t, (1.0, 0.0), 50.0), t)
    assert geo.n_nodes == 0 and not geo.segs and np.all(geo.Hfine == 0)


def test_free_solve_2d():
    """Аньези на профиле: u' = u_b на внутренних узлах, η(x_r) = z(x_r), η'(x_s+) = z'(x_s−); u_b < u_sep."""
    ds = 12.5
    s = np.arange(-6000.0, 6000.1, ds)
    z = 125.0 / (1 + (s / 250.0) ** 2)
    K = FL.hilbert(s.size)
    gp = np.diff(z) / ds
    i_s = int(np.argmin(np.abs(s)))
    assert abs((K @ gp)[i_s] - 0.5) < 2e-3                       # линейная теория: u'(0)/U = H/a
    i_r = int(np.argmin(np.abs(s - 750.0)))
    eta, ub, u = FL.free_solve(z, i_s, i_r, K)
    u = u / ds
    ub = ub / ds
    assert np.max(np.abs(u[i_s + 1:i_r] - ub)) < 1e-9
    assert abs(eta[-1] - z[i_r]) < 1e-9 and abs((eta[1] - eta[0]) / ds - gp[i_s - 1]) < 1e-12
    assert np.all(eta - z[i_s:i_r + 1] >= -1e-6) and 0 < ub < (K @ gp)[i_s]


def test_no_zone_bitwise(agnesi):
    r, geo, sep, thin, mx = agnesi
    empty = SH.Sheet(r, geo, "rest", gamma=np.zeros(geo.n_nodes))
    me = FL.FreeMix(empty, 5, sep=sep)
    assert len(me.fil.seg) == 0
    for zagl in (5.0, 10.0, 50.0, 300.0):
        z = r.panels.height(XS, 0 * XS) + zagl
        pj = M.jh_parts(r, XS, 0 * XS, z)
        for s, mode in ((None, "mix"), (empty, "thin"), (me, "mix")):
            q = FL.free_parts(r, XS, 0 * XS, z, s, geo, sep, mode)
            assert np.array_equal(pj["speed"], q["speed"]) and np.array_equal(pj["speed"], q["speed_sheet"])


def test_agnesi_line_shape(agnesi):
    """Ось хребта: x_s = гребень, x_r = 750 м (подножие, правило SWD7 v2), h_max 85–95 м (оболочка SWG-4 — 32 м),
    η не выше гребня более чем на 10 м; 0 < u_b < u_sep."""
    r, geo, sep, thin, mx = agnesi
    q = min(geo.segs, key=lambda q: abs(q["c"]))
    assert abs(q["s_s"]) < 1e-9 and abs(q["s_r"] - 750.0) < 1e-9 and q["rule"] == "rule"
    assert 85.0 < q["hmax"] < 95.0 and 0 < q["bulge"] < 10.0
    assert 0 < q["u_b"] < q["u_sep"] and not q["neg"]
    h = geo.zone_height(np.array([300.0, 450.0]), np.zeros(2))
    assert np.all(h > 75.0)


def test_agnesi_profile_and_balance(agnesi):
    """10 м за гребнем (x 300, 450): free_jh < 0,35 potential_jh; 100 м — дефицит (< 0,97; 0,95 и 0,78); перед холмом и за 1200 м — < 8 % (5,6 и 5,8 %: поле листа);
    скачок u∥ при z = h < 2 %; ∫u dz = 0 (без предела)."""
    r, geo, sep, thin, mx = agnesi
    k = {x: i for i, x in enumerate(XS)}
    for zagl, lim in ((10.0, 0.35), (100.0, 0.97)):
        z = r.panels.height(XS, 0 * XS) + zagl
        pj = M.jh_parts(r, XS, 0 * XS, z)["speed"]
        q = FL.free_parts(r, XS, 0 * XS, z, mx, geo, sep, "mix")
        rr = q["speed"] / pj
        for x in (300.0, 450.0):
            assert rr[k[x]] < lim
        if zagl == 10.0:
            for x in (-300.0, 1200.0):
                assert abs(rr[k[x]] - 1) < 0.08
    xs = np.array([300.0, 450.0])
    h = geo.zone_height(xs, 0 * xs)
    zg = r.panels.height(xs, 0 * xs)
    lo = FL.free_parts(r, xs, 0 * xs, zg + h - 0.05, mx, geo, sep, "mix")
    hi = FL.free_parts(r, xs, 0 * xs, zg + h + 0.05, mx, geo, sep, "mix")
    assert lo["under"].all() and not hi["under"].any()
    assert np.max(np.abs(lo["u_par"] - hi["u_par"]) / np.abs(hi["u_par"])) < 0.02
    q = FL.free_parts(r, xs, 0 * xs, zg + 5.0, mx, geo, sep, "mix")
    assert not q["capped"].any() and np.all(np.abs(q["resid"]) < 1e-6) and np.all(q["u_par"] < 0)


def test_delta_cap():
    core = 12.5
    d = FL.delta_cap(np.array([0.0, 50.0, 300.0, 300.0]), np.array([100.0, 100.0, 100.0, 5.0]), core)
    assert np.allclose(d, [12.5, 50.0, 93.75, 12.5])
