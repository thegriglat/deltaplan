#!/usr/bin/env python3
"""TK-1: собирает tools/blender/trike_params.json (TK-K1). Запуск: python3 tools/research/trike-model/build_params.py
Оси: Blender (x вправо, y вперёд, z вверх), начало — точка подвески. Скелет пилота — D из tools/blender/build_pilot.py."""
import json, math, os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
XT = "https://www.airborne.com.au/pages/ml_xt912_specs.php"
HADS = "https://www.bmaa.org/files/hads_hm16_tanarg.pdf"
DULV = "https://www.dulv.de/kennblatt/Trike/693-161.pdf"
WIKI_TAN = "https://en.wikipedia.org/wiki/Air_Creation_Tanarg"
WIKI_R912 = "https://en.wikipedia.org/wiki/Rotax_912"
MAST = "https://www.aircraftpilots.com/forums/topic/6284-buzzard-trike-restoration/page/2"
ANTH = "https://www.ergocenter.ncsu.edu/wp-content/uploads/sites/18/2017/09/Anthropometric-Summary-Data-Tables.pdf"

HANG = 2.50
EYE_TRAINING = [0.0, 0.352, -1.144]   # замер measure_eye.gd, x = 0 по симметрии (см. README)
EYE_APOGEE = [0.0, 0.390, -1.122]

# посадка
BACK = math.radians(15.0)        # спинка от вертикали назад
TRUNK = 0.53                     # таз (бедренный сустав) -> C7 по оси туловища, м (вывод из роста сидя, ANTH)
NECK_UP, NECK_FWD = 0.20, 0.08   # C7 -> глаза при вертикальной голове, м
THIGH, SHIN, ANKLE_H = 0.43, 0.45, 0.09   # build_pilot.py class D
THIGH_UP = math.radians(8.0)     # бедро от горизонтали, колено выше таза
SHIN_DOWN = math.radians(50.0)   # голень от горизонтали вниз вперёд -> сгиб колена 58 град
FOOT_X = 0.15

def r(v): return [round(x, 3) for x in v]

ey, ez = EYE_TRAINING[1], EYE_TRAINING[2]
hip = [0.0, ey - (-TRUNK * math.sin(BACK) + NECK_FWD), ez - (TRUNK * math.cos(BACK) + NECK_UP)]
seat_pan = [0.0, hip[1] + 0.10, hip[2] - 0.10]
back_base = [0.0, hip[1] - 0.14, seat_pan[2] + 0.02]
knee = [FOOT_X - 0.02, hip[1] + THIGH * math.cos(THIGH_UP), hip[2] + THIGH * math.sin(THIGH_UP)]
ankle = [FOOT_X, knee[1] + SHIN * math.cos(SHIN_DOWN), knee[2] - SHIN * math.sin(SHIN_DOWN)]
foot = [FOOT_X, ankle[1] + 0.05, ankle[2] - ANKLE_H]
hand_y = 0.70
hand_z = hip[2] + (hand_y - hip[1]) * math.tan(THIGH_UP) + 0.09
seat_height = round(HANG + seat_pan[2], 3)

def d(v, s): return {"value": v, "src": s}
DER = "вывод: "
dims = {
    "length": d(2.745, XT + " (Trike Length)"),
    "width": d(1.91, XT + " (Trike Width, по внешней стороне обтекателей колёс)"),
    "hang_height": d(HANG, DER + "Trike Height 2.53 м (" + XT + ") — верх мачты; болт подвески ≈ на 3 см ниже; пилот на колёсах без нагрузки"),
    "wheelbase": d(1.89, XT + " (Wheel Base)"),
    "track": d(1.70, XT + " (Wheel Track)"),
    "wheel_front_d": d(0.356, DER + "14 дюймов — штатные шины Tanarg (" + HADS + ", Annex B 2b); опция 16 дюймов = 0.406 м"),
    "wheel_rear_d": d(0.356, DER + "14 дюймов — штатные шины Tanarg (" + HADS + ", Annex B 2b); опция 16 дюймов = 0.406 м"),
    "tire_front_w": d(0.10, DER + "оценка: типичная шина 4.00-6 малой авиации (источник по прототипу не найден)"),
    "tire_rear_w": d(0.12, DER + "оценка: типичная шина 4.00-6 малой авиации (источник по прототипу не найден)"),
    "mast_tilt_deg": d(18.0, MAST + " (мачта ≈ 18 градусов от вертикали у Edge-X 582 по сообщению на форуме; у самодельного трайка ≈ 11 градусов)"),
    "seat_height": d(seat_height, DER + "hang_height + seat.seat_pan.z (посадка по замеру глаз); типичная подушка переднего сиденья 0.5-0.6 м, источника по прототипу нет"),
    "engine": d("Rotax 912 UL 2 (80 л.с., редуктор 2.43:1)", XT + " (Engine)"),
    "engine_l": d(0.561, WIKI_R912 + " (Length 561 мм, 912 UL/A/F)"),
    "engine_w": d(0.576, WIKI_R912 + " (Width 576 мм, 912 UL/A/F)"),
    "engine_h": d(0.34, DER + "оценка 0.34 м (высота в Wikipedia не указана; источника нет)"),
    "prop_d": d(1.727, XT + " (Bolly BOS3, 68 дюймов); Tanarg: 1.75 м, " + DULV),
    "prop_blades": d(3, XT + " (Bolly BOS3 — трёхлопастной); Tanarg Helix H50F, 3 лопасти — " + DULV),
    "prop_axis_height": d(1.05, DER + "оценка 1.05 м: ось у середины высоты мачты; конец лопасти ≈ 0.19 м над землёй; прямого источника нет"),
    "prop_tilt_deg": d(2.0, DER + "оценка: ось винта слегка носом вверх; прямого источника нет"),
    "prop_rpm": d(2050, DER + "крейсерские обороты Rotax 912 ≈ 4950 об/мин / 2.43 (" + XT + "); максимум в стоянке 2260 об/мин, " + DULV),
    "prop_cw_from_behind": d(False, DER + "винт Rotax 912 вращается против часовой стрелки при взгляде на фланец винта; у толкающего трайка это взгляд сзади (не подтверждено источником)"),
    # дополнительно (не из контракта; для TK-3)
    "axle_rear_y": d(-0.55, DER + "оценка: задняя ось у основания мачты (мачта наклонена на 18 град, верх на hang_height)"),
    "axle_front_y": d(round(-0.55 + 1.89, 3), DER + "axle_rear_y + wheelbase (" + XT + ")"),
}

seat = {
    "eye": EYE_TRAINING,
    "hip": r(hip),
    "seat_pan": r(seat_pan),
    "seat_pan_size": [0.45, 0.42],
    "backrest_base": r(back_base),
    "backrest_angle_deg": 15.0,
    "backrest_size": [0.40, 0.55],
    "foot_l": r([-FOOT_X, foot[1], foot[2]]),
    "foot_r": r([FOOT_X, foot[1], foot[2]]),
    "throttle_pedal": r([FOOT_X, foot[1] - 0.02, foot[2] + 0.005]),
    "hand_l": r([-FOOT_X, hand_y, hand_z]),
    "hand_r": r([FOOT_X, hand_y, hand_z]),
}

out = {
    "version": 1,
    "prototype": {"name": "Airborne Edge XT 912 / Streak 3 (габариты, винт) + Air Creation Tanarg (шины, винт)", "seats": 2,
                  "sources": [XT, HADS, DULV, WIKI_TAN, WIKI_R912, MAST, ANTH]},
    "dims": dims,
    "ground_z": -HANG,
    "eye_measured": {"training": EYE_TRAINING, "apogee": EYE_APOGEE,
                     "how": "tools/research/trike-model/measure_eye.gd: Camera3D кабинной камеры (eye_mode back_hidden = PilotHead + back_offset_m 0.3) минус HangPoint, в базисе визуала пилота, автопилот, 16 отсчётов в полёте; x усреднён по крену и принят 0 (измерено -0.06 training, -0.09 apogee, разброс +-0.2 от крена)"},
    "seat": seat,
}
path = os.path.join(ROOT, "tools", "blender", "trike_params.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(path, "seat_height", seat_height)
print(json.dumps(seat))
