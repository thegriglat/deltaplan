#!/usr/bin/env python3
"""WPC-4: конфиги крыльев — к паспортам (паспорт — эталон; решение пользователя по шлюзу 1 модуля
wing-physics-check, docs/plan/wing-physics-check.md).

Паспортные цели берутся ровно как в WPC-1 (tools/research/wing_physics_check/wings_audit.py → passport_for:
приведение к массе √(M/M_паспорта); stall = DHV Vmin VG 0, иначе «stall speed» производителя; full_pull = DHV
Vmax VG 0, иначе VG 100; явные ошибки разбора исключены там же). Цели — при эталонной массе крыла
(pilot_mass_ref_kg + wing_mass_kg), ρ = 1,225.

Поляра сдвигается целиком, без подгонки отдельных точек (два параметра на крыло):
  * s — подобие: все точки (V, w) × s (безразмерная поляра CL→CD масштабируется по CL, качество в каждой
    точке сохраняется);
  * V_s — сваливание (первая точка, CL_max): точки медленнее V_s отбрасываются, первая точка ставится на V_s на
    той же кривой CL→CD (линейная в CL — как WingPolar). Только срез: CL_max не продлевается за последнюю точку
    исходной поляры (V_s ≥ V0·s), поэтому кривая остаётся гладкой — это та же кривая, укороченная.
  V_s = паспортное сваливание, если оно есть; иначе max(V0, V0·s) (сваливание не меняется, пока это возможно).
  s — наименьшие квадраты по log(модель/паспорт) для мин. снижения, его скорости, скорости и величины
  макс. качества (что есть в паспорте); без этих чисел s = 1 (меньше всего правки). Ограничение: минимум
  снижения не на сваливании — V_мин.сн ≥ min(R_VMS, V_мин.сн/V_s исходной поляры)·V_s, R_VMS = 1,05 (медиана
  Vms/DHV Vmin у крыльев, где в паспорте есть оба числа: WW U2 1,04 и 1,19 по поляре WW, T2C 1,05, Fizz 0,98).
Скорости трапеции:
  * trim_speed_kmh — паспорт; без него трим × s, но не ниже r·V_s, r = min(R_TRIM, прежний трим/прежнее
    сваливание), R_TRIM = 1,12 (медиана трим/DHV Vmin по паспортам: Discus 1,06, Litespeed S 1,11, Malibu 2 1,14,
    Litespeed RX 1,21);
  * full_pull_speed_kmh — паспорт (DHV Vmax VG 0); без него × s;
  * full_push_speed_kmh — тот же заход за угол срыва, что был: Δα = (CL_от_себя − CL_max)/lift_slope (ход трапеции —
    геометрия; полное выжимание сваливает).
Поляра продолжается до скорости «на себя» точками на той же параболе CD = CD0 + k·CL², которой WingPolar и так
продолжает её быстрее последней точки (таблица покрывает ход трапеции; физика не меняется).
reference.* — замер той же модели (steady_glide FlightModel: CL→CD как WingPolar), как test_polar.
launch.alpha_neutral_deg (К1 v2: ≤ α_срыва − 3°, α_срыва = CL_max/lift_slope + zero_lift_alpha): при новом CL_max
нейтраль разбега ставится на ту же долю CL_max, что была (подъёмная сила на разбеге относительно сваливания — как
раньше; отрыв при нейтрали на той же доле Vmin), с округлением до 0,5°, не выше α_срыва − 3°; только вниз. Упор «нос вниз»
(нейтраль − alpha_range_deg) остаётся на прежнем угле — это геометрия (концы крыла над землёй), поэтому ход
alpha_range_deg уменьшается на столько же, на сколько опущена нейтраль. lift_slope/zero_lift_alpha
у всех крыльев одни (4,5/рад, −6°): данных о геометрии срыва по крыльям нет, угол срыва следует из CL_max.
Atlas: прежняя нейтраль 16° была выше срыва 12,5° (CL > CL_max) — доля CL_max = медиана у остальных крыльев
(0,759 по конфигам до WPC-4: 0,74–0,82) → 8,0°.

Выход:
  configs/wings/<id>.json — для крыльев с паспортными числами (без них — не трогаются);
  tests/flight/fixtures/wing_passport_targets.json — цели и допуски для tests/flight/test_wing_passports.gd;
  tools/research/data/wing_passports/out/passport_fit.csv и passport_fit.md — было/стало/паспорт.

Запуск (из корня репозитория, только стандартная библиотека):
  python3 tools/research/data/wing_passports/fit_passports.py --from-rev 2df5c2f   # воспроизвести WPC-4
  python3 tools/research/data/wing_passports/fit_passports.py [--dry]               # от текущих конфигов
--from-rev — исходные конфиги («было») из git-ревизии (2df5c2f — до WPC-4); без него — текущие конфиги.
Повторный запуск от уже приведённых конфигов почти тождественен (s ≈ 1 ± 0,001, сваливание уже на паспорте).
После make_new_wings.py (он пересоздаёт конфиги подобием от базы) этот скрипт нужно запустить снова.
"""
import copy
import csv
import json
import math
import os
import re
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "tools/research/wing_physics_check"))
from wings_audit import passport_for, scaled  # noqa: E402  (WPC-1, только чтение)

CFG_DIR = ROOT / "configs/wings"
FIXTURE = ROOT / "tests/flight/fixtures/wing_passport_targets.json"
OUT = HERE / "out"
G = 9.80665
RHO = 1.225
WIND_MS = 6.0
R_VMS = 1.05
R_TRIM = 1.12
ALPHA_MARGIN_DEG = 3.0
TOL = {"stall": 7.0, "trim": 7.0, "full_pull": 7.0, "min_sink": 10.0, "min_sink_speed": 10.0,
       "best_glide": 10.0, "best_glide_speed": 10.0}
SHAPE = ("min_sink", "min_sink_speed", "best_glide_speed", "best_glide")
QS = ("stall", "trim", "full_pull", "min_sink", "min_sink_speed", "best_glide", "best_glide_speed")
MARK = " Паспорт (WPC-4):"
# Исключения: паспортные числа, которые противоречат другим числам того же паспорта сильнее допуска.
# Заполняется по итогам прогона (причина — в отчёте и в тесте).
EXCEPT = {}


# ------------------------------------------------------------------ поляра (как WingPolar + FlightModel.steady_glide)
class Polar:
    def __init__(self, points, mass, area):
        pairs = []
        for vk, w in points:
            v = vk / 3.6
            sg = w / v
            cg = math.sqrt(1 - sg * sg)
            cl = 2 * mass * G * cg / (RHO * area * v * v)
            pairs.append((cl, cl * sg / cg))
        pairs.sort()
        self.cl = [p[0] for p in pairs]
        self.cd = [p[1] for p in pairs]
        self.cl_max = self.cl[-1]
        c1, c2 = self.cl[0], self.cl[1]
        self.k = max((self.cd[1] - self.cd[0]) / (c2 * c2 - c1 * c1), 0.0)
        self.cd0 = self.cd[0] - self.k * c1 * c1
        self.mass, self.area = mass, area

    def cd_at(self, cl):
        n = len(self.cl)
        if cl <= self.cl[0]:
            return self.cd0 + self.k * cl * cl
        if cl >= self.cl[-1]:
            s = (self.cd[-1] - self.cd[-2]) / (self.cl[-1] - self.cl[-2])
            return self.cd[-1] + s * (cl - self.cl[-1])
        i = next(j for j in range(1, n) if self.cl[j] >= cl)
        t = (cl - self.cl[i - 1]) / (self.cl[i] - self.cl[i - 1])
        return self.cd[i - 1] + (self.cd[i] - self.cd[i - 1]) * t

    def glide(self, v):
        """FlightModel.steady_glide: (снижение м/с, cosγ) на воздушной скорости v, м/с."""
        cos_g, ld = 1.0, 1.0
        for _ in range(4):
            cl = 2 * self.mass * G * cos_g / (RHO * self.area * v * v)
            ld = cl / self.cd_at(cl)
            cos_g = math.cos(math.atan(1 / ld))
        return v * math.sin(math.atan(1 / ld)), cos_g

    def stall_kmh(self):
        return 3.6 * math.sqrt(2 * self.mass * G / (RHO * self.area * self.cl_max))

    def sweep(self, dv=0.05):
        """Как test_polar.sweep: от сваливания до 100 км/ч, шаг 0,05 м/с (на плоском минимуме — тот же ответ)."""
        v = self.stall_kmh() / 3.6
        r = {"min_sink": 99.0, "min_sink_speed": 0.0, "best_glide": 0.0, "best_glide_speed": 0.0}
        while v < 100 / 3.6:
            w, _ = self.glide(v)
            if w < r["min_sink"]:
                r["min_sink"], r["min_sink_speed"] = w, v * 3.6
            if v / w > r["best_glide"]:
                r["best_glide"], r["best_glide_speed"] = v / w, v * 3.6
            v += dv
        return r


def transform(points, mass, area, s, vs):
    """Точки поляры: подобие × s, срез на сваливании vs (км/ч). None, если vs быстрее/медленнее допустимого."""
    sp = [[v * s, w * s] for v, w in points]
    if vs < sp[0][0] - 0.02:  # 0,02 км/ч — округление точек
        return None  # CL_max за пределом исходной поляры — не продлеваем
    if vs >= sp[-1][0] - 1.0:
        return None
    pol = Polar(sp, mass, area)
    w0, _ = pol.glide(vs / 3.6)
    keep = [[v, w] for v, w in sp if v >= vs + 0.2]
    return [[vs, w0]] + keep


def rnd(pts):
    return [[round(v, 2), round(w, 3)] for v, w in pts]


def metrics(cfg, pts=None, mass=None):
    pts = pts or cfg["polar"]["points_kmh_ms"]
    mass = mass or cfg["pilot_mass_ref_kg"] + cfg["wing_mass_kg"]
    pol = Polar(pts, mass, cfg["area_m2"])
    r = pol.sweep()
    r["stall"] = pol.stall_kmh()
    r["cl_max"] = pol.cl_max
    return r, pol


def alpha_stall_deg(cfg, cl_max):
    return math.degrees(cl_max / cfg["lift_slope_per_rad"]) + cfg["zero_lift_alpha_deg"]


def cl_frac(cfg, cl_max):
    """Доля CL_max при нейтральной трапеции на разбеге."""
    return cfg["lift_slope_per_rad"] * math.radians(cfg["launch"]["alpha_neutral_deg"] - cfg["zero_lift_alpha_deg"]) / cl_max


# Медиана доли CL_max при нейтрали разбега у крыльев, где К1 v2 выполнен (исходные конфиги; ставится в main):
# для крыла, у которого прежняя доля сама нарушала К1 v2 (atlas: нейтраль 16° выше срыва 12,5°).
FRAC_MEDIAN = {"value": None, "n": 0}


def launch_neutral(cfg, cl_old, cl_new):
    """Новая нейтраль разбега (°, доля, откуда доля) или None — не меняется.
    Та же доля CL_max, что была (подъёмная сила на разбеге относительно сваливания — как раньше), не выше
    α_срыва − 3° (К1 v2); если прежняя доля сама нарушала К1 v2 — медиана доли у остальных крыльев."""
    a = cfg["lift_slope_per_rad"]
    lim_frac = 1 - a * math.radians(ALPHA_MARGIN_DEG) / cl_old
    frac = cl_frac(cfg, cl_old)
    why = "была у этого крыла"
    wid = cfg["name"].replace("wing_", "", 1)
    if frac > lim_frac + 1e-9:
        frac = FRAC_MEDIAN["value"]
        why = "медиана у остальных %d крыльев" % FRAC_MEDIAN["n"]
    elif abs(cl_new / cl_old - 1) < 0.005:
        return None
    val = round((cfg["zero_lift_alpha_deg"] + math.degrees(frac * cl_new / a)) * 2) / 2
    val = min(val, math.floor((math.degrees(cl_new / a) + cfg["zero_lift_alpha_deg"] - ALPHA_MARGIN_DEG) * 2) / 2)
    if val >= cfg["launch"]["alpha_neutral_deg"]:
        return None  # только опускаем: выше прежней нейтраль не поднимаем (К1 v2 и так выполнен)
    return val, frac, why


def fm(x, nd=1):
    return (("%." + str(nd) + "f") % x).replace(".", ",")


def gs_trim(pol, trim_kmh):
    w, cg = pol.glide(trim_kmh / 3.6)
    return trim_kmh / 3.6 * cg - WIND_MS


# ------------------------------------------------------------------ подбор
def fit(cfg, tg):
    pts0 = cfg["polar"]["points_kmh_ms"]
    mass = cfg["pilot_mass_ref_kg"] + cfg["wing_mass_kg"]
    area = cfg["area_m2"]
    m0, _ = metrics(cfg)
    v0 = pts0[0][0]
    r0 = m0["min_sink_speed"] / m0["stall"]
    r_vms = min(R_VMS, r0)
    shape = [q for q in SHAPE if q in tg]

    def scan(grid, dv, best):
        for s in grid:
            vs = tg["stall"] if "stall" in tg else max(v0, v0 * s)
            pts = transform(pts0, mass, area, s, vs)
            if pts is None:
                continue
            pol = Polar(pts, mass, area)
            r = pol.sweep(dv=dv)
            if r["min_sink_speed"] < r_vms * pol.stall_kmh() - 0.1:  # 0,1 км/ч — шаг перебора скорости
                continue
            err = sum(math.log(r[q] / tg[q]) ** 2 for q in shape)
            err += 1e-4 * math.log(s) ** 2  # без цели — наименьшая правка (s → 1)
            if best is None or err < best[0]:
                best = (err, s, vs)
        return best

    best = scan([round(0.6 + 0.01 * i, 4) for i in range(121)], 0.05, None)
    if best is not None:
        c = best[1]
        best = scan([round(c + 0.0005 * i, 4) for i in range(-24, 25)], 0.01, None)
    if best is None:
        raise SystemExit("%s: нет допустимого подобия" % cfg["name"])
    return best[1], best[2]


def apply(wid, cfg, tg, src):
    pts0 = cfg["polar"]["points_kmh_ms"]
    mass = cfg["pilot_mass_ref_kg"] + cfg["wing_mass_kg"]
    v0 = pts0[0][0]
    s, vs = fit(cfg, tg)
    new = copy.deepcopy(cfg)
    pts = rnd(transform(pts0, mass, cfg["area_m2"], s, vs))
    new["polar"]["points_kmh_ms"] = pts
    m, pol = metrics(new)
    k_vs = pts[0][0] / v0
    notes = []
    # скорости трапеции
    if "trim" in tg:
        trim = tg["trim"]
        notes.append("трим — паспорт (%s)" % src["trim"])
        trim_doc = "паспорт: %s" % src["trim"]
    else:
        r_trim = min(R_TRIM, cfg["trim_speed_kmh"] / v0)
        trim = max(cfg["trim_speed_kmh"] * s, r_trim * pts[0][0])
        trim_doc = ("в паспорте нет: прежний трим × s = %s, не ниже %s·сваливание (медиана трим/DHV Vmin по паспортам, "
                    "или прежнее отношение, если оно меньше)" % (fm(s, 4), fm(r_trim, 3)))
    if "full_pull" in tg:
        pull = tg["full_pull"]
        pull_doc = "паспорт: %s" % src["full_pull"]
    else:
        pull = cfg["full_pull_speed_kmh"] * s
        pull_doc = "в паспорте нет: прежняя × s = %s" % fm(s, 4)
    # «от себя»: тот же перебор угла атаки за срыв, что был (Δα = (CL_от_себя − CL_max)/lift_slope — геометрия
    # хода трапеции); CL — как в FlightModel._alpha_command (без cosγ)
    q0 = 2 * mass * G / (RHO * cfg["area_m2"])
    m_old, _ = metrics(cfg)
    d_cl = q0 / (cfg["full_push_speed_kmh"] / 3.6) ** 2 - m_old["cl_max"]
    push = 3.6 * math.sqrt(q0 / (m["cl_max"] + d_cl))
    new["trim_speed_kmh"] = round(trim, 1)
    new["full_pull_speed_kmh"] = round(pull, 1)
    new["full_push_speed_kmh"] = round(min(push, 0.95 * pts[0][0]), 1)
    # поляра до скорости «на себя»: точки на той же параболе CD = CD0 + k·CL², которой WingPolar продолжает
    # поляру быстрее последней точки (физика не меняется, таблица покрывает ход трапеции)
    ext = 0
    while pts[-1][0] < new["full_pull_speed_kmh"] + 0.5:
        v = min(pts[-1][0] + 10.0, max(new["full_pull_speed_kmh"] + 0.5, pts[-1][0] + 3.0))
        pts.append([round(v, 2), round(pol.glide(v / 3.6)[0], 3)])
        ext += 1
    if ext:
        new["polar"]["points_kmh_ms"] = pts
        m, pol = metrics(new)
    base_doc = {
        "trim_speed_kmh": "Скорость трима (трапеция в нейтрали) при эталонной массе, км/ч",
        "full_pull_speed_kmh": "Скорость при трапеции полностью на себя при эталонной массе, км/ч",
        "full_push_speed_kmh": ("Скорость, соответствующая трапеции полностью от себя, км/ч. Ниже сваливания — "
                                "полное выжимание сваливает крыло"),
    }
    new["trim_speed_kmh_doc"] = base_doc["trim_speed_kmh"] + " (WPC-4, %s)" % trim_doc
    new["full_pull_speed_kmh_doc"] = base_doc["full_pull_speed_kmh"] + (
        " (WPC-4, %s; VG в игре нет — DHV при VG 0)" % pull_doc)
    new["full_push_speed_kmh_doc"] = base_doc["full_push_speed_kmh"] + (
        " (WPC-4: тот же заход за угол срыва, что был: ΔCL = %s, Δα = %s°)" % (
            fm(d_cl, 3), fm(math.degrees(d_cl / cfg["lift_slope_per_rad"]), 1)))
    # ориентиры — замер модели
    ref = new["reference"]
    ref["stall_speed_kmh"] = round(m["stall"], 1)
    ref["min_sink_ms"] = round(m["min_sink"], 3)
    ref["min_sink_speed_kmh"] = round(m["min_sink_speed"], 1)
    ref["best_glide"] = round(m["best_glide"], 1)
    ref["best_glide_speed_kmh"] = round(m["best_glide_speed"], 1)
    if "sink_at_80_kmh_ms" in ref:
        ref["sink_at_80_kmh_ms"] = round(pol.glide(80 / 3.6)[0], 2)
    ref["_doc"] = ("Ориентиры поляры (FR-1) для тестов и документации: при эталонной массе на уровне моря — замер "
                   "модели (FlightModel.steady_glide по поляре конфига, как tests/flight/test_polar.gd; WPC-4)")
    # поляра: _doc
    pd = re.sub(r"\s*Паспорт \(WPC-4\):.*$", "", new["polar"]["_doc"])
    new["polar"]["_doc"] = pd.rstrip(".") + (
        "." + MARK + " поляра сдвинута целиком (tools/research/data/wing_passports/fit_passports.py): подобие × s = %s "
        "(%s), сваливание (первая точка, CL_max) — %s; точки медленнее сваливания отброшены, первая точка — на той же "
        "кривой CL→CD%s" % (fm(s, 4),
                          "по паспорту: " + ", ".join(q for q in SHAPE if q in tg) if any(q in tg for q in SHAPE)
                          else "в паспорте нет снижения и его скорости — наименьшая правка",
                          ("паспорт: " + src["stall"]) if "stall" in tg else "в паспорте нет — прежнее × max(1, s)",
                          ("; быстрее прежней последней точки до скорости «на себя» — %d точ. на параболе CD = CD0 + k·CL², "
                           "которой модель и так продолжает поляру" % ext) if ext else ""))
    # угол разбега (К1 v2)
    la = new["launch"]
    a_st = alpha_stall_deg(new, m["cl_max"])
    nd = launch_neutral(cfg, m_old["cl_max"], m["cl_max"])
    if nd is not None:
        val, frac, why = nd
        down = cfg["launch"]["alpha_neutral_deg"] - cfg["launch"]["alpha_range_deg"]
        la["alpha_neutral_deg"] = val
        la["alpha_range_deg"] = round(val - down, 1)
        la["alpha_range_deg_doc"] = (
            "Изменение угла атаки при трапеции до упора от себя/на себя на разбеге, °. WPC-4: нейтраль опущена "
            "(%s → %s°), упор «нос вниз» оставлен на прежнем угле %s° (геометрия: концы крыла над землёй, "
            "tests/flight/test_wing_clearance.gd) — ход %s°, упор «нос вверх» %s°" % (
                fm(cfg["launch"]["alpha_neutral_deg"], 1), fm(val, 1), fm(down, 1), fm(val - down, 1),
                fm(2 * val - down, 1)))
        la["alpha_neutral_deg_doc"] = (
            "Угол атаки киля при нейтральной трапеции на разбеге, °. WPC-4: %s — нейтраль "
            "ставится на ту же долю CL_max, что %s: CL = %s·CL_max → α = α0 + CL/lift_slope = %s° (до 0,5°); "
            "К1 v2: не выше α_срыва − 3° = %s/%s рад + (%s°) − 3° = %s°" % (
                ("прежняя нейтраль %s° была выше угла срыва %s° (CL > CL_max: крыло на разбеге сорвано)" % (
                    fm(cfg["launch"]["alpha_neutral_deg"], 1), fm(alpha_stall_deg(cfg, m_old["cl_max"]), 1)))
                if why.startswith("медиана") else
                "CL_max сменился (%s → %s)" % (fm(m_old["cl_max"], 2), fm(m["cl_max"], 2)),
                why, fm(frac, 3), fm(val, 1),
                fm(m["cl_max"], 2), fm(new["lift_slope_per_rad"], 1), fm(new["zero_lift_alpha_deg"], 0),
                fm(a_st - ALPHA_MARGIN_DEG, 1)))
    # общий _doc
    d = re.sub(r"\s*Паспорт \(WPC-4\):.*$", "", new["_doc"])
    srcs = "; ".join("%s — %s" % (q, src[q]) for q in QS if q in tg)
    new["_doc"] = d + MARK + (
        " скорости и поляра приведены к паспорту при эталонной массе %s кг (паспорт — эталон, решение по шлюзу 1 "
        "docs/plan/wing-physics-check.md; цели как в WPC-1 tools/research/wing_physics_check/README.md: "
        "√(M/M_паспорта), DHV Vmin/Vmax при VG 0). Источники: %s. Сделано "
        "tools/research/data/wing_passports/fit_passports.py." % (fm(mass, 1), srcs))
    return new, dict(s=s, vs=pts[0][0], m=m, pol=pol, a_st=a_st)


def load_cfg_rev(wid, rev):
    if not rev:
        return None
    try:
        txt = subprocess.check_output(["git", "-C", str(ROOT), "show", "%s:configs/wings/%s.json" % (rev, wid)],
                                      stderr=subprocess.DEVNULL)
        return json.loads(txt, object_pairs_hook=OrderedDict)
    except subprocess.CalledProcessError:
        return None


def main(argv):
    dry = "--dry" in argv
    rev = argv[argv.index("--from-rev") + 1] if "--from-rev" in argv else None
    merged = {r["key"]: r for r in json.loads((HERE / "wings_merged.json").read_text())}
    polars = json.loads((HERE / "polars_points.json").read_text())
    fixture = OrderedDict([("_doc", (
        "Паспортные цели крыльев (WPC-4) при эталонной массе, ρ = 1,225: value — паспорт, приведённый к массе "
        "mass_kg как в WPC-1 (tools/research/wing_physics_check/README.md); tol_pct — допуск модели; exceptions — "
        "цели вне допуска с причиной. Генерирует tools/research/data/wing_passports/fit_passports.py")),
        ("tolerance_pct", TOL), ("wings", OrderedDict())])
    rows = []
    fr = []
    for path in sorted(CFG_DIR.glob("*.json")):
        c = load_cfg_rev(path.stem, rev) or json.loads(path.read_text())
        cm = metrics(c)[0]["cl_max"]
        if c["launch"]["alpha_neutral_deg"] <= alpha_stall_deg(c, cm) - ALPHA_MARGIN_DEG:
            fr.append(cl_frac(c, cm))
    fr.sort()
    FRAC_MEDIAN["value"] = 0.5 * (fr[(len(fr) - 1) // 2] + fr[len(fr) // 2])
    FRAC_MEDIAN["n"] = len(fr)
    for path in sorted(CFG_DIR.glob("*.json")):
        wid = path.stem
        cfg = load_cfg_rev(wid, rev) or json.loads(path.read_text(), object_pairs_hook=OrderedDict)
        pp, _ = passport_for(wid, cfg, merged, polars)
        mass = cfg["pilot_mass_ref_kg"] + cfg["wing_mass_kg"]
        tg, src = {}, {}
        for q in QS:
            if q in pp:
                val, msrc, txt = pp[q]
                tg[q] = scaled(val, msrc, mass, q)
                src[q] = txt
        before = cfg
        mb, polb = metrics(before)
        if not tg:
            continue
        only_glide = set(tg) <= {"best_glide"} and all(
            abs(mb["best_glide"] / tg[q] - 1) * 100 <= TOL[q] for q in tg)
        if only_glide:
            new, info = cfg, None  # только качество, и оно в допуске: поляра не трогается
            m, pol = mb, polb
        else:
            new, info = apply(wid, cfg, tg, src)
            m, pol = info["m"], info["pol"]
        after = dict(m)
        after["trim"] = new["trim_speed_kmh"]
        after["full_pull"] = new["full_pull_speed_kmh"]
        bef = dict(mb)
        bef["trim"] = before["trim_speed_kmh"]
        bef["full_pull"] = before["full_pull_speed_kmh"]
        ent = OrderedDict([("mass_kg", round(mass, 2)), ("group", cfg["group"]), ("targets", OrderedDict())])
        for q in QS:
            if q in tg:
                d = (after[q] / tg[q] - 1) * 100
                t = OrderedDict([("value", round(tg[q], 3)), ("tol_pct", TOL[q]), ("src", src[q])])
                if abs(d) > TOL[q]:
                    t["exception"] = EXCEPT.get((wid, q), "НЕ РАЗОБРАНО: %+.1f %%" % d)
                ent["targets"][q] = t
        fixture["wings"][wid] = ent
        a_b = alpha_stall_deg(before, mb["cl_max"]) - before["launch"]["alpha_neutral_deg"]
        a_a = alpha_stall_deg(new, m["cl_max"]) - new["launch"]["alpha_neutral_deg"]
        row = OrderedDict([("wing", wid), ("group", cfg["group"]), ("mass_kg", round(mass, 1)),
                           ("changed", int(info is not None)), ("s", round(info["s"], 4) if info else "")])
        for q in QS:
            row[q + "_before"] = round(bef[q], 3)
            row[q + "_after"] = round(after[q], 3)
            row[q + "_passport"] = round(tg[q], 3) if q in tg else ""
            row[q + "_diff_pct"] = round((after[q] / tg[q] - 1) * 100, 1) if q in tg else ""
        row["cl_max_before"] = round(mb["cl_max"], 3)
        row["cl_max_after"] = round(m["cl_max"], 3)
        row["alpha_stall_before"] = round(alpha_stall_deg(before, mb["cl_max"]), 2)
        row["alpha_stall_after"] = round(alpha_stall_deg(new, m["cl_max"]), 2)
        row["alpha_neutral_before"] = before["launch"]["alpha_neutral_deg"]
        row["alpha_neutral_after"] = new["launch"]["alpha_neutral_deg"]
        row["alpha_margin_before"] = round(a_b, 2)
        row["alpha_margin_after"] = round(a_a, 2)
        row["gs6_trim_before"] = round(gs_trim(polb, before["trim_speed_kmh"]), 2)
        row["gs6_trim_after"] = round(gs_trim(pol, new["trim_speed_kmh"]), 2)
        row["gs6_pull_after"] = round(gs_trim(pol, new["full_pull_speed_kmh"]), 2)
        rows.append(row)
        if info is not None and not dry:
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(new, fh, ensure_ascii=False, indent=2)
                fh.write("\n")
    # К1 v2 для всех крыльев (и без паспорта)
    bad = []
    for path in sorted(CFG_DIR.glob("*.json")):
        c = json.loads(path.read_text())
        mm, _ = metrics(c)
        if c["launch"]["alpha_neutral_deg"] > alpha_stall_deg(c, mm["cl_max"]) - ALPHA_MARGIN_DEG + 1e-9:
            bad.append(path.stem)
    if dry:
        print("(--dry: конфиги не записаны)")
    else:
        FIXTURE.parent.mkdir(parents=True, exist_ok=True)
        FIXTURE.write_text(json.dumps(fixture, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        OUT.mkdir(exist_ok=True)
        with open(OUT / "passport_fit.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
            w.writeheader()
            w.writerows(rows)
        (OUT / "passport_fit.md").write_text(table_md(rows), encoding="utf-8")
    print(table_md(rows))
    print("К1 v2 нарушен:", bad or "нет")
    nr = [(w, q, t["exception"]) for w, e in fixture["wings"].items() for q, t in e["targets"].items()
          if "exception" in t]
    print("вне допуска:", nr or "нет")


def table_md(rows):
    names = {"stall": "сваливание", "trim": "трим", "full_pull": "на себя", "min_sink": "мин. снижение",
             "min_sink_speed": "V мин. сн.", "best_glide": "качество", "best_glide_speed": "V кач."}
    out = ["# WPC-4: конфиги крыльев к паспортам — было → стало (паспорт, отклонение)", "",
           "Эталонная масса крыла, ρ = 1,225; скорости км/ч, снижение м/с. Модель — FlightModel.steady_glide по "
           "поляре конфига; трим/«на себя» — скорости конфига (установившийся полёт — tests/flight/"
           "test_wing_passports.gd). s — подобие поляры; α — запас угла срыва над нейтралью разбега, °; "
           "путевая — V·cosγ − 6 м/с на триме. Генерирует fit_passports.py.", "",
           "| крыло | s | " + " | ".join(names[q] for q in QS) + " | α срыва − нейтраль | путевая 6 м/с |",
           "|---|---|" + "---|" * len(QS) + "---|---|"]
    for r in rows:
        cells = []
        for q in QS:
            nd = 3 if q == "min_sink" else 1
            c = "%s → %s" % (fm(r[q + "_before"], nd), fm(r[q + "_after"], nd))
            if r[q + "_passport"] != "":
                c += " (%s, %+.1f %%)" % (fm(r[q + "_passport"], nd), r[q + "_diff_pct"])
            cells.append(c)
        out.append("| %s | %s | %s | %s → %s | %s → %s |" % (
            r["wing"] + ("" if r["changed"] else " (не менялось)"), fm(r["s"], 3) if r["s"] != "" else "—",
            " | ".join(cells), fm(r["alpha_margin_before"]), fm(r["alpha_margin_after"]),
            fm(r["gs6_trim_before"], 2), fm(r["gs6_trim_after"], 2)))
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main(sys.argv[1:])
