#!/usr/bin/env python3
"""Проверка файлов F1/F2/M1 (cascade-2d) по docs/contracts/cascade-2d.md.

  check_contract.py <файлы|каталоги> ...   (рекурсивно *.json по полю format)
  check_contract.py --selftest
Печать OK/FAIL по файлу; выход 1 при любом FAIL.
"""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cascade2d_io as io  # noqa: E402

FORMATS = ("cascade2d-field", "cascade2d-run", "cascade2d-metrics")


def check_file(path, strict=True):
    """-> None (ok) или бросает ContractError; возвращает kind или None, если файл не наш."""
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        raise io.ContractError(f"не читается JSON: {e}")
    fmt = d.get("format") if isinstance(d, dict) else None
    if fmt not in FORMATS:
        if strict or (isinstance(fmt, str) and fmt.startswith("cascade2d")):
            raise io.ContractError(f"неизвестный format={fmt!r}")
        return None
    if fmt == "cascade2d-field":
        meta, arrays = io.read_f1(path)
        io.check_f1_arrays(meta, arrays)
    elif fmt == "cascade2d-run":
        io.validate_f2(d)
    else:
        io.validate_m1(d)
    return fmt


def collect(paths):
    out = []  # (путь, явный ли файл)
    for p in paths:
        if os.path.isdir(p):
            for r, _, fs in os.walk(p):
                out += [(os.path.join(r, f), False) for f in sorted(fs) if f.endswith(".json")]
        else:
            out.append((p, True))
    return out


def run(paths, quiet_skip=True):
    bad = n = 0
    for p, explicit in collect(paths):
        try:
            k = check_file(p, strict=explicit)
        except (io.ContractError, KeyError, TypeError, ValueError) as e:
            print(f"FAIL {p}: {e}")
            bad += 1
            continue
        if k is None:
            if not quiet_skip:
                print(f"SKIP {p}")
            continue
        n += 1
        print(f"OK   {p} [{k}]")
    print(f"проверено {n}, FAIL {bad}")
    return 1 if bad else 0


def selftest():
    import synth
    with tempfile.TemporaryDirectory() as t:
        synth.write_synth_f1(os.path.join(t, "a_d400.json"))
        synth.write_synth_f1(os.path.join(t, "b_d200.json"), dx=200, source="cascade", variant="V1", parent_dx=400)
        with open(os.path.join(t, "r.run.json"), "w") as f:
            json.dump(synth.make_f2(), f)
        with open(os.path.join(t, "m.json"), "w") as f:
            json.dump(synth.make_m1(), f)
        if run([t]) != 0:
            print("selftest: FAIL")
            return 1
        with open(os.path.join(t, "m.json"), "w") as f:
            json.dump(synth.make_m1(version=2), f)
        if run([t]) != 1:
            print("selftest: FAIL (ломаный не пойман)")
            return 1
    print("selftest: ok")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["--selftest"]:
        sys.exit(selftest())
    if not args:
        print(__doc__)
        sys.exit(2)
    sys.exit(run(args))
