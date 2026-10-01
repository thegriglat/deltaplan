#!/usr/bin/env python3
"""Новые крылья по спецификации ТЗ (out/wings3d_spec.json, К3): запись формы, конфиг, перевод названия.

Для каждого id из спецификации:
  * tools/blender/glider_params.json → wings.<id> = копия записи базы + `params` спецификации + своя раскраска
    `design` (палитра в духе класса, детерминированно по номеру раздела ТЗ: разные у разных крыльев);
  * configs/wings/<id>.json = копия конфига базы + паспорт (`config` спецификации) + поляра и скорости по К4
    (подобие по нагрузке на крыло, качество — как у базы) + `_doc` с источниками; чего нет в паспорте — от базы
    с пометкой;
  * locale/ui.csv: wing_<id>,«Производитель Модель Размер» (ru = en).
Необязательная ручная правка (особенности вида из «Заметок по виду», цвета) — файл wings3d_overrides/<id>.json:
{"params": {...}, "design": {...}, "config": {...}} — накладывается последней (свой файл на крыло: ветки не конфликтуют).

Повторный запуск идемпотентен: запись крыла перезаписывается целиком. Записи новых крыльев в glider_params.json и
строки в ui.csv стоят после существующих, в порядке разделов ТЗ (N1, N2, …). Если параллельные ветки всё же
конфликтуют в этих двух файлах — взять любую сторону и запустить `make_new_wings.py --existing` (пересоздаёт все
крылья спецификации, у которых есть configs/wings/<id>.json).

Запуск (из корня репозитория или откуда угодно; только стандартная библиотека):
  python3 tools/research/data/wing_passports/make_new_wings.py icaro_piuma ww_t2c
  python3 tools/research/data/wing_passports/make_new_wings.py --existing      # все уже добавленные
  python3 tools/research/data/wing_passports/make_new_wings.py --all           # все 39 (проба меню)
Печатает таблицу К4 (f, сваливание/трим/качество против базы, DHV Vmin на эталонной массе, масса, пилот).
Потом: blender --background --python tools/blender/build_gliders.py -- <id…>; godot --import.
"""
import colorsys
import copy
import csv
import io
import json
import math
import os
import re
import sys
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
SPEC = os.path.join(HERE, "out", "wings3d_spec.json")
OVERRIDES = os.path.join(HERE, "wings3d_overrides")
PARAMS = os.path.join(ROOT, "tools", "blender", "glider_params.json")
CFG_DIR = os.path.join(ROOT, "configs", "wings")
LOCALE = os.path.join(ROOT, "locale", "ui.csv")
G = 9.80665
RHO = 1.225
MERGED = os.path.join(HERE, "wings_merged.json")
# К4 v2: DHV Vmin базы — по паспорту самой модели или ближайшего аналога того же семейства (ключ wings_merged.json).
# Нет данных — сравнивать не с чем, расхождение нового крыла указывается как есть.
BASE_DHV = {
    "combat": "Aeros|Combat GT||12.7",   # у 13.2 нет Vmin; тот же Combat GT, пересчёт по нагрузке на крыло
    "laminar": "Icaro|Orbiter||14",      # аналог конфига (docs/research/wings_config_sources.md §1)
    "target": "Aeros|Fox||13",           # у Fox 16 нет Vmin; Fox — ближайший к Target 16 (раздел E2 ТЗ)
}


def _vmin_ref(vmin, m_lo, m_hi, s_dhv, m, s):
    """DHV Vmin (при середине «Startgewicht» и площади s_dhv) → при массе m и площади s: × √((m/s)/(m_dhv/s_dhv))."""
    m_dhv = 0.5 * (m_lo + m_hi)
    return vmin * math.sqrt((m / s) / (m_dhv / s_dhv)), m_dhv


def base_dhv_diff(base, base_cfg):
    """Расхождение сваливания поляры базы с DHV Vmin её паспорта/аналога (доля) или None."""
    key = BASE_DHV.get(base)
    if not key:
        return None
    rec = next((r for r in load_json(MERGED) if r["key"] == key), None)
    if rec is None:
        return None
    g = lambda n: (rec["fields"].get(n) or {}).get("value")
    if not (g("vmin_vg0_kmh") and g("takeoff_mass_min_kg") and g("takeoff_mass_max_kg") and g("area_m2")):
        return None
    m = base_cfg["pilot_mass_ref_kg"] + base_cfg["wing_mass_kg"]
    v, _ = _vmin_ref(g("vmin_vg0_kmh"), g("takeoff_mass_min_kg"), g("takeoff_mass_max_kg"), g("area_m2"), m, base_cfg["area_m2"])
    return base_cfg["polar"]["points_kmh_ms"][0][0] / v - 1, key


def fm(x, nd=2):
    s = ("%." + str(nd) + "f") % x
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s.replace(".", ",")


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=OrderedDict)


# ------------------------------------------------------------------ JSON в стиле glider_params.json
def _scalar(v):
    return json.dumps(v, ensure_ascii=False)


def fmt(v, ind):
    """Словари — по строке на ключ, списки чисел/строк — в одну строку (как в glider_params.json)."""
    pad = " " * ind
    if isinstance(v, dict):
        if not v:
            return "{}"
        items = ['%s  %s: %s' % (pad, _scalar(k), fmt(x, ind + 2)) for k, x in v.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(v, list):
        if all(not isinstance(x, (dict, list)) for x in v):
            return "[" + ", ".join(_scalar(x) for x in v) + "]"
        items = ["%s  %s" % (pad, fmt(x, ind + 2)) for x in v]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return _scalar(v)


def split_wings(text):
    """(до списка крыльев, [(id, текст записи)], после). Записи — ключи на отступе 4 внутри "wings": {…}."""
    m = re.search(r'^  "wings": \{\n', text, re.M)
    if not m:
        raise SystemExit("glider_params.json: нет \"wings\"")
    head, rest = text[:m.end()], text[m.end():]
    end = re.search(r"^  \}", rest, re.M)
    body, tail = rest[:end.start()], rest[end.start():]
    entries = []
    for chunk in re.split(r'(?m)^(?=    "[^"]+": )', body):
        if not chunk.strip():
            continue
        wid = re.match(r'    "([^"]+)": ', chunk).group(1)
        entries.append((wid, chunk.rstrip().rstrip(",")))
    return head, entries, tail


def join_wings(head, entries, tail):
    return head + ",\n".join(t for _, t in entries) + "\n" + tail


# ------------------------------------------------------------------ раскраска
def _hsv(h, s, v):
    return [round(x, 2) for x in colorsys.hsv_to_rgb(h % 1.0, s, v)]


def design_for(num, group, double_surface, kingpost):
    """Палитра по номеру раздела ТЗ (золотое сечение по оттенку — соседние номера далеко по цвету). Без надписей."""
    h1 = (0.07 + num * 0.618034) % 1.0
    h2 = (h1 + 0.42 + 0.08 * (num % 3)) % 1.0
    c1 = _hsv(h1, 0.82, 0.86)
    c2 = _hsv(h2, 0.78, 0.72)
    white = [0.96, 0.96, 0.95]
    dark = [0.1, 0.1, 0.12]
    batten = [0.27, 0.27, 0.3]
    if group in ("trainer", "soviet") and not double_surface:
        # учебные: яркий парус целиком или белый с цветным центром (как Falcon / Target)
        pattern = ("center_v", "chevron")[num % 2]
        base = c1 if num % 3 != 1 else white
        return OrderedDict([("base", base), ("le", c2), ("center", white if base is c1 else c1), ("accent", c2),
                            ("te", [0.2, 0.2, 0.25]), ("batten", [0.25, 0.22, 0.15]), ("pattern", pattern)])
    if not kingpost:
        pattern = ("sport", "combat", "laminar")[num % 3]
        d = OrderedDict([("base", white), ("le", dark if num % 2 else _hsv(h2, 0.15, 0.4)), ("center", c1),
                         ("accent", c2 if pattern != "combat" else dark), ("te", dark), ("batten", batten),
                         ("bottom", white if pattern != "sport" else c1), ("bottom_accent", c1 if pattern != "sport" else white),
                         ("bottom_tip", dark), ("pattern", pattern), ("scrim", True)])
        return d
    pattern = ("laminar", "chevron", "center_v")[num % 3]
    d = OrderedDict([("base", white), ("le", [0.88, 0.88, 0.9] if pattern == "laminar" else c2), ("center", c1),
                     ("accent", c2), ("te", dark), ("batten", batten)])
    if double_surface:
        d["bottom"] = white if pattern != "chevron" else c1
        d["bottom_accent"] = c1 if pattern != "chevron" else c2
        d["bottom_tip"] = c2
    d["pattern"] = pattern
    d["scrim"] = pattern == "laminar"
    return d


# ------------------------------------------------------------------ поляра (как WingPolar: таблица CL→CD)
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

    def sink(self, vk):
        """Установившееся снижение на воздушной скорости vk, м/с."""
        v = vk / 3.6
        g = 0.0
        for _ in range(60):
            cl = 2 * self.mass * G * math.cos(g) / (RHO * self.area * v * v)
            g = math.atan(self.cd_at(cl) / cl)
        return v * math.sin(g)


# ------------------------------------------------------------------ конфиг
def set_after(d, key, value, after=None):
    """Ставит ключ (если нового нет — после after), сохраняя порядок остальных."""
    if key in d or after is None or after not in d:
        d[key] = value
        return
    items = list(d.items())
    d.clear()
    for k, v in items:
        d[k] = v
        if k == after:
            d[key] = value


def make_config(wid, s, base_cfg, design, params):
    c = s["config"]
    base = s["base"]
    dhv = c.get("dhv") or {}
    cfg = copy.deepcopy(base_cfg)
    src = "wings_merged.json («%s»)" % "», «".join(s["sources"][:1])
    cert = dhv.get("cert")
    asbase = []  # поля, взятые от базы (паспорта нет)

    def from_spec(key, default, doc_src, doc_base):
        v = c.get(key)
        if v is None:
            asbase.append(key)
            return default, doc_base
        return v, doc_src

    cfg["name"] = "wing_" + wid
    cfg["group"] = c["group"]
    cfg["prototype"] = "%s, %s м² (паспорт: %s%s)" % (c["prototype"], fm(c["area_m2"]), src, "; " + cert if cert else "")
    cfg["era"] = c.get("era") or "?"
    if not c.get("era"):
        asbase.append("era")
        cfg["era_doc"] = "Годы выпуска прототипа: в паспортах и выборке нет — «?» (поправим по источникам)"
    else:
        cfg["era_doc"] = "Годы выпуска прототипа (для строки описания в меню): выборка страниц производителя / год сертификации (ТЗ, раздел %s)" % s["section"]
    cfg["kingpost"] = bool(c["kingpost"])
    cfg["kingpost_doc"] = "Мачта с верхними тросами: true — мачтовое, false — безмачтовое (topless). Тип — по ТЗ (docs/research/glider_3d_tz.md, раздел %s)" % s["section"]
    ds, ds_doc = from_spec("double_surface_pct", base_cfg["double_surface_pct"],
                           "Доля нижней обшивки, %% размаха: 0 — однообшивочное (паспорт: %s)" % src,
                           "Доля нижней обшивки, %% размаха: в паспорте нет — как у базы %s" % base)
    cfg["double_surface_pct"] = int(round(ds))
    cfg["double_surface_pct_doc"] = ds_doc
    cfg["area_m2"] = c["area_m2"]
    cfg["area_m2_doc"] = "Площадь крыла, м² (паспорт, опорный размер %s: %s)" % (s.get("size") or "—", src)
    cfg["span_m"] = c["span_m"]
    cfg["span_m_doc"] = "Размах, м (ТЗ, раздел %s: паспорт или оценка — см. таблицу «Что задать»). Концы крыла — точки опроса воздуха для кренящего момента (FR-8)" % s["section"]
    wm, wm_doc = from_spec("wing_mass_kg", base_cfg["wing_mass_kg"], "Масса крыла, кг (паспорт: %s; при расхождении источников — DHV)" % src,
                           "Масса крыла, кг: в паспорте нет — как у базы %s" % base)
    cfg["wing_mass_kg"] = wm
    cfg["wing_mass_kg_doc"] = wm_doc

    # пилот: hook-in производителя, иначе DHV «Startgewicht» минус масса крыла, иначе база (К4)
    pm = {}
    for side, tk in (("min", "takeoff_mass_min_kg"), ("max", "takeoff_mass_max_kg")):
        v = c.get("pilot_mass_%s_kg" % side)
        if v is not None:
            pm[side] = (float(v), "hook-in производителя (%s)" % src)
        elif dhv.get(tk) is not None and c.get("wing_mass_kg") is not None:
            pm[side] = (float(round(dhv[tk] - c["wing_mass_kg"])), "DHV «Startgewicht» %s кг минус масса крыла %s кг (%s; hook-in в паспорте нет)" % (
                fm(dhv[tk], 1), fm(c["wing_mass_kg"], 1), cert or "DHV"))
        else:
            pm[side] = (float(base_cfg["pilot_mass_%s_kg" % side]), "в паспорте нет — как у базы %s" % base)
            asbase.append("pilot_mass_%s_kg" % side)
    if pm["min"][0] >= pm["max"][0]:
        for side in ("min", "max"):
            pm[side] = (float(base_cfg["pilot_mass_%s_kg" % side]), "источники противоречат (мин ≥ макс) — как у базы %s" % base)
    lo_b, hi_b, ref_b = base_cfg["pilot_mass_min_kg"], base_cfg["pilot_mass_max_kg"], base_cfg["pilot_mass_ref_kg"]
    lo, hi = pm["min"][0], pm["max"][0]
    ref = float(round(lo + (ref_b - lo_b) / (hi_b - lo_b) * (hi - lo)))
    cfg["pilot_mass_min_kg"] = lo
    cfg["pilot_mass_min_kg_doc"] = "Минимальная масса пилота с подвеской (hook-in), кг: " + pm["min"][1]
    cfg["pilot_mass_max_kg"] = hi
    cfg["pilot_mass_max_kg_doc"] = "Максимальная масса пилота с подвеской (hook-in), кг: " + pm["max"][1]
    cfg["pilot_mass_ref_kg"] = ref
    cfg["pilot_mass_ref_kg_doc"] = ("Эталонная масса пилота, для которой задана поляра, кг: на том же месте диапазона, что у базы %s "
                                    "(%s в %s–%s), округлено до 1 кг (К4). Полная эталонная масса = эта + масса крыла" % (
                                        base, fm(ref_b, 0), fm(lo_b, 0), fm(hi_b, 0)))

    # поляра подобием (К4)
    m_new, m_base = ref + wm, ref_b + base_cfg["wing_mass_kg"]
    f = math.sqrt((m_new / c["area_m2"]) / (m_base / base_cfg["area_m2"]))
    pts = [[round(v * f, 2), round(w * f, 3)] for v, w in base_cfg["polar"]["points_kmh_ms"]]
    cfg["polar"]["points_kmh_ms"] = pts
    cfg["polar"]["_doc"] = (base_cfg["polar"]["_doc"] + ". Своей поляры у прототипа нет: поляра базы %s, перенесённая подобием на нагрузку "
                            "этого крыла (docs/wings_models3d_contracts.md, К4): скорости и снижения × f = √((m/S)/(m/S)_база) = %s; "
                            "безразмерная поляра CL→CD и качество — как у базы" % (base, fm(f, 4)))
    ref_d = cfg["reference"]
    for k in ("stall_speed_kmh", "min_sink_speed_kmh", "best_glide_speed_kmh"):
        if k in ref_d:
            ref_d[k] = round(base_cfg["reference"][k] * f, 1)
    ref_d["min_sink_ms"] = round(base_cfg["reference"]["min_sink_ms"] * f, 3)
    if "sink_at_80_kmh_ms" in ref_d:
        pb = Polar(base_cfg["polar"]["points_kmh_ms"], m_base, base_cfg["area_m2"])
        ref_d["sink_at_80_kmh_ms"] = round(f * pb.sink(80.0 / f), 2)
    ref_d["_doc"] = ("Ориентиры поляры (FR-1) для тестов и документации: при эталонной массе на уровне моря. Ориентиры базы %s × f "
                     "(качество best_glide — как у базы: подобие его не меняет; sink_at_80 — по поляре базы на 80/f км/ч × f)" % base)
    for k in ("trim_speed_kmh", "full_pull_speed_kmh", "full_push_speed_kmh"):
        cfg[k] = round(base_cfg[k] * f, 1)
        cfg[k + "_doc"] = base_cfg[k + "_doc"] + " (база %s × f, К4)" % base
    cfg["wind_max_ms_doc"] = base_cfg["wind_max_ms_doc"] + " — как у базы %s" % base

    # DHV Vmin — проверка, не подгонка (К4 v2: расхождение — относительно такого же расхождения у базы, без порога)
    stall = pts[0][0]
    dhv_note = "DHV Vmin нет"
    vmin_ref = diff = rel = None
    bd = base_dhv_diff(base, base_cfg)
    if dhv.get("vmin_vg0_kmh") and dhv.get("takeoff_mass_min_kg") and dhv.get("takeoff_mass_max_kg"):
        vmin_ref, m_dhv = _vmin_ref(dhv["vmin_vg0_kmh"], dhv["takeoff_mass_min_kg"], dhv["takeoff_mass_max_kg"],
                                    c["area_m2"], m_new, c["area_m2"])
        diff = stall / vmin_ref - 1
        if bd is None:
            base_txt = "у базы %s данных DHV Vmin нет — сравнить не с чем" % base
        else:
            rel = (1 + diff) / (1 + bd[0]) - 1
            base_txt = "у базы %s то же расхождение %+.0f %% (DHV «%s») — относительно базы %+.0f %%" % (base, 100 * bd[0], bd[1], 100 * rel)
        dhv_note = ("DHV Vmin (VG 0) %s км/ч при середине «Startgewicht» %s кг (%s) → на эталонной массе %s кг: %s км/ч; сваливание поляры %s км/ч (%+.0f %%); %s. "
                    "Не правится (К4: проверка, не подгонка; при какой массе DHV мерил Vmin, в карточке не сказано)" % (
                        fm(dhv["vmin_vg0_kmh"], 1), fm(m_dhv, 1), cert or "DHV", fm(m_new, 1), fm(vmin_ref, 1), fm(stall, 1), 100 * diff, base_txt))
    elif dhv.get("vmin_vg0_kmh"):
        dhv_note = "DHV Vmin (VG 0) %s км/ч — без диапазона «Startgewicht», на эталонную массу не пересчитан" % fm(dhv["vmin_vg0_kmh"], 1)

    cfg["_doc"] = ("%s (прототип — %s, раздел %s ТЗ docs/research/glider_3d_tz.md; паспорт — tools/research/data/wing_passports/wings_merged.json, "
                   "ключи «%s»%s). Площадь, размах, масса, диапазон пилота, тип конструкции, доля двойной обшивки — по паспорту; %s"
                   "поляра и скорости — подобием от базы %s по нагрузке на крыло (К4, f = %s), качество — как у базы. Остальная физика (крен, "
                   "сваливание, разбег, ветер) — как у базы %s. %s. Конфиг создан tools/research/data/wing_passports/make_new_wings.py." % (
                       s["title"], c["prototype"], s["section"], "», «".join(s["sources"]), ("; " + cert) if cert else "",
                       ("чего в паспорте нет (%s) — как у базы; " % ", ".join(asbase)) if asbase else "", base, fm(f, 4), base, dhv_note))
    vis = cfg["visual"]
    vis["visual_model"] = "res://assets/models/glider_%s.glb" % wid
    vis["root_chord_m"] = params["root_chord_m"]
    vis["color"] = list(design.get("center") if design.get("base") == [0.96, 0.96, 0.95] else design["base"])
    return cfg, dict(f=f, stall=stall, stall_base=base_cfg["polar"]["points_kmh_ms"][0][0], trim=cfg["trim_speed_kmh"],
                     trim_base=base_cfg["trim_speed_kmh"], bg=ref_d["best_glide"], bg_base=base_cfg["reference"]["best_glide"],
                     vmin_ref=vmin_ref, diff=diff, rel=rel, wm=wm, lo=lo, hi=hi, ref=ref, pm_src=(pm["min"][1], pm["max"][1]), m_new=m_new,
                     dhv=dhv)


# ------------------------------------------------------------------ ui.csv
def csv_line(row):
    buf = io.StringIO()
    csv.writer(buf, lineterminator="").writerow(row)
    return buf.getvalue()


def update_locale(spec, names):
    with open(LOCALE, encoding="utf-8", newline="") as f:
        lines = f.read().split("\n")
    keys = {"wing_" + wid: wid for wid in spec}
    kept, ours = [], {}
    for ln in lines:
        k = ln.split(",", 1)[0]
        if k in keys:
            ours[keys[k]] = ln
        else:
            kept.append(ln)
    for wid, name in names.items():
        ours[wid] = csv_line(["wing_" + wid, name, name])
    order = sorted(ours, key=lambda w: int(spec[w]["section"][1:]))
    at = next(i for i, ln in enumerate(kept) if ln.startswith("wing_group_"))
    kept[at:at] = [ours[w] for w in order]
    with open(LOCALE, "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(kept))


# ------------------------------------------------------------------ main
def main(argv):
    spec = load_json(SPEC)
    if "--all" in argv:
        ids = list(spec)
    elif "--existing" in argv:
        ids = [w for w in spec if os.path.exists(os.path.join(CFG_DIR, w + ".json"))]
    else:
        ids = [a for a in argv if not a.startswith("-")]
    if not ids:
        raise SystemExit(__doc__)
    for wid in ids:
        if wid not in spec:
            raise SystemExit("нет в спецификации: %s" % wid)
    with open(PARAMS, encoding="utf-8") as fh:
        ptext = fh.read()
    pall = json.loads(ptext, object_pairs_hook=OrderedDict)["wings"]
    head, entries, tail = split_wings(ptext)
    ent = OrderedDict(entries)
    names, report = OrderedDict(), []
    for wid in ids:
        s = spec[wid]
        base = s["base"]
        if base in spec:
            raise SystemExit("%s: база %s — тоже новое крыло; базой должна быть существующая модель" % (wid, base))
        ov = {}
        ovp = os.path.join(OVERRIDES, wid + ".json")
        if os.path.exists(ovp):
            ov = load_json(ovp)
        p = copy.deepcopy(pall[base])
        p.pop("span_m", None)
        p.pop("area_m2", None)
        for k, v in s["params"].items():
            p[k] = v
        p["config"], p["out"] = wid, "glider_" + wid
        num = int(s["section"][1:])
        design = design_for(num, s["config"]["group"], bool(p["double_surface"]), p["kingpost_m"] > 0)
        design.update(ov.get("design", {}))
        p["design"] = design
        for k, v in ov.get("params", {}).items():
            p[k] = v
        ent[wid] = fmt_entry(wid, p)
        base_cfg = load_json(os.path.join(CFG_DIR, base + ".json"))
        cfg, info = make_config(wid, s, base_cfg, design, p)
        for k, v in ov.get("config", {}).items():
            cfg[k] = v
        with open(os.path.join(CFG_DIR, wid + ".json"), "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        names[wid] = s["config"]["prototype"]
        report.append((wid, s, info))
    # порядок: существующие (не из спецификации) как были, потом новые по номеру раздела ТЗ
    old = [(w, t) for w, t in ent.items() if w not in spec]
    new = sorted(((w, t) for w, t in ent.items() if w in spec), key=lambda x: int(spec[x[0]]["section"][1:]))
    out = join_wings(head, old + new, tail)
    parsed = json.loads(out)  # проверка: файл остаётся корректным JSON
    for wid in ids:
        assert parsed["wings"][wid]["config"] == wid
    with open(PARAMS, "w", encoding="utf-8") as fh:
        fh.write(out)
    update_locale(spec, names)
    print_report(report)


def fmt_entry(wid, p):
    return "    %s: %s" % (_scalar(wid), fmt(p, 4))


def print_report(report):
    print("| id | раздел | база | f | сваливание, км/ч (база) | трим (база) | качество (база) | DHV Vmin на эт. массе | расхождение | относит. базы | крыло, кг | пилот, кг (эталон) | откуда пилот |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for wid, s, i in report:
        print("| %s | %s | %s | %.4f | %s (%s) | %s (%s) | %s (%s) | %s | %s | %s | %s | %s–%s (%s) | %s |" % (
            wid, s["section"], s["base"], i["f"], fm(i["stall"], 1), fm(i["stall_base"], 1), fm(i["trim"], 1), fm(i["trim_base"], 1),
            fm(i["bg"], 1), fm(i["bg_base"], 1), "—" if i["vmin_ref"] is None else fm(i["vmin_ref"], 1),
            "—" if i["diff"] is None else "%+.0f %%" % (100 * i["diff"]),
            "—" if i["rel"] is None else "%+.0f %%" % (100 * i["rel"]), fm(i["wm"], 1), fm(i["lo"], 0), fm(i["hi"], 0), fm(i["ref"], 0),
            i["pm_src"][0] if i["pm_src"][0] == i["pm_src"][1] else "мин: %s; макс: %s" % i["pm_src"]))


if __name__ == "__main__":
    main(sys.argv[1:])
