#!/usr/bin/env python3
"""Страницы сайта «Модели аппаратов» из данных репозитория (контракт C2, docs/plan/site_update.md).

    python3 tools/site/gen_wings.py           # пишет site/content/wings/**
    python3 tools/site/gen_wings.py --check   # ничего не пишет; код 1, если файлы расходятся с данными
                                              # или чего-то не хватает (рендера C1, поля, адреса источника)

Только стандартная библиотека; запуск из любого места (пути — от корня репозитория).

Вход (только чтение): configs/wings/*.json (числа — ровно как в игре), configs/wing_groups.json (группы и их
порядок), locale/ui.csv (русские названия), tools/research/data/wing_passports/ (wings_merged.json — паспорта
с цитатами и файлами разбора, out/wings3d_spec.json — спецификация 39 новых крыльев, wings3d_overrides/ —
ручные правки), docs/research/glider_3d_tz.md (разделы E1–E9, N1–N39: заголовки, строка «Конструкция»),
docs/research/wings_config_sources.md (что из паспорта у 9 старых крыльев — таблица OLD ниже).

Происхождение значения (отметка):
  паспорт — значение конфига совпадает (с точностью округления, 1,5 %) со значением источника той же модели
            и размера в wings_merged.json (страница/PDF производителя, плакат, карточка DHV); ссылки — на эти
            источники. Расхождение источников с конфигом > 3 % показывается рядом («DHV: 36,3 кг»);
  аналог  — то же, но запись паспорта — близкой модели (только laminar: Icaro Easy 2 M / Orbiter 14);
  оценка  — всё остальное: подобие от базы, «как у базы», ТЗ, решение координатора, пересчёт DHV «Startgewicht»,
            непаспортные источники (Википедия, клубные таблицы), а также числа модели игры (трим, сваливание,
            качество — «модель игры»). Неоднозначное — тоже «оценка».
Для 39 новых крыльев запись паспорта — первый ключ `sources` спецификации (так строил make_new_wings.py);
для 9 старых — таблица OLD (по docs/research/wings_config_sources.md §1–§3). Тип конструкции — по строке
«Конструкция» ТЗ: цитата со страницы/PDF производителя или паспорт — «паспорт», остальное — «оценка».

Файлы (C2): site/content/wings/_index.md (сводная таблица), <group>/_index.md (таблица группы) — генератор меняет
только блок между маркерами GEN_BEGIN/GEN_END, остальное — ручной текст; <group>/<id>.md — целиком.
"""
import csv
import glob
import json
import os
import re
import sys
from urllib.parse import urlparse

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "site", "content", "wings")
PP = os.path.join(ROOT, "tools", "research", "data", "wing_passports")
TZ = os.path.join(ROOT, "docs", "research", "glider_3d_tz.md")
GEN_BEGIN = "<!-- gen:begin tools/site/gen_wings.py -->"
GEN_END = "<!-- gen:end -->"
PAGE_NOTE = "<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->"
RENDER = "docs/models/screenshots/glider_%s/iso45.jpg"
DHV_PORTAL = "https://service.dhv.de/db1/technicsearchpage.php?lang=DE"  # docs/research/glider_polars_sources.md
# Раздел «Благодарности» главной: относительная ссылка сырым HTML (обработчик ссылок сайта не умеет «/» с якорем,
# а абсолютный адрес зависит от baseURL). depth — глубина страницы: /wings/ — 1, группа — 2, крыло — 3.
def thanks(text, depth):
    return '<a href="%s#благодарности">%s</a>' % ("../" * depth, text)
TOL = 0.015  # «совпадает с паспортом»: относительная разница не больше (округление конфига)
CONFLICT = 0.03  # другой источник расходится с конфигом больше — показать его значение рядом

# --------------------------------------------------------------------------------------------- источники
# Файл разбора (wings_merged.json → sources[].file) → (подпись, адрес). Адреса — из данных репозитория:
# fetch_makers.py (шаблоны адресов Wills Wing / Moyes / Aeros / Bautek, словарь PDF), sources.md (PDF Icaro и
# Airborne; в таблице адрес усечён слева — домен https://www.icaro2000.com / https://www.airborne.com.au, как у
# соседних адресов в данных), docs/research/glider_3d_tz.md. Нет файла здесь — --check падает.
W = "https://www.willswing.com"
MOYES = "https://www.moyes.com.au/products/hang-gliders/"
ICARO = "https://www.icaro2000.com/Products/Hanggliders/"
SOURCES = {
    "out/haiku/ww__t2c.json": ("willswing.com: T2C", W + "/hang-gliders/t2c/"),
    "out/haiku/ww__t3.json": ("willswing.com: T3", W + "/hang-gliders/t3/"),
    "out/haiku/ww__u2.json": ("willswing.com: U2", W + "/hang-gliders/u2/"),
    "out/haiku/ww__sport-3.json": ("willswing.com: Sport 3", W + "/hang-gliders/sport-3/"),
    "out/haiku/ww__falcon-4.json": ("willswing.com: Falcon 4", W + "/hang-gliders/falcon-4/"),
    "out/haiku/ww__placard.json": ("willswing.com: плакарды", W + "/hang-glider-placard-specifications/"),
    "out/haiku/pdf__ww_t2.json": ("руководство Wills Wing T2 (PDF)", "http://willswing.com/wp-content/uploads/manuals/T2_5th_September_2012.pdf"),
    "out/haiku/aeros_combat_gt_recon.json": ("aeros.com.ua: Combat GT", "https://aeros.com.ua/combat_gt"),
    "out/haiku/pdf__aeros_discus.json": ("руководство Aeros Discus (PDF)", "https://www.delta-club-82.com/bible/manuels/discus.pdf"),
    "out/haiku/pdf__moyes_litespeed_s.json": ("руководство Moyes Litespeed S (PDF)", "https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf"),
    "out/haiku/pdf__airborne_8439.json": ("руководство Airborne F2 (PDF)", "https://www.airborne.com.au/images/manuals/8439.pdf"),
    "out/haiku/pdf__airborne_sting3.json": ("руководство Airborne Sting 3 (PDF)", "https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf"),
    "out/haiku/icaro__mastr.json": ("icaro2000.com: MastR", ICARO + "MastR/MastR.htm"),
    "out/haiku/pdf__icaro_alto_data.json": ("Icaro Alto 2022, данные (PDF)", ICARO + "Alto/Alto%202022%20Metric-Imperial%20data.pdf"),
    "out/haiku/pdf__icaro_alto_manual.json": ("руководство Icaro Alto 2022 (PDF)", ICARO + "Alto/Alto%202022-1-En.pdf"),
    "out/haiku/pdf__icaro_laminar.json": ("руководство Icaro Laminar 2011 (PDF)", "https://www.icaro2000.com/Products/Manuals/Laminar%202011-3-En.docx.pdf"),
    "out/haiku/pdf__icaro_laminar_data_imperial.json": ("Icaro Laminar 2022, данные (PDF)", ICARO + "Laminar/Laminar%202022%20Imperial%20data.pdf"),
    "out/haiku/pdf__icaro_laminar_data_metric.json": ("Icaro Laminar 2022, данные (PDF)", ICARO + "Laminar/Laminar%202022%20Metric%20data.pdf"),
    "out/haiku/pdf__icaro_piuma_manual.json": ("руководство Icaro Piuma 2019 (PDF)", ICARO + "Piuma/Piuma%202019-1-En.pdf"),
    "out/haiku/pdf__icaro_piuma_spec_imperial.json": ("Icaro Piuma, данные (PDF)", ICARO + "Piuma/Piuma%20Spec%20imperial.pdf"),
    "out/haiku/pdf__icaro_piuma_spec_metric.json": ("Icaro Piuma, данные (PDF)", ICARO + "Piuma/Piuma%20Spec%20metric.pdf"),
}
for _s in ("cross-country", "eagle", "fusion", "spectrum", "super-sport", "talon", "ultra-sport"):
    SOURCES["out/haiku/ww__archive_%s.json" % _s] = ("willswing.com (архив): %s" % _s, W + "/hang-gliders/archive/%s/" % _s)
for _s, _n in (("gecko", "Gecko"), ("litespeed-rx", "Litespeed RX"), ("litesport", "Litesport"), ("malibu2", "Malibu 2")):
    SOURCES["out/haiku/moyes__%s_spec.json" % _s] = ("moyes.com.au: %s" % _n, MOYES + _s + "/specifications")
for _s, _n in (("astir", "Astir"), ("fizz", "Fizz"), ("kite", "Kite")):
    SOURCES["out/haiku/bautek__%s.json" % _s] = ("bautek.com: %s" % _n, "https://www.bautek.com/english/hanggliders/%s/" % _s)
# сайты производителей: цитата о мачте с такого адреса (строка «Конструкция» ТЗ) — паспортные данные
MAKER_HOSTS = ("willswing.com", "moyes.com.au", "moyesusa.com", "aeros.com.ua", "icaro2000.com", "airborne.com.au", "bautek.com")

# --------------------------------------------------------------------------------------------- 9 старых крыльев
# По docs/research/wings_config_sources.md (§1 — изменено по паспорту, §2 — сверено, §3 — без паспорта).
# key — запись wings_merged.json той же модели и размера (паспорт) или аналога; fields — поля, взятые из неё;
# note — откуда остальное (непаспортные источники из конфига; оценка); ref — паспорт близкой модели для сравнения.
OLD = {
    "training": {"key": "Wills Wing|Falcon 4||170", "kind": "паспорт",
                 "fields": ["span_m", "area_m2", "wing_mass_kg", "pilot_mass_min_kg", "pilot_mass_max_kg", "cert"],
                 "note": "не из паспорта: docs/plan/wings_lineup.md",
                 "notes": {"double_surface_pct": "числа в паспорте нет; однообшивочное учебное (docs/plan/wings_lineup.md)"}},
    "sport": {"key": "Moyes|Litespeed RS||4", "kind": "паспорт",
              "fields": ["span_m", "area_m2", "wing_mass_kg", "double_surface_pct", "cert"],
              "note": "не из паспорта: docs/plan/wings_lineup.md",
              "notes": {"pilot_mass_min_kg": "hook-in RS 4 в паспортном наборе нет; у Moyes 74–104 кг по архиву спецификаций (docs/plan/wings_lineup.md §1.4)",
                        "pilot_mass_max_kg": "hook-in RS 4 в паспортном наборе нет; у Moyes 74–104 кг по архиву спецификаций (docs/plan/wings_lineup.md §1.4)"}},
    "combat": {"key": "Aeros|Combat GT||13.2", "kind": "паспорт",
               "fields": ["span_m", "area_m2", "wing_mass_kg", "pilot_mass_min_kg", "pilot_mass_max_kg", "double_surface_pct", "cert"],
               "note": "не из паспорта: руководство Combat, docs/plan/wings_lineup.md §1.4"},
    "laminar": {"key": "Icaro|Easy 2||M", "also": ["Icaro|Orbiter||14"], "kind": "аналог",
                "fields": ["wing_mass_kg", "double_surface_pct", "cert", "dhv"],
                "note": "не паспорт: en.wikipedia Icaro_Laminar, руководство icaro2000.com (прямого паспорта Laminar Easy 14 нет)",
                "ref": "Icaro|Easy 2||M"},
    "target": {"note": "не паспорт: en.wikipedia Aeros_Target, delta-nsk.ucoz.ru (ТТХ), aeros.com.ua",
               "ref": "Aeros|Fox||", "ref_note": "тождество Target 16 = Fox не доказано"},
    "magic": {"note": "не паспорт: thisdayinaviation.com (экземпляр в Смитсоновском музее), topaflyers.com"},
    "atlas": {"note": "не паспорт: статья «Крылья Родины» (Кареткин, Рябцев, Бабкин, ЦК ДОСААФ)"},
    "slavutich_ut": {"note": "не паспорт: delta-nsk.ucoz.ru (ТТХ), ru.wikipedia «Славутич (дельтапланы)»"},
    "apogee": {"note": "со слов пилота и reaa.ru; остальное — по ровесникам (docs/plan/wings_lineup.md §1.2, §3)",
               "notes": {"area_m2": "со слов пилота: копия Airwave Magic 155 — 155 кв. фт = 14,4 м²; единичные экземпляры были 16 м², но это редкость",
                         "span_m": "по ровесникам (docs/plan/wings_lineup.md §3); согласуется с копией Magic 155: при удлинении Magic IV 166 (10,26 м, 15,4 м², λ ≈ 6,8) на 14,4 м² — 9,9 м"}},
}

PASSPORT_FIELDS = ("span_m", "area_m2", "wing_mass_kg", "pilot_mass_min_kg", "pilot_mass_max_kg", "double_surface_pct")
UNITS = {"span_m": "м", "area_m2": "м²", "wing_mass_kg": "кг", "pilot_mass_min_kg": "кг", "pilot_mass_max_kg": "кг",
         "double_surface_pct": "%"}
MARKS = ("паспорт", "аналог", "оценка")


# --------------------------------------------------------------------------------------------- утилиты
def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def fm(x):
    """Число как в конфиге, с запятой: 13.4 → «13,4», 73.0 → «73»."""
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, int):
        return str(x)
    s = repr(float(x))
    if s.endswith(".0"):
        s = s[:-2]
    return s.replace(".", ",")


def fr(x, nd=1):
    """Число паспорта (сырое значение в SI) — округлённое для показа."""
    s = ("%." + str(nd) + "f") % x
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s.replace(".", ",")


def cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def close(a, b, tol=TOL):
    return abs(a - b) <= tol * max(abs(a), abs(b), 1e-9)


def link(label, url):
    return "[%s](%s)" % (cell(label).replace("[", "(").replace("]", ")"), url)


class Errors(list):
    def add(self, msg):
        self.append(msg)


ERR = Errors()


# --------------------------------------------------------------------------------------------- данные
def load_locale():
    out = {}
    with open(os.path.join(ROOT, "locale", "ui.csv"), encoding="utf-8", newline="") as f:
        for row in csv.reader(f):
            if len(row) >= 2:
                out[row[0]] = row[1]
    return out


def load_tz():
    """id → {code, title, heading, cons} по заголовкам «## Раздел E1. <title> (`id`) — …»."""
    out = {}
    cur = None
    with open(TZ, encoding="utf-8") as f:
        for ln in f:
            m = re.match(r"## Раздел ([EN]\d+)\. (.+?) \(`([a-z0-9_]+)`\)", ln)
            if m:
                cur = {"code": m.group(1), "title": m.group(2), "heading": ln[3:].strip(), "cons": ""}
                out[m.group(3)] = cur
                continue
            if ln.startswith("## "):
                cur = None
            elif cur is not None and ln.startswith("- **Конструкция:**"):
                cur["cons"] = ln.strip()
    return out


def hugo_anchor(heading):
    """Якорь заголовка, как его строит Hugo (goldmark, autoHeadingIDType = github)."""
    t = heading.replace("`", "").lower()
    t = "".join(ch for ch in t if ch.isalnum() or ch in " -_")
    return t.replace(" ", "-")


DATA = {}


def data():
    if DATA:
        return DATA
    groups = load(os.path.join(ROOT, "configs", "wing_groups.json"))["groups"]
    cfgs = {}
    for p in sorted(glob.glob(os.path.join(ROOT, "configs", "wings", "*.json"))):
        cfgs[os.path.basename(p)[:-5]] = load(p)
    merged = {r["key"]: r for r in load(os.path.join(PP, "wings_merged.json"))}
    spec = load(os.path.join(PP, "out", "wings3d_spec.json"))
    overrides = {}
    for p in sorted(glob.glob(os.path.join(PP, "wings3d_overrides", "*.json"))):
        overrides[os.path.basename(p)[:-5]] = load(p)
    dhv_files = {}
    for p in sorted(glob.glob(os.path.join(PP, "out", "haiku_dhv", "*.json"))):
        dhv_files["out/haiku_dhv/" + os.path.basename(p)] = load(p).get("wings", [])
    DATA.update(groups=groups, cfgs=cfgs, merged=merged, spec=spec, overrides=overrides, dhv_files=dhv_files,
                loc=load_locale(), tz=load_tz())
    return DATA


def order_in_group(gid):
    """Порядок меню игры (scripts/game/wing_catalog.gd): best_glide, затем wind_max_ms, затем путь."""
    cfgs = data()["cfgs"]
    ids = [w for w, c in cfgs.items() if c.get("group") == gid]
    return sorted(ids, key=lambda w: (float(cfgs[w].get("reference", {}).get("best_glide", 0.0)),
                                      float(cfgs[w].get("wind_max_ms", 0.0)), "wings/" + w))


# --------------------------------------------------------------------------------------------- источники значений
def dhv_cert_of(src, rec):
    """Номер сертификата DHV для источника из карточки DHV: по записи разбора с той же цитатой."""
    certs = [c for c in rec.get("cert_standards", []) if c.startswith("DHV ")]
    if len(certs) == 1:
        return certs[0]
    for w in data()["dhv_files"].get(src["file"], []):
        if w.get("cert_standard") in certs and any(f.get("quote") == src.get("quote") for f in w.get("facts", [])):
            return w["cert_standard"]
    return ", ".join(certs) or "DHV"


def src_link(src, rec):
    """Ссылка на источник одного значения паспорта."""
    f = src["file"]
    if f.startswith("out/haiku_dhv/"):
        return link("карточка %s" % dhv_cert_of(src, rec), DHV_PORTAL)
    if f not in SOURCES:
        ERR.add("нет адреса источника для файла разбора %s (запись «%s») — добавить в SOURCES" % (f, rec["key"]))
        return cell(f)
    label, url = SOURCES[f]
    return link(label, url)


def quote(src):
    q = str(src.get("quote", "")).strip()
    if len(q) > 60:
        q = q[:57].rstrip() + "…"
    return "«%s»" % cell(q) if q else ""


def uniq(xs):
    out = []
    for x in xs:
        if x not in out:
            out.append(x)
    return out


def passport_prov(field, value, recs, kind):
    """(отметка, текст) для значения конфига по записям паспорта; None — не совпало ни с одним источником."""
    unit = UNITS.get(field, "")
    for rec in recs:
        f = rec["fields"].get(field)
        if not f:
            continue
        srcs = [s for s in f["sources"] if isinstance(s.get("value"), (int, float))]
        match = [s for s in srcs if close(float(s["value"]), float(value))]
        if not match:
            continue
        by_link = {}
        for s in match:
            by_link.setdefault(src_link(s, rec), []).append(quote(s))
        txt = "; ".join(("%s %s" % (lk, ", ".join(q for q in uniq(qs) if q))).strip() for lk, qs in by_link.items())
        if kind == "аналог":
            txt = "аналог %s: %s" % (rec_name(rec), txt)
        other = [s for s in srcs if not close(float(s["value"]), float(value), CONFLICT)]
        if other:
            alt = uniq("%s %s %s" % (src_link(s, rec), fr(s["value"]), unit) for s in other)
            txt += "; другой источник: " + ", ".join(alt)
        return kind, txt
    return None


def rec_name(rec):
    return " ".join(x for x in (rec["manufacturer"], rec["family"], rec.get("version") or "", rec.get("size") or "") if x)


def other_value(field, recs):
    """Значение паспорта (выбранное сводом) для сравнения с оценкой конфига: текст или ""."""
    for rec in recs:
        f = rec["fields"].get(field)
        if f and isinstance(f.get("value"), (int, float)):
            srcs = f["sources"]
            return "паспорт %s: %s %s (%s)" % (rec_name(rec), fr(f["value"], 2), UNITS.get(field, ""),
                                               ", ".join(uniq(src_link(s, rec) for s in srcs)))
    return ""


def cert_text(rec):
    """(класс, источник) по записи паспорта."""
    parts = []
    for c in rec.get("cert", []):
        sys_ = c.get("system", "")
        if sys_ == "класс на странице производителя":
            parts.append("класс %s (страница производителя)" % c.get("class"))
        else:
            parts.append("%s %s" % (sys_, c.get("class")))
    parts = uniq(parts)
    certs = [c for c in rec.get("cert_standards", []) if c.startswith("DHV ")]
    links = [link("карточка " + c, DHV_PORTAL) for c in certs]
    hgma = [c for c in rec.get("cert_standards", []) if c.startswith("HGMA")]
    if hgma or not certs:
        site = [s for s in rec.get("sources", []) if not s.startswith("out/haiku_dhv/")]
        for s in site:
            if s in SOURCES:
                links.append(link(*SOURCES[s]))
            else:
                ERR.add("нет адреса источника для файла разбора %s (класс, запись «%s»)" % (s, rec["key"]))
    short = "; ".join(parts)
    full = short + ("" if not certs else " (%s)" % ", ".join(certs))
    return short, full, ", ".join(uniq(links))


def dhv_vals(rec, name):
    """Значение поля только из карточек DHV (как make_3d_tz.dhv_value): медиана."""
    f = rec["fields"].get(name) if rec else None
    if not f:
        return None
    vals = sorted(s["value"] for s in f["sources"] if isinstance(s.get("value"), (int, float))
                  and (s.get("kind") == "dhv" or "DHV" in str(s.get("quote", ""))))
    return vals[len(vals) // 2] if vals else None


# --------------------------------------------------------------------------------------------- строки таблицы
def row(param, value, kind, text):
    if kind not in MARKS and kind != "—":
        ERR.add("неизвестная отметка %r (%s)" % (kind, param))
    mark = "—" if kind == "—" else "**%s**" % kind
    return {"param": param, "value": value, "kind": kind, "src": ("%s: %s" % (mark, text)) if text else mark}


def wing_rows(wid):
    d = data()
    cfg = d["cfgs"][wid]
    spec = d["spec"].get(wid)
    ov = d["overrides"].get(wid, {}).get("config", {})
    tz = d["tz"].get(wid, {})
    rows = []
    base_name = ""
    if spec:
        rec = d["merged"].get(spec["sources"][0])
        if rec is None:
            ERR.add("%s: нет записи паспорта «%s»" % (wid, spec["sources"][0]))
            rec = {"key": spec["sources"][0], "fields": {}, "manufacturer": "", "family": spec["sources"][0]}
        recs, kind, old = [rec], "паспорт", None
        base = spec["base"]
        base_name = d["loc"].get(d["cfgs"][base]["name"], base)
        est_default = "как у базы %s (в паспорте нет)" % base_name
    else:
        old = OLD.get(wid)
        if old is None:
            ERR.add("%s: крыла нет ни в спецификации, ни в таблице OLD генератора" % wid)
            old = {"note": ""}
        recs = [d["merged"][k] for k in ([old["key"]] + old.get("also", [])) if k in d["merged"]] if old.get("key") else []
        if old.get("key") and not recs:
            ERR.add("%s: нет записи паспорта «%s»" % (wid, old["key"]))
        kind = old.get("kind", "оценка")
        est_default = old["note"]
    ref_recs = [d["merged"][old["ref"]]] if old and old.get("ref") in d["merged"] else []

    def num_prov(field):
        v = cfg[field]
        if field in ov or (field + "_doc") in ov:
            return "оценка", "ручная правка (wings3d_overrides/%s.json)" % wid
        if old is not None and field not in old.get("fields", []):
            extra = other_value(field, ref_recs) if ref_recs else ""
            if extra and old.get("ref_note"):
                extra += " — " + old["ref_note"]
            return "оценка", old.get("notes", {}).get(field, est_default) + ("; " + extra if extra else "")
        p = passport_prov(field, v, recs, kind)
        if p:
            return p
        if spec:
            return new_estimate(field, v, cfg, spec, rec, base_name)
        ERR.add("%s.%s = %s: по таблице OLD — из паспорта, но с паспортом не совпадает" % (wid, field, v))
        return "оценка", other_value(field, recs)

    for field, title in (("span_m", "Размах"), ("area_m2", "Площадь"), ("wing_mass_kg", "Масса крыла")):
        k, t = num_prov(field)
        rows.append(row(title, "%s %s" % (fm(cfg[field]), UNITS[field]), k, t))
    k1, t1 = num_prov("pilot_mass_min_kg")
    k2, t2 = num_prov("pilot_mass_max_kg")
    val = "%s–%s кг" % (fm(cfg["pilot_mass_min_kg"]), fm(cfg["pilot_mass_max_kg"]))
    if k1 == k2:
        rows.append(row("Масса пилота с подвеской", val, k1, t1 if t1 == t2 else "мин. — %s; макс. — %s" % (t1, t2)))
    else:
        rows.append(row("Масса пилота с подвеской, мин.", "%s кг" % fm(cfg["pilot_mass_min_kg"]), k1, t1))
        rows.append(row("Масса пилота с подвеской, макс.", "%s кг" % fm(cfg["pilot_mass_max_kg"]), k2, t2))
    ds = cfg["double_surface_pct"]
    k, t = num_prov("double_surface_pct")
    rows.append(row("Двойная обшивка", "нет (однообшивочное)" if not ds else "%s %% размаха" % fm(ds), k, t))
    k, t = kingpost_prov(wid, cfg, tz, ov, spec, recs)
    rows.append(row("Мачта", "есть (мачтовое)" if cfg["kingpost"] else "нет (безмачтовое)", k, t))
    # класс / сертификат
    use_cert = spec is not None or (old and "cert" in old.get("fields", []))
    crec = recs[0] if recs and use_cert else None
    if crec and (crec.get("cert") or crec.get("cert_standards")):
        short, full, lk = cert_text(crec)
        k = kind
        t = ("аналог %s: " % rec_name(crec) if kind == "аналог" else "") + lk
        rows.append(row("Класс / сертификат", full, k, t))
    else:
        rows.append(row("Класс / сертификат", "нет данных", "—", ""))
    # годы
    era = cfg.get("era") or "?"
    if spec:
        et = "выборка страниц производителя / год сертификации (ТЗ, раздел %s)" % tz.get("code", "?")
        if era == "?":
            et = "в паспортах и выборке нет"
    else:
        et = "docs/plan/wings_lineup.md"
    rows.append(row("Годы выпуска", "неизвестно" if era == "?" else era, "оценка", et))
    # DHV Vmin / Vmax
    rows += dhv_rows(spec, recs if (old and "dhv" in old.get("fields", [])) else [], kind)
    # модель игры
    rows += model_rows(wid, cfg, spec, base_name)
    return rows


def new_estimate(field, v, cfg, spec, rec, base_name):
    """Происхождение значения нового крыла, не совпавшего с паспортом (по правилам make_new_wings.py / make_3d_tz.py)."""
    c = spec["config"]
    dhv = c.get("dhv") or {}
    if field == "span_m":
        f = rec["fields"]
        if f.get("aspect_ratio") and f.get("area_m2"):
            return "оценка", "√(удлинение × площадь) по паспорту: удлинение %s, площадь %s м² (ТЗ, раздел %s)" % (
                fr(f["aspect_ratio"]["value"], 2), fr(f["area_m2"]["value"], 2), spec["section"])
        return "оценка", "по удлинению базы %s и паспортной площади (ТЗ, раздел %s)" % (base_name, spec["section"])
    if field in ("pilot_mass_min_kg", "pilot_mass_max_kg"):
        side = "min" if field.endswith("min_kg") else "max"
        tk = dhv.get("takeoff_mass_%s_kg" % side)
        wm = c.get("wing_mass_kg")
        if c.get(field) is None and tk is not None and wm is not None and close(float(round(tk - wm)), float(v), 1e-9):
            return "оценка", "DHV «Startgewicht» %s–%s кг минус масса крыла %s кг (%s; hook-in в паспорте нет)" % (
                fr(dhv["takeoff_mass_min_kg"]), fr(dhv["takeoff_mass_max_kg"]), fr(wm), link("карточка " + (dhv.get("cert") or "DHV"), DHV_PORTAL))
        return "оценка", "как у базы %s (в паспорте нет или источники противоречат)" % base_name
    if c.get(field) is None:
        return "оценка", "как у базы %s (в паспорте нет)" % base_name
    return "оценка", other_value(field, [rec]) or "в паспорте нет"


def kingpost_prov(wid, cfg, tz, ov, spec, recs):
    if "kingpost" in ov or "kingpost_doc" in ov:
        return "оценка", "решение по ТЗ (раздел %s; wings3d_overrides/%s.json)" % (tz.get("code", "?"), wid)
    line = tz.get("cons", "")
    if not line:
        ERR.add("%s: в ТЗ нет строки «Конструкция»" % wid)
        return "оценка", ""
    m = re.search(r"\((https?://[^ )]+)\)\.\s*$", line)
    if "по цитате" in line and m:
        url = m.group(1)
        host = urlparse(url).netloc.lower()
        label = host[4:] if host.startswith("www.") else host
        if any(host == h or host.endswith("." + h) for h in MAKER_HOSTS):
            return "паспорт", "цитата со страницы производителя: %s" % link(label, url)
        return "оценка", "по цитате не с сайта производителя: %s" % link(label, url)
    if "по паспорту" in line and spec and recs:
        rec = recs[0]
        lk = uniq(link(*SOURCES[s]) for s in rec.get("sources", []) if s in SOURCES and not s.startswith("out/haiku_dhv/"))
        return "паспорт", "геометрия паспорта: " + ", ".join(lk)
    if "по году" in line:
        return "оценка", "по году выпуска и классу, подтверждающей цитаты нет (ТЗ, раздел %s)" % tz.get("code", "?")
    return "оценка", "ТЗ, раздел %s" % tz.get("code", "?")


def dhv_rows(spec, recs, kind):
    out = []
    if spec:
        dhv = spec["config"].get("dhv") or {}
        cert = dhv.get("cert")
        vals = {k: dhv.get(k) for k in ("vmin_vg0_kmh", "vmax_vg0_kmh", "takeoff_mass_min_kg", "takeoff_mass_max_kg")}
        prefix = ""
    elif recs:
        rec = next((r for r in recs if dhv_vals(r, "vmin_vg0_kmh") or dhv_vals(r, "vmax_vg0_kmh")), None)
        if rec is None:
            return out
        cert = ", ".join(c for c in rec.get("cert_standards", []) if c.startswith("DHV "))
        vals = {k: dhv_vals(rec, k) for k in ("vmin_vg0_kmh", "vmax_vg0_kmh", "takeoff_mass_min_kg", "takeoff_mass_max_kg")}
        prefix = "аналог %s: " % rec_name(rec) if kind == "аналог" else ""
    else:
        return out
    tm = ""
    if vals["takeoff_mass_min_kg"] and vals["takeoff_mass_max_kg"]:
        tm = " (стартовая масса %s–%s кг)" % (fr(vals["takeoff_mass_min_kg"]), fr(vals["takeoff_mass_max_kg"]))
    src = prefix + link("карточка " + (cert or "DHV"), DHV_PORTAL)
    k = "аналог" if prefix else "паспорт"
    if vals["vmin_vg0_kmh"]:
        out.append(row("DHV Vmin (VG 0)", "%s км/ч%s" % (fr(vals["vmin_vg0_kmh"]), tm), k, src))
    if vals["vmax_vg0_kmh"]:
        out.append(row("DHV Vmax (VG 0)", "%s км/ч" % fr(vals["vmax_vg0_kmh"]), k, src))
    return out


def model_rows(wid, cfg, spec, base_name):
    ref = cfg.get("reference", {})
    if spec:
        m = re.search(r"_база\) = ([\d,]+)", cfg.get("polar", {}).get("_doc", ""))
        how = "модель игры: поляра базы %s подобием по нагрузке на крыло%s" % (base_name, " (f = %s)" % m.group(1) if m else "")
    else:
        how = "модель игры: поляра — оценка по классу и источникам (docs/plan/wings_lineup.md)"
    out = [
        row("Скорость трима", "%s км/ч" % fm(cfg["trim_speed_kmh"]), "оценка", how),
        row("Скорость, трапеция полностью на себя", "%s км/ч" % fm(cfg["full_pull_speed_kmh"]), "оценка", how),
        row("Сваливание (прямой полёт)", "%s км/ч" % fm(ref["stall_speed_kmh"]), "оценка", how),
        row("Минимальное снижение", "%s м/с на %s км/ч" % (fm(ref["min_sink_ms"]), fm(ref["min_sink_speed_kmh"])), "оценка", how),
        row("Качество", "%s на %s км/ч" % (fm(ref["best_glide"]), fm(ref["best_glide_speed_kmh"])), "оценка",
            how + ("; подобие качество не меняет — как у базы" if spec else "")),
        row("Ветер на старте до", "%s м/с" % fm(cfg["wind_max_ms"]), "оценка",
            "подсказка меню игры" + (", как у базы %s" % base_name if spec else " (docs/plan/wings_lineup.md §3)")),
    ]
    out.append(row("Эталонная масса пилота (для поляры)", "%s кг" % fm(cfg["pilot_mass_ref_kg"]), "оценка",
                   "модель игры" + (": то же место в диапазоне, что у базы %s" % base_name if spec else "")))
    return out


# --------------------------------------------------------------------------------------------- страницы
def wing_title(wid):
    d = data()
    name = d["loc"].get(d["cfgs"][wid]["name"])
    if not name:
        ERR.add("%s: нет перевода «%s» в locale/ui.csv" % (wid, d["cfgs"][wid]["name"]))
        name = wid
    return name


def group_title(g):
    return data()["loc"].get(g["name"], g["id"])


def prototype(wid):
    tz = data()["tz"].get(wid)
    if not tz:
        ERR.add("%s: нет раздела в docs/research/glider_3d_tz.md" % wid)
        return wid
    return tz["title"]


def fm_q(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def short_class(wid):
    for r in wing_rows_cache(wid):
        if r["param"] == "Класс / сертификат":
            if r["kind"] == "—":
                return "—"
            parts = []
            for x in r["value"].split(" (DHV")[0].split("; "):
                x = re.sub(r"^HGMA/USHPA (\S+).*", r"HGMA \1", x)
                x = re.sub(r"^класс (\S+) \(страница производителя\)", r"класс \1", x)
                parts.append(x)
            return ", ".join(uniq(parts))
    return "—"


_ROWS = {}


def wing_rows_cache(wid):
    if wid not in _ROWS:
        _ROWS[wid] = wing_rows(wid)
    return _ROWS[wid]


def wing_page(wid, g, weight):
    d = data()
    cfg = d["cfgs"][wid]
    name = wing_title(wid)
    gname = group_title(g)
    kp = "мачтовое" if cfg["kingpost"] else "безмачтовое"
    era = cfg.get("era") or "?"
    era_s = "годы неизвестны" if era == "?" else era
    desc = "%s: %s крыло, прототип — %s (%s). Размах %s м, площадь %s м², масса %s кг; откуда каждое число." % (
        name, kp, prototype(wid), era_s, fm(cfg["span_m"]), fm(cfg["area_m2"]), fm(cfg["wing_mass_kg"]))
    L = ["---", "title: %s" % fm_q(name), "weight: %d" % weight, "description: %s" % fm_q(desc), "---", "", PAGE_NOTE, "",
         "# %s" % name, ""]
    L.append("**Прототип:** %s · **годы:** %s · **группа:** [%s](/wings/%s/) · **%s**" % (
        cell(prototype(wid)), era_s, gname, g["id"], kp))
    L.append("")
    img = RENDER % wid
    if os.path.isfile(os.path.join(ROOT, img)):
        L.append("![Модель %s в игре (рендер Blender)](/%s)" % (cell(name), img))
        L.append("")
    else:
        ERR.add("нет рендера %s (C1)" % img)
    L.append("## Данные")
    L.append("")
    L.append("Числа — как в игре (`configs/wings/%s.json`). Отметки: **паспорт**, **аналог**, **оценка** — "
             "[что значат](/wings/#отметки-происхождения)." % wid)
    L.append("")
    L.append("| Параметр | Значение | Откуда |")
    L.append("|---|---|---|")
    for r in wing_rows_cache(wid):
        L.append("| %s | %s | %s |" % (cell(r["param"]), cell(r["value"]), r["src"]))
    L.append("")
    L.append("## Ссылки")
    L.append("")
    L.append("- Конфиг крыла в игре: [configs/wings/%s.json](/configs/wings/%s.json)" % (wid, wid))
    tz = d["tz"].get(wid)
    if tz:
        L.append("- ТЗ на 3D-модель и сверка с паспортом: [раздел %s](/docs/research/glider_3d_tz.md#%s)" % (tz["code"], hugo_anchor(tz["heading"])))
    if wid in d["spec"]:
        L.append("- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), "
                 "как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)")
    else:
        L.append("- Что в конфиге из паспорта, что оценка, противоречия: [wings_config_sources.md](/docs/research/wings_config_sources.md)")
    L.append("- Данные карточек DHV — спасибо DHV: %s" % thanks("благодарность на главной", 3))
    L.append("")
    return "\n".join(L)


def summary_table(ids, mast_column):
    """Таблица крыльев. mast_column=False (группа): без столбца «Мачта» — тип у исключений из типа группы
    (большинства) приписан к прототипу."""
    d = data()
    kp = [bool(d["cfgs"][w]["kingpost"]) for w in ids]
    major = kp.count(True) >= kp.count(False)
    head = "| Модель | Прототип, годы |%s Площадь, м² | Размах, м | Масса, кг | Пилот, кг | Класс |" % (" Мачта |" if mast_column else "")
    L = [head, "|---" * (8 if mast_column else 7) + "|"]
    for wid in ids:
        c = d["cfgs"][wid]
        g = c["group"]
        era = c.get("era") or "?"
        proto = cell(prototype(wid))
        if not mast_column and bool(c["kingpost"]) != major:
            proto += " (мачтовое)" if c["kingpost"] else " (безмачтовое)"
        mast = (" %s |" % ("есть" if c["kingpost"] else "нет")) if mast_column else ""
        L.append("| %s | %s, %s |%s %s | %s | %s | %s–%s | %s |" % (
            link(wing_title(wid), "/wings/%s/%s/" % (g, wid)), proto, "годы ?" if era == "?" else era,
            mast, fm(c["area_m2"]), fm(c["span_m"]), fm(c["wing_mass_kg"]),
            fm(c["pilot_mass_min_kg"]), fm(c["pilot_mass_max_kg"]), cell(short_class(wid))))
    return L


LEGEND = [
    "## Отметки происхождения",
    "",
    "- **паспорт** — число из паспорта той же модели и размера: страница или PDF производителя, плакат, "
    "карточка DHV (ссылка и цитата — в столбце «Откуда»). Если источники расходятся с игрой больше чем на 3 %, "
    "рядом показано и другое значение.",
    "- **аналог** — из паспорта близкой модели (какой — указано).",
    "- **оценка** — не из паспорта: подобие от базового крыла по нагрузке, «как у базы», решение по ТЗ, "
    "непаспортные источники; сюда же все числа модели игры (трим, сваливание, снижение, качество).",
    "",
    "Числа в таблицах — как в игре (`configs/wings/*.json`). Страницы собирает `tools/site/gen_wings.py` "
    "из конфигов и [паспортного набора](/tools/research/data/wing_passports/README.md); данные карточек DHV — "
    "спасибо DHV (%s)." % thanks("благодарность", 1),
]


def section_block():
    d = data()
    L = []
    for g in d["groups"]:
        ids = order_in_group(g["id"])
        L.append("## [%s](/wings/%s/)" % (group_title(g), g["id"]))
        L.append("")
        L += summary_table(ids, True)
        L.append("")
    L += LEGEND
    return "\n".join(L)


def group_block(g):
    L = summary_table(order_in_group(g["id"]), False)
    L.append("")
    L.append("Порядок — как в меню игры: по качеству, при равенстве — по ветру. Отметки происхождения чисел — "
             "[в разделе](/wings/#отметки-происхождения).")
    return "\n".join(L)


def default_index(title, weight, desc, collapse):
    return "\n".join(["---", "title: %s" % fm_q(title), "weight: %d" % weight,
                      "bookCollapseSection: %s" % ("true" if collapse else "false"), "description: %s" % fm_q(desc), "---", ""])


def with_block(path, block, default_head, default_intro):
    """Текст _index.md: ручная часть сохраняется, блок между маркерами — заменяется."""
    full = GEN_BEGIN + "\n" + block.rstrip("\n") + "\n" + GEN_END
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            old = f.read()
        i, j = old.find(GEN_BEGIN), old.find(GEN_END)
        if i >= 0 and j > i:
            return old[:i] + full + old[j + len(GEN_END):]
        ERR.add("%s: нет маркеров блока — блок добавлен в конец" % os.path.relpath(path, ROOT))
        return old.rstrip("\n") + "\n\n" + full + "\n"
    return default_head + "\n" + default_intro + "\n\n" + full + "\n"


def build():
    """{путь: текст} всех файлов раздела."""
    d = data()
    files = {}
    ids_all = set(d["cfgs"])
    seen = set()
    files[os.path.join(OUT, "_index.md")] = with_block(
        os.path.join(OUT, "_index.md"), section_block(),
        default_index("Модели аппаратов", 15, "Все крылья Deltaplan по группам: прототип, размеры, массы, класс и откуда каждое число — паспорт, аналог или оценка.", False),
        "# Модели аппаратов\n\nКрылья, на которых можно летать в игре, по группам меню. У каждого числа — откуда оно: паспорт, аналог или оценка.")
    for gi, g in enumerate(d["groups"], 1):
        gdir = os.path.join(OUT, g["id"])
        ids = order_in_group(g["id"])
        gname = group_title(g)
        hint = d["loc"].get(g.get("hint", ""), "")
        files[os.path.join(gdir, "_index.md")] = with_block(
            os.path.join(gdir, "_index.md"), group_block(g),
            default_index(gname, gi, "%s: %s. Крылья группы, их прототипы и данные." % (gname, hint.lower() if hint else ""), True),
            "# %s\n\n%s." % (gname, hint) if hint else "# %s" % gname)
        for wi, wid in enumerate(ids, 1):
            files[os.path.join(gdir, wid + ".md")] = wing_page(wid, g, wi)
            seen.add(wid)
    for wid in sorted(ids_all - seen):
        ERR.add("%s: группа «%s» не из configs/wing_groups.json" % (wid, d["cfgs"][wid].get("group")))
    for p, txt in files.items():
        if re.search(r"мам|пап[аы]", txt, re.I):
            ERR.add("%s: в публичном тексте упоминание родителей" % os.path.relpath(p, ROOT))
    return files


def stale_pages(files):
    out = []
    for p in sorted(glob.glob(os.path.join(OUT, "*", "*.md"))):
        if p in files or os.path.basename(p) == "_index.md":
            continue
        with open(p, encoding="utf-8") as f:
            if PAGE_NOTE in f.read():
                out.append(p)
    return out


def count_marks(files):
    n = {k: 0 for k in MARKS}
    for wid in data()["cfgs"]:
        for r in wing_rows_cache(wid):
            if r["kind"] in n:
                n[r["kind"]] += 1
    return n


def main(argv):
    check = "--check" in argv
    files = build()
    stale = stale_pages(files)
    diff = []
    for p in sorted(files):
        cur = None
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                cur = f.read()
        if cur != files[p]:
            diff.append(p)
            if not check:
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "w", encoding="utf-8") as f:
                    f.write(files[p])
    for p in stale:
        if not check:
            os.remove(p)
    n = count_marks(files)
    rel = lambda p: os.path.relpath(p, ROOT)
    print("крыльев: %d, файлов: %d; отметки: паспорт %d, аналог %d, оценка %d" % (
        len(data()["cfgs"]), len(files), n["паспорт"], n["аналог"], n["оценка"]))
    if check:
        for p in diff:
            ERR.add("расходится с данными (запустить tools/site/gen_wings.py): %s" % rel(p))
        for p in stale:
            ERR.add("лишняя сгенерированная страница: %s" % rel(p))
    else:
        for p in diff:
            print("записан", rel(p))
        for p in stale:
            print("удалён", rel(p))
    for e in ERR:
        print(" -", e)
    return 1 if (check and ERR) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
