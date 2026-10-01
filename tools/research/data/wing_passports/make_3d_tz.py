#!/usr/bin/env python3
"""Генератор docs/research/glider_3d_tz.md — ТЗ на 3D-модели крыльев по паспортам.

Вход: tz_curated.py (ручная часть), wings_merged.json, wings_geometry.json,
out/construction/batch_*.json (тип конструкции — выборка из открытых источников),
tools/blender/glider_params.json, configs/wings/*.json, wings3d_geometry.py.
Выход: docs/research/glider_3d_tz.md.  Запуск: python3 make_3d_tz.py (только стандартная библиотека).
"""
import glob
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tz_curated as C  # noqa: E402
import wings3d_geometry as G  # noqa: E402

ROOT = G.ROOT
OUT = os.path.join(ROOT, "docs", "research", "glider_3d_tz.md")

MERGED = json.load(open(os.path.join(HERE, "wings_merged.json"), encoding="utf-8"))
GEOM = {r["key"]: r for r in json.load(open(os.path.join(HERE, "wings_geometry.json"), encoding="utf-8"))}
PARAMS = G.load_params()
MFR_SHORT = {"Delta Flugschule Condor": "Delta Flugschule Condor"}
BY_KEY = {}
for r in MERGED:
    BY_KEY[(r["manufacturer"], r["family"], r["version"] or "", r["size"] or "")] = r

# ------------------------------------------------------------------ конструкция из выборок
CONS = {}  # (mfr lower, family lower) -> dict


def _norm(f):
    """Приводит запись выборки (две схемы: вложенная и плоская) к одному виду."""
    c = f.get("construction")
    if isinstance(c, dict):
        ctype, ev = c.get("type"), c.get("evidence") or {}
    else:
        ctype, ev = c, f.get("evidence") or {}
    s = f.get("surface")
    if isinstance(s, dict):
        stype, spct = s.get("type"), s.get("double_percent")
    else:
        stype, spct = s, f.get("surface_percent")
    v = f.get("vg")
    vg = v.get("present") if isinstance(v, dict) else v
    p = f.get("production")
    if isinstance(p, dict):
        fy, ly = p.get("first_year"), p.get("last_year")
    else:
        fy, ly = f.get("first_year"), f.get("last_year")
    sp = f.get("successor_or_predecessor")
    rel = sp.get("relations") if isinstance(sp, dict) else ([sp] if sp and sp != "unknown" else [])
    dn = f.get("design_notes")
    dn = [dn] if isinstance(dn, str) else (dn or [])
    return dict(ctype=ctype, cquote=(ev or {}).get("quote", ""), curl=(ev or {}).get("url", ""), stype=stype, spct=spct, vg=vg,
                fy=fy, ly=ly, rel=[str(x) for x in (rel or [])], dn=[str(x) for x in dn], sizes=f.get("sizes") or [])


def load_cons():
    for fn in sorted(glob.glob(os.path.join(HERE, "out", "construction", "batch_*.json"))):
        d = json.load(open(fn, encoding="utf-8"))
        for f in d.get("families", []):
            CONS[(str(f.get("manufacturer", "")).lower(), str(f.get("family", "")).lower())] = _norm(f)


load_cons()


def _type_ok(kind, quote):
    q = (quote or "").lower()
    if kind == "kingpost":
        return bool(re.search(r"king[- ]?post", q)) and not re.search(r"king-?post-?less|no king|without king|lacking a king", q)
    if kind == "topless":
        return bool(re.search(r"topless|top-less|king-?post-?less|no king-?post|without (a )?king|lacking a king", q))
    return False


def _find(entry):
    key = (str(entry.get("mfr") or "").lower(), str(entry.get("family") or "").lower())
    if not key[0]:
        return None
    for (m, fam), v in CONS.items():
        if m.startswith(key[0].split()[0]) and (fam == key[1] or fam.startswith(key[1] + " ") or key[1].startswith(fam + " ")):
            return v
    return None


def construction(entry):
    """(тип, пояснение). Тип принимается из выборки только если цитата прямо называет мачту/безмачтовость."""
    if entry.get("cons_force"):
        return entry["cons_force"]
    r = rec(entry["mfr"], entry["family"], entry["version"], entry["size"]) if entry.get("mfr") else None
    kd = geom_val(r, "kingpost_design") if r else None
    if kd:
        return "kingpost", "по паспорту (geometry `kingpost_design` = «%s», страница производителя)" % kd
    f = _find(entry)
    if f and f["ctype"] in ("kingpost", "topless") and _type_ok(f["ctype"], f["cquote"]):
        return f["ctype"], "по цитате: «%s» (%s)" % (f["cquote"][:130].replace("\n", " "), f["curl"])
    hint = entry.get("cons")
    if hint:
        txt = {"kingpost": "мачтовое", "topless": "безмачтовое"}[hint]
        return hint, "%s — по году выпуска/классу (подтверждающей цитаты нет; поправим по отзывам пилотов)" % txt
    return "kingpost", "мачтовое — по умолчанию (год/тип неизвестны; поправим по отзывам пилотов)"


def extra_cons(entry):
    return _find(entry)


# ------------------------------------------------------------------ форматирование
def fm(x, nd=2):
    if x is None:
        return "—"
    if isinstance(x, str):
        return x
    s = ("%." + str(nd) + "f") % x
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s.replace(".", ",")


def rec(mfr, fam, ver, size):
    return BY_KEY.get((mfr, fam, ver or "", size or ""))


def fv(r, name):
    if not r:
        return None
    f = r["fields"].get(name)
    return None if not f else f.get("value")


def frange(r, name):
    if not r:
        return None
    f = r["fields"].get(name)
    return f.get("range") if f else None


def geom_items(r):
    if not r:
        return []
    g = GEOM.get(r["key"])
    return g["items"] if g else []


def geom_val(r, name):
    for it in geom_items(r):
        if it["name"] == name:
            return it.get("value_mm", it.get("value_deg", it.get("value", it.get("text"))))
    return None


def rnd(x):
    return int(math.floor(x + 0.5))


def fc(x):
    """Хорда, м: всегда две цифры после запятой."""
    return ("%.2f" % x).replace(".", ",")


def _upper_count(value, quote):
    """Верхние латы: «16 / 6» (DHV: верх./низ), «22+4» (верх.+низ) → первое число; иначе само значение."""
    q = str(quote or "")
    m = re.search(r"(\d+)\s*(?:/|\+)\s*(\d+)\s*$", q.strip()) or re.search(r"(\d+)\s*\+\s*(\d+)", q)
    if m and 9 <= int(m.group(1)) <= 40:
        return float(m.group(1))
    return float(value)


def battens_per_side(r):
    """Число лат на сторону по паспорту (верхних всего / 2), если значение правдоподобно (9…40 всего)."""
    vals = []
    if r:
        f = r["fields"].get("battens")
        if f:
            pairs = []
            for s in f["sources"]:
                if isinstance(s["value"], (int, float)) and 9 <= s["value"] <= 40 and not re.search(r"\d\s*mm|мм", str(s.get("quote", ""))):
                    pairs.append((s.get("kind"), _upper_count(s["value"], s.get("quote"))))
            dhv = [v for k, v in pairs if k == "dhv"]
            vals = dhv or [v for _, v in pairs]
    if not vals:
        for it in geom_items(r):
            if it["name"] in ("battens", "battens_top", "battens_upper") and isinstance(it.get("value"), (int, float)) and 9 <= it["value"] <= 40 \
                    and not re.search(r"\d\s*mm", str(it.get("quote", ""))):
                vals.append(_upper_count(it["value"], it.get("quote")))
    if not vals:
        return None
    lo, hi = min(vals), max(vals)
    return (lo, hi, lo / 2.0, hi / 2.0)


def nose_angle(r):
    if not r:
        return None
    f = r["fields"].get("nose_angle_deg")
    if f:
        rng = f.get("range") or [f["value"], f["value"]]
        return (rng[0], rng[1], f["value"])
    vals = []
    for it in geom_items(r):
        if it["name"] == "nose_angle":
            v = it.get("value_deg", it.get("value"))
            if isinstance(v, (int, float)) and 100 <= v <= 145:
                vals.append(v)
            m = re.search(r"(1[0-4]\d)\s*[-–to ]+\s*(1[0-4]\d)", str(it.get("quote", "")))
            if m:
                vals += [float(m.group(1)), float(m.group(2))]
    if vals:
        return (min(vals), max(vals), (min(vals) + max(vals)) / 2)
    return None


# ------------------------------------------------------------------ источники
WW = "https://www.willswing.com"
URLS = {
    "ww__placard": WW + "/hang-glider-placard-specifications/",
    "ww__polar_data": WW + "/polar-data-for-wills-wing-hang-gliders/",
    "aeros_combat_gt_recon": "https://aeros.com.ua/combat_gt",
    "icaro__alto": "https://www.icaro2000.com/Products/Hanggliders/Alto/Alto.htm",
    "icaro__intro": "https://www.icaro2000.com/Products/Hanggliders/Introduction.htm",
    "pdf__aeros_discus": "https://www.delta-club-82.com/bible/manuels/discus.pdf",
    "pdf__airborne_8439": "https://www.airborne.com.au/images/manuals/8439.pdf",
    "pdf__airborne_downtube_table": "https://www.airborne.com.au/images/pdf/downtube_table.pdf",
    "pdf__airborne_f2_brochure": "https://www.airborne.com.au/images/hang_glider_brochures/F2_brochure.pdf (адрес сокращён в sources.md)",
    "pdf__airborne_sting3": "https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf",
    "pdf__airborne_xt_dimensions": "https://www.airborne.com.au/images/pdf/xt_series_dimensions.pdf",
    "pdf__icaro_alto_data": "https://www.icaro2000.com/Products/Hanggliders/Alto/Alto 2022 Metric-Imperial data.pdf",
    "pdf__icaro_alto_manual": "https://www.icaro2000.com/Products/Hanggliders/Alto/Alto 2022-1-En.pdf",
    "pdf__icaro_laminar": "https://www.icaro2000.com/Products/Manuals/Laminar%202011-3-En.docx.pdf",
    "pdf__icaro_laminar_data_imperial": "https://www.icaro2000.com/Products/Hanggliders/Laminar/Laminar 2022 Imperial data.pdf",
    "pdf__icaro_laminar_data_metric": "https://www.icaro2000.com/Products/Hanggliders/Laminar/Laminar 2022 Metric data.pdf",
    "pdf__icaro_piuma_manual": "https://www.icaro2000.com/Products/Hanggliders/Piuma/Piuma 2019-1-En.pdf",
    "pdf__icaro_piuma_spec_imperial": "https://www.icaro2000.com/Products/Hanggliders/Piuma/Piuma Spec imperial.pdf",
    "pdf__icaro_piuma_spec_metric": "https://www.icaro2000.com/Products/Hanggliders/Piuma/Piuma Spec metric.pdf",
    "pdf__icaro_schedarev": "https://www.icaro2000.com/Products/Hanggliders/Revisions/SchedaRevDelta.pdf",
    "pdf__moyes_litespeed_s": "https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf",
    "pdf__ww_t2": "http://willswing.com/wp-content/uploads/manuals/T2_5th_September_2012.pdf",
}


def src_label(path):
    base = os.path.basename(path)[:-5]
    if "haiku_dhv" in path:
        return "DHV Geräteportal (service.dhv.de/db1; файл разбора %s)" % base
    if base in URLS:
        return URLS[base]
    m = re.match(r"ww__archive_(.+)", base)
    if m:
        return WW + "/hang-gliders/archive/%s/" % m.group(1)
    m = re.match(r"ww__(.+)", base)
    if m:
        return WW + "/hang-gliders/%s/" % m.group(1)
    m = re.match(r"moyes__(.+)_(spec|desc)$", base)
    if m:
        return "https://www.moyes.com.au/products/hang-gliders/%s/%s" % (m.group(1), "specifications" if m.group(2) == "spec" else "description")
    m = re.match(r"bautek__(.+)", base)
    if m:
        return "https://www.bautek.com/english/hanggliders/%s/" % m.group(1)
    m = re.match(r"icaro__(.+)", base)
    if m:
        return "https://www.icaro2000.com/ (страница Icaro, файл разбора %s)" % base
    m = re.match(r"airborne__(.+)", base)
    if m:
        return "https://www.airborne.com.au/pages/hang_gliders.php (файл разбора %s)" % base
    return base


def record_sources(recs):
    files = []
    for r in recs:
        if not r:
            continue
        for f in r.get("sources", []):
            if f not in files:
                files.append(f)
    return files


def cert_line(recs):
    out = []
    for r in recs:
        if not r:
            continue
        for c in r.get("cert_standards", []):
            if c.startswith("DHV") and c not in out:
                out.append(c)
    return out


# ------------------------------------------------------------------ геометрия хорд
def chords_for(base_id, area, span, tip_round=None):
    bp = PARAMS[base_id]
    ratio = bp["tip_chord_m"] / bp["root_chord_m"]
    tr = bp.get("tip_round", True) if tip_round is None else tip_round
    kr, kt = G.mean_chord_factor(tr)
    root = (area / span) / (kr + kt * ratio)
    tip = ratio * root
    return round(root, 2), round(tip, 2)


def hang_fwd(r):
    """(м, пояснение): расстояние нос → точка подвеса по паспорту (петля подвеса или ЦТ), либо None."""
    if not r:
        return None
    items = {it["name"]: it for it in geom_items(r)}
    f = items.get("keel_hang_loop_forward") or items.get("hang_loop_forward")
    b = items.get("keel_hang_loop_rear") or items.get("hang_loop_rear")
    if f and b:
        a1, a2 = f["value_mm"], b["value_mm"]
        return (a1 + a2) / 2000.0, "паспорт: петля подвеса от носа %s–%s мм (середина)" % (fm(a1, 0), fm(a2, 0))
    it = items.get("keel_to_hang_loop")
    if it:
        m = re.search(r"(\d+\.\d+)\s*-\s*(\d+\.\d+)", str(it.get("quote", "")))
        if m:
            lo, hi = float(m.group(1)) * 25.4, float(m.group(2)) * 25.4
            return (lo + hi) / 2000.0, "паспорт: петля подвеса от линии носовых болтов %s–%s мм (49,75–51,25 in), середина" % (fm(lo, 0), fm(hi, 0))
        return it["value_mm"] / 1000.0, "паспорт: петля подвеса от носа %s мм" % fm(it["value_mm"], 0)
    it = items.get("cg_front_of_keel")
    if it:
        return it["value_mm"] / 1000.0, "паспорт: положение ЦТ от носа киля %s мм" % fm(it["value_mm"], 0)
    return None


def crossbar_u_from(r, span, nose_deg):
    """Положение поперечины на передней кромке (доля длины кромки от носа) по паспорту, либо None."""
    if not r or not span:
        return None
    items = {it["name"]: it for it in geom_items(r)}
    le_len = (span / 2) / math.sin(math.radians(nose_deg / 2))
    cbx = items.get("leading_edge_nose_to_crossbar") or items.get("nose_to_crossbar")
    if cbx:
        return cbx["value_mm"] / 1000.0 / le_len, "паспорт: нос→поперечина %s мм при длине передней кромки ≈ %s м" % (fm(cbx["value_mm"], 0), fm(le_len))
    L = items.get("crossbar_overall_length")
    k = items.get("keel_to_crossbar_center")
    if L and k:
        c = math.cos(math.radians(nose_deg / 2))
        kk, LL = k["value_mm"] / 1000.0, L["value_mm"] / 1000.0
        sol = (2 * kk * c + math.sqrt(4 * kk * kk * c * c - 4 * (kk * kk - LL * LL))) / 2
        return sol / le_len, "паспорт: поперечина %s мм от центрального штыря (на киле в %s мм от носа) до кромки ⇒ крепление на расстоянии %s м от носа по кромке длиной ≈ %s м" % (fm(L["value_mm"], 0), fm(k["value_mm"], 0), fm(sol), fm(le_len))
    return None


BOILER = (
    "**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; "
    "сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — "
    "`assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и "
    "`godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, "
    "`ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). "
    "Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить "
    "скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и "
    "в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; "
    "закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы."
)


# ------------------------------------------------------------------ таблица размеров
def size_table(recs):
    hdr = "| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |\n|---|---|---|---|---|---|---|---|---|---|\n"
    rows = []
    for r in recs:
        if not r:
            continue
        nm = (r["family"] + (" " + r["version"] if r["version"] else "") + (" " + r["size"] if r["size"] else "")).strip()
        na = nose_angle(r)
        nas = "—" if not na else (fm(na[0], 1) if na[0] == na[1] else "%s–%s" % (fm(na[0], 1), fm(na[1], 1)))
        bs = battens_per_side(r)
        bss = "—" if not bs else (fm(bs[0], 0) if bs[0] == bs[1] else "%s–%s" % (fm(bs[0], 0), fm(bs[1], 0)))
        pmin, pmax = fv(r, "pilot_mass_min_kg"), fv(r, "pilot_mass_max_kg")
        pl = "—" if pmin is None else "%s–%s" % (fm(pmin, 0), fm(pmax, 0))
        rows.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            nm, fm(fv(r, "area_m2")), fm(fv(r, "span_m")), fm(fv(r, "aspect_ratio")), fm(fv(r, "wing_mass_kg"), 1), pl,
            fm(fv(r, "double_surface_pct"), 0), fm(fv(r, "vne_kmh"), 0), nas, bss))
    return hdr + "\n".join(rows) + "\n"


def geom_table(r):
    items = geom_items(r)
    if not items:
        return ""
    skip = {"packed_length", "packed_length_short", "packed_length_long"}
    seen = set()
    out = []
    for it in items:
        v = it.get("value_mm", it.get("value_deg", it.get("value", it.get("text"))))
        k = (it["name"], str(v))
        if k in seen or it["name"] in skip:
            continue
        seen.add(k)
        unit = "мм" if "value_mm" in it else ("°" if "value_deg" in it else "")
        out.append("- `%s` = %s %s — «%s»" % (it["name"], fm(v, 1) if isinstance(v, (int, float)) else v, unit, str(it.get("quote", "")).replace("\n", " ")[:90]))
    return "\n".join(out[:22]) + "\n"


# ------------------------------------------------------------------ раздел существующей модели
def section_existing(n, e):
    wid = e["id"]
    p = PARAMS[wid]
    cfg = G.load_cfg(p["config"])
    span = cfg["span_m"]
    area_cfg = cfg["area_m2"]
    r = rec(e["mfr"], e["family"], e["version"], e["size"]) if e["mfr"] else None
    recs = [r] + [rec(*k) for k in e.get("also", [])] if e["mfr"] else []
    L = []
    L.append("## Раздел E%d. %s (`%s`) — существующая модель" % (n, e["title"], wid))
    L.append("")
    L.append("- **Модель:** %s; файл `assets/models/glider_%s.glb`, параметры — `tools/blender/glider_params.json` → `wings.%s`, конфиг — `configs/wings/%s.json`." % (e["title"], wid, wid, p["config"]))
    L.append("- **Класс:** %s. Группа игры: `%s`." % (e["cls"], e["group"]))
    ctype, cnote = construction(e)
    L.append("- **Что есть сейчас:** размах %s м, площадь в конфиге %s м², в плане по модели %s м²; угол носа %s°, хорда у корня/на конце %s/%s м, лат на сторону %s, "
             "двойная поверхность %s (нижняя обшивка на %s хорды), кингпост %s м, подвес: нос на %s м впереди; двугранность %s°, закрутка %s°." % (
                 fm(span), fm(area_cfg), fm(G.implied_area(p["root_chord_m"], p["tip_chord_m"], span, p.get("tip_round", True)), 1),
                 p["nose_angle_deg"], fm(p["root_chord_m"]), fm(p["tip_chord_m"]), p["battens_per_side"],
                 "да" if p["double_surface"] else "нет", fm(p["lower_cover"]), fm(p["kingpost_m"]), fm(p["nose_forward_m"]),
                 fm(p["dihedral_deg"], 1), p["washout_deg"]))
    L.append("- **Конструкция:** %s." % ("мачтовое" if p["kingpost_m"] else "безмачтовое (топлесс)"))
    L.append("")
    L.append("### Что менять")
    L.append("")
    changes, keep = [], []
    if not r:
        keep.append("паспортов этого семейства в наборе нет — числа не меняются")
    else:
        # площадь в плане
        A = fv(r, "area_m2")
        ia = G.implied_area(p["root_chord_m"], p["tip_chord_m"], span, p.get("tip_round", True))
        if not e.get("strict", True):
            pass
        elif A and abs(ia / A - 1) > 0.015:
            tip = round(G.solve_tip(A, span, p["root_chord_m"], p.get("tip_round", True)), 2)
            changes.append(("tip_chord_m", fc(p["tip_chord_m"]), fc(tip),
                            "площадь в плане по модели %s м² против паспортных %s м² (допуск ±1,5 %%); хорду у корня не менять" % (fm(ia, 1), fm(A))))
        elif A:
            keep.append("площадь в плане %s м² ≈ паспорт %s м²" % (fm(ia, 1), fm(A)))
        b = fv(r, "span_m")
        if not e.get("strict", True):
            keep.append("размах и площадь не правятся: тождество прототипа с аналогом в паспорте не доказано")
        elif b and abs(b - span) > 0.04:
            changes.append(("span_m (configs/wings/%s.json)" % p["config"], fm(span), fm(b), "паспорт"))
        elif b:
            keep.append("размах %s м ≈ паспорт %s м" % (fm(span), fm(b)))
        na = nose_angle(r)
        if na:
            if na[0] - 0.6 <= p["nose_angle_deg"] <= na[1] + 0.6:
                keep.append("угол носа %s° в паспортном диапазоне %s–%s°" % (p["nose_angle_deg"], fm(na[0], 1), fm(na[1], 1)))
            else:
                changes.append(("nose_angle_deg", p["nose_angle_deg"], fm(round((na[0] + na[1]) / 2), 0) if na[0] != na[1] else fm(na[0], 0),
                                "паспортный диапазон %s–%s°" % (fm(na[0], 1), fm(na[1], 1))))
        bs = battens_per_side(r)
        if bs:
            want = int(math.floor((bs[0] + bs[1]) / 4.0))
            if abs(p["battens_per_side"] - want) >= 2:
                changes.append(("battens_per_side", p["battens_per_side"], fm(want, 0),
                                "паспорт: верхних лат всего %s–%s (÷2 = %s–%s на сторону)" % (fm(bs[0], 0), fm(bs[1], 0), fm(bs[2], 1), fm(bs[3], 1))))
            else:
                keep.append("число лат %s на сторону ≈ паспорт (%s всего)" % (p["battens_per_side"], fm(bs[0], 0) if bs[0] == bs[1] else "%s–%s" % (fm(bs[0], 0), fm(bs[1], 0))))
        cg = geom_val(r, "cg_front_of_keel") or geom_val(rec("Moyes", "Litespeed RX", "", "4"), "cg_front_of_keel") if wid == "sport" else geom_val(r, "cg_front_of_keel")
        if cg:
            new = round(cg / 1000.0, 2)
            if abs(new - p["nose_forward_m"]) > 0.03:
                changes.append(("nose_forward_m", fm(p["nose_forward_m"]), fm(new), "паспорт: ЦТ %s мм от носа киля (RX 4/S 4); RS 4 отдельной цифры нет" % fm(cg, 0)))
        ds = fv(r, "double_surface_pct")
        if ds is not None:
            keep.append("доля двойной поверхности по паспорту %s %% (в конфиге %s %%: см. правки json)" % (fm(ds, 0), cfg["double_surface_pct"]))
    # ручные, специфичные для модели
    if wid == "laminar":
        changes.append(("battens_per_side", p["battens_per_side"], "9",
                        "аналог Easy 2 M / Orbiter 14 (DHV: 18 лат всего), а не топлесс-Laminar (22–26 верхних)"))
    if wid == "sport":
        changes.append(("battens_per_side", p["battens_per_side"], "11",
                        "DHV и Moyes (RS/RX/S): 23 верхних лат всего → 11 на сторону + 1 у киля (проверить)"))
        changes.append(("nose_angle_deg", p["nose_angle_deg"], "128",
                        "паспорт: RX 125–130°, S 130–132°, по lineup для RS 4 125–130° — середина; было 132"))
        changes.append(("nose_forward_m", fm(p["nose_forward_m"]), "1,35", "паспорт: ЦТ 1343–1353 мм от носа киля (RX 4 — 1353, S 4 — 1353)"))
    if wid == "combat":
        changes.append(("battens_per_side", p["battens_per_side"], "12",
                        "Aeros: «Number of upper sail battens 24» → 12 на сторону (DHV: 26 всего — 13)"))
    # дедупликация по параметру (ручные перекрывают автоматические)
    seen = {}
    for c in changes:
        seen[c[0]] = c
    changes = list(seen.values())
    if changes:
        L.append("| Параметр | Сейчас | Стало | Основание |")
        L.append("|---|---|---|---|")
        for c in changes:
            L.append("| `%s` | %s | %s | %s |" % c)
    else:
        L.append("Числовых правок нет.")
    L.append("")
    if keep:
        L.append("Без изменений, подтверждено паспортом: " + "; ".join(keep) + ".")
        L.append("")
    for t in e.get("notes", []):
        L.append("- " + t)
    L.append("")
    if r:
        L.append("### Паспортные данные")
        L.append("")
        L.append(size_table(recs))
        gt = geom_table(r)
        if gt:
            L.append("Размеры каркаса/прочее (из `wings_geometry.json`):")
            L.append("")
            L.append(gt)
    L.append("### Источники")
    L.append("")
    if r:
        files = record_sources(recs)
        for f in files[:10]:
            L.append("- " + src_label(f))
        cs = cert_line(recs)
        if cs:
            L.append("- Номера DHV-сертификатов: " + ", ".join(cs))
        L.append("- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `%s`)." % "`, `".join(x["key"] for x in recs if x))
    else:
        L.append("- Прежние источники модели — `docs/plan/wings_lineup.md`, `docs/research/wing_sources.md`; паспортов в наборе нет.")
    L.append("- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.")
    L.append("")
    L.append("### Открытые вопросы")
    L.append("")
    for q in e.get("questions", []) or ["нет"]:
        L.append("- " + q)
    L.append("")
    L.append(BOILER)
    L.append("")
    return "\n".join(L)


# ------------------------------------------------------------------ раздел новой модели
def pick_base(e, ctype):
    b = e.get("base")
    if ctype == "topless" and b in ("training", "target", "laminar", "magic"):
        return "sport"
    if ctype == "kingpost" and b in ("sport", "combat"):
        return "laminar"
    return b or ("sport" if ctype == "topless" else ("laminar" if e["group"] == "kingpost" else "training"))


def section_new(n, e):
    wid = e["id"]
    r = rec(e["mfr"], e["family"], e["version"], e["size"])
    if not r:
        raise SystemExit("нет записи паспорта: %s" % e)
    recs = [r] + [rec(*k) for k in e.get("also", [])]
    recs = [x for x in recs if x]
    ctype, cnote = construction(e)
    base = pick_base(e, ctype)
    bp = PARAMS[base]
    A = fv(r, "area_m2")
    b = fv(r, "span_m")
    AR = fv(r, "aspect_ratio")
    span_note = "паспорт"
    if not b and A and AR:
        b = round(math.sqrt(AR * A), 2)
        span_note = "√(удлинение·площадь): %s·%s" % (fm(AR), fm(A))
    if not b and A:
        cfgb = G.load_cfg(bp["config"])
        b = round(math.sqrt(cfgb["span_m"] ** 2 / cfgb["area_m2"] * A), 2)
        span_note = "оценка: паспорта нет; удлинение базы (%s) × паспортная площадь" % fm(cfgb["span_m"] ** 2 / cfgb["area_m2"])
        e = dict(e, _span_estimated=True)
    if b and A and not (8.0 <= b <= 12.5):
        span_note += "; внимание: вне диапазона 8–12,5 м — перепроверить"
    L = []
    L.append("## Раздел N%d. %s (`%s`) — новая модель, приоритет %s" % (n, e["title"], wid, e.get("prio", "P2")))
    L.append("")
    L.append("- **Модель:** %s; будущий файл `assets/models/glider_%s.glb`, запись `tools/blender/glider_params.json` → `wings.%s` (новая), конфиг `configs/wings/%s.json` (новый; физику и поляру ведёт отдельная задача)." % (e["title"], wid, wid, wid))
    L.append("- **Класс:** %s. Предлагаемая группа игры: `%s` (`configs/wing_groups.json`)." % (e["cls"], e["group"]))
    if ctype and cnote.startswith(("по ", "мачтовое", "безмачтовое")):
        L.append("- **Конструкция:** %s%s." % ("" if cnote.startswith(("мачтовое", "безмачтовое")) else ("мачтовое — " if ctype == "kingpost" else "безмачтовое (топлесс) — "), cnote))
    else:
        L.append("- **Конструкция:** %s." % cnote)
    ex = extra_cons(e)
    if ex:
        bits = []
        if ex["vg"] not in (None, "unknown"):
            bits.append("VG: %s" % ex["vg"])
        if ex["fy"] not in (None, "unknown"):
            bits.append("с %s%s" % (ex["fy"], (" по %s" % ex["ly"]) if ex["ly"] not in (None, "unknown") else ""))
        if ex["rel"]:
            bits.append("преемственность: " + "; ".join(ex["rel"][:2]))
        if bits:
            L.append("- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** " + "; ".join(bits) + ".")
        if ex["dn"]:
            L.append("- **Заметки по виду (из выборки, проверять по первоисточнику):** " + "; ".join(x[:160] for x in ex["dn"][:4]) + ".")
    L.append("- **Что есть сейчас:** 3D-модели и конфига нет.")
    L.append("- **База:** копия записи `wings.%s` из `glider_params.json` (модель `glider_%s.glb`: %s лат на сторону, угол носа %s°, %s); правится только то, что в таблице ниже." % (
        base, base, bp["battens_per_side"], bp["nose_angle_deg"], "мачтовое" if bp["kingpost_m"] else "безмачтовое"))
    L.append("")
    L.append("### Что задать")
    L.append("")
    rows = []
    rows.append(("config", wid, "id модели; `out` = `glider_%s`" % wid))
    if b:
        rows.append(("span_m", fm(b), span_note + ((" (опорный размер %s)" % r["size"]) if r["size"] else " (размер в паспорте не указан)")))
    else:
        rows.append(("span_m", fm(round(bp["span_m"] if "span_m" in bp else 10.0, 2)), "паспорта нет — по базе; уточнить"))
    if A:
        rows.append(("area_m2", fm(A), "паспорт" + ((", опорный размер %s" % r["size"]) if r["size"] else " (размер в паспорте не указан)")))
    na = nose_angle(r)
    if na:
        ang = round((na[0] + na[1]) / 2.0, 1)
        rows.append(("nose_angle_deg", fm(ang, 1), "паспорт%s" % ("" if na[0] == na[1] else ": диапазон %s–%s° (VG), берём середину" % (fm(na[0], 1), fm(na[1], 1)))))
    else:
        ang = bp["nose_angle_deg"]
        rows.append(("nose_angle_deg", fm(ang, 0), "паспорта нет — как у базы; если появится, ставить паспортный"))
    if A and b:
        root, tip = chords_for(base, A, b, bp.get("tip_round", True))
        rows.append(("root_chord_m / tip_chord_m", "%s / %s" % (fc(root), fc(tip)),
                     "форма базы (отношение хорд %s) пересчитана под паспортные размах и площадь; площадь в плане при этом %s м²" % (fm(bp["tip_chord_m"] / bp["root_chord_m"], 3),
                                                                                                                        fm(G.implied_area(root, tip, b, bp.get("tip_round", True)), 2))))
        hf = hang_fwd(r)
        if hf:
            rows.append(("nose_forward_m", fm(round(hf[0], 2)), hf[1]))
        else:
            rows.append(("nose_forward_m", fm(round(0.568 * root, 2)), "0,568·хорда у корня (как у всех существующих моделей; паспорта нет)"))
    bs = battens_per_side(r)
    if bs:
        want = int(math.floor((bs[0] + bs[1]) / 4.0))
        rows.append(("battens_per_side", fm(want, 0), "паспорт: верхних лат всего %s%s ⇒ на сторону %d%s" % (
            fm(bs[0], 0), "" if bs[0] == bs[1] else "–%s" % fm(bs[1], 0), want,
            " (нечётное число: одна центральная лата у киля не считается)" if int(bs[0]) % 2 or int(bs[1]) % 2 else "")))
    else:
        rows.append(("battens_per_side", str(bp["battens_per_side"]), "паспорта нет — как у базы"))
    ds = fv(r, "double_surface_pct")
    if ds is not None:
        if ds >= 50:
            rows.append(("double_surface / lower_cover", "true / %s" % fm(ds / 100.0), "паспорт: двойная поверхность %s %%; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя)" % fm(ds, 0)))
        else:
            rows.append(("double_surface / lower_cover", "false / %s" % fm(max(0.14, ds / 100.0)), "паспорт: нижняя обшивка %s %% — однообшивочное с частичной нижней обшивкой" % fm(ds, 0)))
    else:
        rows.append(("double_surface / lower_cover", "%s / %s" % ("true" if bp["double_surface"] else "false", fm(bp["lower_cover"])), "паспорта нет — как у базы"))
    if ctype == "kingpost":
        rows.append(("kingpost_m", fm(bp["kingpost_m"]) if bp["kingpost_m"] else "1,2", "высоты в паспортах нет — как у базы (мачтовая)"))
    elif ctype == "topless":
        rows.append(("kingpost_m", "0", "безмачтовое"))
    cu = crossbar_u_from(r, b, ang)
    if cu:
        rows.append(("crossbar_u", fm(round(cu[0], 2)), cu[1]))
    else:
        rows.append(("crossbar_u", fm(bp["crossbar_u"]), "данных нет — как у базы"))
    for x in e.get("rows", []):
        rows = [y for y in rows if y[0] != x[0]] + [x]
    rows.append(("dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend", "как у базы", "в источниках чисел нет — не выдумывать"))
    L.append("| Параметр | Значение | Откуда |")
    L.append("|---|---|---|")
    for x in rows:
        L.append("| `%s` | %s | %s |" % x)
    L.append("")
    L.append("Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = %s`, `k_t = %s` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки)." % (
        fm(G.mean_chord_factor(bp.get('tip_round', True))[0], 4), fm(G.mean_chord_factor(bp.get('tip_round', True))[1], 4)))
    L.append("")
    for t in e.get("notes", []):
        L.append("- " + t)
    L.append("")
    L.append("### Паспортные данные по размерам")
    L.append("")
    L.append(size_table(recs))
    gt = geom_table(r)
    if gt:
        L.append("Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):")
        L.append("")
        L.append(gt)
    L.append("### Источники")
    L.append("")
    for f in record_sources(recs)[:10]:
        L.append("- " + src_label(f))
    cs = cert_line(recs)
    if cs:
        L.append("- Номера DHV-сертификатов: " + ", ".join(cs))
    L.append("- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `%s`)." % "`, `".join(x["key"] for x in recs))
    L.append("")
    L.append("### Открытые вопросы")
    L.append("")
    qs = list(e.get("questions", []))
    if e.get("_span_estimated"):
        qs.append("Размаха и удлинения в паспорте нет — размах оценён по удлинению базы, уточнить по первоисточнику.")
    if not na:
        qs.append("Угол носа в паспорте не найден — значение базы.")

    for q in qs or ["нет"]:
        L.append("- " + q)
    L.append("")
    L.append(BOILER)
    L.append("")
    return "\n".join(L)


def main():
    parts = []
    exist = [m for m in C.MODELS if m["status"] == "existing"]
    new = [m for m in C.MODELS if m["status"] == "new"]
    groups_order = {"trainer": 0, "kingpost": 1, "topless": 2}
    # сводная таблица
    summary = ["| Раздел | Модель | id | Класс (кратко) | Конструкция | База | Приоритет |", "|---|---|---|---|---|---|---|"]
    body = []
    for i, e in enumerate(exist, 1):
        ct, _ = construction(e)
        summary.append("| E%d | %s | `%s` | %s | %s | — | существующая |" % (i, e["title"], e["id"], e["cls"].split(",")[0], "мачтовое" if PARAMS[e["id"]]["kingpost_m"] else "безмачтовое"))
        body.append(section_existing(i, e))
    for i, e in enumerate(new, 1):
        ct, _ = construction(e)
        summary.append("| N%d | %s | `%s` | %s | %s | `%s` | %s |" % (i, e["title"], e["id"], e["cls"].split(",")[0],
                                                                      {"kingpost": "мачтовое", "topless": "безмачтовое", "": "?"}[ct] + (" (по году)" if "по году" in _ or "по умолчанию" in _ else ""),
                                                                      pick_base(e, ct), e.get("prio", "P2")))
        body.append(section_new(i, e))
    head = open(os.path.join(HERE, "tz_head.md"), encoding="utf-8").read()
    excl = ["", "## Не включены в ТЗ", "", "| Семейства | Почему |", "|---|---|"] + ["| %s | %s |" % x for x in C.EXCLUDED]
    text = head.rstrip() + "\n\n" + "\n".join(summary) + "\n\n" + "\n".join(excl) + "\n\n---\n\n" + "\n---\n\n".join(body)
    open(OUT, "w", encoding="utf-8").write(text)
    print("записано", OUT, len(text), "символов;", len(exist), "существующих,", len(new), "новых")


if __name__ == "__main__":
    main()
