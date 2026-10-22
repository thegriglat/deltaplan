#!/usr/bin/env python3
"""Пишет configs/tow_tug.json (блоки TT-К1; старые ключи TW-К9 сохраняются), thrust_table.csv, wing_trike_ixess15.json."""
import json, math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tugmodel import *
import cart

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
CFG = os.path.join(ROOT, "configs", "tow_tug.json")
tp = json.load(open(os.path.join(ROOT, "tools", "blender", "trike_params.json")))["dims"]
W = lambda k: tp[k]["value"]

DOC = "docs/research/tow/trike-tug.md"
cda = cart.cda()
m_cg, cg_f, cg_u, cg_len = cart.cg()
cart_mass = cart.EMPTY + cart.PILOT + cart.FUEL
prop = Prop(R582)
wing = Wing(cda)

# --- таблица тяги ---
vs = [0, 2.5, 5, 7.5, 10, 12.5, 15, 17.5, 20, 22.5, 25, 27.5, 30, 35]
full = []; idle = []; rpm = []
for v in vs:
    r, T, eta = prop.full(v)
    full.append(round(T)); idle.append(round(prop.idle(v))); rpm.append(round(r))
with open(os.path.join(HERE, "thrust_table.csv"), "w") as f:
    f.write("v_ms,full_n,idle_n,rpm_full,eta\n")
    for v, a, b, c in zip(vs, full, idle, rpm):
        f.write("%g,%d,%d,%d,%.3f\n" % (v, a, b, c, prop.full(v)[2]))

cfg = json.load(open(CFG), object_pairs_hook=__import__("collections").OrderedDict)
cfg["contract"] = "TT-К1 v1"
cfg["_doc"] = ("Буксировщик аэробуксировки: дельталёт (тележка с Rotax 582 + крыло iXess 15), TT-К1 v1. Расчёты, источники и допущения — " + DOC +
               "; скрипты — tools/research/tow-trike/ (python3 build.py). Верхние ключи TW-К9 (tow_speed_kmh … away_s) оставлены, пока "
               "scripts/game/tow_tug.gd их читает (до TT-4). ЧЕСТНО: тяга — расчётная (винт по калибровке, не по измерению), "
               "массы — оценка по аналогам, а не паспорт конкретной тележки; блока autopilot нет (TT-4).")
cfg["wing"] = "trike_ixess15"
cfg["wing_doc"] = "id крыла в configs/wings/ (TT-К2); числа — tools/research/tow-trike/wing_trike_ixess15.json"
cfg["cart"] = {
 "empty_mass_kg": cart.EMPTY,
 "empty_mass_kg_doc": "Двухместная тележка с Rotax 582 без крыла, сухая (без топлива): оценка 150 кг. Аналоги (Wikipedia, масса пустого аппарата, обычно с крылом): Aquilair Swing 155, TL-22 Duo 160, Deltacraft MD-50C 178, FUL Graffiti 185, Junkers Profly 186 (крыло 12,8 м²), PowerTrike II/Sunward ST 198 (кг); минус крыло 35-50 кг → 110-160. Паспорт HADS Tanarg/912: 250 − 53 = 197. Разброс ±25 кг",
 "pilot_mass_kg": cart.PILOT,
 "pilot_mass_kg_doc": "Пилот, 80-85 кг (configs/pilot.json), взято 82,5",
 "fuel_kg": cart.FUEL,
 "fuel_kg_doc": "Топливо ≈ 40 л из бака 53 л (tools/blender/trike_params.json tank_volume_l) × 0,74 кг/л (смесь бензин+масло); буксировочный полёт короткий",
 "mass_kg": cart_mass,
 "mass_kg_doc": "Сумма empty + pilot + fuel; без крыла (53 кг iXess 15 — в configs/wings)",
 "cg_below_hang_m": round(cg_len, 2),
 "cg_below_hang_m_doc": "Расстояние ЦМ тележки с пилотом от подвески: расчёт по узлам trike_params.json (сиденье, бак, ось винта; двигатель, рама и остаток — оценка) — cart.py: ЦМ %.2f м вперёд и %.2f м вниз → %.2f м; без учёта кувыркающегося пилота" % (cg_f, -cg_u, cg_len),
 "cda_m2": round(cda, 2),
 "cda_m2_doc": "Лобовое сопротивление тележки с пилотом, оценка по составляющим (cart.py): пилот 0,45 (Wilson, Bicycling Science), колёса 0,12, трубы 0,20 (Hoerner), двигатель 0,05; ±30 %. Прямого источника для трайка нет",
 "arms_force_max_n": 500.0,
 "arms_force_max_n_doc": "Предел силы на штанге, Н: оценка. Момент крена при смещении ЦМ тележки 0,3 м от подвески при 315 кг ≈ 900 Н·м на плече штанги ≈1,6 м → до 560 Н; сильный взрослый развивает 400-600 Н двумя руками. Источника по трайкам не нашёл (BMAA/HADS силу не нормируют)",
 "tow_hook": [0.0, -1.55, 1.45],
 "tow_hook_doc": "Точка троса, оси trike.glb (от HangPoint, +Y вверх, нос −Z): задний узел рамы за двигателем на 1,55 м ниже подвески (0,95 м над землёй), на 1,45 м позади (длина тележки 2,745 м; trike_params: ось заднего колеса −0,55 м, двигатель за сиденьями) — оценка: у буксировщиков отцеп на хвосте рамы",
 "tow_hook_on": "pilot",
 "tow_hook_on_doc": "Трос тянет за раму тележки (пилот+рама), а не за подвеску",
}
cfg["engine"] = {
 "name": "Rotax 582 UL DCDI",
 "name_doc": "Двигатель аппарата: Rotax 582 UL DCDI (trike_params.json prototype)",
 "gear_ratio": 3.47,
 "gear_ratio_doc": "Редуктор Rotax типа C 3,47:1 (trike_params.json; Wikipedia Rotax 582: C/E 2,62-4,0)",
 "power_max_kw": 48.0,
 "power_max_kw_doc": "Rotax 582 UL DCDI: 48 кВт (64 л.с.) @ 6500 об/мин, макс. момент 75 Нм @ 6000, макс. 6800 (rotax-owner.com, OM 582 UL; Wikipedia Rotax 582); редуктор C 3,47:1 (trike_params.json)",
 "prop_d_m": 1.8,
 "prop_d_m_doc": "trike_params.json dims.prop_d: 1,8 м",
 "prop_blades": 2,
 "prop_blades_doc": "trike_params.json dims.prop_blades (решение пользователя)",
 "prop_rpm_idle": W("prop_rpm_idle"),
 "prop_rpm_max": W("prop_rpm_max"),
 "prop_rpm_doc": "Обороты винта = trike_params.json dims.prop_rpm_idle / prop_rpm_max (2000 и 6800 об/мин двигателя ÷ 3,47)",
 "thrust_tilt_deg": W("prop_tilt_deg"),
 "thrust_tilt_deg_doc": "trike_params.json dims.prop_tilt_deg",
}
cfg["thrust"] = {
 "_doc": ("T(V,g) = idle_n(V) + g·(full_n(V) − idle_n(V)); обороты винта rpm = prop_rpm_idle + g·(rpm_full − prop_rpm_idle). Расчёт (tugmodel.py): "
          "мощность двигателя по кривой 582 (48 кВт @6500) и винт фиксированного шага Ct=Ct0(1−J/J0), Cp=Cp0(1−0,35 J/J0); Cp0 — по статическим оборотам 5600 об/мин двигателя, "
          "Ct0 — по статической тяге с FM 0,60 (идеальный диск), J0 — по пику КПД 0,72; равновесие мощности двигателя и винта. "
          "Статика %d Н при FM 0,60 (диапазон FM 0,5-0,7 → ≈1450-1700 Н). Измеренной тяги винта 1,8 м/582 в источниках нет; метод проверен на Tanarg/912ULS: см. документ. "
          "idle_n обрезан снизу нулём (контракт): отрицательная тяга авторотации винта на холостых не моделируется." % full[0]),
 "v_ms": vs, "full_n": full, "idle_n": idle, "rpm_full": rpm,
}
cfg["ground"] = {
 "keel_angle_deg": 10.0,
 "keel_angle_deg_doc": "Тангаж киля крыла на земле при нейтральной штанге, °: оценка. Тележка на трёх колёсах горизонтальна, штанга нейтральна → крыло на угле, близком к углу атаки триммерного полёта (≈10-12° у крыльев такого класса); источника нет",
 "rotate_deg": 8.0,
 "rotate_deg_doc": "Добавка тангажа при полностью отданной штанге, °: оценка; запас до угла сваливания α_max ≈ CL_max %.2f / 4,5 ≈ 20° от нуля подъёмной силы" % wing.CLmax,
 "rolling_crr": 0.07,
 "rolling_crr_doc": "Коэффициент качения по траве: 0,05 (короткая) … 0,10 (высокая) — Gudmundsson, General Aviation Aircraft Design, табл. 'ground friction' (трава 0,05-0,10, твёрдый грунт 0,04); взято 0,07 с пневматиками 14″ низкого давления",
 "wheel_base_agl_m": round(-GROUND_Z - cg_len * (-cg_u) / cg_len, 2) if False else round(-cart.GROUND_Z + cg_u, 2),
 "wheel_base_agl_m_doc": "Высота ЦМ тележки над землёй на колёсах = hang_height (2,50 м) − вертикальная составляющая ЦМ под подвеской (%.2f м); trike_params.json" % (-cg_u),
}
cfg["tow"] = {
 "tow_speed_kmh": 60.0,
 "tow_speed_kmh_doc": "Решение пользователя 55-65, середина; BHPA 64 км/ч при начальном наборе (kinds-bhpa.md); сваливание iXess 15 при тележке с крылом 315 кг ≈ %.0f км/ч (HADS Vso 59,3 при 450 кг × √(315/450))" % (wing.vstall(cart_mass + 53) * 3.6),
 "slack_speed_ms": 1.0,
 "slack_speed_ms_doc": "Скорость выбора слабины: оценка (как TW-К9)",
 "glider_hold_agl_m": 3.0,
 "glider_hold_agl_m_doc": "BHPA §2.7.6 E: дельтаплан ≈3 м над землёй, буксировщик на разбеге (kinds-bhpa.md)",
 "rotate_speed_kmh": 56.0,
 "rotate_speed_kmh_doc": "Скорость отрыва тележки: ≈1,12 Vs крыла (Vs ≈ %.0f км/ч при 315 кг) — оценка по правилу 1,1-1,2 Vs; тележка без дельтаплана в паспортах (TODR 252 м у Tanarg, HADS Annex F) для 582 не найдена" % (wing.vstall(cart_mass + 53) * 3.6),
 "power_reduce_agl_m": 152.0,
 "power_reduce_agl_m_doc": "BHPA §2.7.6 E 2e: выше 500 фт (152 м) мощность снижают (kinds-bhpa.md)",
 "climb_limit_ms": 3.05,
 "climb_limit_ms_doc": "BHPA: выше 152 м набор ≤ 600 фт/мин = 3,05 м/с (kinds-bhpa.md)",
 "circuit_start_agl_m": 150.0,
 "circuit_start_agl_m_doc": "≈500 фт, не раньше (BHPA §2.7.6 E 2e; число для поворота в источниках н/д — оценка как TW-К9)",
 "circuit_bank_deg": 8.0,
 "circuit_bank_deg_doc": "Крен ≤ 10° на тросе 75±5 м (BHPA §2.7.6 E 2e5); взято 8° — круг R = 200 м при 60 км/ч даёт atan(v²/gR) = 8°",
}
cfg["away"] = {
 "throttle": 0.35,
 "throttle_doc": "После отцепа буксировщик снижает мощность (BHPA §2.7.6 E g); доля газа — оценка (на отрыв тяги хватает ≈ T − D)",
 "turn_deg": 0.0,
 "turn_deg_doc": "BHPA §2.7.6 E g: «снижает мощность и уходит прямо» — разворота нет; TT-4 может добавить уход в сторону",
 "turn_s": 4.0,
 "turn_s_doc": "Время разворота (не используется при turn_deg 0), оценка",
 "away_s": 15.0,
 "away_s_doc": "Через сколько секунд игра убирает модель (как TW-К9)",
}
with open(CFG, "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent="\t"); f.write("\n")

# --- крыло для TT-2 ---
cart_ref = cart_mass
m_ref = cart_ref + 53.0
s_ref = math.sqrt(m_ref / Wing.MTOW)
vs_ref = wing.vstall(m_ref)
pts = []
for f_ in [1.0, 1.04, 1.08, 1.15, 1.25, 1.4, 1.6, 1.85, 2.15, 2.5, 2.9, 3.3]:
    v = vs_ref * f_
    cl = m_ref * G / (0.5 * RHO * v**2 * Wing.S)
    sink = v * wing.cd(cl) / cl
    pts.append([round(v * 3.6, 2), round(sink, 3)])
best_g = max(pts, key=lambda p: p[0] / 3.6 / p[1])
ms = min(pts, key=lambda p: p[1])
sink80 = None
v80 = 80 / 3.6; cl80 = m_ref * G / (0.5 * RHO * v80**2 * Wing.S); sink80 = v80 * wing.cd(cl80) / cl80
trim = round(83.3 * s_ref, 1)
SRC_M = "вывод: HADS HM16 Vso 59,3 км/ч при MTOW 450 → ×√(m/450), m = тележка с пилотом %.1f + крыло 53 кг" % cart_ref
SRC_P = ("вывод (tugmodel.py Wing): параболическая поляра CD=CD0+k·CL², k=1/(π e AR), e=0,75, AR 6,66; CD0=%.4f по HADS HM16 Annex F "
         "(качество 6,6 всей связки на 74,1 км/ч, MTOW 450) минус CdA тележки %.2f м²; CL_max=%.2f по Vso 59,3. Поляра крыла БЕЗ тележки (тележка — cda_m2 в tow_tug.json). Ошибка поляры ≈ ±15 %%" % (wing.CD0, cda, wing.CLmax))
out = {
 "_doc": "Числа крыла iXess 15 для TT-2 (configs/wings/trike_ixess15.json, glider_params.json → wings.trike_ixess15): каждое {value, src}; 'оценка' — без источника, 'вывод' — расчёт. Скрипт: build.py. Масса — тележка Rotax 582 с пилотом и топливом.",
 "area_m2": {"value": 15.0, "src": "tools/research/trike-model/wings.json: Wikipedia Air Creation iXess; BMAA HADS HM16 §5(c)"},
 "span_m": {"value": 10.0, "src": "tools/research/trike-model/wings.json: Wikipedia Air Creation iXess (Tanarg: 9,85)"},
 "wing_mass_kg": {"value": 53.0, "src": "tools/research/trike-model/wings.json: Wikipedia Air Creation iXess (WDLA); паспорта нет"},
 "pilot_mass_min_kg": {"value": round(cart.EMPTY + 55 + 15, 1), "src": "вывод: тележка 150 + мин. один пилот 55 кг (HADS §7(B) 55-120) + 15 кг топлива; масса ТЕЛЕЖКИ с пилотом"},
 "pilot_mass_max_kg": {"value": 397.0, "src": "вывод: MTOW 450 (HADS §7(A)) − крыло 53 кг = 397 кг тележки с экипажем и топливом"},
 "pilot_mass_ref_kg": {"value": cart_ref, "src": "tools/research/tow-trike: configs/tow_tug.json cart.mass_kg = 150 + 82,5 + 30"},
 "polar": {"points_kmh_ms": pts, "src": SRC_P + "; скорости при эталонной массе " + str(round(m_ref, 1)) + " кг, ρ=1,225"},
 "reference": {
  "stall_speed_kmh": {"value": round(vs_ref * 3.6, 2), "src": SRC_M},
  "min_sink_ms": {"value": ms[1], "src": SRC_P},
  "min_sink_speed_kmh": {"value": ms[0], "src": SRC_P},
  "best_glide": {"value": round(best_g[0] / 3.6 / best_g[1], 2), "src": SRC_P},
  "best_glide_speed_kmh": {"value": best_g[0], "src": SRC_P},
  "sink_at_80_kmh_ms": {"value": round(sink80, 3), "src": SRC_P},
 },
 "trim_speed_kmh": {"value": trim, "src": "оценка: скорость наилучшего набора 83,3 км/ч (HADS HM16 Annex D(g), 450 кг) × √(m/450); собственно трим в HADS не указан"},
 "full_pull_speed_kmh": {"value": 82.0, "src": "модельная скорость полной выборки штангой, ход TT-8 (0,1107 м) на упоре: 81,5 км/ч на нулевом газу (замеры TP-17, docs/research/trike-pilot/speed-range.md). 130 км/ч - Va по HADS (133, только в снижении), не горизонтальная скорость; горизонтальный потолок Rotax 582 по тяге ≈ 120 км/ч"},
 "full_push_speed_kmh": {"value": round(vs_ref * 3.6 * 1.05, 1), "src": "оценка: штанга полностью отдана — на пороге сваливания, 1,05·Vs"},
 "double_surface_pct": {"value": 90, "src": "tools/research/trike-model/wings.json: Wikipedia Air Creation iXess (по пересказу, не перепроверено)"},
 "kingpost": {"value": True, "src": "tools/research/trike-model/wings.json: Wikipedia iXess — крыло с кингпостом; проверить по фото"},
 "glider_params": {
  "nose_angle_deg": {"value": 120, "src": "wings.json: Wikipedia iXess"},
  "root_chord_m": {"value": 2.4, "src": "wings.json: вывод R+T=2S/b, T/R=0,25"},
  "tip_chord_m": {"value": 0.6, "src": "wings.json: вывод R+T=2S/b, T/R=0,25"},
  "kingpost_m": {"value": 1.4, "src": "оценка: н/д в HADS и Wikipedia; training 1,25 м при размахе меньше, пропорционально размаху"},
  "dihedral_deg": {"value": 1.5, "src": "оценка: как glider_params.json training; в источниках н/д"},
  "washout_deg": {"value": 10, "src": "оценка: как sport (pendulum.washout_deg 10); в HADS н/д"},
  "battens_per_side": {"value": 12, "src": "оценка: н/д; крылья 15 м² с двойной обшивкой 90 % — 10-14"},
 },
}
json.dump(out, open(os.path.join(HERE, "wing_trike_ixess15.json"), "w"), ensure_ascii=False, indent=1)
print("OK", full[:4], "cg_len %.2f cda %.2f mass %.1f vs_ref %.1f" % (cg_len, cda, cart_mass, vs_ref * 3.6))
