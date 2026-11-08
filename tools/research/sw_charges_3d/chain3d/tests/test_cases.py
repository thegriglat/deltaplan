"""C2 (ротор у Пикара L ≈ 800 м) и C4 (ротора нет): разрезы cascade-2d, вытянутые вдоль оси (20·L) — для chain3d."""
import os
import time

import numpy as np
import pytest

import panels3d as P
import chain3d
from panels3d.terrain import u_ref_of

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


def reverse_len(case, ch, sig, x_c, z_agl=15.0):
    xs = np.arange(x_c, x_c + 3000.0, 20.0)
    ys = np.zeros_like(xs)
    zz = case["t"].height(xs, ys) + z_agl
    u = chain3d.velocity_chain(case["p"], sig, case["bg"], ch, xs, ys, zz, 0.1, infl=case["infl"])[0]
    neg = u < -0.5
    if not neg.any():
        return 0.0, u
    i0 = int(np.argmax(neg))
    j = i0
    while j + 1 < len(neg) and neg[j + 1]:
        j += 1
    return float(xs[j] - xs[i0] + 20.0), u


def test_c4_no_rotor_by_slope(c4):
    ch, sig, info = chain3d.chain_rotor(c4["p"], c4["bg"], 0.1, c4["infl"], {})
    print(f"\nC4 N={c4['p'].N}: роторов {len(info['rotors'])}")
    assert info["rotors"] == [] and len(ch["fil"].seg) == 0 and np.array_equal(sig, c4["sg"]) and info["n_solves"] == 0


def test_c2_rotor_present_state_and_length(c2):
    p, bg = c2["p"], c2["bg"]
    ch0, sig0, info0 = chain3d.chain_rotor(p, bg, 0.1, c2["infl"], {})
    assert len(info0["rotors"]) >= 1
    r = info0["rotors"][0]
    print(f"\nC2 N={p.N}: ротор {r['length_m']:.0f} м, S={r['S']:.2f}, state {r['state']}, u_min/U на 10 м {r['u_min_over_U']:+.3f}")
    assert r["state"] in ("есть", "дышит", "нет") and r["S"] > 0 and info0["n_solves"] <= 2
    t0 = time.time()
    ch, sig, info = chain3d.chain_rotor(p, bg, 0.1, c2["infl"], dict(apply_state=False, keep_unconverged=True, position="equilibrium"))
    ok = info["links"]
    print(f"C2 (state отключён): сошлось {len(ok)}/{len(info['links'])}, {time.time() - t0:.0f} с, решений {info['n_solves']}")
    if ok:
        x_c = ok[len(ok) // 2]["x_c"][0]
        L, u = reverse_len(c2, ch, sig, x_c)
        print(f"C2: L(u∥<−0,5 на 15 м) = {L:.0f} м (Пикар ≈ 800), min u∥ {np.nanmin(u):.1f}")
