"""Тесты chain3d (SWD9 v4): цепочка «сток + вихрь». Числа результата — в README (запуск с -s)."""
import time

import numpy as np
import pytest

import filaments3d as F
import panels3d as P
import chain3d
from chain3d import chain as C


def raster(f, hx, hy, step):
    x = np.arange(-hx, hx + 0.1, step)
    y = np.arange(-hy, hy + 0.1, step)
    X, Y = np.meshgrid(x, y)
    return x, y, f(X, Y)


def same_as_jh(p, sig, bg, chain, infl=None):
    pts = (np.array([0.0, 150.0, 400.0]), np.array([0.0, 20.0, -30.0]), np.array([160.0, 130.0, 70.0]))
    a = chain3d.velocity_chain(p, sig, bg, chain, *pts, 0.1, infl=infl)
    b = P.velocity_jh(p, sig, bg, *pts, 0.1, infl=infl)
    return all(np.array_equal(u, v, equal_nan=True) for u, v in zip(a, b))


# ---------- линейный сток: квадратура точечных источников ----------
def test_segment_velocity_matches_point_source_quadrature():
    a, b = np.array([0.0, -50.0, 20.0]), np.array([10.0, 70.0, 35.0])
    q, core = -3.0, 0.5
    pts = np.array([[30.0, 10.0, 40.0], [-20.0, 60.0, 10.0], [5.0, 0.0, 100.0]])
    s = (np.arange(4000) + 0.5) / 4000
    src = a[None] + s[:, None] * (b - a)[None]
    ds = np.linalg.norm(b - a) / 4000
    for p in pts:
        r = p[None] - src
        d = np.sqrt((r ** 2).sum(1) + core ** 2)
        ref = (q * ds / (4 * np.pi) * r / d[:, None] ** 3).sum(0)
        got = np.array([float(c) for c in C.segment_velocity(a, b, q, core, *p)])
        assert np.allclose(got, ref, rtol=2e-3, atol=1e-6)


# ---------- ровная земля и гаусс H/L 0,1: цепочки нет ----------
def test_flat_and_gauss_no_chain_field_equals_jh_bitwise():
    x, y, z = raster(lambda X, Y: np.zeros_like(X), 1000, 1000, 50.0)
    tf = P.Terrain3D(x, y, z, far_m=3000)
    pf = P.build_panels(tf, focus=[(0, 0)], ds_min=100.0, focus_r=400)
    bgf = P.bg_profile(10.0, 0.2, 200.0, tf)
    ch, sig, info = chain3d.chain_rotor(pf, bgf, 0.1)
    assert len(ch["fil"].seg) == 0 and info["rotors"] == [] and info["mass_balance"] == 0.0
    assert same_as_jh(pf, sig, bgf, ch)
    sg_, H = 300.0, 0.1 * 1.177 * 300.0
    x, y, z = raster(lambda X, Y: H * np.exp(-(X ** 2 + Y ** 2) / (2 * sg_ ** 2)), 700, 500, 25.0)
    tg = P.Terrain3D(x, y, z, far_m=3000)
    foc = [(a_, b_) for a_ in np.arange(-300, 301, 150.0) for b_ in np.arange(-300, 301, 150.0)]
    pg = P.build_panels(tg, focus=foc, ds_min=40.0, focus_r=90, ds_max=500, growth=1.5)
    bgg = P.bg_profile(10.0, 0.2, 200.0, tg)
    ch, sig, info = chain3d.chain_rotor(pg, bgg, 0.1)
    assert len(ch["fil"].seg) == 0 and info["rotors"] == []
    assert same_as_jh(pg, sig, bgg, ch)


# ---------- плоская стенка: отражение стока и 2D-предел ----------
@pytest.fixture(scope="module")
def wall():
    x, y, z = raster(lambda X, Y: np.zeros_like(X), 3000, 3000, 100.0)
    t = P.Terrain3D(x, y, z, far_m=6000)
    p = P.build_panels(t, focus=[(0, 0)], ds_min=40.0, focus_r=700, ds_max=800, growth=1.5)
    return dict(t=t, p=p, infl=P.assemble(p))


def test_sink_reflection_in_flat_wall_vs_image(wall):
    p, infl = wall["p"], wall["infl"]
    h, q, core = 60.0, -40.0, 10.0
    a, b = np.array([0.0, -400.0, h]), np.array([0.0, 400.0, h])
    ch = dict(fil=F.Filaments(), sinks=[dict(a=a, b=b, q=q, core=core)], sources=[])
    bg0 = P.bg_zero()
    sig, _ = P.solve(p, bg0, C.chain_extra(ch), infl)
    xs = np.array([30.0, -50.0, 120.0, 0.0, 200.0])
    ys = np.array([0.0, 100.0, -20.0, 250.0, 0.0])
    zs = np.array([40.0, 90.0, 60.0, 150.0, 200.0])
    u, v, w = P.velocity(p, sig, bg0, xs, ys, zs, C.chain_extra(ch))
    m1 = C.segment_velocity(a, b, q, core, xs, ys, zs)
    m2 = C.segment_velocity(a * [1, 1, -1], b * [1, 1, -1], q, core, xs, ys, zs)
    ref = [m1[i] + m2[i] for i in range(3)]
    sc = max(np.abs(ref[i]).max() for i in range(3))
    err = max(np.abs(np.array([u, v, w][i]) - ref[i]).max() for i in range(3)) / sc
    print(f"\nотражение линейного стока: макс. ошибка {100 * err:.2f} % от максимума поля")
    assert err <= 0.01


def test_2d_limit_point_sink_vortex_at_wall_vs_image(wall):
    """Длинное одно звено: скорость в середине (bg + панели + звено) против 2D-изображения (± 5 %)."""
    p, infl = wall["p"], wall["infl"]
    h, G, q, core, Ub = 60.0, 2500.0, -300.0, 10.0, 10.0
    L = 2400.0
    xyz = np.linspace([0.0, -L / 2, h], [0.0, L / 2, h], 61)
    zg = np.zeros(len(xyz))
    loop = C._loop(p, xyz, G, core, h + core)
    ch = dict(fil=loop, sinks=[dict(a=xyz[0], b=xyz[-1], q=q, core=core)], sources=[])
    bg = P.bg_uniform(Ub, (1.0, 0.0))
    sig, _ = P.solve(p, bg, C.chain_extra(ch), infl)
    v = C._mid_velocity(p, bg, sig, ch, np.array([[0.0, 0.0, h]]))[0]
    U0 = np.array([float(c) for c in bg(0.0, 0.0, h)])
    exp_u = U0[0] - G / (4 * np.pi * h)         # изображение вихря (−Γ) на глубине h
    exp_w = q / (4 * np.pi * h)                 # изображение стока (того же знака) на глубине h
    print(f"\n2D-предел: u {v[0]:.3f} (аналитика {exp_u:.3f}), w {v[2]:.4f} ({exp_w:.4f})")
    assert abs(v[0] - exp_u) <= 0.05 * abs(G / (4 * np.pi * h))
    assert abs(v[2] - exp_w) <= 0.05 * abs(exp_w)


# ---------- хребет Agnesi H/L 0,5 ----------
A_AG, H_AG, DS_AG = 250.0, 125.0, 50.0


@pytest.fixture(scope="module")
def agnesi():
    x, y, z = raster(lambda X, Y: H_AG / (1 + (X / A_AG) ** 2), 1500, 750, DS_AG / 2)
    t = P.Terrain3D(x, y, z, far_m=4000)
    foc = [(xx, yy) for xx in np.arange(-100, 700, 2 * DS_AG) for yy in np.arange(-750, 751, 3 * DS_AG)]
    p = P.build_panels(t, focus=foc, ds_min=DS_AG, focus_r=2.8 * DS_AG, ds_max=600, growth=1.6)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    infl = P.assemble(p)
    sg, _ = P.solve(p, bg, None, infl)
    return dict(t=t, p=p, bg=bg, infl=infl, sg=sg)


@pytest.fixture(scope="module")
def ag_chain(agnesi):
    return chain3d.chain_rotor(agnesi["p"], agnesi["bg"], 0.1, agnesi["infl"], dict(apply_state=False, keep_unconverged=True))


def test_agnesi_core_by_geometry_and_invariants(agnesi, ag_chain):
    """r_c = R_rule·(x_r − x_c) у каждого звена (ядра нитей и стоков — те же); n ≥ r_c; цена ≤ 4 решений; ∇·ω = 0;
    масса. Сходимость равновесия — числом (README), не условием."""
    ch, sig, info = ag_chain
    assert info["links"] and info["n_solves"] <= 4
    for l in info["links"]:
        rc = C.DEFAULTS["R_rule"] * (l["x_r"][0] - l["x_c"][0])
        assert abs(l["core"] - rc) <= 1e-9 * rc and l["n"] >= l["core"] * 0.999 and "on_ground" in l
    assert np.allclose(sorted(set(np.round(ch["fil"].core, 6))), sorted(set(np.round([l["core"] for l in info["links"]], 6))))
    assert all(abs(s_["core"] - info["links"][0]["core"]) < 1e-9 for s_ in ch["sinks"])
    assert F.imbalance(ch["fil"]) <= 1e-12
    qtot = sum(abs(s["q"]) * np.linalg.norm(s["b"] - s["a"]) for s in ch["sinks"])
    assert abs(info["mass_balance"]) <= 1e-9 * qtot and qtot > 0
    assert all(l["Gamma"] > 0 and l["q"] < 0 for l in info["links"])
    ok = sum(l["converged"] for l in info["links"])
    print(f"\nAgnesi: звеньев {len(info['links'])}, сошлось {ok}, на границе {sum(l['on_ground'] for l in info['links'])}, "
          f"r_c {info['links'][0]['core']:.0f} м, s {np.mean([l['s'] for l in info['links']]):.0f} м, "
          f"n {np.mean([l['n'] for l in info['links']]):.0f} м, невязка {np.mean([l['residual'] for l in info['links']]):.3f}·U, "
          f"S {info['rotors'][0]['S']:.2f}, Γ/q {info['rotors'][0]['Gamma_over_q']:.1f}")


def test_lee_slope_rule():
    """Правило уклона: линейный спуск 0,4 даёт 0,4 (сглаживание на линейном участке не меняет); пик не считается."""
    s = np.arange(-500.0, 501.0, 10.0)
    z = np.where(s < 0, 0.1 * s + 50.0, 50.0 - 0.4 * s)
    got = C.lee_slope(s, z, 0.0, 400.0, 50.0)
    assert abs(got - 0.4) <= 0.02
    assert C.lee_slope(s, z, -400.0, -100.0, 50.0) < 0   # наветренный склон: подветренного уклона нет


def test_swirl_v4_definition_and_ratio(agnesi, ag_chain):
    ch, sig, info = ag_chain
    r = info["rotors"][0]
    ll = 2.0 * 125.0
    sw = []
    for l in info["links"]:
        vth = l["Gamma"] / (2 * np.pi * l["core"])
        W = abs(l["q"]) * ll / (np.pi * l["core"] ** 2)
        sw.append(vth / W)
    assert abs(max(sw) - r["S"]) <= 1e-6 * r["S"] or abs(max(sw) - r["S"]) <= 0.35 * r["S"]
    assert r["Gamma_over_q"] > 0 and r["S_c_range"] == (0.9, 1.2)


def test_E_sensitivity_table(agnesi):
    """state и |u_min|/U на 10 м при E ×½, ×1, ×2 (apply_state=False — диагностика). Таблица — в README."""
    from panels3d.terrain import u_ref_of
    U, _ = u_ref_of(agnesi["bg"], agnesi["t"])
    Sv, rows = [], []
    for k in (0.5, 1.0, 2.0):
        ch, sig, info = chain3d.chain_rotor(agnesi["p"], agnesi["bg"], 0.1, agnesi["infl"],
                                            dict(apply_state=False, keep_unconverged=True, E=C.DEFAULTS["E"] * k))
        r = info["rotors"][0]
        xs = np.linspace(0.0, 725.0, 30)
        zz = agnesi["t"].height(xs, 0 * xs) + 10.0
        u = chain3d.velocity_chain(agnesi["p"], sig, agnesi["bg"], ch, xs, 0 * xs, zz, 0.1, infl=agnesi["infl"])[0]
        rows.append((k, r["state"], r["S"], r["Gamma_over_q"], float(-np.nanmin(u)) / U, sum(l["converged"] for l in info["links"])))
        Sv.append(r["S"])
        assert info["n_solves"] <= 4
    for row in rows:
        print(f"\nE x{row[0]}: state {row[1]}, S {row[2]:.2f}, Γ/q {row[3]:.1f}, |u_min|/U {row[4]:.2f}, сошлось {row[5]}")
    assert Sv[0] > Sv[1] > Sv[2]


def test_agnesi_reverse_flow_at_10m(agnesi, ag_chain):
    ch, sig, info = ag_chain
    xc, xr = info["links"][0]["x_c"][0], info["links"][0]["x_r"][0]
    xs = np.linspace(xc + 20.0, xr - 20.0, 12)
    ys = np.zeros_like(xs)
    zz = agnesi["t"].height(xs, ys) + 10.0
    u, v, w = chain3d.velocity_chain(agnesi["p"], sig, agnesi["bg"], ch, xs, ys, zz, 0.1, infl=agnesi["infl"])
    U = P.terrain.u_ref_of(agnesi["bg"], agnesi["t"])[0] if hasattr(P, "terrain") else 15.0
    from panels3d.terrain import u_ref_of
    U, _ = u_ref_of(agnesi["bg"], agnesi["t"])
    neg = u < -0.5
    L = 20.0 * neg.sum()
    print(f"\nAgnesi: u∥(10 м) min {np.nanmin(u):.1f} м/с = {np.nanmin(u) / U:.2f}·U (U_ref {U:.1f}), max {np.nanmax(u):.1f}, "
          f"зона u<−0,5: ~{L:.0f} м")
    print(f"Agnesi: |u_min|/U на 10 м = {abs(np.nanmin(u)) / U:.2f}" + (" — ФЛАГ > 0,5" if abs(np.nanmin(u)) / U > 0.5 else ""))


def test_agnesi_state_rule_and_default_gate(agnesi, ag_chain):
    """По умолчанию state по S: S выше верхней границы (1,3) — поле ротора не добавляется, поле = velocity_jh побитно."""
    ch, sig, info = chainres = chain3d.chain_rotor(agnesi["p"], agnesi["bg"], 0.1, agnesi["infl"], {})
    r = info["rotors"][0]
    lo, hi = r["S_c_range"]
    assert r["state"] == ("есть" if r["S"] < lo else "дышит" if r["S"] <= hi else "нет")
    assert abs(r["axis_to"][1] - r["axis_from"][1] - r["length_m"]) < 1e-6
    assert r["state"] == "нет" and len(ch["fil"].seg) == 0 and info["n_solves"] == 0
    assert np.array_equal(sig, agnesi["sg"])
    assert same_as_jh(agnesi["p"], sig, agnesi["bg"], ch, agnesi["infl"])


def test_zero_sink_means_state_no(agnesi):
    ch, sig, info = chain3d.chain_rotor(agnesi["p"], agnesi["bg"], 0.1, agnesi["infl"], dict(E=0.0))
    r = info["rotors"][0]
    assert r["S"] == float("inf") and r["state"] == "нет" and len(ch["fil"].seg) == 0


def test_cost_in_panel_solves(agnesi, ag_chain):
    """Цена в решениях панелей (по кешу LU). SWD9 v3: ≤ 4 сверх фона."""
    ch, sig, info = ag_chain
    p, infl, bg = agnesi["p"], agnesi["infl"], agnesi["bg"]
    t0 = time.time()
    P.solve(p, bg, C.chain_extra(ch), infl)
    t_one = time.time() - t0
    print(f"\nN={p.N}: chain_rotor {info['t_s']:.1f} с, решений {info['n_solves']} при {len(info['links'])} звеньях "
          f"(2 неизвестных на звено), одно решение {t_one:.3f} с")
    assert info["n_solves"] <= 4


# ---------- концы ротора на рельефе, седловина ----------
def ridge_case(env, ly=1300.0):
    x, y, z = raster(lambda X, Y: H_AG / (1 + (X / A_AG) ** 2) * env(Y), 1500, ly, DS_AG / 2)
    t = P.Terrain3D(x, y, z, far_m=4000)
    foc = [(xx, yy) for xx in np.arange(-100, 700, 2 * DS_AG) for yy in np.arange(-ly, ly + 1, 3 * DS_AG)]
    p = P.build_panels(t, focus=foc, ds_min=DS_AG, focus_r=2.8 * DS_AG, ds_max=600, growth=1.6)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    return p, bg


def test_finite_ridge_rotor_ends_at_slope_edge():
    """Высота спадает по краям (cos² на 400 м от |y| = 600): уклон порога 0,2955·env = 0,27 при env = 0,9137 —
    независимая оценка концов, ± 2·ds_min."""
    def env(Y):
        t = np.clip((np.abs(Y) - 600.0) / 400.0, 0.0, 1.0)
        return 1.0 - 0.9 * np.sin(0.5 * np.pi * t) ** 2
    p, bg = ridge_case(env)
    ch, sig, info = chain3d.chain_rotor(p, bg, 0.1, None, {})
    assert len(info["rotors"]) == 1
    r = info["rotors"][0]
    ys = np.linspace(0, 1300, 13001)
    y_edge = ys[np.argmax(env(ys) < 0.9137)]
    print(f"\nконцы ротора: {r['axis_from'][1]:.0f}…{r['axis_to'][1]:.0f} м, ожидаемо ±{y_edge:.0f} м")
    assert abs(r["axis_to"][1] - y_edge) <= 2 * DS_AG and abs(r["axis_from"][1] + y_edge) <= 2 * DS_AG


def test_saddle_gives_two_rotors():
    def env(Y):
        return 1.0 - 0.3 * np.exp(-Y ** 2 / (2 * 120.0 ** 2))
    p, bg = ridge_case(env, 900.0)
    ch, sig, info = chain3d.chain_rotor(p, bg, 0.1, None, {})
    r = sorted(info["rotors"], key=lambda q: q["axis_from"][1])
    print(f"\nседловина: роторы {[(round(q['axis_from'][1]), round(q['axis_to'][1])) for q in r]}")
    assert len(r) == 2 and r[0]["axis_to"][1] < 0 < r[1]["axis_from"][1] or \
        (len(r) == 2 and r[0]["axis_to"][1] <= r[1]["axis_from"][1])
