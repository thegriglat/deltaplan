#!/usr/bin/env python3
"""TT-8: трапеция trike_ixess15 и положения штанги в треугольнике тележки (TT-К6 v1).

Запуск (из корня): python3 tools/research/tow-trike/trapeze_calc.py [--write]
Вход: tools/blender/trike_params.json, glider_params.json (control_frame), configs/tow_tug.json,
pilot_sit.json (extract_sit.py: поза sit из pilot.glb), trim_pendulum.json (замер measure_trim.gd).
Выход (--write): trapeze.json. Оси: Blender от HangPoint, (y вперёд, z вверх) в плоскости x = 0, м; углы: + нос крыла вверх
(штанга «от себя» -> вперёд-вверх по дуге около подвески).
"""
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
J = lambda *p: json.load(open(os.path.join(ROOT, *p), encoding="utf-8"))

TP = J("tools", "blender", "trike_params.json")
GP = J("tools", "blender", "glider_params.json")
TUG = J("configs", "tow_tug.json")
SIT = J("tools", "research", "tow-trike", "pilot_sit.json")
TRIM = J("tools", "research", "tow-trike", "trim_pendulum.json")
D = {k: v["value"] if isinstance(v, dict) else v for k, v in TP["dims"].items()}

R_BAR = GP["control_frame"]["basebar_r_m"]          # 0.015
R_MAST, R_STRUT, R_KEEL = D["tube_mast_d"] / 2, D["tube_strut_d"] / 2, D["tube_keel_d"] / 2
MARGIN = 0.01
BAR_WIDTH = 1.10   # ширина базовой штанги крыла, м: оценка (в источниках н/д), см. trike-tug.md
G = 9.81


# ---------------------------------------------------------------- треугольник тележки (build_trike.py)
def fillet2(pts, d, n=4):
    """Как build_trike.fillet: ломаная со скруглёнными углами (квадратичная Безье), точки (y, z)."""
    P = [np.array(p, float) for p in pts]
    out = [P[0]]
    for i in range(1, len(P) - 1):
        p, a, b = P[i], P[i - 1], P[i + 1]
        n1 = (a - p) / np.linalg.norm(a - p)
        n2 = (b - p) / np.linalg.norm(b - p)
        p0 = p + n1 * min(d, np.linalg.norm(a - p) * 0.45)
        p1 = p + n2 * min(d, np.linalg.norm(b - p) * 0.45)
        for k in range(n + 1):
            t = k / n
            out.append((p0 + (p - p0) * t) * (1 - t) + (p + (p1 - p) * t) * t)
    out.append(P[-1])
    return out


KZ = -2.12
MAST_BASE = np.array([-math.tan(math.radians(D["mast_tilt_deg"])) * (-KZ), KZ])
Y_F = D["axle_rear_y"] + D["wheelbase"]
NOSE = np.array([Y_F + 0.14, -2.0])
PN = TP["panel"]
PNN = np.array(PN["normal"][1:])               # (ny, nz)
PC = np.array(PN["center"][1:])
PB = PC - PNN / np.linalg.norm(PNN) * 0.015
_dir = (PB - np.array([0, -0.03])) / np.linalg.norm(PB - np.array([0, -0.03]))
CORNER = PB + _dir * 0.35
STRUT = fillet2([(0, -0.03), tuple(CORNER), tuple(NOSE)], 0.35, 4)
MAST = [np.zeros(2), MAST_BASE]
KEEL = [np.array([-0.98, KZ]), np.array([0.7, KZ]), NOSE]


def seg_dist(p, a, b):
    ab = b - a
    t = np.clip(np.dot(p - a, ab) / np.dot(ab, ab), 0, 1)
    return float(np.linalg.norm(p - (a + ab * t)))


def poly_dist(p, poly):
    return min(seg_dist(p, poly[i], poly[i + 1]) for i in range(len(poly) - 1))


def rot(v, deg):
    """Поворот (y, z) около подвески, + = нос крыла вверх: точка ниже подвески уходит вперёд."""
    a = math.radians(deg)
    return np.array([v[0] * math.cos(a) - v[1] * math.sin(a), v[0] * math.sin(a) + v[1] * math.cos(a)])


# ---------------------------------------------------------------- панель (прямоугольник в виде сбоку)
_pn = PNN / np.linalg.norm(PNN)
_pu = np.array([_pn[1], -_pn[0]])           # вверх в плоскости панели: n x X в (y, z) = (nz, -ny)
PW2 = PN["size"][1] / 2   # половина высоты в плоскости
PT2 = 0.0175              # толщина 0.03 + лицевая накладка до 0.0175 от центра по нормали


def panel_dist(p):
    d = p - PC
    a, b = abs(np.dot(d, _pu)) - PW2, abs(np.dot(d, _pn)) - PT2
    return float(math.hypot(max(a, 0), max(b, 0)) if (a > 0 or b > 0) else max(a, b))


# ---------------------------------------------------------------- тело пилота в позе sit
BODY = np.array(SIT["body_pts"])
ARM = np.array(SIT["arm_pts"])
BODY = np.vstack([BODY, ARM[np.abs(ARM[:, 0]) < 0.10]])      # грудь/живот, ошибочно в группах рук (|x| < 0.1)
BODY_YZ = BODY[:, 1:]
B = SIT["bones"]
SH = np.array(B["UpperArm.R"][0])              # плечевой сустав (x, y, z)
UP = np.linalg.norm(np.array(B["UpperArm.R"][1]) - np.array(B["UpperArm.R"][0]))
FORE = np.linalg.norm(np.array(B["Forearm.R"][1]) - np.array(B["Forearm.R"][0]))
HAND_L = np.linalg.norm(np.array(SIT["empties"]["HandR"]) - np.array(B["Forearm.R"][1]))   # запястье -> хват
ARM_LEN = UP + FORE + HAND_L
EYE = np.array(SIT["empties"]["Head"][1:])


def body_gap(p):
    """Зазор оси штанги до поверхности тела (по вершинам меша), м."""
    return float(np.min(np.linalg.norm(BODY_YZ - p, axis=1))) - R_BAR


def reach(p, hx):
    return float(np.linalg.norm(np.array([hx, p[0], p[1]]) - SH * np.array([np.sign(hx) or 1, 1, 1])))


def view_gap(p):
    """Расстояние оси штанги до лучей глаз -> углы панели (виден ли прибор), м, минус радиус."""
    h = PW2
    ends = [PC + _pu * s for s in (-h, h)]
    return min(seg_dist(p, EYE, e) for e in ends) - R_BAR


def tri_gaps(p):
    """Зазоры оси штанги до мачты, подкоса, киля: расстояние между осями минус (радиусы труб + 0.01)."""
    return {"mast": poly_dist(p, MAST) - (R_MAST + R_BAR + MARGIN),
            "strut": poly_dist(p, STRUT) - (R_STRUT + R_BAR + MARGIN),
            "keel": poly_dist(p, KEEL) - (R_KEEL + R_BAR + MARGIN)}


# ---------------------------------------------------------------- тангаж крыла относительно тележки на трейме
def cart_equilibrium(v_ms, d_tot_n):
    """Тангаж тележки theta_c (нос вверх от положения на земле), при котором момент около подвески = 0:
    вес в ЦМ, тяга винта (ось HUB, наклон 2 градуса), сопротивление тележки cda·q назад в ЦМ.
    Крыло действует на тележку только силой в подвеске (момента нет)."""
    c = TUG["cart"]
    m = c["mass_kg"]
    cg = np.array([-0.13, -1.70])                                  # cart.py: ЦМ -0.13 вперёд, 1.70 вниз
    hub = np.array([-0.92 - D["engine_l"] / 2 - 0.05, -2.5 + D["prop_axis_height"]])
    tilt = math.radians(D["prop_tilt_deg"])
    q = 0.5 * 1.225 * v_ms ** 2
    d_cart = q * c["cda_m2"]
    t = d_tot_n

    def torque(th):                               # + = нос вверх (против часовой в (y, z))
        r = lambda p: rot(p, math.degrees(th))
        tq = 0.0
        pg = r(cg)
        tq += pg[0] * (-m * G)                                     # вес: y*Fz
        ph = r(hub)
        fth = np.array([math.cos(th + tilt), math.sin(th + tilt)]) * t
        tq += ph[0] * fth[1] - ph[1] * fth[0]
        tq += -pg[1] * (-d_cart)                                   # сопротивление назад в ЦМ: -z*Fy
        return tq

    lo, hi = math.radians(-15), math.radians(25)
    for _ in range(80):
        mid = (lo + hi) / 2
        if torque(lo) * torque(mid) > 0:
            lo = mid
        else:
            hi = mid
    return math.degrees((lo + hi) / 2), d_cart


def main():
    write = "--write" in sys.argv
    v = TUG["tow_speed_kmh"] / 3.6
    lvl = TRIM["tow"]                            # замер при 60 км/ч: theta, vy
    gamma = math.degrees(math.asin(lvl["vy"] / lvl["airspeed_ms"]))
    alpha = lvl["theta_deg"] - gamma             # угол киля к потоку
    theta_level = alpha                          # горизонтальный полёт: gamma = 0
    wtot = (TUG["cart"]["mass_kg"] + 53.0) * G
    d_tot = wtot * abs(lvl["vy"]) / lvl["airspeed_ms"]
    th_c, d_cart = cart_equilibrium(v, d_tot)
    psi_a = theta_level - th_c
    # проверка по «Маятнику»: нейтраль (ноль ввода) в осях крыла
    nr = TRIM["neutral_rel"]
    line_back = math.degrees(math.atan2(-nr[0], nr[2]))        # линия подвеска -> пилот позади нормали крыла
    cg_back = math.degrees(math.atan2(0.13, 1.70))             # то же в осях тележки на земле
    psi_neutral = -(cg_back - line_back)                       # крыло относительно тележки при нейтрали маятника (нос вверх +)
    psi_b = psi_neutral + lvl["phi_deg"]
    print("level: theta_keel %.2f alpha %.2f gamma %.2f; D_tot %.0f Н, D_cart %.0f Н; тангаж тележки %.2f; psi A %.2f  psi B %.2f"
          % (lvl["theta_deg"], alpha, gamma, d_tot, d_cart, th_c, psi_a, psi_b))
    psi = psi_a

    # ---- перебор хвата: (y, z) кистей при trim; пределы хода по дуге
    hx = 0.19
    PU_MIN, REACH_TRIM_MAX = 5.0, 0.60

    def ok(q, hxx=hx):
        g = tri_gaps(q)
        return (min(g.values()) >= 0 and panel_dist(q) >= R_BAR + 0.02 and view_gap(q) >= 0.02), g

    def limits(p0):
        pu = pl = None
        for a in np.arange(0, 40, 0.1):
            if not ok(rot(p0, a))[0]:
                pu = a
                break
        for a in np.arange(0, 60, 0.1):
            q = rot(p0, -a)
            if body_gap(q) < 0.05 or not ok(q)[0]:
                pl = a
                break
        return pu, pl

    res = []
    for yh in np.arange(0.50, 0.95, 0.02):
        for zh in np.arange(-1.75, -1.30, 0.02):
            p0 = np.array([yh, zh])
            if reach(p0, hx) > REACH_TRIM_MAX or not ok(p0)[0] or body_gap(p0) < 0.05:
                continue
            pu, pl = limits(p0)
            if pu is None or pl is None or pu < PU_MIN:
                continue
            rp = reach(rot(p0, pu), hx)
            if rp > ARM_LEN - 0.01:
                continue
            res.append((yh, zh, pu, pl, reach(p0, hx), rp, reach(rot(p0, -pl), hx)))
    res = np.array(res)
    print("кандидатов", len(res))
    best = res[np.argmax(res[:, 3] * 100 - np.abs(res[:, 4] - 0.55))]
    yh, zh = float(best[0]), float(best[1])
    p0 = np.array([yh, zh])
    R = float(np.linalg.norm(p0))

    def first_fail(f, amax, step=0.05):
        """Первый угол от 0, где условие f нарушено (линейный просмотр, затем бисекция): дуга может выйти за подкос."""
        a = 0.0
        while a < amax and f(a):
            a += step
        lo, hi = max(a - step, 0.0), a
        for _ in range(50):
            mid = (lo + hi) / 2
            lo, hi = (mid, hi) if f(mid) else (lo, mid)
        return lo

    pu = first_fail(lambda a: tri_gaps(rot(p0, a))["strut"] > 0 and tri_gaps(rot(p0, a))["mast"] > 0, 60)
    pl = first_fail(lambda a: body_gap(rot(p0, -a)) >= 0.05 and min(tri_gaps(rot(p0, -a)).values()) >= 0, 60)
    full_push, full_pull = rot(p0, pu), rot(p0, -pl)
    # какие ограничения ещё срабатывают на концах (панель, взгляд)
    def allc(q):
        g = tri_gaps(q)
        return {"mast": g["mast"], "strut": g["strut"], "keel": g["keel"], "body": body_gap(q) - 0.05,
                "panel": panel_dist(q) - R_BAR - 0.02, "view": view_gap(q) - 0.02}
    steps = []
    a = -pl
    while a <= pu + 1e-9:
        steps.append(a)
        a += 0.5
    steps.append(pu)
    worst = {k: min(allc(rot(p0, a))[k] for a in steps) for k in ("mast", "strut", "keel", "body", "panel", "view")}
    print("trim", p0, "R %.3f" % R, "push %.2f pull %.2f" % (pu, pl), "худшие зазоры", {k: round(v, 4) for k, v in worst.items()})
    # крыло: координаты штанги в осях крыла (киль горизонтален): поворот на -psi
    bar_w = rot(p0, -psi)
    cf = GP["control_frame"]
    top_z, top_x = cf["upright_top_z_m"], cf["upright_top_x_m"]
    w = BAR_WIDTH / 2
    s_len = float(math.hypot(bar_w[0], bar_w[1] - top_z))
    tilt = math.degrees(math.atan2(bar_w[0], top_z - bar_w[1]))
    upr = math.sqrt(s_len ** 2 + (w - top_x) ** 2)
    print("psi %.2f; штанга в осях крыла y %.3f z %.3f; s %.3f; tilt %.2f; upright_len %.3f (3D, ширина %.2f)" % (
        psi, bar_w[0], bar_w[1], s_len, tilt, upr, 2 * w))
    arm_travel = R * math.radians(pl + pu)
    out = dict(psi=psi, p0=p0, R=R, pu=pu, pl=pl, full_push=full_push, full_pull=full_pull, bar_w=bar_w, tilt=tilt,
               upr=upr, s_len=s_len, hx=hx, worst=worst, arm_len=ARM_LEN, psi_a=psi_a, psi_b=psi_b, th_c=th_c,
               d_cart=d_cart, d_tot=d_tot, alpha=alpha, gamma=gamma, w=w, arm_travel=arm_travel,
               reach_trim=reach(p0, hx), reach_push=reach(full_push, hx), reach_pull=reach(full_pull, hx),
               parts=(UP, FORE, HAND_L), shoulder=SH.tolist(), allc=allc)
    return out


def r4(x):
    return round(float(x), 4)


def build_json(o):
    p0, fpu, fpl = o["p0"], o["full_push"], o["full_pull"]
    X = lambda p: [0.0, r4(p[0]), r4(p[1])]
    hl, hr = [-o["hx"], r4(p0[0]), r4(p0[1])], [o["hx"], r4(p0[0]), r4(p0[1])]
    tl = TRIM
    # положения по «Маятнику»: ход относительно trim (tow, 60 км/ч, ввод +0,5) -> phi маятника
    phi_tow = tl["tow"]["phi_deg"]
    phi_push_lim = [r["phi_deg"] for r in tl["runs"] if r["pitch"] == 1.0][0]
    phi_pull_lim = [r["phi_deg"] for r in tl["runs"] if r["pitch"] == -1.0][0]
    neutral = rot(p0, -phi_tow)                       # ноль ввода маятника: 69,5 км/ч в планировании, штанга позади trim
    L = tl["hang_len"]
    j = {
        "_doc": "TT-8 (TT-К6 v1): трапеция крыла trike_ixess15 и штанга в треугольнике тележки. Считает tools/research/tow-trike/trapeze_calc.py --write; проверяет check_trapeze.py. Оси Blender от HangPoint (x вправо, y вперёд, z вверх), м; углы + «от себя» (нос крыла вверх относительно тележки).",
        "glider_params": {
            "upright_len_m": {"value": r4(o["upr"]), "src": "расчёт: расстояние от оси болта под килем до оси штанги в углу при штанге bar.trim в осях крыла (поворот на -psi) и ширине %.2f м; в допуске control_frame 1,6…1,75; источника по длине стоек трайковых крыльев н/д" % (2 * o["w"])},
            "upright_tilt_deg": {"value": r4(o["tilt"]), "src": "расчёт: наклон стойки к нормали киля, из положения штанги в осях крыла (aframe_cg --pick-reach не применяется)"},
            "basebar_width_m": {"value": 2 * o["w"], "src": "оценка: ширина базовой штанги трайкового крыла в открытых источниках н/д; 1,10 м = хват +-%.2f м плюс запас, укладывает стойки в допуск 1,6…1,75; не влияет на инварианты TT-К6 (проекция на x = 0)" % o["hx"]},
            "hang_from_apex_m": {"value": 0.0, "src": "умолчание control_frame для двухповерхностных (double_surface: true) — без изменений"},
            "psi_deg": {"value": r4(o["psi"]), "src": "расчёт: тангаж киля на горизонтальном полёте 60 км/ч (замер «Маятника», trim_pendulum.json) минус тангаж тележки по балансу моментов (тяга, сопротивление, вес); контроль по нейтрали «Маятника» %.2f" % o["psi_b"]},
        },
        "wing_frame_bar": {"y": r4(o["bar_w"][0]), "z": r4(o["bar_w"][1]), "src": "штанга trim в осях крыла (киль горизонтален): bar.trim, повёрнутая на -psi вокруг HangPoint"},
        "bar": {
            "wing": "trike_ixess15", "d": 0.03, "half_width": o["w"],
            "trim": X(p0), "full_push": X(fpu), "full_pull": X(fpl),
            "travel_m": r4(o["arm_travel"]), "travel_deg": r4(o["pu"] + o["pl"]),
            "push_deg": r4(o["pu"]), "pull_deg": r4(o["pl"]), "radius_m": r4(o["R"]),
            "how": "trim — кисти на высоте/вылете, выбранных перебором (шаг 2 см) так, чтобы рука согнута (reach %.3f м при длине руки %.3f), тело не ближе 5 см на всём ходу назад, упор в подкос не раньше %.1f°; full_push — касание подкоса (зазор осей = r_подкоса + r_штанги + 0,01), full_pull — зазор до тела 0,05 м (по вершинам меша pilot.glb, поза sit); дуга радиуса %.3f м около HangPoint" % (o["reach_trim"], o["arm_len"], o["pu"], o["R"]),
        },
        "hands": {"hand_l": hl, "hand_r": hr},
        "shoulder": [r4(x) for x in o["shoulder"]],
        "arm_len": r4(o["arm_len"]),
        "arm_parts": {"upper": r4(o["parts"][0]), "fore": r4(o["parts"][1]), "hand": r4(o["parts"][2]),
                      "src": "pilot.glb, поза sit: кости UpperArm.R, Forearm.R, запястье -> HandR; плечо 0,186 H (Drillis & Contini 1966, по Winter, Biomechanics and Motor Control of Human Movement) при H 1,75 = 0,326"},
        "reach": {"trim": r4(o["reach_trim"]), "full_push": r4(o["reach_push"]), "full_pull": r4(o["reach_pull"])},
        "clearances": {k: r4(v) for k, v in o["worst"].items()},
        "clearances_doc": "минимум по ходу (шаг 0,5°) от full_pull до full_push: зазор до мачты, подкоса, киля = расстояние осей − (r_трубы + r_штанги + 0,01); body — до тела минус 0,05; panel — до панели минус (r_штанги + 0,02); view — до луча глаз -> панель минус 0,02",
        "pendulum": {
            "src": "trim_pendulum.json (measure_trim.gd): PendulumModel, trike_ixess15, тележка configs/tow_tug.json cart (262,5 кг, hang 1,71 м)",
            "phi_tow_deg": r4(phi_tow), "phi_push_limit_deg": r4(phi_push_lim), "phi_pull_limit_deg": r4(phi_pull_lim),
            "push_from_trim_model_deg": r4(phi_push_lim - phi_tow), "pull_from_trim_model_deg": r4(phi_tow - phi_pull_lim),
            "push_from_trim_geometry_deg": r4(o["pu"]), "pull_from_trim_geometry_deg": r4(o["pl"]),
            "neutral_input0": X(neutral), "neutral_input0_doc": "положение штанги при нулевом вводе «Маятника» (планирование 69,5 км/ч) — на %.2f° «на себя» от trim" % phi_tow,
            "shift_x_push_cart_m": r4(L * math.sin(math.radians(phi_tow + o["pu"]))),
            "shift_x_pull_cart_m": r4(L * math.sin(math.radians(o["pl"] - phi_tow))),
            "shift_doc": "для TT-4: ход PilotArms от нейтрали (ноль ввода) до упоров геометрии = L·sin(угол): «от себя» до подкоса, «на себя» до груди (штатные 0,3 / 0,45 м не помещаются в треугольник)",
        },
        "balance": {
            "theta_keel_level_deg": r4(TRIM["tow"]["theta_deg"] - o["gamma"]), "alpha_deg": r4(o["alpha"]), "gamma_glide_deg": r4(o["gamma"]),
            "drag_total_n": r4(o["d_tot"]), "drag_cart_n": r4(o["d_cart"]), "cart_pitch_deg": r4(o["th_c"]),
            "psi_A_deg": r4(o["psi_a"]), "psi_B_deg": r4(o["psi_b"]),
        },
    }
    return j


def main_write():
    o = main()
    j = build_json(o)
    json.dump(j, open(os.path.join(HERE, "trapeze.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("trapeze.json записан")


if __name__ == "__main__":
    if "--write" in sys.argv:
        main_write()
    else:
        main()
