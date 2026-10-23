#!/usr/bin/env python3
"""TT-8: проверка инвариантов TT-К6 v1 по параметрам (trapeze.json) и геометрии build_trike/trike_params/pilot.glb.

    python3 tools/research/tow-trike/check_trapeze.py tools/research/tow-trike/trapeze.json
Код 0 — все инварианты выполнены, 1 — нет. Печатает зазоры. Геометрия — из trapeze_calc.py (те же функции, что при расчёте:
треугольник тележки, тело пилота в позе sit из pilot_sit.json), числа проверки — только из json.
"""
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trapeze_calc as T  # noqa: E402

TOL = 1e-3


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(T.HERE, "trapeze.json")
    j = json.load(open(path, encoding="utf-8"))
    bar = j["bar"]
    bad = []

    def chk(ok, msg):
        print(("ok   " if ok else "FAIL ") + msg)
        if not ok:
            bad.append(msg)

    trim, push, pull = (np.array(bar[k][1:]) for k in ("trim", "full_push", "full_pull"))
    r_bar = bar["d"] / 2
    chk(abs(r_bar - T.R_BAR) < 1e-9, "d штанги = 2·basebar_r_m (%.3f)" % bar["d"])
    # все три положения на одной дуге около HangPoint
    rs = [float(np.linalg.norm(p)) for p in (trim, push, pull)]
    chk(max(rs) - min(rs) < 2e-3, "положения на одной дуге: R = %s" % [round(r, 4) for r in rs])
    a_push = math.degrees(math.atan2(push[0], -push[1]) - math.atan2(trim[0], -trim[1]))
    a_pull = math.degrees(math.atan2(trim[0], -trim[1]) - math.atan2(pull[0], -pull[1]))
    chk(a_push > 0 and a_pull > 0, "порядок: full_pull -> trim -> full_push (%.2f° / %.2f°)" % (a_pull, a_push))
    chk(abs((a_push + a_pull) - bar["travel_deg"]) < 0.05, "travel_deg = %.2f" % bar["travel_deg"])
    chk(abs(math.radians(a_push + a_pull) * rs[0] - bar["travel_m"]) < 0.01, "travel_m = %.3f (по дуге)" % bar["travel_m"])
    # промежуточные положения, шаг <= 2° (берём 0.5°)
    worst = {"mast": 9, "strut": 9, "keel": 9, "body": 9, "panel": 9, "view": 9}
    a = -a_pull
    while a <= a_push + 1e-9:
        q = T.rot(trim, a)
        g = T.tri_gaps(q)
        g["body"] = T.body_gap(q) - 0.05
        g["panel"] = T.panel_dist(q) - T.R_BAR - 0.02
        g["view"] = T.view_gap(q) - 0.02
        for k in worst:
            worst[k] = min(worst[k], g[k])
        a += 0.5
    for k in ("mast", "strut", "keel"):
        chk(worst[k] >= -TOL, "зазор до %s по всему ходу, м: %.4f (>= 0 сверх r_трубы + r_штанги + 0,01)" % (k, worst[k]))
    chk(worst["panel"] >= -TOL, "штанга вне панели (>= r_штанги + 0,02): %.4f" % worst["panel"])
    chk(worst["view"] >= -TOL, "луч глаз -> панель не перекрыт штангой (>= 0,02): %.4f" % worst["view"])
    gp = T.tri_gaps(push)["strut"]
    chk(abs(gp) <= 2e-3, "full_push — касание подкоса с зазором r+r+0,01: отклонение %.4f м" % gp)
    gb = T.body_gap(pull)
    chk(gb >= 0.05 - TOL, "full_pull: зазор до тела пилота %.4f м (>= 0,05)" % gb)
    chk(T.body_gap(trim) > 0.05 and trim[0] > T.BODY_YZ[:, 0][T.BODY_YZ[:, 1] > trim[1] - 0.1].max(),
        "trim перед грудью пилота: y штанги %.3f > грудь/живот %.3f" % (
            trim[0], T.BODY_YZ[:, 0][(T.BODY_YZ[:, 1] > trim[1] - 0.1) & (T.BODY_YZ[:, 1] < trim[1] + 0.1)].max()))
    # руки
    hl, hr = np.array(j["hands"]["hand_l"]), np.array(j["hands"]["hand_r"])
    chk(abs(hl[0] + hr[0]) < 1e-6 and abs(hl[1] - hr[1]) < 1e-6 and abs(hl[2] - hr[2]) < 1e-6, "хват симметричен")
    for h, nm in ((hl, "hand_l"), (hr, "hand_r")):
        chk(abs(h[1] - trim[0]) <= 0.01 and abs(h[2] - trim[1]) <= 0.01, "%s на оси штанги trim (±1 см)" % nm)
    chk(abs(abs(hr[0]) - T.SH[0]) <= 0.05, "ширина хвата по плечам: |x| %.3f, плечи %.3f" % (abs(hr[0]), T.SH[0]))
    chk(abs(j["arm_len"] - T.ARM_LEN) < 5e-3, "длина руки %.3f = pilot.glb %.3f" % (j["arm_len"], T.ARM_LEN))
    sh = np.array(j["shoulder"])
    for nm, p in (("trim", trim), ("full_push", push)):
        rch = float(np.linalg.norm(np.array([T.SH[0], p[0], p[1]]) - sh))
        lim = j["arm_len"] - (0.05 if nm == "trim" else 0.0)
        chk(rch <= lim, "расстояние плечо - хват (%s): %.3f <= %.3f" % (nm, rch, lim))
    # крыло: стойки дают штангу trim после поворота на psi
    gp_ = j["glider_params"]
    cf = T.GP["control_frame"]
    w = gp_["basebar_width_m"]["value"] / 2
    L, tilt = gp_["upright_len_m"]["value"], math.radians(gp_["upright_tilt_deg"]["value"])
    dx = w - cf["upright_top_x_m"]
    s = math.sqrt(L * L - dx * dx)
    y_bb, z_bb = -gp_["hang_from_apex_m"]["value"] + s * math.sin(tilt), cf["upright_top_z_m"] - s * math.cos(tilt)
    q = T.rot(np.array([y_bb, z_bb]), gp_["psi_deg"]["value"])
    chk(float(np.linalg.norm(q - trim)) <= 0.01, "стойки (aframe_geom.frame_points) + psi %.2f° дают trim: расхождение %.4f м" % (
        gp_["psi_deg"]["value"], float(np.linalg.norm(q - trim))))
    chk(1.6 <= L <= 1.75 and 4 <= math.degrees(tilt) <= 35, "стойки в допуске control_frame: длина %.3f, наклон %.1f°" % (L, math.degrees(tilt)))
    chk(abs(bar["half_width"] - w) < 1e-9, "half_width = basebar_width_m/2")
    print("ИТОГ:", "FAIL (%d)" % len(bad) if bad else "OK")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
