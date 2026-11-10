#!/usr/bin/env python3
"""Разбор строк PROBE {json} логов Godot -> список словарей."""
import json, sys

def read(path):
    out = []
    for l in open(path, errors="replace"):
        if l.startswith("PROBE "):
            out.append(json.loads(l[6:]))
    return out

if __name__ == "__main__":
    for d in read(sys.argv[1]):
        print(d)
