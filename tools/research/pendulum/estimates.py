#!/usr/bin/env python3
"""Оценки для плана модуля pendulum (docs/plan/pendulum.md): частоты мод, инерции, Cm_alpha по
точкам балансировки, устойчивость интегратора. Только numpy-free python. Вывод — estimates.json
и таблица в stdout. Воспроизведение: python3 tools/research/pendulum/estimates.py
"""
import json, math, os, sys

G = 9.81
RHO = 1.225
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

def cfg(path):
    with open(os.path.join(ROOT, "configs", path)) as f:
        return json.load(f)

out = {}

# ---------------------------------------------------------------- 1. Полюса Hiway Demon
# Abouheaf, Gueaieb, Lewis (arXiv:2108.02393), модель Cook & Spottiswoode 2006, дискретизация 0.01 с.
# Table 2, разомкнутая система: lon 0.9801 e^{±0.0219i}, 1.0009 e^{±0.0116i};
# lat 0.7978, 0.9949, 0.9973 e^{±0.0088i}, 1.0000.
dt = 0.01
def pole(r, ang=0.0):
    s_re = math.log(r) / dt
    s_im = ang / dt
    wn = math.hypot(s_re, s_im)
    zeta = -s_re / wn if wn > 0 else None
    T = 2 * math.pi / s_im if s_im > 0 else None
    return {"re_1s": round(s_re, 3), "im_rads": round(s_im, 3), "wn_rads": round(wn, 3),
            "zeta": round(zeta, 3) if zeta is not None else None, "period_s": round(T, 2) if T else None}
out["hiway_demon_modes"] = {
    "source": "arXiv:2108.02393 Table 2 (model: Cook & Spottiswoode, Aeronaut. J. 2006), dt=0.01 s",
    "short_period": pole(0.9801, 0.0219),
    "phugoid": pole(1.0009, 0.0116),
    "roll_subsidence": pole(0.7978),
    "spiral": pole(0.9949),
    "dutch_roll": pole(0.9973, 0.0088),
    "note": "4 состояния по тангажу (u,w,q,θ) и 5 по крену — пилот жёстко связан с крылом (controls fixed), отдельной степени маятника нет",
}

# ---------------------------------------------------------------- 2. Геометрия и массы (sport, pilot.json)
wing = cfg("wings/sport.json")
pilot = cfg("pilot.json")
flight = cfg("flight.json")
m_p = wing["pilot_mass_ref_kg"]
m_w = wing["wing_mass_kg"]
b = wing["span_m"]; S = wing["area_m2"]; c = S / b
L_strap = pilot["visual"]["hang_length_m"]
d_cg = pilot["visual"]["body_below_hang_m"]  # центр тела под подвеской (ЦМ пилота ≈ там)
x_bar = flight["visual"]["pilot_bar_m"]; y_shift = flight["visual"]["pilot_shift_m"]
out["geometry"] = {"m_pilot_kg": m_p, "m_wing_kg": m_w, "span_m": b, "area_m2": S, "mean_chord_m": round(c, 3),
                   "strap_m": L_strap, "pilot_cg_below_hang_m": d_cg, "bar_travel_pitch_m": x_bar, "bar_travel_roll_m": y_shift}

# ---------------------------------------------------------------- 3. Маятник пилота
# точечная масса на нити d: T = 2π√(d/g); физический маятник (тело лёжа, I_cg поперёк ≈ m·h²/12, h=1.75):
h = pilot["visual"]["height_m"]
I_p_pitch = m_p * h * h / 12.0          # лёжа, вокруг поперечной оси (стержень)
I_p_roll = m_p * (0.18 ** 2) / 2.0 * 1.3  # вокруг продольной оси: цилиндр r≈0.18 м, ×1.3 за руки/ноги (оценка)
def pend(d, I_cg):
    w2 = m_p * G * d / (I_cg + m_p * d * d)
    return {"wn_rads": round(math.sqrt(w2), 3), "period_s": round(2 * math.pi / math.sqrt(w2), 3)}
out["pilot_pendulum"] = {
    "point_mass_d=strap": pend(L_strap, 0.0),
    "point_mass_d=cg": pend(d_cg, 0.0),
    "physical_pitch_swing(I_cg=m h^2/12)": pend(d_cg, I_p_pitch),
    "physical_roll_swing(I_cg~cylinder)": pend(d_cg, I_p_roll),
    "I_pilot_pitch_kgm2": round(I_p_pitch, 1), "I_pilot_roll_kgm2": round(I_p_roll, 2),
    "note": "крыло не закреплено: маятник качается относительно общего ЦМ, приведённая длина d·m_w/(m_w+m_p)… см. coupled",
}
# связанная система крыло(точка)+пилот без аэродинамики: относительное колебание с приведённой массой
mu = m_p * m_w / (m_p + m_w)
w2_free = (m_p + m_w) / m_w * G / d_cg   # маятник, у которого точка подвеса — свободная масса m_w
out["pilot_pendulum"]["coupled_free_wing_no_aero"] = {"wn_rads": round(math.sqrt(w2_free), 3),
    "period_s": round(2 * math.pi / math.sqrt(w2_free), 3),
    "note": "верхняя граница частоты: крыло без аэродинамики свободно; в полёте подъёмная сила ~ держит крыло, частота между point_mass и этим"}

# ---------------------------------------------------------------- 4. Инерция крыла (оценка по модели масс flight.json ground_bank)
gb = flight["ground_bank"]
I_w_roll = gb["span_mass_fraction"] * m_w * b * b / 12.0
I_added_roll = math.pi / 48.0 * RHO * c * c * b ** 3
I_w_pitch = m_w * 0.55 * (2.3 ** 2) / 12.0 + m_w * 0.45 * 0.15 ** 2  # киль+ЛЕ вдоль хорды (стержень 2.3 м ~55 % массы), остальное у ЦМ
I_added_pitch = math.pi / 128.0 * RHO * c ** 4 * b  # пластина: m_add=πρc²b/4 на единицу… ≈ πρ c^4 b/128 вокруг середины хорды
I_w_yaw = I_w_roll + I_w_pitch
out["wing_inertia_estimate_sport"] = {
    "Ixx_structure": round(I_w_roll, 1), "Ixx_added_air": round(I_added_roll, 1), "Ixx_total": round(I_w_roll + I_added_roll, 1),
    "Iyy_structure": round(I_w_pitch, 1), "Iyy_added_air": round(I_added_pitch, 1), "Iyy_total": round(I_w_pitch + I_added_pitch, 1),
    "Izz_structure": round(I_w_yaw, 1),
    "pilot_about_hang_point_m_d2": round(m_p * d_cg ** 2, 1),
    "note": "оценки по трубам и присоединённой массе (flight.json → ground_bank); точный расчёт по модели масс Blender — задача PD-1",
}

# ---------------------------------------------------------------- 5. Балансировка: Cm_alpha по двум точкам трима
polar_ref_mass = wing["pilot_mass_ref_kg"] + m_w
a = wing["lift_slope_per_rad"]; alpha0 = math.radians(wing["zero_lift_alpha_deg"])
def cl_at(v_kmh):
    v = v_kmh / 3.6
    return 2 * polar_ref_mass * G / (RHO * S * v * v)
def alpha_at(v_kmh):
    return cl_at(v_kmh) / a + alpha0
v_trim = wing["trim_speed_kmh"]; v_pull = wing["full_pull_speed_kmh"]; v_push = wing["full_push_speed_kmh"]
q_pull = 0.5 * RHO * (v_pull / 3.6) ** 2
M_pilot_full = m_p * G * x_bar  # момент веса пилота при полном ходе трапеции (статика: вес × смещение ЦМ)
dalpha = alpha_at(v_pull) - alpha_at(v_trim)
Cm_alpha = abs(M_pilot_full / (q_pull * S * c * dalpha))  # по модулю, 1/рад
q_trim = 0.5 * RHO * (v_trim / 3.6) ** 2
M_alpha_trim = q_trim * S * c * Cm_alpha
out["trim_calibration_sport"] = {
    "CL_trim": round(cl_at(v_trim), 3), "alpha_trim_deg": round(math.degrees(alpha_at(v_trim)), 2),
    "CL_pull": round(cl_at(v_pull), 3), "alpha_pull_deg": round(math.degrees(alpha_at(v_pull)), 2),
    "CL_push_config": round(cl_at(v_push), 3), "note_push": "CL_push > CL_max: полный ход «от себя» в конфиге лежит за сваливанием — в модели моментов скорость «от себя» задаётся не конфигом, а срывом",
    "pilot_moment_full_bar_Nm": round(M_pilot_full, 1),
    "Cm_alpha_abs_per_rad": round(Cm_alpha, 3),
    "M_alpha_at_trim_Nm_per_rad": round(M_alpha_trim, 1),
    "bar_force_at_full_pull_N(статика, плечо до штанги 1.55 м)": round(M_pilot_full / 1.55, 1),
}
# короткий период: ω² ≈ M_α/I; крыло отдельно (пилот свободно качается) и controls fixed (пилот жёстко)
I_wing_pitch_tot = I_w_pitch + I_added_pitch
I_fixed = I_wing_pitch_tot + m_p * d_cg ** 2
out["short_period_estimate_sport"] = {
    "wing_alone_wn_rads": round(math.sqrt(M_alpha_trim / I_wing_pitch_tot), 2),
    "controls_fixed_wn_rads": round(math.sqrt(M_alpha_trim / I_fixed), 2),
    "note": "без Cm_q и Z_w; реальная связанная мода — между ними; Cook/Spottiswoode (Hiway Demon): 2.97 рад/с, ζ 0.68",
}
# фугоида Ланчестера
V_trim = v_trim / 3.6
out["phugoid_lanchester"] = {"period_s": round(math.pi * math.sqrt(2) * V_trim / G, 2), "V_trim_ms": round(V_trim, 2)}

# ---------------------------------------------------------------- 6. Интегратор
hz = [60, 120, 240]
w_pend = out["pilot_pendulum"]["coupled_free_wing_no_aero"]["wn_rads"]
k_arm = 3000.0  # Н/м — жёсткость «руки-регулятора» (оценка: 300 Н на 0,1 м хода)
w_arm = math.sqrt(k_arm / m_p)
EA_webbing = 4.0e5  # Н — полиэстеровая стропа 25 мм, ε≈1 % при 4 кН (порядок, по данным производителей строп)
k_strap = EA_webbing / L_strap
w_strap = math.sqrt(k_strap / m_p)
out["integrator"] = {
    "omega_dt": {f"{h}Hz": {"pendulum": round(w_pend / h, 4), "arm_spring(k=3000)": round(w_arm / h, 3),
                             "strap_as_spring(EA=4e5)": round(w_strap / h, 3)} for h in hz},
    "omega_arm_rads": round(w_arm, 2), "omega_strap_rads": round(w_strap, 1),
    "rule": "полу-неявный Эйлер устойчив при ω·dt < 2; стропа как пружина при 120 Гц ω·dt≈0.5 — на грани (жёсткая), поэтому стропа — ограничение (PBD), не пружина",
}

# ---------------------------------------------------------------- 7. Крен: статика смещения веса
# момент веса при полном смещении и аэродемпфирование крена
M_roll_full = m_p * G * y_shift
Clp = -0.45  # 1/рад, типично для крыла с удлинением ~7 (Kroo/ESDU порядок)
Lp = 0.5 * RHO * V_trim * S * b * b * Clp / 4.0  # Н·м·с (производная по p, рад/с)
I_roll_total = I_w_roll + I_added_roll + m_p * 0.0  # пилот на оси крыла по крену почти не добавляет (висит на оси)
out["roll_estimate_sport"] = {
    "pilot_moment_full_shift_Nm": round(M_roll_full, 1),
    "L_p_Nms_at_trim": round(Lp, 1),
    "roll_time_constant_s(I/|L_p|)": round(I_roll_total / abs(Lp), 3),
    "steady_roll_rate_if_no_restoring_dps": round(math.degrees(M_roll_full / abs(Lp)), 1),
    "note": "установившейся скорости крена нет: в вираже вес пилота уходит в плоскость симметрии (Takamatsu & Ochi 2022) и крен держит аэродинамика; число — только порядок",
}

with open(os.path.join(HERE, "estimates.json"), "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
for k, v in out.items():
    print(f"## {k}")
    print(json.dumps(v, ensure_ascii=False, indent=1))
