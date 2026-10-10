#!/usr/bin/env python3
"""Заглушка `osmtiles` (CLI O5) для тестов оркестратора world.py, пока нет настоящих pack/finalize (OT-2).

Вход pack — любой файл; тайлы региона берутся из файла --poly (строки `j i`, как вывод `cover`). Содержимое тайла —
детерминированная функция (регион, j, i, байты входа). Фрагменты — frags/<регион>/<j>/<i>.dpt (JSON). Склейка берёт
фрагмент с самым длинным payload, при равенстве — из региона с меньшим id (как O4).
Переменные окружения для сбоев: STUB_PACK_SLEEP=<с> (пауза до записи), STUB_DIE_ONCE=<файл> (первый pack падает
после половины тайлов и создаёт файл).
"""
import argparse
import hashlib
import json
import os
import sys
import time


def atomic(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def poly_tiles(path):
    out = []
    for line in open(path):
        p = line.split()
        if len(p) == 2 and p[0].lstrip("-").isdigit():
            out.append((int(p[0]), int(p[1])))
    return out


def cmd_pack(a):
    data = open(a.input, "rb").read()
    tiles = poly_tiles(a.poly)
    time.sleep(float(os.environ.get("STUB_PACK_SLEEP", "0")))
    die = os.environ.get("STUB_DIE_ONCE")
    for n, (j, i) in enumerate(tiles):
        if die and n == len(tiles) // 2 and not os.path.exists(die):
            open(die, "w").close()
            sys.stderr.write("stub: падаю посреди pack\n")
            os._exit(7)
        h = hashlib.sha256(("%s/%d/%d/" % (a.region, j, i)).encode() + data).hexdigest()
        payload = h * (1 + int(h[:2], 16) % 4)
        atomic(os.path.join(a.frag_dir, a.region, str(j), "%d.dpt" % i),
               json.dumps({"region": a.region, "j": j, "i": i, "payload": payload}).encode())
    rep = {"region": a.region, "input": a.input, "input_bytes": len(data), "osm_timestamp": 1760000000,
           "tiles": [[j, i, 1] for j, i in tiles], "seconds_total": 0.0, "peak_rss_mb": 1.0}
    atomic(os.path.join(a.frag_dir, a.region + ".pack.json"), json.dumps(rep).encode())


def cmd_finalize(a):
    rows = []
    for line in open(a.list):
        p = line.split()
        if not p:
            continue
        j, i, regs = int(p[0]), int(p[1]), p[2:]
        frs = []
        for r in sorted(regs):
            fp = os.path.join(a.frag_dir, r, str(j), "%d.dpt" % i)
            if os.path.exists(fp):
                frs.append(json.load(open(fp)))
        out = os.path.join(a.out, "v1", str(j), "%d.dpt" % i)
        if not frs:
            if os.path.exists(out):
                os.remove(out)
            rows.append({"j": j, "i": i, "bytes": 0, "sha256": "", "objects": 0})
            continue
        best = frs[0]
        for f in frs[1:]:
            if len(f["payload"]) > len(best["payload"]):
                best = f
        body = b"STUBDPT" + json.dumps({"sources": sorted(f["region"] for f in frs), "payload": best["payload"]},
                                       sort_keys=True).encode()
        atomic(out, body)
        rows.append({"j": j, "i": i, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(), "objects": 1})
    if a.report:
        atomic(a.report, "".join(json.dumps(r) + "\n" for r in rows).encode())


def cmd_manifest(a):
    srcs = json.load(open(a.sources))
    tiles = []
    root = os.path.join(a.tiles, "v1")
    for j in sorted(os.listdir(root), key=lambda x: (not x.lstrip("-").isdigit(), x)):
        if not j.lstrip("-").isdigit():
            continue
        for f in sorted(os.listdir(os.path.join(root, j))):
            if f.endswith(".dpt"):
                b = open(os.path.join(root, j, f), "rb").read()
                tiles.append([int(j), int(f[:-4]), len(b), hashlib.sha256(b).hexdigest()])
    atomic(a.out, json.dumps({"sources": srcs, "tiles": tiles, "pad": "x" * 100}).encode())


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack")
    for k in ("--input", "--region", "--poly", "--frag-dir", "--tmp", "--threads", "--report"):
        p.add_argument(k)
    p.set_defaults(fn=cmd_pack)
    f = sub.add_parser("finalize")
    for k in ("--frag-dir", "--out", "--list", "--threads", "--report"):
        f.add_argument(k)
    f.set_defaults(fn=cmd_finalize)
    m = sub.add_parser("manifest")
    for k in ("--tiles", "--sources", "--out"):
        m.add_argument(k)
    m.set_defaults(fn=cmd_manifest)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
