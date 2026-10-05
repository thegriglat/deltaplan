#!/usr/bin/env python3
"""Файлы для кабинета Steamworks из конфига игры (контракт S6).

  python3 tools/steam/partner_files.py          записать steam/partner/achievements.csv
  python3 tools/steam/partner_files.py --check  проверить конфиг и что csv совпадает с ним (exit 1 иначе)
"""
import csv
import io
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "configs" / "achievements.json"
OUT = ROOT / "steam" / "partner" / "achievements.csv"
HEADER = ["api", "name_en", "desc_en", "name_ru", "desc_ru", "hidden"]


def load():
    data = json.loads(CONFIG.read_text(encoding="utf-8"))
    items = data["achievements"]
    seen = set()
    for a in items:
        if not re.fullmatch(r"ACH_[A-Z0-9_]+", a["api"]):
            raise SystemExit("плохой api: " + a["api"])
        if a["api"] in seen:
            raise SystemExit("повтор api: " + a["api"])
        seen.add(a["api"])
        for k in ("name", "desc"):
            for lang in ("ru", "en"):
                if not a[k].get(lang):
                    raise SystemExit("нет %s.%s у %s" % (k, lang, a["api"]))
        if not isinstance(a["hidden"], bool) or "type" not in a["rule"]:
            raise SystemExit("плохая запись: " + a["api"])
    return items


def render(items):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(HEADER)
    for a in items:
        w.writerow([a["api"], a["name"]["en"], a["desc"]["en"], a["name"]["ru"], a["desc"]["ru"],
                    "1" if a["hidden"] else "0"])
    return buf.getvalue()


def main():
    text = render(load())
    if "--check" in sys.argv:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == text
        print("achievements.csv: " + ("ok" if ok else "устарел или отсутствует"))
        return 0 if ok else 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print("записано: %s (%d строк)" % (OUT.relative_to(ROOT), text.count("\n") - 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
