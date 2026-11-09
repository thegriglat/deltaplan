"""pytest sw_ground/zone (SWG-8): без листа = potential_jh побитно; ровная земля — листа нет; Γ слоёв = Γ тонкого листа;
непрерывность при z = h; профиль u(z) на 10–100 м за гребнем Аньези H/L = 0,5 (числом); сходимость по числу листов."""
import numpy as np
import pytest

import filaments3d as F
from ground import model as M
from sheet import core as SH
from wake import core as W
from wake import synth as S
from zone import core as Z

XS = np.array([-300.0, 150.0, 300.0, 450.0, 600.0, 900.0, 1200.0])


@pytest.fixture(scope="module")
def agnesi():
    r = S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0))
    g = W.WakeGrid(r.terrain, (1.0, 0.0), 25.0)
    geo = SH.SheetGeom(g, r.terrain)
    sep = Z.SepDist(geo)
    thin = SH.Sheet(r, geo, "rest")
    return r, geo, sep, thin, Z.MixSheet(thin, Z.N_LAYERS, sep=sep)


def test_flat_ground_no_sheet():
    import panels3d as P
    x = np.arange(-1000.0, 1000.1, 50.0)
    t = P.Terrain3D(x, x, np.zeros((x.size, x.size)), far_m=3000.0)
    geo = SH.SheetGeom(W.WakeGrid(t, (1.0, 0.0), 50.0), t)
    assert geo.n_nodes == 0 and not geo.segs
    assert np.all(Z.SepDist(geo).D == 0)


def test_no_sheet_bitwise(agnesi):
    r, geo, sep, thin, mx = agnesi
    empty = SH.Sheet(r, geo, "rest", gamma=np.zeros(geo.n_nodes))
    me = Z.MixSheet(empty, 5, sep=sep)
    assert len(me.fil.seg) == 0
    for zagl in (5.0, 10.0, 50.0, 300.0):
        z = r.panels.height(XS, 0 * XS) + zagl
        pj = M.jh_parts(r, XS, 0 * XS, z)
        for s, mode in ((None, "mix"), (empty, "thin"), (me, "mix")):
            q = Z.zone_parts(r, XS, 0 * XS, z, s, sep, mode)
            assert np.array_equal(pj["speed"], q["speed"]) and np.array_equal(pj["speed"], q["speed_sheet"])


def test_layers_same_circulation(agnesi):
    r, geo, sep, thin, mx = agnesi
    _, w = Z.layer_weights(Z.N_LAYERS)
    assert abs(w.sum() - 1) < 1e-12 and np.all(w > 0)
    # Σ|Γ| по отрезкам: каждый слой — копия петель тонкого листа с долей w_k ⇒ сумма та же
    assert abs(np.abs(mx.fil.gamma).sum() / np.abs(thin.fil.gamma).sum() - 1) < 1e-9
    assert F.imbalance(mx.fil) < 1e-9 * max(1.0, float(np.abs(mx.fil.gamma).max()))
    one = Z.MixSheet(thin, 1, sep=sep)                       # один слой — тонкий лист
    assert np.allclose(one.fil.x, thin.fil.x) and np.allclose(one.fil.gamma, thin.fil.gamma)


def test_continuity_and_reverse(agnesi):
    r, geo, sep, thin, mx = agnesi
    xs = np.array([300.0, 450.0])
    h = geo.zone_height(xs, 0 * xs)
    zg = r.panels.height(xs, 0 * xs)
    lo = Z.zone_parts(r, xs, 0 * xs, zg + h - 0.05, mx, sep, "mix")
    hi = Z.zone_parts(r, xs, 0 * xs, zg + h + 0.05, mx, sep, "mix")
    assert lo["under"].all() and not hi["under"].any()
    assert np.max(np.abs(lo["speed"] - hi["speed"]) / hi["speed"]) < 0.02
    q = Z.zone_parts(r, xs, 0 * xs, zg + 5.0, mx, sep, "mix")
    assert np.all(q["ur"] <= Z.C_MAX * q["Ue"] + 1e-12)
    assert np.any(q["u_par"] < 0)                             # обратный поток у пола зоны


def test_zone_profile_mass_balance():
    """Без ограничения сверху ∫ u∥ dz = 0 по [z0, h] (правило — ψ = 0 на полу и оболочке)."""
    z0, h, d = 0.1, 40.0, 20.0
    zq = np.linspace(z0, h, 4001)
    u, ur, cap = Z.zone_profile(zq, np.full(zq.size, h), np.full(zq.size, d), np.full(zq.size, 3.0),
                                np.full(zq.size, 100.0), z0)
    assert not cap.any() and 0 < ur[0] < 3.0
    assert abs(np.trapezoid(u, zq)) / (3.0 * h) < 2e-3


def test_agnesi_profile_numbers(agnesi):
    """H 125, a 250 м: 10–100 м за гребнем (x = 300, 450 м). zone_jh: 10 м — < 0,15 potential_jh; 50 м — дефицит
    слоя смешения (< 0,95 potential_jh, у тонкого листа ≥ 1,0); 100 м — |Δ| < 10 %; перед холмом и за 1200 м — < 3 %."""
    r, geo, sep, thin, mx = agnesi
    k = {x: i for i, x in enumerate(XS)}
    out = {}
    for zagl in (10.0, 50.0, 100.0):
        z = r.panels.height(XS, 0 * XS) + zagl
        pj = M.jh_parts(r, XS, 0 * XS, z)["speed"]
        q = Z.zone_parts(r, XS, 0 * XS, z, mx, sep, "mix")
        qt = Z.zone_parts(r, XS, 0 * XS, z, thin, sep, "thin")
        out[zagl] = (q["speed"] / pj, qt["speed_sheet"] / pj)
    for x in (300.0, 450.0):
        assert out[10.0][0][k[x]] < 0.15
        assert out[50.0][0][k[x]] < 0.95 and out[50.0][1][k[x]] >= 0.98
        assert abs(out[100.0][0][k[x]] - 1) < 0.10
    for x in (-300.0, 1200.0):
        assert abs(out[10.0][0][k[x]] - 1) < 0.03


def test_layer_convergence(agnesi):
    """s(N) за гребнем на 10–100 м: |s(7) − s(9)|/s(9) < 5 % (zone_jh), убывает с N."""
    r, geo, sep, thin, mx = agnesi
    xs = np.array([300.0, 450.0, 600.0])
    X, Zg = np.meshgrid(xs, np.array([10.0, 30.0, 50.0, 100.0]), indexing="ij")
    x, za = X.ravel(), Zg.ravel()
    z = r.panels.height(x, 0 * x) + za
    s = {n: Z.zone_parts(r, x, 0 * x, z, Z.MixSheet(thin, n, sep=sep), sep, "mix")["speed"] for n in (3, 5, 7, 9)}
    d = {n: np.max(np.abs(s[n] - s[9]) / np.maximum(s[9], 0.05 * thin.U_ref)) for n in (3, 5, 7)}
    assert d[7] < 0.05 and d[7] <= d[5] <= d[3]
