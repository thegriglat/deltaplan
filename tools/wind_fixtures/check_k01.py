#!/usr/bin/env python3
"""Срезы k = 0 (FULL) и k = 1 (MEAN) каждого tests/fixtures/wind/cases/*.bin — побитно те же, что в
<git-ref> (RW-2b: второй набор фикстур добавляет k >= 2 и не должен менять первые два).
Шаг по k — 2 + len(terms) из соседнего .json (terms: null -> 2). exit 1 при любом расхождении."""
import glob
import json
import os
import subprocess
import sys

CASES = "tests/fixtures/wind/cases"


def git_show(ref, path):
    r = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def k_n(meta):
    terms = meta.get("terms")
    return 2 + (len(terms) if terms else 0)


def main():
    if len(sys.argv) != 2:
        print("usage: check_k01.py <git-ref>")
        return 2
    ref = sys.argv[1]
    bad = 0
    for jf in sorted(glob.glob(f"{CASES}/*.json")):
        if jf.endswith(".desc.json"):
            continue
        name = os.path.basename(jf)[:-5]
        old_bin = git_show(ref, f"{CASES}/{name}.bin")
        old_js = git_show(ref, f"{CASES}/{name}.json")
        if old_bin is None or old_js is None:
            print(f"{name}: нет в {ref} (пропуск)")
            continue
        kn_old = k_n(json.loads(old_js))
        kn_new = k_n(json.load(open(jf)))
        new_bin = open(f"{CASES}/{name}.bin", "rb").read()
        so, sn = kn_old * 16, kn_new * 16  # байт на точку
        if len(old_bin) % so or len(new_bin) % sn or len(old_bin) // so != len(new_bin) // sn:
            print(f"{name}: число (момент, точка) не совпало: {len(old_bin)}/{so} против {len(new_bin)}/{sn}")
            bad += 1
            continue
        diff = 0
        for i in range(len(old_bin) // so):
            if old_bin[i * so : i * so + 32] != new_bin[i * sn : i * sn + 32]:
                diff += 1
                if diff <= 3:
                    print(f"{name}: расходится (момент, точка) №{i}")
        if diff:
            print(f"{name}: расхождений {diff}")
            bad += 1
    print("check_k01:", "расхождения" if bad else "k = 0, 1 побитно прежние")
    return 1 if bad else 0


sys.exit(main())
