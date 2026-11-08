"""Тесты rotor3d (SWD7 v1): нить ротора с геометрическим замыканием. Результат модели — в README."""
import time

import numpy as np
import pytest

import filaments3d as F
import panels3d as P
import rotor3d
from rotor3d import rotor as R


def raster(f, hx, hy, step):
    x = np.arange(-hx, hx + 0.1, step)
    y = np.arange(-hy, hy + 0.1, step)
    X, Y = np.meshgrid(x, y)
    return x, y, f(X, Y)


def same_as_jh(p, sig, bg, fil, infl=None):
    pts = (np.array([0.0, 150.0, 400.0]), np.array([0.0, 20.0, -30.0]), np.array([160.0, 130.0, 70.0]))
    a = rotor3d.velocity_rotor(p, sig, bg, fil, *pts, 0.1, infl=infl)
    b = P.velocity_jh(p, sig, bg, *pts, 0.1, infl=infl)
    return all(np.array_equal(u, v, equal_nan=True) for u, v in zip(a, b))


# ---------- правило геометрии по профилю (без панелей) ----------
def test_profile_rule_foot_tail_valley():
    s = np.arange(-3000, 3000.1, 12.5)
    ds = 25.0
    # Agnesi: минимума за гребнем нет — подножие по остатку 10 % высоты, x_m — середина
    za = 125.0 / (1 + (s / 250.0) ** 2)
    r = R.profile_rule(s, za, ds)
    assert r["rule_r"] == "foot" and abs(r["s_c"]) < 1e-9
    assert abs(r["s_r"] - 750.0) < 40.0 and abs(r["s_m"] - 0.5 * r["s_r"]) < 1e-9
    assert r["slope_m"] < 0 and r["slope_lee"] > 0.27
    # два гребня через 3L: середина долины ближе, чем подножие (первый минимум) — минимум стоит посередине
    zd = 125.0 * (1 / (1 + (s / 250.0) ** 2) + 1 / (1 + ((s - 750.0) / 250.0) ** 2))
    r2 = R.profile_rule(s, zd, ds)
    assert r2["rule_r"] in ("foot", "valley_mid") and 0 < r2["s_r"] <= 400.0      # не дальше середины между гребнями
    # гребень с настоящим подножием (гаусс на плато), минимум — первый за гребнем
    zg = 100.0 * np.exp(-s ** 2 / (2 * 200.0 ** 2)) + 30.0 * np.exp(-(s - 1500) ** 2 / (2 * 100.0 ** 2))
    r3 = R.profile_rule(s, zg, ds)
    assert r3["rule_r"] == "valley_mid" or r3["rule_r"] == "foot"
    assert r3["s_r"] > r3["s_c"] and r3["s_c"] == pytest.approx(0.0, abs=1e-9)
    # без гребня правила нет
    assert R.profile_rule(s, 0.0 * s, ds) is None


# ---------- ровная земля и гаусс H/L 0,1: нити нет, поле = velocity_jh побитно ----------
def test_flat_and_gauss_no_filament_field_equals_jh_bitwise():
    x, y, z = raster(lambda X, Y: np.zeros_like(X), 1000, 1000, 50.0)
    tf = P.Terrain3D(x, y, z, far_m=3000)
    pf = P.build_panels(tf, focus=[(0, 0)], ds_min=100.0, focus_r=400)
    bgf = P.bg_profile(10.0, 0.2, 200.0, tf)
    fil, sig, info = rotor3d.rotor_vortex(pf, bgf, 0.1)
    assert len(fil.seg) == 0 and info["n_ridges"] == 0 and F.imbalance(fil) == 0.0
    assert same_as_jh(pf, sig, bgf, fil)

    sg_, H = 300.0, 0.1 * 1.177 * 300.0
    x, y, z = raster(lambda X, Y: H * np.exp(-(X ** 2 + Y ** 2) / (2 * sg_ ** 2)), 700, 500, 25.0)
    tg = P.Terrain3D(x, y, z, far_m=3000)
    foc = [(a_, b_) for a_ in np.arange(-300, 301, 150.0) for b_ in np.arange(-300, 301, 150.0)]
    pg = P.build_panels(tg, focus=foc, ds_min=40.0, focus_r=90, ds_max=500, growth=1.5)
    bgg = P.bg_profile(10.0, 0.2, 200.0, tg)
    fil, sig, info = rotor3d.rotor_vortex(pg, bgg, 0.1)
    assert len(fil.seg) == 0 and info["n_unconverged"] == 0 and info["ridges"] == []     # порог Хеда не пройден
    assert all(not c["head"] for c in info["candidates"])
    assert same_as_jh(pg, sig, bgg, fil)


# ---------- хребет Agnesi H/L 0,5 ----------
A_AG, H_AG, DS_AG = 250.0, 125.0, 50.0


@pytest.fixture(scope="module")
def agnesi():
    x, y, z = raster(lambda X, Y: H_AG / (1 + (X / A_AG) ** 2), 1500, 750, DS_AG / 2)
    t = P.Terrain3D(x, y, z, far_m=4000)
    foc = [(xx, yy) for xx in np.arange(-100, 700, 2 * DS_AG) for yy in np.arange(-750, 751, 3 * DS_AG)]
    p = P.build_panels(t, focus=foc, ds_min=DS_AG, focus_r=2.8 * DS_AG, ds_max=600, growth=1.6)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    t0 = time.time()
    infl = P.assemble(p)
    sg, _ = P.solve(p, bg, None, infl)
    t_cold = time.time() - t0
    t0 = time.time()
    P.solve(p, bg, None, infl)
    t_warm = time.time() - t0
    return dict(t=t, p=p, bg=bg, infl=infl, t_cold=t_cold, t_warm=t_warm, sg=sg)


@pytest.fixture(scope="module")
def ag_contract(agnesi):
    """Правило SWD7 как в контракте (x_m — середина x_c…x_r)."""
    return rotor3d.rotor_vortex(agnesi["p"], agnesi["bg"], 0.1, agnesi["infl"], {})


@pytest.fixture(scope="module")
def ag_shifted(agnesi):
    """Диагностика: x_m = x_c + 0,3·(x_r − x_c) — единственное отличие от контракта (params m_frac)."""
    return rotor3d.rotor_vortex(agnesi["p"], agnesi["bg"], 0.1, agnesi["infl"], dict(m_frac=0.3))


def test_agnesi_contract_rule_has_no_root(agnesi, ag_contract):
    """Результат: при x_m посередине корня (R > 0, Γ > 0) нет — касательная скорость у подножия остаётся
    отрицательной (перелёт) при любом R; нить не ставится, поле = velocity_jh побитно."""
    fil, sig, info = ag_contract
    assert info["n_ridges"] == 1 and info["candidates"][0]["head"]            # порог Хеда пройден
    r = info["ridges"][0]
    assert r["rule_r"] == "foot" and r["gate"] == "head"
    assert abs(r["x_c"]) < 1.0 and r["x_r"] > 400.0 and abs(r["x_m"] - 0.5 * (r["x_c"] + r["x_r"])) < 1e-9
    assert not r["converged"] and info["n_unconverged"] == 1 and len(fil.seg) == 0
    g = [v for _, v in r["grid"]]
    assert max(g) < -0.3, g           # (u_t в x_r при u_t(x_c)=0)/U < 0 на всей сетке R
    assert r["ut_bg"][0] > 10.0 and 0 < r["ut_bg"][1] < 0.4 * r["ut_bg"][0]     # u_t фона: гребень ≫ подножие
    assert np.array_equal(sig, agnesi["sg"])
    assert same_as_jh(agnesi["p"], sig, agnesi["bg"], fil, agnesi["infl"])
    print(f"\nAgnesi (контракт): u_t фона гребень/подножие {r['ut_bg'][0]:.1f}/{r['ut_bg'][1]:.1f} м/с, "
          f"g(R) = {[(round(a, 2), round(float(v), 2)) for a, v in r['grid']]}")


def test_linear_in_gamma_matches_direct_solve(agnesi):
    """Скорость на станциях линейна по Γ: a + Γ·b (b — одно решение единичной нити при фоне 0) = прямое решение
    с нитью Γ при фоне bg; на этом держится 1-D поиск R."""
    p, bg = agnesi["p"], agnesi["bg"]
    ridges = R._fp.find_ridges(agnesi["t"], (1.0, 0.0), DS_AG)
    ridge = ridges[0]
    ax = R._fp._axis_of(ridge, (1.0, 0.0), ridge["dc"])
    Pc = ax["c0"] + 0.5 * (ax["t0"] + ax["t1"]) * ax["a"]
    from panels3d.jh import _line_profile
    s, z = _line_profile(agnesi["t"], float(Pc[0]), float(Pc[1]), 1.0, 0.0, DS_AG / 2)
    rule = R.profile_rule(s, z, DS_AG, 0.0, 0.1, 0.3)
    U = P.terrain.u_ref_of(bg, agnesi["t"])[0] if hasattr(P, "terrain") else 15.0
    ob = R._Rotor(p, bg, ridge, (1.0, 0.0), U, 0.5 * DS_AG, 2 * DS_AG, 1.5, rule)
    a = np.array([ob.tangent(st, agnesi["sg"], None) for st in ob.st])
    b, _ = ob.unit(100.0, agnesi["infl"], P.bg_zero())
    s_, h_ = ob.geometry(100.0)
    G = 3000.0
    fil = ob.build(s_, h_, G)
    extra = R._fp._induced_fn(fil)
    sig, _ = P.solve(p, bg, extra, agnesi["infl"])
    direct = np.array([ob.tangent(st, sig, extra) for st in ob.st])
    assert np.allclose(direct, a + G * b, rtol=1e-6, atol=1e-6 * abs(G * b).max())


def test_agnesi_shifted_root_closes_both_stagnation_points(agnesi, ag_shifted):
    """С x_m = x_c + 0,3·(x_r − x_c) корень есть: |u_t| в x_c и x_r ≤ 1e-3·U (проверка независимым решением
    панелей с итоговой нитью), нить замкнута, Γ > 0. Размер Γ/(U·H) — в README (физически велик)."""
    fil, sig, info = ag_shifted
    r = info["ridges"][0]
    assert r["converged"] and r["Gamma"] > 0 and r["R"] > 0 and len(fil.seg) > 0
    assert F.imbalance(fil) <= 1e-12 and fil.anchored.sum() == 2
    p, bg = agnesi["p"], agnesi["bg"]
    extra = R._fp._induced_fn(fil)
    sig2, _ = P.solve(p, bg, extra, agnesi["infl"])
    assert np.allclose(sig, sig2, rtol=1e-6, atol=1e-6 * np.abs(sig2).max())          # линейность: σ без нового решения
    ridges = R._fp.find_ridges(agnesi["t"], (1.0, 0.0), DS_AG)
    from panels3d.jh import _line_profile
    ax = R._fp._axis_of(ridges[0], (1.0, 0.0), ridges[0]["dc"])
    Pc = ax["c0"] + 0.5 * (ax["t0"] + ax["t1"]) * ax["a"]
    s, z = _line_profile(agnesi["t"], float(Pc[0]), float(Pc[1]), 1.0, 0.0, DS_AG / 2)
    rule = R.profile_rule(s, z, DS_AG, 0.0, 0.1, 0.3)
    U, _ = __import__("panels3d.terrain", fromlist=["u_ref_of"]).u_ref_of(bg, agnesi["t"])
    ob = R._Rotor(p, bg, ridges[0], (1.0, 0.0), U, 0.5 * DS_AG, 2 * DS_AG, 1.5, rule)
    ut = [ob.tangent(st, sig2, extra) for st in ob.st]
    assert max(abs(v) for v in ut) <= 1e-3 * U, ut
    # обратный u∥ у земли между x_c и x_r (10 м над землёй, на оси)
    xs = np.linspace(r["x_c"] + 20.0, r["x_r"] - 20.0, 12)
    zg = agnesi["t"].height(xs, np.zeros_like(xs)) + 10.0
    u, v, w = rotor3d.velocity_rotor(p, sig, bg, fil, xs, np.zeros_like(xs), zg, 0.1, infl=agnesi["infl"])
    print(f"\nAgnesi (x_m=0,3): R={r['R']:.1f} м, Γ={r['Gamma']:.0f} м²/с = {r['Gamma'] / (U * r['H']):.1f}·U·H, "
          f"u∥(10 м) min {np.nanmin(u):.1f} max {np.nanmax(u):.1f}, x_r={r['x_r']:.0f}, ut={np.round(ut, 4)}")
    assert np.nanmin(u) < 0


def test_cost_in_panel_solves(agnesi, ag_shifted, ag_contract):
    """Цена ≤ 5 решений панелей того же N (по кешу LU): число решений и время относительно решения с нитью."""
    for name, (fil, sig, info) in (("корень", ag_shifted), ("без корня", ag_contract)):
        assert info["nsolve"] <= 5, (name, info["nsolve"])
    p, bg = agnesi["p"], agnesi["bg"]
    fil = ag_shifted[0]
    t0 = time.time()
    P.solve(p, bg, R._fp._induced_fn(fil), agnesi["infl"])
    t_one = time.time() - t0
    t_r = ag_shifted[2]["t_s"]
    print(f"\nN={p.N}: rotor_vortex {t_r:.1f} с (решений {ag_shifted[2]['nsolve']}), одно решение с нитью {t_one:.2f} с "
          f"(≈ {t_r / t_one:.1f}), холодное {agnesi['t_cold']:.1f} с, тёплое без нити {agnesi['t_warm']:.3f} с")
