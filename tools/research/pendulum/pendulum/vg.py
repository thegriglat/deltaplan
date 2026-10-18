"""VG (variable geometry, натяжение паруса) для прототипа маятника — PB-2, контракт PB-К1.

`apply_vg(p, vg)` → новая копия Params; `vg` 0…1 (0 — шнур отпущен, как сейчас; 1 — затянут до упора).
Меняются только параметры крыла; крыло без VG (`has_vg(wing_id)` False) — без изменений при любом `vg`.
VG постоянен на прогон.

Что физически делает VG (руководства и Kroo 1981, см. docs/research/pendulum/vg.md, раздел «Физика VG»):
шнур через полиспаст тянет поперечину назад вдоль киля → угол носа каркаса растёт (T2C 127→132°, Litespeed
130→132°, Combat L 129→131°) → парус натягивается вдоль размаха → меньше крутки (washout) и упругости паруса →
трим быстрее (T2C: 34 → 40–47 км/ч к ¾ хода), меньше усилие «на себя» на скорости, лучше качество на скорости,
крен тяжелее и медленнее (T2C: за ½ хода «усилия заметно растут, поворотливость заметно падает»).

Рычаги модели (всё — существующие поля Params / геометрии; величины — из источников, оценки помечены EST):
- `washout`: −VG_WASHOUT_DEG·min(vg/0,75; 1), не ниже VG_WASHOUT_MIN_DEG (сproги/антипикирующие держат минимум
  крутки конца). Величина — калибровка по документированному сдвигу трима T2C (×1,28 к ¾ хода), не по Vmax;
  насыщение к ¾ — T2C («между ¾ и полностью трим почти не меняется»), Litespeed («к ½ хода большая часть
  крутки снята»);
- `sweep`, `span` (угол носа +VG_NOSE_DEG·vg при той же длине кромки, размах ∝ sin(нос/2)) — рычаг есть, но
  ВЫКЛЮЧЕН (VG_NOSE_ENABLED = False): в полосовой модели +3° носа сдвигают концы на ≈ 13 см вперёд, фокус уходит
  вперёд от подвески, трим падает 35 → 30 км/ч и качество 10,9 → 7,6 (pb2_calib.py, nose_vg1) — против
  руководств (трим с VG растёт). Реальное крыло сбалансировано как целое; документированный суммарный сдвиг
  трима уже сидит в калибровке крутки, включать нос — считать его дважды;
- `sail_flex`: ×(1 − VG_FLEX_DROP·vg) — перекос пузыря пропорционален слабине паруса; остаток у затянутого
  (EST 30 %): Litespeed «full tight — quite difficult to control», но управляем;
- `extra["vg_cd_factor"]`: множитель к калибровке сопротивления полос (Sim.cd_scale выставляет опыт):
  1 − VG_CD_DROP·vg — качество на 55–80 км/ч +10–15 % по прежнему разбору руководств WW/Aeros
  (docs/archive/plan/wings-lineup.md, §5, [О]); Kroo 1981: «higher sail tension … reduces the drag
  substantially at low angles of attack» (рис. 45–46), крутка увеличивает CDmin и K (рис. 44);
- `dihedral`, `dcm0`, `cn_beta` — не меняются (источника с числом нет; EST «без изменений»).

Крылья с VG — `VG_WINGS` (из паспортов DHV: tools/research/pendulum/pb2_passport.py → out/pb2/passport.json;
без паспорта — по классу: безмачтовые все с VG, учебные без).
"""

from __future__ import annotations

import json
import math
from dataclasses import replace
from pathlib import Path

from .params import Params

VG_NOSE_DEG = 3.0  # ° угла носа за полный ход (T2C 5°, Litespeed 2°, Combat L 2°; середина, EST)
VG_NOSE_ENABLED = False  # см. докстринг: геометрический рычаг носа выключен
VG_WASHOUT_DEG = 6.0  # ° крутки конца, снимаемой к ¾ хода: калибровка по сдвигу трима T2C ×1,28 (34 → 40–47 км/ч)
# на sport: 35,4 → 44,9 км/ч (×1,27) при 6°; 4° → ×1,16, 8° → ×1,42 (pb2_calib.py, out/pb2/calib.md)
VG_WASHOUT_SAT = 0.75  # доля хода, к которой крутка снята (T2C, Litespeed)
VG_WASHOUT_MIN_DEG = 2.0  # ° минимальная крутка конца (антипикирующие; EST)
VG_FLEX_DROP = 0.7  # доля перекоса пузыря, снимаемая полным ходом (EST)
VG_CD_DROP = 0.12  # доля сопротивления полос, снимаемая полным ходом (качество +10–15 % на скорости, [О])

_HERE = Path(__file__).resolve().parent
_PASSPORT = _HERE.parent / "out" / "pb2" / "passport.json"
_CLASS4 = {"sport", "combat", "air_c4", "air_rev", "aeros_combat_c", "aeros_combat_l", "dp_she1", "moyes_litespeed_rx",
           "moyes_litespeed_s", "seed_spyder", "ww_fusion", "ww_t2c", "ww_t3", "ww_talon", "icaro_laminar_z9"}
_PASSPORT_VG = {"aeros_discus", "air_sting3", "bautek_fizz", "fs_space", "icaro_alto", "icaro_mastr", "moyes_gecko",
                "seed_skyrunner_xr", "ww_u2"}  # DHV: колонка «VG 100 %» в листе (passport.json)
# laminar — обобщённое мачтовое по образцу Icaro Laminar (VG есть: DHV Laminar 14.1 «V max 80 / >90»); EST по образцу
_BY_CLASS_VG = {"laminar", "moyes_litesport", "fs_crossover"}
VG_WINGS = _CLASS4 | _PASSPORT_VG | _BY_CLASS_VG


def has_vg(wing_id: str) -> bool:
    """Есть ли у крыла VG: паспорт DHV (passport.json, если есть) или список VG_WINGS."""
    if _PASSPORT.exists():
        try:
            row = json.loads(_PASSPORT.read_text(encoding="utf-8")).get(wing_id)
            if row is not None and row.get("has_vg") is not None:
                return bool(row["has_vg"])
        except (OSError, ValueError):
            pass
    return wing_id in VG_WINGS


def vg_washout(washout: float, vg: float) -> float:
    d = math.radians(VG_WASHOUT_DEG) * min(vg / VG_WASHOUT_SAT, 1.0)
    return max(washout - d, min(washout, math.radians(VG_WASHOUT_MIN_DEG)))


def apply_vg(p: Params, vg: float) -> Params:
    """Параметры крыла при натяжении VG `vg` (0…1). Копия; vg = 0 или крыло без VG — без изменений."""
    vg = float(min(max(vg, 0.0), 1.0))
    if vg <= 0.0 or not has_vg(p.wing_id):
        return replace(p)
    nose0 = math.pi - 2.0 * p.sweep
    nose = nose0 + math.radians(VG_NOSE_DEG) * vg if VG_NOSE_ENABLED else nose0
    span = p.span * math.sin(0.5 * nose) / math.sin(0.5 * nose0)
    return replace(
        p,
        sweep=0.5 * math.pi - 0.5 * nose,
        span=span,
        washout=vg_washout(p.washout, vg),
        sail_flex=p.sail_flex * (1.0 - VG_FLEX_DROP * vg),
        extra={**p.extra, "vg": vg, "vg_cd_factor": 1.0 - VG_CD_DROP * vg, "span_vg0": p.span,
               "washout_vg0_deg": math.degrees(p.washout)},
    )
