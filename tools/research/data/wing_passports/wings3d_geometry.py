#!/usr/bin/env python3
"""Геометрия паруса 3D-моделей (tools/blender/build_gliders.py → WingShape) без Blender.

Повторяет формулу хорды: c(a) = tip + (root - tip)·(1 - a^0.85), a = |y|/полуразмах, скруглённая
законцовка (a > 0.9) множит хорду на 1 - 0.35·((a - 0.9)/0.1)². Площадь паруса в плане = размах·∫c(a)da.
Используется для: (1) проверки, что площадь 3D-модели сходится с площадью конфига/паспорта;
(2) подбора хорды на конце при заданных размахе, площади, хорде у корня.
Только стандартная библиотека.
"""
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))


def mean_chord_factor(tip_round: bool = True, n: int = 2000):
    """(k_root, k_tip): ∫c(a)da = k_root·root + k_tip·tip."""
    kr = kt = 0.0
    for i in range(n):
        a = (i + 0.5) / n
        w = 1.0
        if tip_round and a > 0.9:
            w = 1.0 - 0.35 * ((a - 0.9) / 0.1) ** 2
        s = (1 - a ** 0.85) * w
        t = (1 - (1 - a ** 0.85)) * w
        kr += s / n
        kt += t / n
    return kr, kt


def implied_area(root: float, tip: float, span: float, tip_round: bool = True) -> float:
    kr, kt = mean_chord_factor(tip_round)
    return span * (kr * root + kt * tip)


def solve_tip(area: float, span: float, root: float, tip_round: bool = True) -> float:
    kr, kt = mean_chord_factor(tip_round)
    return (area / span - kr * root) / kt


def le_tip_setback(span: float, nose_angle_deg: float) -> float:
    """Отход концов крыла назад от носа по передней кромке (м): (b/2)/tan(угол_носа/2)."""
    return span / 2 / math.tan(math.radians(nose_angle_deg / 2))


def load_params():
    p = json.load(open(os.path.join(ROOT, "tools", "blender", "glider_params.json"), encoding="utf-8"))
    return p["wings"]


def load_cfg(name):
    return json.load(open(os.path.join(ROOT, "configs", "wings", name + ".json"), encoding="utf-8"))


if __name__ == "__main__":
    print("id | span | area_cfg | area_3d | d% | root | tip | nose | LE setback | 3D AR")
    for wid, p in load_params().items():
        cfg = load_cfg(p["config"])
        span = p.get("span_m", cfg["span_m"])
        a3 = implied_area(p["root_chord_m"], p["tip_chord_m"], span, p.get("tip_round", True))
        ac = p.get("area_m2", cfg["area_m2"])
        print(f"{wid:13s} {span:6.2f} {ac:6.2f} {a3:6.2f} {100*(a3/ac-1):+5.1f} "
              f"{p['root_chord_m']:.2f} {p['tip_chord_m']:.2f} {p['nose_angle_deg']} "
              f"{le_tip_setback(span, p['nose_angle_deg']):.2f} {span**2/ac:.2f}")
