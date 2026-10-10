#!/usr/bin/env python3
"""Заглушка `osmium extract --strategy smart -c <cfg.json> [--overwrite] <input>` для тестов нарезки world.py.
Выход части — детерминированная функция входа и bbox. STUB_OSMIUM_SLEEP=<с> — пауза; STUB_OSMIUM_DIE_ONCE=<файл> —
первый запуск падает, не записав ничего."""
import hashlib
import json
import os
import sys
import time

args = sys.argv[1:]
assert args[0] == "extract", args
cfg = json.load(open(args[args.index("-c") + 1]))
data = open(args[-1], "rb").read()
time.sleep(float(os.environ.get("STUB_OSMIUM_SLEEP", "0")))
die = os.environ.get("STUB_OSMIUM_DIE_ONCE")
if die and not os.path.exists(die):
    open(die, "w").close()
    sys.stderr.write("stub osmium: падаю\n")
    sys.exit(1)
for e in cfg["extracts"]:
    body = hashlib.sha256(data + json.dumps(e["bbox"]).encode()).digest() * 1000
    with open(e["output"], "wb") as f:
        f.write(body)
