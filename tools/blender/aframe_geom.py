"""Геометрия трапеции и центровка крыла без Blender (docs/contracts/aframe-geometry.md, A1).

Общий код: build_gliders.py (сборка .glb) и aframe_cg.py (офлайн-скрипт центровки).
Оси крыла как в Blender: X вправо, Y вперёд, Z вверх; начало — HangPoint. d — расстояние вдоль
киля от носа назад (нос d = 0, у HangPoint d = nose_forward_m).
"""
import math

HANG_CG_OFFSET_DEFAULT = 0.015


def param(p: dict, cf: dict, key: str):
    """Параметр трапеции: запись крыла, иначе умолчание control_frame."""
    if key in p:
        return p[key]
    return cf[key]


def hang_from_apex(p: dict, cf: dict) -> float:
    """Подвеска вдоль киля относительно оси стоек под килем (+ — подвеска впереди вершины)."""
    if "hang_from_apex_m" in p:
        return p["hang_from_apex_m"]
    dd = cf["hang_from_apex_m"]  # умолчания {single, double} по двойной поверхности
    return dd["double"] if p["double_surface"] else dd["single"]


def frame_points(p: dict, cf: dict, tilt_deg: float = None) -> dict:
    """Точки трапеции в осях HangPoint (Blender: Y вперёд): вершина (ось стоек под килем),
    угол (ось базовой штанги), длина в плоскости киля s. Наклон — угол стойки к нормали киля
    в плоскости симметрии (проекция на YZ), низом вперёд."""
    tilt = math.radians(param(p, cf, "upright_tilt_deg") if tilt_deg is None else tilt_deg)
    w = p["basebar_width_m"] * 0.5
    top_x, top_z = cf["upright_top_x_m"], cf["upright_top_z_m"]
    length = param(p, cf, "upright_len_m")
    dx = w - top_x
    s = math.sqrt(length * length - dx * dx)  # длина проекции стойки на плоскость симметрии
    apex_y = -hang_from_apex(p, cf)
    return {
        "apex_y": apex_y, "top_x": top_x, "top_z": top_z, "w": w,
        "y_bb": apex_y + s * math.sin(tilt), "z_bb": top_z - s * math.cos(tilt), "s": s,
        "length": length,
    }


def basebar_spec(p: dict, cf: dict) -> tuple:
    """(bow_m, straight_len_m) базовой штанги крыла (PV3): wings.<id>.basebar, иначе
    control_frame.basebar_default; straight => (0, 0)."""
    b = p.get("basebar") or cf["basebar_default"]
    if b["shape"] == "straight":
        return 0.0, 0.0
    return float(b["bow_m"]), float(b.get("straight_len_m", 0.0))


def bow_at(x: float, w: float, bow: float, straight_len: float) -> float:
    """Вынос оси штанги вперёд в точке x (PV3): гладкая дуга (cos^2) на |x| < w - straight_len,
    у углов прямые участки; в центре ровно bow."""
    half = w - straight_len
    a = abs(x)
    if bow <= 0.0 or a >= half:
        return 0.0
    return bow * math.cos(math.pi * a / (2.0 * half)) ** 2


def le_d(p: dict, half: float, a: float) -> float:
    """Расстояние от носа вдоль киля до передней кромки на доле полуразмаха a (WingShape.le)."""
    tan_ha = math.tan(math.radians(p["nose_angle_deg"] * 0.5))
    d = a * half / tan_ha
    if a > 0.9 and p.get("tip_round", True):
        d += 0.35 * p["tip_chord_m"] * ((a - 0.9) / 0.1) ** 2 * 0.6
    return d


def cg_from_nose(p: dict, cf: dict, span: float, tilt_deg: float = None) -> float:
    """Центр масс крыла вдоль киля от носа, м: грубая оценка по трубам (киль, передние кромки,
    поперечина, кингпост, стойки, базовая штанга) + ткань, если задан sail_mass_kg.
    Подвеска зависит от самого центра масс (HangPoint = ЦМ + hang_cg_offset_m), а положение
    трапеции — от подвески, поэтому решается итерацией."""
    mm = cf["mass_model"]
    half = span * 0.5
    off = param(p, cf, "hang_cg_offset_m")
    parts = []  # (масса, d центра)

    def seg(rate: float, d0: float, x0: float, d1: float, x1: float, n: int = 1) -> None:
        for i in range(n):
            a0, a1 = i / n, (i + 1) / n
            da, xa = d0 + (d1 - d0) * a0, x0 + (x1 - x0) * a0
            db, xb = d0 + (d1 - d0) * a1, x0 + (x1 - x0) * a1
            parts.append((rate * math.hypot(db - da, xb - xa), (da + db) * 0.5))

    tail_d = p["root_chord_m"] + p["keel_extra_m"]
    seg(mm["keel"], 0.0, 0.0, tail_d, 0.0)
    for i in range(30):  # передние кромки (две)
        a0, a1 = i / 30 * 0.97, (i + 1) / 30 * 0.97
        seg(2 * mm["leading_edge"], le_d(p, half, a0), a0 * half, le_d(p, half, a1), a1 * half)
    ju = p["crossbar_u"]
    seg(2 * mm["crossbar"], le_d(p, half, ju), ju * half, p["crossbar_from_nose_m"], 0.03)
    sail = p.get("sail_mass_kg", cf.get("sail_mass_kg"))
    if sail:
        # ткань: центр тяжести плоской трапеции — грубо 0,45 корневой хорды от носа
        parts.append((sail, 0.45 * p["root_chord_m"]))
    cg = 0.0
    fixed = p.get("hang_from_nose_m") if p.get("hang_source") == "passport" else None
    for _ in range(50):
        d_hang = fixed if fixed is not None else cg - off
        fp = frame_points(p, cf, tilt_deg)
        d_apex = d_hang + hang_from_apex(p, cf)
        d_bb = d_apex - (fp["y_bb"] - fp["apex_y"])
        dx = fp["w"] - fp["top_x"]
        extra = list(parts)
        if p["kingpost_m"] > 0:
            extra.append((mm["kingpost"] * p["kingpost_m"], d_apex))
        extra.append((2 * mm["upright"] * fp["length"], (d_apex + d_bb) * 0.5))
        extra.append((mm["basebar"] * 2 * fp["w"], d_bb))
        m = sum(x for x, _ in extra)
        new = sum(x * d for x, d in extra) / m
        if abs(new - cg) < 1e-7:
            cg = new
            break
        cg = new
    return cg
