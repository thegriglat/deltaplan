"""Сведение разобранных паспортов дельтапланов в единый набор данных.
Вход:  out/haiku/*.json, out/haiku_dhv/*.json (+ out/text/dhv__* для признака «Wölbklappe» у DHV).
Выход: wings_merged.json / .csv, wings_geometry.json, polars_points.json, docs/research/glider_models.md.
Запуск: python3 consolidate.py   (без аргументов, только стандартная библиотека).
Правила — в README.md этого каталога."""
import json, glob, re, csv, statistics, collections, pathlib, datetime

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"
REPO = HERE.parents[3]
TOL = 0.03          # расхождение значений из разных источников > 3 % -> conflict

# ---------------------------------------------------------------- вспомогательное
def fixmoji(s):
    if not isinstance(s, str): return s
    try: return s.encode("latin1").decode("utf8")
    except Exception: return s

def num_label(x):
    """'12,7' -> '12.7', '154' -> '154'."""
    x = x.replace(",", ".")
    f = float(x)
    return str(int(f)) if f == int(f) else ("%g" % f)

# ---------------------------------------------------------------- производители
def norm_mfr(m, src=""):
    t = fixmoji(m or "").lower()
    if not t:  # пусто: по имени файла источника
        for k, v in (("icaro", "Icaro"), ("moyes", "Moyes"), ("aeros", "Aeros"), ("airborne", "Airborne"),
                     ("bautek", "Bautek"), ("ww_", "Wills Wing")):
            if k in src.lower(): return v
        return ""
    for k, v in (("wills", "Wills Wing"), ("moyes", "Moyes"), ("aeros", "Aeros"), ("icaro", "Icaro"),
                 ("laminar", "Icaro"), ("airborne", "Airborne"), ("bautek", "Bautek"),
                 ("rühle", "A.I.R."), ("a.i.r", "A.I.R."), ("seedwings", "Seedwings"), ("ellipse", "Ellipse"),
                 ("flugsport", "Flugsport Skypoint"), ("delta flugschule", "Delta Flugschule Condor"),
                 ("designproducts", "DesignProducts")):
        if k in t: return v
    return fixmoji(m)

# ---------------------------------------------------------------- модели -> (семейство, версия, размер, год модели)
SIZE_LET = re.compile(r"(?<![A-Za-z])(XL|S|M|L)(?![A-Za-z0-9])")
NUM = re.compile(r"\d+(?:[.,]\d+)?")

def first_num(s):
    m = NUM.search(s or ""); return num_label(m.group()) if m else ""

def norm_model(mfr, model, size):
    """возвращает (family, version, size, model_year, variant)"""
    model = fixmoji(model or "").strip(); size = fixmoji(size or "").strip()
    if re.fullmatch(r"0\d", size): size = ""   # '07' в поле размера - год модели (Combat-L 12 07)
    low = model.lower(); version = variant = ""; year = ""
    def sz(rest):
        s = first_num(size.replace("RX", "").replace("L1", "1", 0)) if re.search(r"\d", size) else ""
        if re.match(r"^[Ll]\d", size): s = first_num(size)
        if s: return s
        r = first_num(rest)
        if r: return r
        if size.upper() in ("S", "M", "L", "XL"): return size.upper()
        m = SIZE_LET.search(rest); return m.group(1) if m else ""
    if mfr == "Wills Wing":
        rules = [("attack duck", "Attack Duck"), (r"duck", "Duck"), (r"falcon \(original\)", "Falcon"),
                 (r"falcon 2", "Falcon 2"), (r"falcon 3", "Falcon 3"), (r"falcon 4", "Falcon 4"), (r"falcon", "Falcon"),
                 (r"fusion", "Fusion"), (r"hp at", "HP AT"), (r"hp ii", "HP II"), (r"^hp", "HP"),
                 (r"harrier ii", "Harrier II"), (r"harrier", "Harrier"), (r"sport 3", "Sport 3"), (r"sport 2", "Sport 2"),
                 (r"sport at", "Sport AT"), (r"sportster", "Sportster"), (r"super sport", "Super Sport"),
                 (r"^super$", "Super Sport"), (r"ultra sport", "Ultra Sport"), (r"^ultra$", "Ultra Sport"),
                 (r"^sport$", "Sport"), (r"cross country", "Cross Country"), (r"^xc$", "Cross Country"),
                 (r"t2/t2c", "T2/T2C"), (r"t2c", "T2C"), (r"^t2", "T2"), (r"^t3", "T3"), (r"^u2", "U2"),
                 (r"talon", "Talon"), (r"spectrum", "Spectrum"), (r"skyhawk", "Skyhawk"), (r"raven", "Raven"),
                 (r"ramair", "RamAir"), (r"eagle", "Eagle"), (r"condor", "Condor")]
        fam = next((f for p, f in rules if re.search(p, low)), model)
        if "original" in low: variant = "Original"
        if "fusion sp" in low: variant = "SP"
        if re.search(r"fusion.*\bR\b", model): variant = "R"
        if "race" in low: variant = "Race"
        m = re.findall(r"\b\d{3}\b", model)
        s = num_label(size) if re.fullmatch(r"\d{3}", size) else (m[-1] if m else "")
        return fam, version, s, year, variant
    if mfr == "Moyes":
        if "litespeed rx" in low or "technora" in low: fam = "Litespeed RX"
        elif "litespeed rs" in low: fam = "Litespeed RS"
        elif "litespeed s" in low: fam = "Litespeed S"
        elif "litesport" in low: fam = "Litesport"
        elif "gecko" in low: fam = "Gecko"
        elif "malibu" in low: fam, version = "Malibu", ("2" if "malibu 2" in low else "")
        else: fam = model
        rest = re.sub(r"(?i)moyes|litespeed rx|litespeed rs|litespeed s|technora-?|litesport|gecko|malibu 2|malibu|rx", "", model)
        sz_ = first_num(size) or first_num(rest)
        return fam, version, sz_, year, variant
    if mfr == "Aeros":
        ym = re.search(r"\b(0[5-9]|1\d)\b", model)
        if re.search(r"combat[- ]?l\b|combat[- ]?l\d", low): fam = "Combat L"
        elif "gt" in low: fam = "Combat GT"
        elif re.match(r"combat", low) and re.search(r"\bc\b|\d\s*c\b", low): fam = "Combat C"
        elif "combat" in low: fam = "Combat"
        elif "discus" in low: fam = "Discus"
        elif "target" in low: fam = "Target"
        elif "fox" in low: fam = "Fox"
        elif "phantom" in low: fam = "Phantom"
        else: fam = model
        if ym and fam.startswith("Combat"): year = "20" + ym.group(1)
        if "lw" in low.split(): variant = "LW"
        if "discus" in low and re.search(r"\bc\b", low): variant = "C"
        rest = re.sub(r"(?i)combat[- ]?l?|discus|target|fox|phantom|\b0\d\b|gt|lw", " ", model)
        s = first_num(size) or first_num(rest)
        return fam, version, s, year, variant
    if mfr == "Icaro":
        if "laminar" in low or re.match(r"l\d", low):
            fam = "Laminar"
            if "zero 9" in low: version = "Zero 9"
            elif "z8" in low: version = "Z8"
            elif "zero 7" in low: version = "Zero 7"
            s = first_num(re.sub(r"(?i)zero \d|z8|laminar|^l(?=\d)", "", model)) or first_num(size.replace("L", "", 1) if size.startswith("L") else size)
            if not s and size[:1] == "L" and re.search(r"\d", size): s = first_num(size)
            return fam, version, s, year, variant
        for k, f in (("alto", "Alto"), ("piuma", "Piuma"), ("mastr", "MastR"), ("orbiter", "Orbiter"),
                     ("pibi", "PiBi"), ("biplace", "Biplace"), ("rx 2 bip", "RX 2 BIP"), ("easy 2", "Easy 2")):
            if k in low:
                fam = f
                if "trike" in low or "trike" in size.lower(): version = "Trike"
                rest = re.sub(r"(?i)" + k + r"|trike|-", "", model)
                s = first_num(rest) if fam == "Orbiter" else ""
                if not s:
                    m = SIZE_LET.search(rest) or SIZE_LET.search(size)
                    s = m.group(1) if m else ""
                if fam == "Orbiter" and not s: s = first_num(size)
                return fam, version, s, year, variant
        return model, version, first_num(size), year, variant
    if mfr == "Airborne":
        if "sting 3" in low:
            fam = "Sting 3"; variant = "XC" if "xc" in low else ("Race" if "race" in low else "")
        elif low.startswith("c4"): fam = "C4"
        elif low.startswith("rev"): fam = "REV"
        elif low.startswith("f2"): fam = "F2"
        elif low.startswith("xt"): fam = "XT"
        else: fam = model
        rest = re.sub(r"(?i)sting 3|xc|race|c4|rev|f2|xt series", "", model)
        s = first_num(size) if size and re.search(r"\d{2,}", size) else first_num(rest)
        if fam in ("REV",) and not s: s = first_num(rest)
        if fam == "REV" and size == "5": s = first_num(rest)
        return fam, version, s, year, variant
    if mfr == "A.I.R.":
        for k, f in (("vrq", "Atos VRQ"), ("vrs", "Atos VRS"), ("vr", "Atos VR"), ("vq", "Atos VQ")):
            if re.search(r"atos[- ]" + k, low):
                fam = f; break
        else: fam = model
        if "plus" in low: variant = "Plus"
        if "light" in low: variant = "Light"
        if "race" in low: variant = "Race"
        m = re.findall(r"\d{3}", model)
        return fam, version, m[-1] if m else "", year, variant
    if mfr == "Flugsport Skypoint":
        for k in ("Crossover", "Funky", "Space"):
            if k.lower() in low: return k, version, first_num(model) or first_num(size), year, variant
    if mfr == "Delta Flugschule Condor":
        if "crex" in low:
            return "Crex", ("3" if re.match(r"crex 3$", low) else ""), ("" if re.match(r"crex 3$", low) else first_num(model) or first_num(size)), year, variant
        return model.title() if model.isupper() and len(model) > 4 else model, version, first_num(size), year, variant
    if mfr == "DesignProducts":
        if "she 1" in low: return "SHE 1", version, first_num(size) or first_num(model.replace("SHE 1", "")), year, variant
        return "Combat C AC", version, first_num(size) or first_num(model.replace("Combat C AC", "")), year, variant
    if mfr == "Seedwings":
        if "spyder" in low: return "Spyder", version, first_num(model) or first_num(size), year, variant
        return "Skyrunner XR", version, first_num(size), year, variant
    if mfr == "Bautek":
        fam = {"astir": "Astir", "bico": "BiCo", "fizz": "Fizz", "kite": "Kite"}.get(low.strip(), model)
        return fam, version, first_num(size), year, variant
    if mfr == "Ellipse": return "Sol'R", version, first_num(size), year, variant
    return model, version, first_num(size), year, variant

# ---------------------------------------------------------------- единицы
def U(u): return re.sub(r"[\s.^]", "", (u or "").lower().replace("²", "2"))
AREA = {"m2": 1, "sqm": 1, "m": 1, "sqmeter": 1, "sqft": 0.09290304, "sqf": 0.09290304, "sft": 0.09290304, "ft2": 0.09290304}
LEN = {"m": 1, "ml": 1, "ft": 0.3048, "in": 0.0254, "inches": 0.0254, "mm": 0.001, "cm": 0.01}
MASS = {"kg": 1, "kgs": 1, "lb": 0.45359237, "lbs": 0.45359237}
SPEED = {"mph": 1.609344, "kph": 1, "kmh": 1, "km/h": 1, "kt": 1.852, "m/s": 3.6, "ft/min": 0.3048 / 60 * 3.6}
# поле -> (имя в выходе, тип единиц, допустимый диапазон (lo, hi))
FIELDS = {
    "area": ("area_m2", AREA, (8, 22)), "span": ("span_m", LEN, (8, 12.5)),
    "aspect_ratio": ("aspect_ratio", None, (3.5, 9.5)), "double_surface_pct": ("double_surface_pct", None, (0, 100)),
    "wing_mass": ("wing_mass_kg", MASS, (18, 45)),
    "pilot_mass_min": ("pilot_mass_min_kg", MASS, (30, 250)), "pilot_mass_max": ("pilot_mass_max_kg", MASS, (30, 250)),
    "takeoff_mass_min": ("takeoff_mass_min_kg", MASS, (40, 250)), "takeoff_mass_max": ("takeoff_mass_max_kg", MASS, (40, 250)),
    "vne": ("vne_kmh", SPEED, (50, 120)), "va": ("va_kmh", SPEED, (40, 110)),
    "stall_speed": ("stall_speed_kmh", SPEED, (20, 50)), "trim_speed": ("trim_speed_kmh", SPEED, (30, 70)),
    "vms": ("vms_kmh", SPEED, (25, 50)), "vd": ("vd_kmh", SPEED, (40, 130)),
    "vmin_vg0": ("vmin_vg0_kmh", SPEED, (20, 55)), "vmin_vg100": ("vmin_vg100_kmh", SPEED, (20, 55)),
    "vmax_vg0": ("vmax_vg0_kmh", SPEED, (50, 130)), "vmax_vg100": ("vmax_vg100_kmh", SPEED, (50, 130)),
    "best_glide": ("best_glide", None, (6, 20)), "best_glide_speed": ("best_glide_speed_kmh", SPEED, (30, 80)),
    "min_sink": ("min_sink_ms", None, (0.4, 1.6)),
    "nose_angle": ("nose_angle_deg", None, (100, 140)), "battens": ("battens", None, (8, 40)),
    "year": ("year", None, (1975, 2027)),
}
OUT_NAMES = [v[0] for v in FIELDS.values()]

def name_of(field): return FIELDS[field][0]

def convert(field, value, unit, flags_out):
    """-> (имя_выхода, значение SI, заметка|None). Перекласс. неверных единиц — с заметкой, не молча."""
    note = None; u = U(unit)
    if field == "vms" and u in ("ft/min", "m/s"):   # Vms в ft/min — на деле скорость снижения
        field = "min_sink"; note = "vms задан в единицах скорости снижения -> min_sink"
        v = value * (0.3048 / 60 if u == "ft/min" else 1); return FIELDS[field][0], v, note
    if field == "best_glide":
        if u in SPEED and value > 25:
            field = "best_glide_speed"; note = "best_glide с единицей скорости и значением > 25 -> best_glide_speed"
        elif u in ("mph", "kph", "kmh"): note = "единица скорости у безразмерного качества, значение принято как отношение"; return "best_glide", value, note
        else: return "best_glide", value, None
    if field == "double_surface_pct" and value <= 1:
        return name_of(field), value * 100, "доля двойной поверхности задана дробью (<=1), умножено на 100"
    if field == "battens" and u == "mm": return "battens", None, "единица мм у числа латов: значение отброшено"
    name, tab, _ = FIELDS[field]
    if tab is None: return name, value, None
    if u == "" and tab is SPEED: return name, None, "нет единицы скорости"
    if u == "kmh": u = "kmh"
    f = tab.get(u) if u in tab else tab.get(unit.lower().strip())
    if f is None: return name, None, f"неизвестная единица {unit!r}"
    if field == "area" and u == "m" and unit.strip() == "m": note = "единица «m» у площади принята как м²"
    return name, value * f, note

# ---------------------------------------------------------------- загрузка
def src_kind(path):
    n = pathlib.Path(path).name
    if "haiku_dhv" in str(path): return "dhv"
    if n.startswith("ww__archive_"): return "archive"
    if n == "ww__placard.json": return "placard"
    if n == "ww__polar_data.json": return "polar"
    if n.startswith("pdf__"):
        return "pdf"
    return "site"
OLD_PDF = ("pdf__aeros_discus", "pdf__airborne_sting3", "pdf__icaro_laminar.json", "pdf__moyes_litespeed_s", "pdf__ww_t2")

def load_all():
    recs = []
    for f in sorted(glob.glob(str(OUT / "haiku/*.json")) + glob.glob(str(OUT / "haiku_dhv/*.json"))):
        d = json.load(open(f))
        rel = str(pathlib.Path(f).relative_to(HERE))
        for w in d.get("wings") or []:
            w = dict(w); w["_file"] = rel; w["_src"] = w.get("src") or d.get("src") or (d.get("src_files") or [""])[0]
            recs.append(w)
    return recs

# ---------------------------------------------------------------- Wölbklappe/VG в DHV
def dhv_flap():
    res = {}
    for f in glob.glob(str(OUT / "text/dhv__*")):
        t = open(f, errors="ignore").read()
        m = re.search(r"idtype_(\d+)|fieldvalue_(\d+)", f); i = m.group(1) or m.group(2)
        hit = re.search(r"[^.\n]{0,100}W(?:ö|Ã¶)lbklappe[^.\n]{0,100}", t)
        if hit and i not in res: res[i] = hit.group(0).strip()
    return res

def dhv_id(srcname):
    m = re.search(r"idtype_(\d+)", srcname or ""); return m.group(1) if m else None

def clean_cert(kind, cls, std):
    """(система, класс) из сырых cert_class/cert_standard. Мусор (даты, номера) отбрасывается; пусто - если класса нет."""
    t = (cls or "").strip()
    m = re.search(r"(Novice|Intermediate|Advanced)", t, re.I)
    if m and kind != "dhv" and "DHV" not in t.upper().replace("HGMA/DHV", ""):
        lvl = {"novice": "II Novice", "intermediate": "III Intermediate", "advanced": "IV Advanced"}[m.group(1).lower()]
        return "HGMA/USHPA", lvl
    m = re.search(r"(?<![\d/])([123](?:\s*-\s*[123])?)\s*(E)?\b", re.sub(r"\d+/\d+/\d+|\d\d/\d+/\d+", "", t))
    if m:
        val = m.group(1).replace(" ", "") + ("E" if m.group(2) else "")
        if kind == "dhv" or "DHV" in t.upper(): return "DHV", val
        if re.fullmatch(r"(class\s*)?[123]( ?-[123])?( ?E)?", t, re.I) or "class" in t.lower():
            return "класс на странице производителя", val
    return "", ""

# ---------------------------------------------------------------- геометрия
GEO_ALIAS = [
    (r"^(wing_?)?span.*(tips|wingtips)$", "wingspan_with_tips"), (r"^(wing_?)?span(_tip_to_tip|_extreme)?$", "wingspan"),
    (r"nose.?angle", "nose_angle"), (r"short.?pack", "packed_length_short"), (r"pack(ed)?.?length|breakdown", "packed_length"),
    (r"wing.?tube|front.?leading.?edge.?dia|nose_od|nose_diameter", "leading_edge_dia_front"),
    (r"crossbar.*(dia|od)|crossbar_largest|crossbar_max|leading_edge_crossbar_od", "crossbar_dia"),
    (r"keel.*(dia|od)", "keel_dia"), (r"cg|centre.?of.?gravity|cog", "cg_front_of_keel"),
]
def geo_canon(name):
    n = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    for p, c in GEO_ALIAS:
        if re.search(p, n):
            suffix = "_with_tips" if "with_tips" in n or "with_wingtips" in n else ""
            return c + suffix if c in ("packed_length",) and suffix else c
    return n
LENGTH_U = {"mm": 1.0, "cm": 10.0, "m": 1000.0, "ft": 304.8, "in": 25.4, "inches": 25.4}

def geo_entry(g):
    name, v, u, q = g.get("name", ""), g.get("value"), (g.get("unit") or "").strip(), g.get("quote", "")
    e = {"name": geo_canon(name), "name_source": name, "raw_value": v, "raw_unit": u, "quote": q}
    ul = u.lower()
    if isinstance(v, (int, float)) and ul.split(" ")[0] in LENGTH_U and "ths" not in ul:
        e["value_mm"] = round(v * LENGTH_U[ul.split(" ")[0]], 2)
    elif isinstance(v, (int, float)) and "64ths" in ul: e["value_mm"] = round(v / 64 * 25.4, 2)
    elif isinstance(v, (int, float)) and "32nds" in ul: e["value_mm"] = round(v / 32 * 25.4, 2)
    elif isinstance(v, (int, float)) and ul in ("deg", "degrees"): e["value_deg"] = v
    elif isinstance(v, (int, float)) and ul == "%": e["value_pct"] = v
    elif isinstance(v, (int, float)) and ul == "g": e["value_g"] = v
    elif isinstance(v, (int, float)): e["value"] = v
    else: e["text"] = v
    return e

# ---------------------------------------------------------------- основной проход
def main():
    recs = load_all(); flap = dhv_flap()
    wings = {}; geo = {}; unparsed = []; polar_pts = []; placard = []
    for w in recs:
        mfr = norm_mfr(w.get("manufacturer"), w["_file"] + w["_src"])
        fam, ver, size, myear, variant = norm_model(mfr, w.get("model"), w.get("size"))
        kind = src_kind(w["_file"])
        if any(o in w["_file"] for o in OLD_PDF): kind_old = True
        else: kind_old = False
        key = "|".join([mfr, fam, ver, size])
        R = wings.setdefault(key, {"key": key, "manufacturer": mfr, "family": fam, "version": ver, "size": size or None,
            "model_names": set(), "variants": set(), "model_years": set(), "cert": [], "fields": collections.defaultdict(list),
            "sources": set(), "kinds": set(), "flags": [], "features": {}})
        R["model_names"].add(fixmoji(w.get("model") or ""));
        if variant: R["variants"].add(variant)
        if myear: R["model_years"].add(myear)
        R["sources"].add(w["_file"]); R["kinds"].add("oldpdf" if kind_old else kind)
        if w.get("cert_class") or w.get("cert_standard"):
            system, cc = clean_cert(kind, w.get("cert_class") or "", w.get("cert_standard") or "")
            if cc:
                R["cert"].append({"system": system, "class": cc, "standard": w.get("cert_standard") or "",
                                  "file": w["_file"], "class_raw": w.get("cert_class") or ""})
        i = dhv_id(w["_src"])
        if kind == "dhv" and i in flap:
            R["features"]["vg_camber_flap_dhv"] = {"quote": fixmoji(flap[i]), "dhv_id": i, "note": "в тексте DHV-отчёта упомянута Wölbklappe (VG/закрылок-«профиль»): у крыла есть управляемая кривизна"}
        metric_placard = False
        if "placard" in w["_file"]:   # на странице плакатов часть записей метрическая, но разобрана с единицами mph/lb
            fx = {x["field"]: x["value"] for x in w.get("facts") or []}
            metric_placard = fx.get("vne", 0) > 65 or fx.get("va", 0) > 60   # 65 mph = 105 км/ч - невозможно для Vne этих крыльев
        w = dict(w)
        w["facts"] = [dict(x, unit=("km/h" if U(x.get("unit")) == "mph" else "kg" if U(x.get("unit")) in ("lb", "lbs") else x.get("unit")),
                           _reint="единица в разборе «%s», значения метрические (Vne/Va слишком велики для mph) - переинтерпретировано как км/ч, кг" % x.get("unit"))
                      if metric_placard else x for x in w.get("facts") or []]
        for x in w.get("facts") or []:
            f = x["field"]
            if f not in FIELDS and f != "best_glide_speed":
                R["flags"].append({"field": f, "kind": "unknown_field", "detail": x}); continue
            name, v, note = convert(f, x["value"], x.get("unit", ""), None)
            ent = {"file": w["_file"], "quote": x.get("quote", ""), "raw_value": x["value"], "raw_unit": x.get("unit", ""),
                   "value": v, "kind": "oldpdf" if kind_old else kind}
            if x.get("_reint"): ent["note"] = x["_reint"]
            elif note: ent["note"] = note
            R["fields"][name].append(ent)
            if v is not None and f != "year" and kind != "dhv" and False: pass
        for g in w.get("geometry") or []:
            G = geo.setdefault(key, {"key": key, "manufacturer": mfr, "family": fam, "version": ver, "size": size or None, "items": []})
            e = geo_entry(g); e["file"] = w["_file"]; G["items"].append(e)
        # nose_angle и числа латов — и в геометрию
        for x in w.get("facts") or []:
            if x["field"] in ("nose_angle", "battens"):
                G = geo.setdefault(key, {"key": key, "manufacturer": mfr, "family": fam, "version": ver, "size": size or None, "items": []})
                e = geo_entry({"name": x["field"], "value": x["value"], "unit": x.get("unit", ""), "quote": x.get("quote", "")})
                if x["field"] == "battens": e["value"] = x["value"]; e.pop("value_mm", None); e.pop("text", None)
                e["file"] = w["_file"]; G["items"].append(e)
        for p in w.get("polar") or []:
            sp = p["speed"] * SPEED.get(U(p.get("unit_speed", "")), 1)
            sk = p["sink"] * (0.3048 / 60 if U(p.get("unit_sink", "")) == "fpm" else 1)
            polar_pts.append({"key": key, "manufacturer": mfr, "family": fam, "size": size or None, "kind": "polar_point",
                              "speed_kmh": round(sp, 2), "sink_ms": round(sk, 3), "raw_speed": p["speed"], "raw_unit_speed": p.get("unit_speed"),
                              "raw_sink": p["sink"], "raw_unit_sink": p.get("unit_sink"), "quote": p.get("quote", ""), "file": w["_file"]})
        if "placard" in w["_file"]:
            pl = {"key": key, "manufacturer": mfr, "family": fam, "size": size or None, "kind": "placard", "file": w["_file"],
                  "cert_class": w.get("cert_class"), "cert_standard": w.get("cert_standard")}
            for x in w["facts"]:
                nm, v, _ = convert(x["field"], x["value"], x.get("unit", ""), None)
                pl[nm] = None if v is None else round(v, 2); pl["raw_" + x["field"]] = f'{x["value"]} {x.get("unit","")}'
            placard.append(pl)
    # --- сводка полей
    PRIO = {"dhv": 1, "pdf": 2, "oldpdf": 2, "site": 3, "placard": 3, "polar": 4, "archive": 4}
    n_conf = n_flag = 0
    out = []; byfield_cov = collections.Counter()
    rng_by_name = {v[0]: v[2] for v in FIELDS.values()}
    for key, R in sorted(wings.items()):
        fields = {}
        for name, ents in R["fields"].items():
            # дубликаты (тот же файл, то же значение) сворачиваем
            seen = set(); uniq = []
            for e in ents:
                k = (e["file"], e["raw_value"], e["raw_unit"], e["quote"])
                if k in seen: continue
                seen.add(k); uniq.append(e)
            for e in uniq:
                if e.get("note") and e["value"] is None or (e.get("note", "").startswith("неизвестная") or e.get("note", "").startswith("нет единицы")):
                    R["flags"].append({"field": name, "kind": "unit_problem", "detail": e["note"], "file": e["file"], "quote": e["quote"]})
            rng_ = rng_by_name.get(name)
            for e in uniq:
                if e["value"] is None or not rng_: continue
                if not (rng_[0] <= e["value"] <= rng_[1]):
                    e["out_of_range"] = True
                    fl = {"field": name, "kind": "out_of_range", "range": list(rng_), "value_si": round(e["value"], 3), "file": e["file"], "quote": e["quote"]}
                    if U(e["raw_unit"]) in ("mph", "lb", "lbs", "ft", "ft2", "sqft", "sft", "sqf", "fpm", "ft/min") and rng_[0] <= e["raw_value"] <= rng_[1]:
                        fl["hint"] = "сырое число попадает в диапазон как метрическое: единица в источнике, вероятно, указана неверно (не исправлено)"
                    R["flags"].append(fl)
            vals = [e for e in uniq if e["value"] is not None]
            if not vals: fields[name] = {"value": None, "sources": uniq}; continue
            good = [e for e in vals if not e.get("out_of_range")]
            use = good or vals
            best = min(PRIO[e["kind"]] for e in use)
            chosen = statistics.median([e["value"] for e in use if PRIO[e["kind"]] == best])
            lo, hi = min(e["value"] for e in use), max(e["value"] for e in use)
            conflict = name not in ("year",) and lo > 0 and (hi - lo) / lo > TOL
            ent = {"value": round(chosen, 4), "conflict": bool(conflict), "sources": uniq}
            if not good: ent["value_out_of_range"] = True
            if conflict: ent["range"] = [round(lo, 4), round(hi, 4)]; n_conf += 1
            for e in uniq:
                if e.get("note", "").startswith("единица в разборе"):
                    R["flags"].append({"field": "placard", "kind": "placard_metric_reinterpreted", "detail": e["note"], "file": e["file"]})
                elif e.get("note") and e["value"] is not None: R["flags"].append({"field": name, "kind": "reclassified_or_suspect_unit", "detail": e["note"], "file": e["file"], "quote": e["quote"]})
            fields[name] = ent
        # парность min/max
        for a, b in (("pilot_mass_min_kg", "pilot_mass_max_kg"), ("takeoff_mass_min_kg", "takeoff_mass_max_kg")):
            if fields.get(a, {}).get("value") and fields.get(b, {}).get("value") and fields[a]["value"] > fields[b]["value"]:
                R["flags"].append({"field": a, "kind": "min_gt_max"})
        vv = {n: fields.get(n, {}).get("value") for n in ("vms_kmh", "vd_kmh", "va_kmh", "vne_kmh")}
        if vv["vd_kmh"] and vv["vne_kmh"] and vv["vd_kmh"] < vv["vne_kmh"] * 0.97:
            R["flags"].append({"field": "vd_kmh", "kind": "vd_below_vne", "detail": f"Vd={vv['vd_kmh']:.0f} < Vne={vv['vne_kmh']:.0f} км/ч: по смыслу «скорость пикирования» это невозможно, вероятно Vd в источнике — другая скорость"})
        # согласованность площадь/размах/удлинение
        A = fields.get("area_m2", {}).get("value"); S = fields.get("span_m", {}).get("value"); AR = fields.get("aspect_ratio", {}).get("value")
        if A and S and AR and abs(S * S / A - AR) / AR > 0.05:
            R["flags"].append({"field": "aspect_ratio", "kind": "ar_inconsistent", "detail": f"span^2/area={S*S/A:.2f}, заявлено {AR}"})
        # сертификация
        cert_years = sorted({int(e["value"]) for e in R["fields"].get("year", []) if e["value"] and e["kind"] == "dhv"})
        classes = collections.OrderedDict()
        for c in R["cert"]:
            k = (c["system"], c["class"]); classes.setdefault(k, c)
        modern = bool(cert_years and max(cert_years) >= 2015) or bool(R["kinds"] & {"site", "pdf"})
        rec = {"key": key, "manufacturer": R["manufacturer"], "family": R["family"], "version": R["version"] or None, "size": R["size"],
               "model_names": sorted(R["model_names"]), "variants": sorted(R["variants"]), "model_years": sorted(R["model_years"]),
               "cert": [{"system": s, "class": c} for (s, c) in classes], "cert_standards": sorted({c["standard"] for c in R["cert"] if c["standard"]}),
               "cert_years": cert_years, "status": "current" if modern else "historical",
               "source_kinds": sorted(R["kinds"]), "features": R["features"], "fields": fields,
               "flags": [json.loads(x) for x in sorted({json.dumps(f, sort_keys=True, ensure_ascii=False) for f in R["flags"]})],
               "sources": sorted(R["sources"])}
        n_flag += len(rec["flags"])
        for name, ent in fields.items():
            if ent.get("value") is not None: byfield_cov[name] += 1
        out.append(rec)
    # --- запись
    def dump(name, obj): (HERE / name).write_text(json.dumps(obj, ensure_ascii=False, indent=1) + "\n")
    dump("wings_merged.json", out)
    geo_out = []
    for key, G in sorted(geo.items()):
        seen = set(); items = []
        for e in G["items"]:
            k = (e["name"], e.get("value_mm"), e.get("value_deg"), e.get("value"), e.get("text"), e.get("value_g"), e.get("value_pct"), e["file"])
            if k in seen: continue
            seen.add(k); items.append(e)
        G["items"] = items; geo_out.append(G)
    dump("wings_geometry.json", geo_out)
    dump("polars_points.json", {"polar_points": polar_pts, "placard": placard,
         "_doc": "polar_points: точки поляры Wills Wing (страница polar_data), скорость км/ч, снижение м/с; placard: Vms/Vd/Va/Vne (км/ч) и диапазон стартовой массы (кг) по плакатам. Vms - скорость минимального снижения, Vd - скорость пикирования (в тексте плаката)."})
    cols = ["manufacturer", "family", "version", "size", "status", "cert", "cert_years", "area_m2", "span_m", "aspect_ratio", "double_surface_pct", "wing_mass_kg",
            "pilot_mass_min_kg", "pilot_mass_max_kg", "takeoff_mass_min_kg", "takeoff_mass_max_kg", "vne_kmh", "va_kmh", "vms_kmh", "vd_kmh",
            "stall_speed_kmh", "trim_speed_kmh", "vmin_vg0_kmh", "vmax_vg0_kmh", "vmin_vg100_kmh", "vmax_vg100_kmh", "best_glide", "min_sink_ms",
            "nose_angle_deg", "battens", "n_sources", "n_flags", "conflict_fields"]
    with open(HERE / "wings_merged.csv", "w", newline="") as fh:
        wr = csv.writer(fh); wr.writerow(cols)
        for r in out:
            row = []
            for c in cols:
                if c in r["fields"]: row.append(r["fields"][c].get("value"))
                elif c == "cert": row.append(";".join(f'{x["system"]} {x["class"]}'.strip() for x in r["cert"]))
                elif c == "cert_years": row.append(";".join(map(str, r["cert_years"])))
                elif c == "n_sources": row.append(len(r["sources"]))
                elif c == "n_flags": row.append(len(r["flags"]))
                elif c == "conflict_fields": row.append(";".join(n for n, e in r["fields"].items() if e.get("conflict")))
                else: row.append(r.get(c))
            wr.writerow(row)
    # --- статистика
    stats = {"input_records": len(recs), "merged_records": len(out), "sized_records": sum(1 for r in out if r["size"]),
             "families": len({(r["manufacturer"], r["family"]) for r in out}), "manufacturers": len({r["manufacturer"] for r in out}),
             "current_records": sum(1 for r in out if r["status"] == "current"),
             "current_families": len({(r["manufacturer"], r["family"]) for r in out if r["status"] == "current"}),
             "flags": n_flag, "conflicts": n_conf, "records_with_flags": sum(1 for r in out if r["flags"]),
             "flag_kinds": dict(collections.Counter(f["kind"] for r in out for f in r["flags"])),
             "field_coverage": dict(byfield_cov.most_common()), "geometry_records": len(geo_out),
             "geometry_items": sum(len(g["items"]) for g in geo_out), "polar_points": len(polar_pts), "placard": len(placard)}
    dump("consolidate_stats.json", stats)
    write_models_md(out, geo_out, polar_pts, placard, stats)
    print(json.dumps(stats, ensure_ascii=False, indent=1))

# ---------------------------------------------------------------- docs/research/glider_models.md
def repo_configs():
    res = {}
    for f in sorted(glob.glob(str(REPO / "configs/wings/*.json"))):
        d = json.load(open(f)); res[pathlib.Path(f).name] = (d.get("name", ""), d.get("prototype", ""))
    return res

def write_models_md(out, geo, polar_pts, placard, stats):
    fam = collections.OrderedDict()
    for r in out:
        F = fam.setdefault((r["manufacturer"], r["family"]), {"recs": [], "m": r["manufacturer"], "f": r["family"]})
        F["recs"].append(r)
    geo_keys = {g["key"] for g in geo if any(("value_mm" in i) for i in g["items"])}
    polar_keys = {(p["manufacturer"], p["family"]) for p in polar_pts}
    plac_keys = {(p["manufacturer"], p["family"]) for p in placard}
    cfgs = repo_configs()
    cfg_txt = {n: (nm + " " + pr).lower() for n, (nm, pr) in cfgs.items()}
    def cfg_match(m, f):
        toks = {"Wills Wing": {"Falcon": "falcon"}, "Aeros": {"Combat GT": "combat", "Combat C": "combat", "Combat L": "combat", "Target": "target"},
                "Icaro": {"Laminar": "laminar"}, "Moyes": {"Litespeed RS": "litespeed_rs", "Litespeed S": "litespeed_rs", "Litespeed RX": "litespeed_rs"}}
        t = toks.get(m, {}).get(f)
        if not t: return ""
        return ", ".join(n for n, s in cfg_txt.items() if t in s or t in n)
    lines = ["# Список моделей дельтапланов", "",
             f"Сгенерировано `tools/research/data/wing_passports/consolidate.py` ({datetime.date.today()}). Не править руками: добавить источник и перезапустить скрипт (см. «Как расширять»).", "",
             f"Всего: {stats['merged_records']} записей (семейство+версия+размер), {stats['families']} семейств, {stats['manufacturers']} производителей; "
             f"современных (сертификация ≥ 2015 или есть на сайте производителя): {stats['current_families']} семейств.", "",
             "Столбцы: **Класс** — DHV (1, 1-2, 2, 2-3, 3, 3E) и прочие системы (HGMA/USHPA и т. п. как записаны в источнике). **Паспорт** — где есть: "
             "П = страница/PDF производителя, D = карточка DHV, Пл = плакат Wills Wing (Vms/Vd/Va/Vne), Пр = точки поляры. **3D** — есть размеры каркаса в мм "
             "(в `wings_geometry.json`). **Конфиг** — есть ли близкий `configs/wings/*.json` (по имени/прототипу, без сверки параметров).", ""]
    flapped = sorted({f'{r["manufacturer"]} {r["family"]}' for r in out if r["features"]})
    lines += ["Wölbklappen (управляемая кривизна: закрылки/VG-типа; в DHV-отчёте упомянуты) у: " + ", ".join(flapped) + ". Это жёсткие/особые аппараты, их размах (13–14,5 м) выходит за диапазон обычных 8–12,5 м — в `wings_merged.json` помечено `out_of_range`.", ""]
    def row(F):
        rs = F["recs"]
        sizes = sorted({r["size"] for r in rs if r["size"]}, key=lambda s: (not s[0].isdigit(), float(s) if s[0].isdigit() else ["S", "M", "L", "XL"].index(s) if s in ("S", "M", "L", "XL") else 0))
        vers = sorted({r["version"] for r in rs if r["version"]})
        cl = collections.OrderedDict()
        for r in rs:
            for c in r["cert"]:
                cl[f'{c["system"]} {c["class"]}'.strip()] = 1
        years = sorted({y for r in rs for y in r["cert_years"]})
        kinds = {k for r in rs for k in r["source_kinds"]}
        src = []
        if kinds & {"site", "pdf", "oldpdf", "archive"}: src.append("П")
        if "dhv" in kinds: src.append("D")
        if (F["m"], F["f"]) in plac_keys: src.append("Пл")
        if (F["m"], F["f"]) in polar_keys: src.append("Пр")
        g3 = "да" if any(r["key"] in geo_keys for r in rs) else "—"
        st = ("актуальная (серт. ≥ 2015)" if years and max(years) >= 2015 else "актуальная (на сайте)") if any(r["status"] == "current" for r in rs) else "историческая"
        fn = F["f"] + (f' ({", ".join(vers)})' if vers else "")
        ys = f'{years[0]}–{years[-1]}' if len(years) > 1 else (str(years[0]) if years else "—")
        return f'| {F["m"]} | {fn} | {"; ".join(cl) or "—"} | {", ".join(sizes) or "—"} | {ys} | {st} | {"+".join(src)} | {g3} | {cfg_match(F["m"], F["f"]) or "—"} |'
    head = "| Производитель | Семейство | Класс | Размеры | Годы сертификации (DHV) | Статус | Паспорт | 3D | Конфиг |\n|---|---|---|---|---|---|---|---|---|"
    cur = [F for F in fam.values() if any(r["status"] == "current" for r in F["recs"])]
    his = [F for F in fam.values() if F not in cur]
    lines += ["## Современные аппараты (сертификация ≥ 2015 или актуальны на сайте производителя)", "", head] + [row(F) for F in sorted(cur, key=lambda F: (F["m"], F["f"]))]
    lines += ["", "## Исторические", "", head] + [row(F) for F in sorted(his, key=lambda F: (F["m"], F["f"]))]
    lines += ["", "## Как расширять", "",
              "1. Добавить источник: `fetch_makers.py` / `fetch_pdfs.py` / `fetch_dhv.py` кладут сырьё в `raw/`; разбор (Haiku, промпт `haiku_prompt.md`, схема в `parse.py`) даёт JSON в `out/haiku/` (страницы и PDF производителей) или `out/haiku_dhv/` (карточки DHV, пачки).",
              "2. Запустить `python3 consolidate.py` в `tools/research/data/wing_passports/` — пересоберёт `wings_merged.json/csv`, `wings_geometry.json`, `polars_points.json`, эту страницу и `consolidate_stats.json`.",
              "3. Новое семейство с нетривиальным названием: добавить правило в `norm_model()` (иначе оно попадёт в список «как есть», а размер определится по первому числу).",
              "4. Новый производитель: строка в `norm_mfr()`.", "",
              "## Кандидаты, упомянутые в источниках, но без паспорта", ""]
    lines += candidates_section(out)
    (REPO / "docs/research").mkdir(parents=True, exist_ok=True)
    (REPO / "docs/research/glider_models.md").write_text("\n".join(lines) + "\n")

CAND_NOTE = "Список ниже собирается скриптом из `out/text/*` (если он есть локально) — имена моделей, встречающиеся рядом с названиями производителей, но без записей в наборе."
def candidates_section(out):
    have = {(r["manufacturer"], r["family"].lower()) for r in out}
        # поиск по локальным текстам: слова-кандидаты по шаблонам
    pats = {"Moyes": r"Litespeed \w+|Gecko|Malibu \d|Xtralite|Tempo|Mars|Sonic|Axxess|Maxlite|Sting|Mission|Lightspeed",
            "Aeros": r"Combat(?:[- ]\w+)?|Discus|Target|Fox|Phantom|Stranger|Bravo",
            "Icaro": r"Laminar|Piuma|Alto|MastR|Orbiter|Easy|PiBi|Biplace|Revolution|Zero \d|Mini",
            "Airborne": r"Sting \d|C4|REV|F2|Fun \d|Climax|Edge|Streak|Blade|XT|Ninja|Clip|Hyper|Tandem|Quickstep",
            "Wills Wing": r"Sport \d|Falcon \d|T2C?|T3|U2|Fusion|Condor|Talon|Harrier|Raven|Eagle|Duck|Super Sport|Attack Duck|Ultra Sport|Alpha|Sport AT|XC|RamAir",
            "A.I.R.": r"Atos[- ]\w+|Stratos|Nexus|Zephir"}
    cand = collections.defaultdict(collections.Counter)
    for f in glob.glob(str(OUT / "text/*")):
        if "dhv__" in f: continue
        t = open(f, errors="ignore").read()
        for m_, p in pats.items():
            for x in re.findall(p, t): cand[m_][x.strip()] += 1
    lines = [CAND_NOTE, ""]
    def known(m, x):
        xl = x.lower()
        alias = {"xc": "cross country"}
        xl = alias.get(xl, xl)
        return any(mm == m and (fam in xl or xl in fam) for mm, fam in have)
    for m_, c in cand.items():
        miss = [(x, n) for x, n in c.most_common() if not known(m_, x) and n >= 2]
        if miss: lines.append(f"- **{m_}**: " + ", ".join(f"{x} ({n})" for x, n in miss[:25]))
    # DHV Geräteportal: индекс всех дельтапланов (raw/dhv/index.json, если есть) против разобранных карточек
    idx_f = HERE / "raw/dhv/index.json"
    if idx_f.exists():
        idx = json.load(open(idx_f))
        parsed = {c for r in out for c in r["cert_standards"]}
        def yr(c):
            m = re.search(r"-(\d\d)$", c or ""); return None if not m else (2000 + int(m.group(1)) if int(m.group(1)) < 50 else 1900 + int(m.group(1)))
        modern_missing = [x for x in idx if (yr(x["cert"]) or 0) >= 2015 and x["cert"] not in parsed]
        lines += ["", f"DHV Geräteportal: в индексе {len(idx)} дельтапланов (1979–2026), карточки скачаны и разобраны для {sum(1 for x in idx if x.get('data_file'))}; "
                  f"сертификаты ≥ 2015 без разобранной карточки: {len(modern_missing)}" + (": " + ", ".join(f'{x["name"]} ({x["maker"]}, {x["cert"]})' for x in modern_missing) if modern_missing else " (все современные сертификаты DHV в наборе)") + ".",
                  "Остальные ~400 карточек — старые модели 1979–2013 (не скачивались). Расширить: `fetch_dhv.py` с большим лимитом, затем разбор пачек в `out/haiku_dhv/`."]
    cfgnames = [f"{n} ({nm})" for n, (nm, pr) in repo_configs().items()]
    lines += ["", "Конфиги игры без записи в наборе (прототипы, которых нет в источниках паспортов): " + ", ".join(c for c in cfgnames if not any(k in c for k in ("combat", "laminar", "sport.json", "target", "training"))) + "."]
    return lines

if __name__ == "__main__":
    main()
