"""Параметры прототипа «честного маятника»: крыло, пилот, подвеска — из конфигов игры.

Источники чисел (подробно — docs/research/pendulum.md, таблица параметров):
- configs/wings/<id>.json — площадь, размах, масса крыла, поляра, трим, наклон CL(α), α0;
- tools/blender/glider_params.json — геометрия каркаса (угол носа, хорды, крутка, V, трапеция, ЦМ труб);
- configs/pilot.json — масса пилота, ЦМ тела под карабином;
- оценки (помечены EST) — там, где в источниках числа нет.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field, replace
from pathlib import Path

import numpy as np

G = 9.80665
# Эффективное поперечное V в полёте (кромки под нагрузкой + пузырь паруса) и доля разницы нагрузок
# консолей, остающаяся после крутки гибкого паруса — калибровка по лётному опыту Takamatsu & Ochi 2022
# (Sport 2 155: ~30 Н вбок → крен ≈ 30° за ≈ 7 с, вираж ≈ 33° держится с усилием < 10 Н); сетка —
# docs/research/pendulum.md. Обе — настройки «Аппарат» (оценка, не паспорт).
DIHEDRAL_EFF_DEG = 1.0
FLEX_RELIEF = 0.2
RHO = 1.225
ROOT = Path(__file__).resolve().parents[4]  # корень копии репозитория


def _load(p: str) -> dict:
    return json.loads((ROOT / p).read_text())


class Polar:
    """Порт WingPolar (scripts/flight/wing_polar.gd): таблица CL→CD из точек (км/ч, м/с)."""

    def __init__(self, points, mass_ref, rho_ref, area):
        pairs = []
        for v_kmh, sink in points:
            v = v_kmh / 3.6
            sg = sink / v
            cg = math.sqrt(1 - sg * sg)
            cl = 2 * mass_ref * G * cg / (rho_ref * area * v * v)
            pairs.append((cl, cl * sg / cg))
        pairs.sort()
        self.cl = np.array([p[0] for p in pairs])
        self.cd = np.array([p[1] for p in pairs])
        self.cl_max = float(self.cl[-1])
        c1, c2 = self.cl[0], self.cl[1]
        self.k = max((self.cd[1] - self.cd[0]) / (c2 * c2 - c1 * c1), 0.0)
        self.cd0 = self.cd[0] - self.k * c1 * c1
        n = len(self.cl)
        self.slope_hi = (self.cd[n - 1] - self.cd[n - 2]) / (self.cl[n - 1] - self.cl[n - 2])

    def cd_at(self, cl):
        cl = np.asarray(cl, dtype=float)
        lo = self.cd0 + self.k * cl * cl
        hi = self.cd[-1] + self.slope_hi * (cl - self.cl[-1])
        mid = np.interp(cl, self.cl, self.cd)
        return np.where(cl <= self.cl[0], lo, np.where(cl >= self.cl[-1], hi, mid))


@dataclass
class Params:
    wing_id: str
    # крыло
    area: float
    span: float
    m_wing: float
    polar: Polar
    v_trim_ref: float  # м/с при эталонной массе
    v_pull_ref: float
    v_push_ref: float
    lift_slope: float  # 1/рад (3D, как в игре)
    alpha0: float  # рад, α нулевой подъёмной силы киля (игра)
    sweep: float  # рад, стреловидность передней кромки = 90° − угол носа/2
    root_chord: float
    tip_chord: float
    washout: float  # рад, крутка корень→конец (линейно)
    dihedral: float  # рад, поперечное V (+ концы вверх)
    keel_len: float
    crossbar_from_nose: float
    x_hang_game: float  # м от носа: подвеска в игре (ЦМ труб − 1,5 см, AF)
    upright_len: float
    upright_tilt: float  # рад, низ стоек вперёд от нормали к килю
    kingpost: float
    # пилот и подвеска
    m_pilot: float
    m_pilot_ref: float
    hang_len: float = 1.20  # м, подвеска → ЦМ пилота (de Matteis 1991 / Ochi: Hiway Demon 1,2 м)
    pilot_cda: float = 0.21  # м², Kroo 1981 (NASA TM-81269): 0,21 (разброс 0,12–0,23)
    strap_mass: float = 1.0  # кг, EST: стропа, карабин, стропы подвесной (на промежуточные звенья)
    strap_compliance: float = 4.0e-5  # м/Н, EST: удлинение подвески ~3 см под весом пилота
    # руки
    arm_force_max: float = 300.0  # Н, EST: предел усилия рук (Ochi 2022: в вираже |Tcy| до ~40 Н)
    arm_tau: float = 0.30  # с, EST: время реакции рук (как ground_bank.pilot_response_s)
    arm_ti: float = 0.0  # с: интеграл удержания положения; 0 — нет (PD-19: прямая подача силы маятника)
    shift_y_max: float = 0.45  # м, EST: смещение ЦМ пилота поперёк до упора (полуширина штанги − плечи)
    shift_x_pull: float = 0.45  # м, EST: «на себя» до упора — пилот вперёд относительно трапеции
    shift_x_push: float = 0.30  # м, EST: «от себя» до упора — пилот назад
    # аэродинамика
    n_strips: int = 16  # полос на всё крыло (чётное)
    cp_chord: float = 0.25  # доля хорды: точка приложения сил полосы (четверть хорды)
    cn_beta: float = 0.05  # 1/рад: «эквивалентный киль» (килевой карман); с полосами Cnβ крыла 0,038–0,06 —
    # выше Hiway Demon 0,0275 (0,018–0,04); PD-23: 0,035–0,045 — перевороты sport в болтанке на поле эталона
    cn_p_add: float = 0.15  # добавка Cn на pb/2V (PD-К2 v4, PD-23): Cnp полос −0,15 → литература
    cn_r_add: float = -0.03  # добавка Cn на rb/2V (PD-К2 v4, PD-23): Cnr → −0,058 (Hiway Demon)
    fin_arm: float = 1.6  # м позади ЦМ крыла: «эквивалентный киль», несущий Cnβ (и даёт Cnr, CYβ)
    fin_slope: float = 2.0  # 1/рад, малое удлинение
    apparent_roll: bool = True  # присоединённая масса воздуха по крену (π/48·ρ·c²·b³)
    flex_relief: float = FLEX_RELIEF  # 1 — жёсткое крыло; <1 — доля разницы нагрузок консолей, остающаяся после крутки паруса (EST)
    billow_shift_deg: float = 0.0  # крутка конца, ° на единицу tg угла стропы к крылу (EST, Kroo: киль-карман)
    dcm0: float = 0.0  # добавка Cm0 (рефлекс/парус), по умолчанию 0 — трим задаёт подвеска
    x_hang: float = float("nan")  # м от носа; NaN — из условия трима при dcm0 (см. trim.solve_hang)
    rho: float = RHO
    extra: dict = field(default_factory=dict)

    @property
    def m_total(self) -> float:
        return self.m_wing + self.m_pilot

    @property
    def fin_area(self) -> float:
        return self.cn_beta * self.area * self.span / (self.fin_slope * self.fin_arm)

    @property
    def chord_mean(self) -> float:
        return self.area / self.span

    def with_(self, **kw) -> "Params":
        return replace(self, **kw)


def load_params(wing_id: str, pilot_mass: float | None = None) -> Params:
    w = _load(f"configs/wings/{wing_id}.json")
    gp = _load("tools/blender/glider_params.json")
    geo = gp["wings"][wing_id]
    cf = gp["control_frame"]
    m_ref = float(w["pilot_mass_ref_kg"])
    m_wing = float(w["wing_mass_kg"])
    area = float(w["area_m2"])
    polar = Polar(w["polar"]["points_kmh_ms"], m_ref + m_wing, RHO, area)
    nose = math.radians(float(geo["nose_angle_deg"]))
    root = float(geo["root_chord_m"])
    return Params(
        wing_id=wing_id,
        area=area,
        span=float(w["span_m"]),
        m_wing=m_wing,
        polar=polar,
        v_trim_ref=float(w["trim_speed_kmh"]) / 3.6,
        v_pull_ref=float(w["full_pull_speed_kmh"]) / 3.6,
        v_push_ref=float(w["full_push_speed_kmh"]) / 3.6,
        lift_slope=float(w["lift_slope_per_rad"]),
        alpha0=math.radians(float(w["zero_lift_alpha_deg"])),
        sweep=0.5 * math.pi - 0.5 * nose,
        root_chord=root,
        tip_chord=float(geo["tip_chord_m"]),
        washout=math.radians(float(geo["washout_deg"])),
        dihedral=math.radians(DIHEDRAL_EFF_DEG),
        keel_len=root + float(geo.get("keel_extra_m", 0.1)),
        crossbar_from_nose=float(geo["crossbar_from_nose_m"]),
        x_hang_game=float(geo["cg_from_nose_m"]) - float(cf["hang_cg_offset_m"]),
        upright_len=float(geo.get("upright_len_m", cf["upright_len_m"])),
        upright_tilt=math.radians(float(geo.get("upright_tilt_deg", cf["upright_tilt_deg"]))),
        kingpost=float(geo.get("kingpost_m", 0.0)),
        m_pilot=float(pilot_mass if pilot_mass is not None else m_ref),
        m_pilot_ref=m_ref,
        extra={"mass_model": cf["mass_model"], "crossbar_u": float(geo.get("crossbar_u", 0.55)),
               "dihedral_geom_deg": float(geo["dihedral_deg"])},
    )


# Ориентиры игры (docs/guide/flight.md, режим weight_shift; учебное / мачтовое / спортивное).
GAME_REF = {
    "training": {"bank_full_shift_deg": 41, "center_level_s": 2.0, "overbank_deg": 70},
    "laminar": {"bank_full_shift_deg": 45, "center_level_s": 2.6, "overbank_deg": 65},
    "sport": {"bank_full_shift_deg": 44, "center_level_s": 3.3, "overbank_deg": 60},
    "_all": {"reversal_ws_s": 2.2, "reversal_rate_s": [2.3, 2.7]},
}
