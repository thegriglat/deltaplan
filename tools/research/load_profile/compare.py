#!/usr/bin/env python3
"""compare.py <до>.json <после>.json → md-таблица медиан (FL-К3 v1). Сравниваются группы <место>/<air_cache> с одинаковым ключом,
либо, если ключи различаются (none → miss/hit), — одно место: каждая группа «после» против единственной группы «до» того же места."""
import json
import sys


def load(p):
    return json.load(open(p))["median"]


def base_for(before, key):
    if key in before:
        return before[key]
    place = key.split("/")[0]
    c = [v for k, v in before.items() if k.split("/")[0] == place]
    return c[0] if c else None


def row(name, b, a, unit):
    if b is None or a is None:
        return f"| {name} | {b if b is not None else '—'} | {a if a is not None else '—'} | — | — |"
    d = a - b
    pct = f"{d / b * 100:+.0f} %" if b else "—"
    return f"| {name} | {b:g} {unit} | {a:g} {unit} | {d:+.2f} | {pct} |"


def main():
    before, after = load(sys.argv[1]), load(sys.argv[2])
    for key, a in sorted(after.items()):
        b = base_for(before, key)
        print(f"\n### {key} (до: n={b['n'] if b else 0}, после: n={a['n']})\n")
        print("| показатель | до | после | разница | % |\n|---|---|---|---|---|")
        if not b:
            print("| нет группы «до» | | | | |")
            continue
        print(row("to_flying_s", b["to_flying_s"], a["to_flying_s"], "с"))
        print(row("load_max_gap_ms", b["load_max_gap_ms"], a["load_max_gap_ms"], "мс"))
        for s in sorted(set(b["stages"]) | set(a["stages"])):
            print(row(f"этап {s}", b["stages"].get(s), a["stages"].get(s), "с"))


if __name__ == "__main__":
    main()
