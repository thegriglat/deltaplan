#!/usr/bin/env python3
"""RW-10d: усадка данных дампа — w_mech поля (build его не читает) обнуляется, тела перепаковываются zstd -19.
Использование: recompress.py <каталог случая>... (после dump_air_thermals)."""
import json, subprocess, sys, os

def zdec(path, raw_bytes):
    return subprocess.run(["zstd", "-dc", path], capture_output=True, check=True).stdout

def zenc(data, path):
    subprocess.run(["zstd", "-19", "-q", "-f", "-o", path], input=data, check=True)

for d in sys.argv[1:]:
    h = json.load(open(os.path.join(d, "field.json")))
    body = bytearray(zdec(os.path.join(d, "field.bin"), h["raw_bytes"]))
    for lv in h["levels"]:
        off, nbytes, _ = lv["arrays"]["w_mech"]
        body[int(off):int(off) + int(nbytes)] = bytes(int(nbytes))
    zenc(bytes(body), os.path.join(d, "field.bin"))
    r = json.load(open(os.path.join(d, "ref.json")))
    zenc(zdec(os.path.join(d, "ref.bin"), r["raw_bytes"]), os.path.join(d, "ref.bin"))
    print(d, os.path.getsize(os.path.join(d, "field.bin")), os.path.getsize(os.path.join(d, "ref.bin")))
