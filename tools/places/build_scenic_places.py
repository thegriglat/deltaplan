"""Сборка каталога красивых мест (SCP-К1 v2, docs/contracts/scenic-places.md).

Читает tools/places/scenic/*.json, объединяет countries и places, проверяет уникальность id,
пишет data/places/scenic_places.json: json.dumps(ensure_ascii=False, indent=1) + '\\n',
места по id, страны по коду. Без сети. Запуск: python3 tools/places/build_scenic_places.py [--src ДИР] [--out ФАЙЛ]
"""
import argparse, glob, json, os, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "tools/places/scenic")
OUT = os.path.join(ROOT, "data/places/scenic_places.json")


def build(paths):
    countries, places, seen = {}, [], {}
    for path in paths:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        for code, names in d["countries"].items():
            if code in countries and countries[code] != names:
                raise ValueError("страна %s: разные названия в %s" % (code, path))
            countries[code] = names
        for p in d["places"]:
            if p["id"] in seen:
                raise ValueError("повтор id %s: %s и %s" % (p["id"], seen[p["id"]], path))
            seen[p["id"]] = path
            places.append(p)
    places.sort(key=lambda p: p["id"])
    used = {p["country"] for p in places}
    countries = {c: countries[c] for c in sorted(countries) if c in used}
    return {"format": "deltaplan.scenic_places", "version": 1, "countries": countries, "places": places}


def write(doc, out):
    text = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, out)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args(argv)
    paths = sorted(glob.glob(os.path.join(a.src, "*.json")))
    if not paths:
        print("нет файлов в %s" % a.src)
        return 1
    try:
        doc = build(paths)
    except ValueError as e:
        print("ошибка: %s" % e)
        return 1
    write(doc, a.out)
    print("мест %d, стран %d -> %s" % (len(doc["places"]), len(doc["countries"]), a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
