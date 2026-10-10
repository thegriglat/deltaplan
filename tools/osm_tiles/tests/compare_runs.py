#!/usr/bin/env python3
"""Сравнение двух выходных корней тайлов (OT-6): наборы файлов <корень>/v1/<j>/<i>.dpt и их sha256.

  compare_runs.py <out_a> <out_b>   -> `same N tiles` (код 0) или `DIFF …` (код 1). manifest.pb не сравнивается
  (в нём время создания).
"""
import hashlib
import os
import sys


def tile_hashes(root):
    out = {}
    base = os.path.join(root, "v1")
    if not os.path.isdir(base):
        return out
    for j in os.listdir(base):
        d = os.path.join(base, j)
        if not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            if f.endswith(".dpt"):
                with open(os.path.join(d, f), "rb") as fh:
                    out[(int(j), int(f[:-4]))] = hashlib.sha256(fh.read()).hexdigest()
    return out


def main(argv):
    if len(argv) != 3:
        print("usage: compare_runs.py <out_a> <out_b>")
        return 2
    a, b = tile_hashes(argv[1]), tile_hashes(argv[2])
    if not a and not b:
        print("DIFF: оба корня пусты")
        return 1
    only_a, only_b = sorted(set(a) - set(b)), sorted(set(b) - set(a))
    diff = sorted(t for t in set(a) & set(b) if a[t] != b[t])
    if only_a or only_b or diff:
        print("DIFF: только в A %d, только в B %d, разный sha %d (примеры: %s)" % (
            len(only_a), len(only_b), len(diff), (only_a[:2] + only_b[:2] + diff[:2])))
        return 1
    print("same %d tiles" % len(a))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
