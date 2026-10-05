#!/usr/bin/env python3
"""Сводка инвентаря по группам: summarize.py build/inventory/Linux.json [--md]"""
import collections, json, sys
inv = json.load(open(sys.argv[1]))
g = collections.OrderedDict()
for i in inv["items"]:
    k = (i["kind"], i["group"], i["assets_md"] or "НЕТ СТРОКИ", (i["license"] or "")[:50].replace("|", "/"), i["commercial_ok"], i["attribution"])
    e = g.setdefault(k, [0, 0, i["path"]])
    e[0] += 1; e[1] += i["bytes"]
print("| kind | группа | ASSETS.md | лицензия | коммерч. | атриб. | файлов | МБ | пример |")
print("|---|---|---|---|---|---|---|---|---|")
for k, (n, b, ex) in sorted(g.items(), key=lambda x: (x[0][0], x[0][1])):
    print(f"| {k[0]} | {k[1]} | {k[2]} | {k[3]} | {k[4]} | {k[5]} | {n} | {b/1e6:.2f} | `{ex}` |")
