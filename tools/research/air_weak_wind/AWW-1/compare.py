"""AWW-1: diff.md по контракту W1 — строки (место, старт, колонка), где |Δ| > 5 % или > 0,1 в абсолютных единицах,
между variant=main и каждым другим variant в starts.csv. Запуск: python3 compare.py > diff.md
"""
import csv
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKIP = {"variant", "place", "site", "wind_ms", "hour", "sky"}


def main():
    rows = list(csv.DictReader((HERE / "starts.csv").open(encoding="utf-8")))
    cols = [c for c in rows[0].keys() if c not in SKIP]
    base = {(r["place"], r["site"]): r for r in rows if r["variant"] == "main"}
    variants = sorted({r["variant"] for r in rows} - {"main"})
    print("# AWW-1: до/после по прототипам (контракт W1 v1)\n")
    print("Порог: |Δ| > 5 % или > 0,1 в единицах колонки. Пусто → число и наоборот — тоже строка.\n")
    for v in variants:
        print(f"## variant = {v} против main\n")
        print("| место | старт | колонка | main | после | Δ | Δ, % |")
        print("|---|---|---|---|---|---|---|")
        n = 0
        for r in rows:
            if r["variant"] != v:
                continue
            b = base.get((r["place"], r["site"]))
            if b is None:
                continue
            for c in cols:
                a, z = b[c], r[c]
                if a == "" and z == "":
                    continue
                if a == "" or z == "":
                    print(f"| {r['place']} | {r['site']} | {c} | {a or '—'} | {z or '—'} | — | — |")
                    n += 1
                    continue
                fa, fz = float(a), float(z)
                d = fz - fa
                pct = abs(d) / abs(fa) * 100 if fa != 0 else float("inf")
                if d != 0 and (abs(d) > 0.1 or pct > 5):
                    print(f"| {r['place']} | {r['site']} | {c} | {fa:.3f} | {fz:.3f} | {d:+.3f} | {pct:.0f} |")
                    n += 1
        print(f"\nСтрок: {n}\n")


if __name__ == "__main__":
    main()
