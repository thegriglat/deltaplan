"""PT-3: фикстуры сверки 2-го порядка picard_rs с air3d (adv2, limiter 0/1/2), float64 на GPU.

Пологий синтетический хребет (Аньези H/L = 0,2; на H = L 2-й порядок не сходится, reference.md), нагрев
солнцем + ветер, чтобы были ненулевыми обе поправки (импульс и тепло θ′, θ′_d). Блоки одной итерации
пишет air3d/fixtures.py (make_case): шаблоны Cm/bm и Ch_d/bh_d/Ch/bh уже содержат поправку adv2 (adv2_mom,
adv2_heat вызываются до build_*), sol_* — решение до критерия с adv2. Файлы: D/fixtures/adv2_l{0,1,2}.{json,bin},
D = $PICARD_TERRAIN_DATA (по умолчанию ~/data/picard_terrain).

    PYTHONPATH=tools/research/air3d tools/research/sw_charges_3d/py tools/research/picard_terrain/adv2_fixtures.py [0 1 2]
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import air as A
import fixtures as FX
import synth as SY

D = Path(os.environ.get("PICARD_TERRAIN_DATA", Path.home() / "data/picard_terrain"))
H_OVER_L = 0.2


def case(limiter: int):
    g = A.Grid(100.0, 32, 24, 50.0, -50.0, 16, -1600.0, -1200.0)
    X, Y = SY.XY(g)
    hc = SY.ridge3d(X, Y, 60.0, 300.0, 600.0)
    heat = SY.sun_flux(hc, g.dx, az=100.0, el=45.0)
    cs = A.Case(U10=5.0, wdir=270.0, gam=SY.cbl_gam(1500.0, 5.8e-3), z_i=1500.0, H=heat)
    prm = A.Params(dtau_u=600.0, adv2=True, limiter=limiter, pr_t=0.85)
    return g, hc, cs, prm


if __name__ == "__main__":
    FX.OUT = D / "fixtures"
    which = [int(a) for a in sys.argv[1:]] or [0, 1, 2]
    for lim in which:
        g, hc, cs, prm = case(lim)
        FX.make_case(f"adv2_l{lim}", g, hc, cs, prm)
