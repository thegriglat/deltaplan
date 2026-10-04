#!/usr/bin/env python3
"""Конвертер каталога стартов SY-9 -> data/places/hg_takeoffs.json (PP-К1).

Источник берётся из git (коммит REV): takeoffs_game.json, takeoffs.csv, summary.json.
Детерминированно: одинаковый вход -> те же байты. Только stdlib.
"""
import argparse, csv, io, json, re, subprocess, sys
from collections import Counter

REV = "5a2ed468"
BASE = "tools/research/air_synth/hg_sites/"
COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
           "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
# немецкие формы: O (Ost) -> E
GERMAN = {"NO": "NE", "SO": "SE", "NNO": "NNE", "ONO": "ENE", "OSO": "ESE", "SSO": "SSE"}
NUM = re.compile(r"^\d+(\.\d+)?$")


def _one(tok):
    """Токен-направление -> индекс румба или None."""
    if NUM.match(tok):
        d = float(tok)
        if 0 <= d <= 360:
            return int(d / 22.5 + 0.5) % 16
        return None
    tok = GERMAN.get(tok, tok)
    return COMPASS.index(tok) if tok in COMPASS else None


def parse_orientation(raw, dropped=None):
    """Сырая строка OSM -> список румбов PP-К1."""
    if not raw:
        return []
    out = []

    def add(i):
        if COMPASS[i] not in out:
            out.append(COMPASS[i])

    for tok in re.split(r"[;,/\s]+", raw.upper()):
        if not tok:
            continue
        idx = None
        if "-" in tok and not NUM.match(tok):
            parts = tok.split("-")
            if len(parts) == 2 and parts[0] and parts[1]:
                a, b = _one(parts[0]), _one(parts[1])
                if a is not None and b is not None:
                    fwd = (b - a) % 16
                    if fwd == 8:
                        steps = [a, b]
                    elif fwd < 8:
                        steps = [(a + k) % 16 for k in range(fwd + 1)]
                    else:
                        steps = [(a - k) % 16 for k in range(16 - fwd + 1)]
                    for i in steps:
                        add(i)
                    continue
        else:
            idx = _one(tok)
            if idx is not None:
                add(idx)
                continue
        if dropped is not None:
            dropped.append(tok)
    return out


def git_show(rev, path):
    return subprocess.check_output(["git", "show", f"{rev}:{BASE}{path}"]).decode("utf-8")


def build(rev):
    src = json.loads(git_show(rev, "takeoffs_game.json"))
    summ = json.loads(git_show(rev, "summary.json"))
    countries = {}
    for r in csv.DictReader(io.StringIO(git_show(rev, "takeoffs.csv"), newline="")):
        code = r["country"].strip()
        if not code:
            continue
        en = re.sub(r"\s*\(.*\)\s*$", "", r["country_name"]).strip()
        ru = r["country_name_ru"].strip()
        if code not in countries or (not countries[code]["en"] and en):
            countries[code] = {"en": en or code, "ru": ru or en or code}
    dropped, takeoffs, with_or = [], [], 0
    for s in sorted(src, key=lambda x: x["id"]):
        o = parse_orientation(s.get("orientation"), dropped)
        with_or += bool(o)
        takeoffs.append({"id": s["id"], "name": s.get("name") or "", "lat": s["lat"], "lon": s["lon"],
                         "country": s.get("country") or "", "ele": s.get("ele"), "orientation": o})
    used = {t["country"] for t in takeoffs if t["country"]}
    countries = {k: countries[k] for k in sorted(used)}
    missing = used - set(countries)
    if missing:
        sys.exit(f"нет названий стран: {sorted(missing)}")
    cat = {"format": "deltaplan.hg_takeoffs", "version": 1,
           "source": f"© OpenStreetMap contributors, ODbL 1.0; каталог SY-9 (air-synth), коммит {rev}",
           "fetch_date_utc": summ["fetch_date_utc"], "countries": countries, "takeoffs": takeoffs}
    return cat, with_or, dropped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rev", default=REV)
    ap.add_argument("--out", default="data/places/hg_takeoffs.json")
    a = ap.parse_args()
    cat, with_or, dropped = build(a.rev)
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cat, f, ensure_ascii=False, sort_keys=True, indent=1)
        f.write("\n")
    c = Counter(dropped)
    print(f"стартов: {len(cat['takeoffs'])}; стран: {len(cat['countries'])}; с ориентацией: {with_or}; "
          f"отброшено токенов: {len(dropped)} {dict(c.most_common(10))}", file=sys.stderr)


if __name__ == "__main__":
    main()
