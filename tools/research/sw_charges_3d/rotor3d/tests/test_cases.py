"""Разрезы cascade-2d C2 (ротор у Пикара L ≈ 800 м) и C4 (ротора нет), вытянутые вдоль оси в длинный хребет (20·L).
Профили земли — из полей Пикара F1 dx 50 (tests/data/*.npz: x, h, alpha, max_profile, U10)."""
import os
import time

import numpy as np
import pytest

import filaments3d as F
import panels3d as P
import rotor3d
from rotor3d import rotor as R

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
CASES = dict(C2=dict(x0=-1800, x1=2400, Ly=6000, foc=(-250, 900), sm=0.0),
             C4=dict(x0=-1800, x1=3400, Ly=5500, foc=(-300, 1500), sm=25.0))
DS = 60.0


def build(case):
    c = CASES[case]
    d = np.load(os.path.join(DATA, f"{case}_profile.npz"))
    x, h = d["x"], d["h"]
    m = (x >= c["x0"]) & (x <= c["x1"])
    x, h = x[m], h[m]
    y = np.arange(-c["Ly"] / 2 - 4 * DS, c["Ly"] / 2 + 4 * DS + 0.1, 50.0)
    t = P.Terrain3D(x, y, np.tile(h, (len(y), 1)), smooth_m=c["sm"], far_m=5000)
    alpha, mp = float(d["alpha"]), float(d["mp"])
    bg = P.bg_profile(float(d["U10"]), alpha, 10.0 * mp ** (1 / alpha), t, smooth_m=250.0)
    foc = [(xx, yy) for xx in np.arange(c["foc"][0], c["foc"][1], 2 * DS) for yy in np.arange(-c["Ly"] / 2, c["Ly"] / 2 + 1, 4 * DS)]
    p = P.build_panels(t, focus=foc, ds_min=DS, focus_r=2.5 * DS, ds_max=1000, growth=2.0)
    infl = P.assemble(p)
    sg, _ = P.solve(p, bg, None, infl)
    return dict(t=t, p=p, bg=bg, infl=infl, sg=sg)


@pytest.fixture(scope="module")
def c2():
    return build("C2")


@pytest.fixture(scope="module")
def c4():
    return build("C4")


def reverse_zone(case, fil, sig, x_c, z_agl=15.0, y=0.0):
    """Протяжённость (м) непрерывной зоны u∥ < −0,5 м/с на высоте z_agl за гребнем x_c вдоль ветра (по оси y = 0)."""
    xs = np.arange(x_c, x_c + 3000.0, 20.0)
    ys = np.full_like(xs, y)
    zz = case["t"].height(xs, ys) + z_agl
    u = rotor3d.velocity_rotor(case["p"], sig, case["bg"], fil, xs, ys, zz, 0.1, infl=case["infl"])[0]
    neg = u < -0.5
    if not neg.any():
        return 0.0, u
    i0 = int(np.argmax(neg))
    j = i0
    while j + 1 < len(neg) and neg[j + 1]:
        j += 1
    return float(xs[j] - xs[i0] + 20.0), u


def test_c4_no_false_rotor_with_contract_rule(c4):
    """C4 (у Пикара ротора нет): нить не ставится. Флаги порогов Хеда и уклона — числами (README)."""
    fil, sig, info = rotor3d.rotor_vortex(c4["p"], c4["bg"], 0.1, c4["infl"], {})
    cand = info["candidates"]
    print(f"\nC4 N={c4['p'].N}: кандидаты {cand}; ridges {[(r['x_c'], r['placed'], r['residual']) for r in info['ridges']]}")
    assert len(fil.seg) == 0 and all(not r["placed"] for r in info["ridges"])
    assert F.imbalance(fil) == 0.0
    assert np.array_equal(sig, c4["sg"])
    # порог по уклону отрезает C4 (макс. подветренный уклон ниже 0,27); Хед — см. README
    main = min(cand, key=lambda q: abs(q["x_c"] - 62.5))
    assert main["slope"] is False and main["slope_lee"] < 0.27


def test_c4_slope_gate_no_ridge(c4):
    fil, sig, info = rotor3d.rotor_vortex(c4["p"], c4["bg"], 0.1, c4["infl"], dict(gate="slope"))
    assert len(fil.seg) == 0 and info["ridges"] == [] and info["n_rejected"] == info["n_ridges"]


def test_c2_contract_rule_and_shifted(c2):
    """C2 (у Пикара ротор L ≈ 800 м): по правилу контракта корня нет; со сдвигом x_m (диагностика) — числа."""
    p, bg = c2["p"], c2["bg"]
    t0 = time.time()
    f0, s0, i0 = rotor3d.rotor_vortex(p, bg, 0.1, c2["infl"], dict(gate="slope"))
    r0 = i0["ridges"][0]
    print(f"\nC2 N={p.N}: x_c={r0['x_c']:.0f} x_r={r0['x_r']:.0f} ({r0['rule_r']}) a={np.round(r0['ut_bg'], 2)} "
          f"g={[(round(a, 2), round(float(b), 2)) for a, b in r0['grid']]} {time.time() - t0:.0f} с")
    assert i0["candidates"][0]["slope"] and i0["candidates"][0]["head"]
    assert not r0["converged"] and len(f0.seg) == 0
    L0, _ = reverse_zone(c2, f0, s0, r0["x_c"])
    assert L0 == 0.0
    f1, s1, i1 = rotor3d.rotor_vortex(p, bg, 0.1, c2["infl"], dict(gate="slope", m_frac=0.3))
    r1 = i1["ridges"][0]
    print(f"C2 x_m=0,3: converged={r1['converged']} R={r1['R']:.1f} Γ={r1['Gamma']:.0f} nsolve={i1['nsolve']}")
    if r1["converged"]:
        L1, u = reverse_zone(c2, f1, s1, r1["x_c"])
        print(f"C2 x_m=0,3: L(u∥<−0,5 на 15 м) = {L1:.0f} м (Пикар ≈ 800), min u∥ {np.nanmin(u):.1f}")
        assert F.imbalance(f1) <= 1e-12
