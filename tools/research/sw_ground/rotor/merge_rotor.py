"""Склейка частичных rotor_<CASES>.json в out/swg-2/rotor.json (случаи считались отдельными запусками из-за занятого GPU)."""
import glob
import json
import os
import sys

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out", "swg-2")
parts = sorted(glob.glob(os.path.join(out, "rotor_*.json")))
docs = [json.load(open(p)) for p in parts]
base = docs[0]
for d in docs[1:]:
    assert d["params"] == base["params"] and d["criterion"] == base["criterion"], "параметры должны совпадать"
    for k in ("rows", "ridges", "timing"):
        base[k] += d[k]
    base["case_info"].update(d["case_info"])
order = {"ASK_TU03B": 0, "PERD_NE": 1, "PERD_SW": 2}
for k in ("rows", "ridges", "timing"):
    base[k].sort(key=lambda r: order[r["case"]])
tmp = os.path.join(out, "rotor.json.tmp")
json.dump(base, open(tmp, "w"), ensure_ascii=False, indent=1, allow_nan=False)
os.replace(tmp, os.path.join(out, "rotor.json"))
print("merged", [os.path.basename(p) for p in parts])
