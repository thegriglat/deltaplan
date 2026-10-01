"""Б2: откуда рост итераций — α/max_profile (профиль притока) или λ/h. Онгудай 12:00, 150°, эталон air.py (f32, CuPy),
критерий как у фикстур picard. Четыре набора: до (α 0,14, max 1,8, λ/h 0,25), только профиль, только λ/h, после.

    cd tools/research/air3d && flock /tmp/heat_ca_gpu.lock $PY ../b2/split.py   # → ../b2/out/split.md
"""
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "air3d"))
import air as A  # noqa: E402
import real as R  # noqa: E402

TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)
CASES = [(400, 0.0, True), (400, 3.0, True), (400, 3.0, False), (200, 0.0, True), (200, 3.0, True)]


def run(dx, U, heat, prof_new, lam_new):
    g, hc = R.grid_domain("ongudai", dx)
    c = R.case("ongudai", g, hc, 12.0, U, 150.0, heat=heat)
    if not prof_new:
        c.alpha, c.max_profile = 0.14, 1.8
    prm = A.Params(lam_frac=0.0158 if lam_new else 0.25)
    S = R.make("ongudai", g, hc, c, prm=prm, dtype=np.float32)
    S.init_background()
    st = S.solve(max_outer=3000, **TOL)
    return st, S.outer


def main():
    rows = ["| область | ветер | нагрев | до | только профиль | только λ/h | после |", "|---|---|---|---|---|---|---|"]
    for dx, U, heat in CASES:
        r = []
        for pn, ln in ((False, False), (True, False), (False, True), (True, True)):
            st, it = run(dx, U, heat, pn, ln)
            r.append(f"{it}" + ("" if st == "ok" else f" ({st})"))
            print(dx, U, heat, pn, ln, st, it, flush=True)
        rows.append(f"| {dx} м | {U:g} м/с | {'да' if heat else 'нет'} | " + " | ".join(r) + " |")
    (HERE / "out" / "split.md").write_text("\n".join(rows) + "\n")
    print("\n".join(rows))


if __name__ == "__main__":
    main()
