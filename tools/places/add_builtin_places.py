#!/usr/bin/env python3
"""Добавляет старты встроенных мест (configs/locations/*.json -> start_sites) в каталог
«Популярные места» (data/places/hg_takeoffs.json, PP-К1 v2). Идемпотентно: прежние builtin/* и manual/* заменяются.
Ручные старты (нет в OSM, не встроенные места) — из tools/places/manual_takeoffs.json, id manual/<место>/<старт>.
Название — русская подпись из locale/ui.csv; ориентация — румб из heading_deg (ветер дует с направления разбега);
высота ele — только где в name_doc места явно названа абсолютная высота старта/горы.
Запуск из корня проекта: python3 tools/places/add_builtin_places.py (после build_hg_takeoffs.py)."""
import csv, glob, json, os

CAT = "data/places/hg_takeoffs.json"
DIRS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
ELE = {  # м над уровнем моря, из name_doc места
    "altai/sinyukha_east": 1210, "ongudai/kayancha_south": 1870, "askarovo/biyagoda_west": 630,
    "askarovo/biyagoda_east": 630, "askarovo/biyagoda_south_west": 725,
    "aushkul/aushtau_east": 645, "aushkul/aushtau_south": 645,
}
COUNTRY = "RU"  # все четыре встроенных места — Россия (Алтай, Башкирия, Южный Урал)

ru = {}
with open("locale/ui.csv", encoding="utf8", newline="") as f:
    for row in csv.reader(f):
        if len(row) >= 2:
            ru[row[0]] = row[1]

cat = json.load(open(CAT, encoding="utf8"))
cat["takeoffs"] = [t for t in cat["takeoffs"] if not t["id"].startswith(("builtin/", "manual/"))]
for path in sorted(glob.glob("configs/locations/*.json")):
    loc = os.path.basename(path)[:-5]
    for st in json.load(open(path, encoding="utf8")).get("start_sites", []):
        key = f"{loc}/{st['id']}"
        h = float(st["heading_deg"])
        cat["takeoffs"].append({
            "id": f"builtin/{key}", "name": ru[st["name"]], "lat": st["lat"], "lon": st["lon"],
            "country": COUNTRY, "ele": ELE.get(key), "orientation": [DIRS[round(h / 22.5) % 16]],
            "location": loc, "site": st["id"], "heading_deg": st["heading_deg"],
        })
cat["takeoffs"] += json.load(open("tools/places/manual_takeoffs.json", encoding="utf8"))["takeoffs"]
assert COUNTRY in cat["countries"]
with open(CAT, "w", encoding="utf8") as f:
    json.dump(cat, f, ensure_ascii=False, sort_keys=True, indent=1)
    f.write("\n")
print("builtin:", sum(t["id"].startswith("builtin/") for t in cat["takeoffs"]), "всего:", len(cat["takeoffs"]))
