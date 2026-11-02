#!/usr/bin/env python3
"""TKF-9: допустимый диапазон дуги штанги в треугольнике тележки (инварианты TT-К6) и запас на сдвиг вида.
Использует функции tools/research/tow-trike/trapeze_calc.py (треугольник, тело пилота, панель). Углы: + к подкосу ("от себя"),
от bar.trim (0,72 вперёд; -1,51) в осях Blender (y вперёд, z вверх). Запуск из корня: python3 tools/research/trike-fix/strut/geometry.py
"""
import json, math, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tow-trike"))
import trapeze_calc as T

TRIM = np.array([0.72, -1.51])


def rotb(v, deg):  # + = к подкосу (вперёд): точка ниже подвески уходит вперёд
    return T.rot(v, deg)


def gaps(a, trim=TRIM):
    q = rotb(trim, a)
    g = T.tri_gaps(q)
    g["body"] = T.body_gap(q) - 0.05
    g["panel"] = T.panel_dist(q) - T.R_BAR - 0.02
    g["view"] = T.view_gap(q) - 0.02
    return g


def limits(trim=TRIM, lo=-25.0, hi=25.0, step=0.05):
    """Интервал a (от trim), где все зазоры >= 0 и связный с a=0."""
    def ok(a):
        return min(gaps(a, trim).values()) >= -1e-3
    a_hi = 0.0
    while a_hi < hi and ok(a_hi + step):
        a_hi += step
    a_lo = 0.0
    while a_lo > lo and ok(a_lo - step):
        a_lo -= step
    def who(a):
        g = gaps(a, trim)
        return min(g, key=g.get)
    return a_lo, a_hi, who(a_lo - step), who(a_hi + step)


if __name__ == "__main__":
    a_lo, a_hi, w_lo, w_hi = limits()
    print("trim: от %.2f (%s) до +%.2f (%s)" % (a_lo, w_lo, a_hi, w_hi))
    print("полный ход, град: %.2f; дуга R=%.3f" % (a_hi - a_lo, float(np.linalg.norm(TRIM))))
    print("зазоры в trim:", {k: round(v, 4) for k, v in gaps(0).items()})
    print("STRUT:", [list(map(lambda x: round(float(x), 3), p)) for p in T.STRUT[::6]], "NOSE", T.NOSE)
    print("KZ", T.KZ, "MAST_BASE", T.MAST_BASE)
