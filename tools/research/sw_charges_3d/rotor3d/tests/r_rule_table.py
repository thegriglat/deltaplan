"""Таблица чувствительности R_rule (SWD7 v2) и уклон C2/C4 при сглаживании 0/25 м. Не тест: запуск
`tools/research/sw_charges_3d/py tools/research/sw_charges_3d/rotor3d/tests/r_rule_table.py` (≈ 10 мин на CPU)."""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import conftest  # noqa: F401,E402  (прячет CuPy при занятом GPU)
import panels3d as P  # noqa: E402
import rotor3d  # noqa: E402
import test_cases as TC  # noqa: E402
import test_rotor3d as TR  # noqa: E402
from panels3d.jh import _line_profile  # noqa: E402
from rotor3d import rotor as R  # noqa: E402


def agnesi():
    x, y, z = TR.raster(lambda X, Y: TR.H_AG / (1 + (X / TR.A_AG) ** 2), 1500, 750, TR.DS_AG / 2)
    t = P.Terrain3D(x, y, z, far_m=4000)
    foc = [(xx, yy) for xx in np.arange(-100, 700, 2 * TR.DS_AG) for yy in np.arange(-750, 751, 3 * TR.DS_AG)]
    p = P.build_panels(t, focus=foc, ds_min=TR.DS_AG, focus_r=2.8 * TR.DS_AG, ds_max=600, growth=1.6)
    bg = P.bg_profile(10.0, 0.2, 200.0, t)
    return dict(t=t, p=p, bg=bg, infl=P.assemble(p))


def zone(case, fil, sig, x_c, U):
    L, u = TC.reverse_zone(case, fil, sig, x_c)
    return L, float(np.nanmin(u)) / U


def agnesi_umin(c, fil, sig, r):
    xs = np.linspace(r["x_c"] + 20.0, r["x_r"] - 20.0, 12)
    zg = c["t"].height(xs, np.zeros_like(xs)) + 10.0
    return float(np.nanmin(rotor3d.velocity_rotor(c["p"], sig, c["bg"], fil, xs, np.zeros_like(xs), zg, 0.1, infl=c["infl"])[0]))


def slope_of(case, sm):
    """Макс. подветренный уклон сглаженного (σ = 2·ds_min) профиля между x_c и x_r при сглаживании рельефа sm."""
    cc = TC.CASES[case]
    d = np.load(os.path.join(TC.DATA, f"{case}_profile.npz"))
    x, h = d["x"], d["h"]
    m = (x >= cc["x0"]) & (x <= cc["x1"])
    x, h = x[m], h[m]
    y = np.arange(-cc["Ly"] / 2 - 4 * TC.DS, cc["Ly"] / 2 + 4 * TC.DS + 0.1, 50.0)
    t = P.Terrain3D(x, y, np.tile(h, (len(y), 1)), smooth_m=sm, far_m=5000)
    s, z = _line_profile(t, float(x[np.argmax(h)]), 0.0, 1.0, 0.0, 25.0)
    rule = R.profile_rule(s, z, TC.DS, 0.0)
    return None if rule is None else rule["slope_lee"]


def main():
    for k in ("C2", "C4"):
        print(f"{k}: уклон подветренный sm=0 -> {slope_of(k, 0.0)}, sm=25 -> {slope_of(k, 25.0)}", flush=True)
    rows = []
    cases = [("Agnesi H/L 0,5", agnesi(), "head", None)]
    for k in ("C2", "C4"):
        cases.append((k, TC.build(k), "none", k))
    for name, c, gate, key in cases:
        U = P.terrain.u_ref_of(c["bg"], c["t"])[0]
        for rr in (0.15, 0.25, 0.35):
            fil, sig, info = rotor3d.rotor_vortex(c["p"], c["bg"], 0.1, c["infl"], dict(gate=gate, R_rule=rr))
            if not info["ridges"]:
                rows.append((name, rr, "нет хребта", "", "", "", "", ""))
                continue
            r = info["ridges"][0]
            sl = r["slope_lee"]
            if r["converged"]:
                if key:
                    L, umin = zone(c, fil, sig, r["x_c"], U)
                else:
                    L, umin = float("nan"), agnesi_umin(c, fil, sig, r) / U
                rows.append((name, rr, "да", f"{r['R']:.0f}", f"{r['Gamma']:.0f}", f"{r['Gamma'] / (U * r['H']):.1f}",
                             f"{umin:.2f}", "—" if key is None else f"{L:.0f}", f"{sl:.3f}"))
            else:
                rows.append((name, rr, "нет (Γ ≤ 0 или невязка)", f"{r['R']:.0f}", f"{r['Gamma']:.0f}", "", "", "", f"{sl:.3f}"))
            print(rows[-1], flush=True)
    print("\n| Случай | R_rule | корень | R, м | Γ, м²/с | Γ/(U·H) | min u∥/U | L зоны u∥<−0,5, м | уклон |")
    for r in rows:
        print("| " + " | ".join(str(v) for v in r) + " |")


if __name__ == "__main__":
    main()
