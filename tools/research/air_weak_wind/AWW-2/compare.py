"""AWW-2: diff.md по контракту W1 — строки (место, старт, день, колонка), где |Δ| > 5 % или > 0,1 в единицах колонки,
между variant=main и variant=AWW-2 в starts.csv. Оценка «ожидаемо?/почему» — notes.json:
{"<place>/<site>/<day>": {"*": [да|нет, почему], "<колонка>": [да|нет, почему]}}; нет записи — «?».
Запуск: python3 compare.py > diff.md
"""
import csv
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKIP = {"variant", "place", "site", "wind_ms", "hour", "sky"}


def day_of(r):
    if r["place"] in ("training_island", "volcano_island"):
        return "старт"
    return "слабый" if float(r["wind_ms"]) < 3 else "сильный"


def main():
    rows = list(csv.DictReader((HERE / "starts.csv").open(encoding="utf-8")))
    notes = json.loads((HERE / "notes.json").read_text(encoding="utf-8")) if (HERE / "notes.json").exists() else {}
    cols = [c for c in rows[0].keys() if c not in SKIP]
    key = lambda r: (r["place"], r["site"], r["wind_ms"], r["hour"], r["sky"])
    base = {key(r): r for r in rows if r["variant"] == "main"}
    print("# AWW-2: W1 до/после правки 1 (θ′·h механизма F)\n")
    print("Порог: |Δ| > 5 % или > 0,1 в единицах колонки; пусто ↔ число — тоже строка. Режим calc (--nobake), "
          "сид configs/atmosphere.json. «Старт» — погода встроенного старта; «слабый» — 2 м/с, ясно; "
          "«сильный» — 5 м/с, переменная облачность; оба 12 ч, ветер в старт.\n")
    print("| место | старт | день | величина | main | AWW-2 | Δ | ожидаемо? | почему |")
    print("|---|---|---|---|---|---|---|---|---|")
    n = 0
    unexpected = []
    for r in rows:
        if r["variant"] != "AWW-2":
            continue
        b = base.get(key(r))
        if b is None:
            continue
        day = day_of(r)
        nt = notes.get(f"{r['place']}/{r['site']}/{day}", {})
        for c in cols:
            a, z = b[c], r[c]
            if a == "" and z == "":
                continue
            if a == "" or z == "":
                sa, sz, sd = a or "—", z or "—", "—"
            else:
                fa, fz = float(a), float(z)
                d = fz - fa
                if c == "dir10_deg":
                    d = (d + 180.0) % 360.0 - 180.0
                pct = abs(d) / abs(fa) * 100 if fa != 0 else float("inf")
                if d == 0 or not (abs(d) > 0.1 or pct > 5):
                    continue
                sa, sz, sd = f"{fa:.3f}", f"{fz:.3f}", f"{d:+.3f}"
            exp, why = nt.get(c, nt.get("*", ["?", ""]))
            print(f"| {r['place']} | {r['site']} | {day} | {c} | {sa} | {sz} | {sd} | {exp} | {why} |")
            n += 1
            if exp != "да":
                unexpected.append(f"{r['place']}/{r['site']}/{day}: {c} {sa} → {sz}" + (f" — {why}" if why else ""))
    print(f"\nСтрок: {n}\n")
    print("## Неожиданно сдвинулось\n")
    for u in unexpected:
        print(f"- {u}")
    if not unexpected:
        print("- нет")


if __name__ == "__main__":
    main()
