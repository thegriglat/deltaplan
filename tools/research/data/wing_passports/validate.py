"""Пост-проверка извлечённого LLM: цитата есть в тексте источника, число есть в цитате, физ. диапазон, конвертация единиц,
слияние по (изготовитель, модель+размер) -> wings.json / wings.csv / coverage.json.  Запуск: python3 validate.py [extracted.jsonl]"""
import re, json, sys, csv, glob, pathlib
from collections import defaultdict
from common import RAW, ROOT
OUT = ROOT / "out"; TXT = OUT / "text"
ext_file = sys.argv[1] if len(sys.argv) > 1 else str(OUT / "extracted_qwen3.5_9b.jsonl")
# поле: (целевая единица, диапазон, {единица источника: множитель})
L = {"m2": 1, "m²": 1, "sqm": 1, "sq ft": 0.09290304, "sq.ft": 0.09290304, "ft2": 0.09290304, "ft²": 0.09290304}
LEN = {"m": 1, "ft": 0.3048, "in": 0.0254, "cm": 0.01, "mm": 0.001}
MASS = {"kg": 1, "lb": 0.45359237, "lbs": 0.45359237}
SPD = {"km/h": 1, "kmh": 1, "kph": 1, "mph": 1.609344, "kt": 1.852, "kts": 1.852, "knots": 1.852, "m/s": 3.6}
PCT = {"%": 1, "": 1}
F = {"area": ("m2", (8, 25), L), "span": ("m", (8, 14), LEN), "aspect_ratio": ("", (4, 10), {"": 1}),
     "double_surface_pct": ("%", (0, 100), PCT), "wing_mass": ("kg", (15, 50), MASS),
     "pilot_mass_min": ("kg", (30, 200), MASS), "pilot_mass_max": ("kg", (30, 200), MASS),
     "takeoff_mass_min": ("kg", (40, 500), MASS), "takeoff_mass_max": ("kg", (40, 500), MASS),
     "vne": ("km/h", (40, 130), SPD), "va": ("km/h", (30, 100), SPD), "stall_speed": ("km/h", (15, 50), SPD),
     "trim_speed": ("km/h", (25, 60), SPD), "vms": ("km/h", (15, 50), SPD), "vd": ("km/h", (30, 150), SPD),
     "vmin_vg0": ("km/h", (20, 50), SPD), "vmin_vg100": ("km/h", (20, 50), SPD),
     "vmax_vg0": ("km/h", (50, 140), SPD), "vmax_vg100": ("km/h", (50, 140), SPD),
     "best_glide": ("", (6, 20), {"": 1, ":1": 1}), "nose_angle": ("deg", (100, 150), {"deg": 1, "°": 1, "degrees": 1, "": 1}),
     "battens": ("", (8, 40), {"": 1}), "year": ("", (1970, 2027), {"": 1})}
def norm(s): return re.sub(r"\s+", " ", s.replace(" ", " ")).strip().lower()
ALN = lambda s: re.sub(r"[^0-9a-zа-яäöüß]", "", s.lower())
def num_forms(v):
    out = {repr(float(v)), ("%g" % v), ("%.1f" % v), ("%.2f" % v), ("%.0f" % v) if float(v).is_integer() else ""}
    out |= {x.replace(".", ",") for x in out}
    return {x for x in out if x}
def num_in(quote, v):
    q = norm(quote)
    toks = re.findall(r"\d+(?:[.,]\d+)?", q)
    return any(abs(float(t.replace(",", ".")) - v) < 1e-9 for t in toks)
texts = {}
def doc_text(src):
    if src in texts: return texts[src]
    if src.startswith("dhv:"):
        r = json.load(open(RAW / "dhv/index.json")); rec = [x for x in r if x.get("data_file") == src[4:]][0]
        t = "" 
        for f in [rec["data_file"], rec.get("test_file")]:
            if f: t += (TXT / (f.replace("/", "__") + ".txt")).read_text() + "\n"
    else: t = (TXT / (src.replace("/", "__") + ".txt")).read_text()
    texts[src] = norm(t); return texts[src]
_al = {}
def doc_aln(src):
    if src not in _al: _al[src] = ALN(doc_text(src))
    return _al[src]
MAKER = {"ww/": "Wills Wing", "moyes/": "Moyes", "aeros": "Aeros", "icaro/": "Icaro", "airborne/": "Airborne", "bautek/": "Bautek",
         "pdf/moyes": "Moyes", "pdf/aeros": "Aeros", "pdf/icaro": "Icaro", "pdf/airborne": "Airborne", "pdf/ww": "Wills Wing"}
dhv_idx = {("dhv:" + x["data_file"]): x for x in json.load(open(RAW / "dhv/index.json")) if x.get("data_file")}
def maker_of(src, w):
    if src in dhv_idx: return dhv_idx[src]["maker"]
    for k, v in MAKER.items():
        if src.startswith(k): return v
    return w.get("manufacturer") or "?"
def key_of(maker, w, src):
    m = w["model"].strip(); s = w["size"].strip()
    if src in dhv_idx: m = dhv_idx[src]["name"]; s = ""
    full = m if (not s or norm(s) in norm(m)) else m + " " + s
    return re.sub(r"[^a-z0-9]", "", norm(re.sub(r"(?i)wills wing|moyes|aeros|icaro( 2000)?|airborne|bautek", "", full))), full.strip()
PRIO = lambda src: 0 if not src.startswith("dhv:") and not src.startswith("pdf/") else (1 if src.startswith("pdf/") else 2)
cand = defaultdict(lambda: defaultdict(list)); meta = {}; stats = defaultdict(int); flag_log = []
for line in open(ext_file):
    ch = json.loads(line); src = ch["src"]
    if not ch["wings"]: continue
    try: T = doc_text(src)
    except Exception as e: print("no text", src, e); continue
    for w in ch["wings"]:
        for ft in w.get("facts", []): w.setdefault(ft["field"], ft) if ft["field"] not in w else None
        mk = maker_of(src, w); k, full = key_of(mk, w, src)
        if not k: continue
        kk = (re.sub(r"\W", "", mk.lower())[:6], k)
        meta.setdefault(kk, dict(manufacturer=mk, model=full, sources=set()))["sources"].add(ch["url"])
        for f, (unit, rng, conv) in F.items():
            d = w.get(f); 
            if not isinstance(d, dict) or d.get("value") is None: continue
            v = float(d["value"]); u = (d.get("unit") or "").strip().lower(); q = d.get("quote") or ""; flags = []
            stats["extracted"] += 1
            if not q: flags.append("quote_not_in_source")
            elif norm(q) in T: pass
            elif ALN(q) in doc_aln(src): pass
            else:
                wt = [x for x in re.findall(r"[^\W\d_]{3,}", q.lower())]
                ok = (not wt or sum(1 for x in wt if x in T) / len(wt) >= 0.6) and any(abs(float(t.replace(",", ".")) - v) < 1e-9 for t in re.findall(r"\d+(?:[.,]\d+)?", T))
                flags.append("quote_fuzzy" if ok else "quote_not_in_source")
            if not num_in(q, v): flags.append("number_not_in_quote")
            if u not in conv: flags.append("unit_unknown:" + u); val = v
            else: val = v * conv[u]
            if f == "double_surface_pct" and v <= 1.0 and not flags: flags.append("fraction_not_percent")
            if not (rng[0] <= val <= rng[1]): flags.append("out_of_range")
            rec = dict(value=round(val, 3), raw_value=v, raw_unit=d.get("unit"), source_ref=ch["url"], source_file=src, quote=q,
                       conversion=(None if conv.get(u, 1) == 1 else f"{v} {u} x {conv[u]}"), flags=flags)
            cand[kk][f].append(rec)
            hard = [x for x in flags if x != "quote_fuzzy"]
            if hard: stats["flagged"] += 1; flag_log.append((meta[kk]["model"], f, flags, q[:60]))
        for f in ("cert_class", "cert_standard"):
            if w.get(f, "").strip(): cand[kk][f].append(dict(value=w[f].strip(), source_ref=ch["url"], source_file=src, quote="", flags=[]))
# слияние: лучший кандидат без флагов по приоритету источника; остальные значения - alternatives
wings = []
for kk, fs in cand.items():
    m = meta[kk]; rec = dict(manufacturer=m["manufacturer"], model=m["model"], sources=sorted(m["sources"]), fields={}, n_flagged=0)
    for f, lst in fs.items():
        lst.sort(key=lambda r: (bool([x for x in r["flags"] if x != "quote_fuzzy"]), PRIO(r["source_file"])))
        best = dict(lst[0]); alts = []
        for r in lst[1:]:
            if r["value"] != best["value"] and r["value"] not in [a["value"] for a in alts]:
                alts.append(dict(value=r["value"], source_ref=r["source_ref"], quote=r["quote"], flags=r["flags"]))
        if alts: best["alternatives"] = alts
        if [x for x in best.get("flags", []) if x != "quote_fuzzy"]: rec["n_flagged"] += 1
        rec["fields"][f] = best
    # DHV: Startgewicht - это стартовая масса, дубликат pilot_mass не считаем отдельным полем
    fl = rec["fields"]
    if "takeoff_mass_min" in fl and "pilot_mass_min" in fl and fl["pilot_mass_min"]["quote"] == fl["takeoff_mass_min"]["quote"]:
        del fl["pilot_mass_min"]; fl.pop("pilot_mass_max", None)
    wings.append(rec)
wings.sort(key=lambda r: (r["manufacturer"].lower(), r["model"].lower()))
json.dump(wings, open(ROOT / "wings.json", "w"), ensure_ascii=False, indent=1)
cols = list(F) + ["cert_class", "cert_standard"]
with open(ROOT / "wings.csv", "w", newline="") as fo:
    wr = csv.writer(fo); wr.writerow(["manufacturer", "model", "n_flagged"] + cols + [c + "_flag" for c in cols] + ["source_first"])
    for r in wings:
        fl = r["fields"]
        wr.writerow([r["manufacturer"], r["model"], r["n_flagged"]] + [fl[c]["value"] if c in fl else "" for c in cols] +
                    [";".join(fl[c]["flags"]) if c in fl and fl[c].get("flags") else "" for c in cols] + [r["sources"][0]])
cov = {f: dict(n=sum(1 for r in wings if f in r["fields"]), n_clean=sum(1 for r in wings if f in r["fields"] and not [x for x in r["fields"][f]["flags"] if x != "quote_fuzzy"])) for f in cols}
by_maker = defaultdict(int)
for r in wings: by_maker[r["manufacturer"]] += 1
json.dump(dict(models=len(wings), extracted_values=stats["extracted"], flagged_values=stats["flagged"], coverage=cov, by_maker=dict(by_maker),
               flags=[list(map(str, x)) for x in flag_log]), open(OUT / "coverage.json", "w"), ensure_ascii=False, indent=1)
print(len(wings), "моделей;", stats["extracted"], "значений;", stats["flagged"], "flagged")
