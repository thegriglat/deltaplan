"""Тело пилота (PB-1, `Params.pilot_body = "body"`): пилот лёжа в коконе как вытянутое тело.

Чем отличается от точки (`"point"`: изотропное сопротивление `pilot_cda` по относительной скорости):
1. Сопротивление анизотропно: вдоль тела — лобовое `CdA_f` (Kroo 1981: 0,21 м²), поперёк — по
   принципу поперечного обтекания (cross-flow principle, Allen & Perkins 1951, NACA RM A50L07):
   нормальная сила пропорциональна квадрату поперечной составляющей скорости, коэффициент
   `body_cd_cross` конечного цилиндра (Hoerner 1965, гл. III: l/d ≈ 5 → ≈ 0,8), площади — боковая
   (`body_len·body_depth`) и плановая (`body_len·body_width`). Линейного по углу члена у замкнутого
   тела нет (потенциальная сила Мунка = 0 при нулевой площади донного среза), остаётся только
   дестабилизирующий момент Мунка q·Vol·(k2 − k1)·sin 2β (Munk 1924, NACA TR-184).
2. Тело разбито на `body_segments` отрезков по длине: у каждого своя местная скорость (поступательная
   скорость узла пилота + ω_крыла × r), так что вращение тела даёт демпфирование само собой.
3. Ориентация: ось тела — ось киля крыла, спроецированная перпендикулярно стропе («тело ⊥ стропе»,
   как в `_head_world`); тело держится руками за штангу — по рысканию и крену оно жёстко связано с
   крылом: его собственная инерция `body_izz`, `body_ixx` прибавляется к инерции крыла, а
   аэродинамический момент тела (составляющие по рысканию и крену) передаётся крылу. Тангажная
   составляющая момента (кивок тела вокруг поперечной оси) отбрасывается: кивок не моделируется.
4. Сила тела приложена к узлу пилота (ЦМ тела), как и у точки; доля сопротивления пилота в поляре
   (`cd_pilot_share`) по-прежнему `pilot_cda`: при `body_cda_front = pilot_cda` трим не меняется.

Все числа тела — оценки по антропометрии и справочникам (EST в params.py), не подгонка.
"""

from __future__ import annotations

import math

import numpy as np

from .params import Params


def body_frame(R: np.ndarray, d_world: np.ndarray):
    """Оси тела в мире: fwd — киль ⊥ стропе, right — вправо, up — к подвеске (−d).
    d_world — направление стропы от подвески к пилоту (единичное или нет)."""
    d = d_world / max(float(np.linalg.norm(d_world)), 1e-9)
    up = -d
    x = R[:, 0]
    fwd = x - float(x @ up) * up
    n = float(np.linalg.norm(fwd))
    if n < 1e-6:
        fwd = R[:, 2] - float(R[:, 2] @ up) * up
        n = float(np.linalg.norm(fwd))
    fwd = fwd / n
    right = np.cross(fwd, up)
    return fwd, right, up


def cda_front(p: Params) -> float:
    return p.pilot_cda if math.isnan(p.body_cda_front) else p.body_cda_front


def body_aero(p: Params, va: np.ndarray, w: np.ndarray, fwd, right, up):
    """Сила на тело (мир) и момент около его ЦМ (мир) при скорости ЦМ относительно воздуха va и
    угловой скорости w (мир; тело вращается с крылом). Возвращает (F, M_yaw_roll), где во второй
    оставлены только составляющие по осям up (рыскание) и fwd (крен)."""
    rho = p.rho
    n = max(int(p.body_segments), 1)
    L = p.body_len
    xs = (np.arange(n) + 0.5) / n * L - 0.5 * L
    dl = L / n
    a_side = p.body_depth * dl  # боковая площадь отрезка (нормаль — right)
    a_plan = p.body_width * dl  # плановая площадь отрезка (нормаль — up)
    cdc = p.body_cd_cross
    F = np.zeros(3)
    M = np.zeros(3)
    ua0 = float(va @ fwd)
    # лобовое — по осевой составляющей, равномерно по длине (момента не даёт)
    F += -0.5 * rho * cda_front(p) * ua0 * abs(ua0) * fwd
    for x in xs:
        r = x * fwd
        v = va + np.cross(w, r)
        uy, uz = float(v @ right), float(v @ up)
        uc = math.hypot(uy, uz)
        f = -0.5 * rho * cdc * uc * (a_side * uy * right + a_plan * uz * up)
        F += f
        M += np.cross(r, f)
    # момент Мунка (дестабилизирующий) по рысканию: |N| = q·Vol·(k2−k1)·sin 2β_тела; ветер справа
    # (uy0 > 0) поворачивает нос влево, то есть момент вдоль +up (= −z связанных осей)
    uy0 = float(va @ right)
    V2 = float(va @ va)
    if V2 > 1e-6 and p.body_volume > 0.0:
        beta_b = math.atan2(uy0, max(ua0, 0.1))
        M += 0.5 * rho * V2 * p.body_volume * p.body_munk * math.sin(2.0 * beta_b) * up
    # к крылу — только рыскание и крен (тело держится руками); кивок не моделируется
    M_out = float(M @ up) * up + float(M @ fwd) * fwd
    return F, M_out


def pilot_force(p: Params, va: np.ndarray, w: np.ndarray, R: np.ndarray, d_world: np.ndarray):
    """Единая точка входа: сила на пилота (мир) и момент тела на крыло (мир) для point / body."""
    if p.pilot_body != "body":
        return -0.5 * p.rho * p.pilot_cda * float(np.linalg.norm(va)) * va, np.zeros(3)
    fwd, right, up = body_frame(R, d_world)
    return body_aero(p, va, w, fwd, right, up)


def inertia_add(p: Params) -> np.ndarray:
    """Добавка к тензору инерции крыла (оси B) от тела, жёстко связанного по крену и рысканию."""
    I = np.zeros((3, 3))
    if p.pilot_body == "body":
        I[0, 0] = p.body_ixx
        I[2, 2] = p.body_izz
    return I
