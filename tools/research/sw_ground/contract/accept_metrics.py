#!/usr/bin/env python3
"""Числа для проверок приёмки sw-ground (карточки SWG-*): печатает строки `<имя> <число>`.

  py accept_metrics.py ground <ground.json>   decomp_lv_perd, decomp_terms, scan_params, base_variants, new_variants, masts_new, summary_lv
  py accept_metrics.py rotor <rotor.json>     rows_menke, rows_cases, ridges
  py accept_metrics.py timing <timing.json>   rows, windows, stages
Отсутствующий файл — `missing 1`, выход 1.
"""
import json
import sys


def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except OSError:
        print("missing 1")
        sys.exit(1)


def ground(d):
    lv = [r for r in d["decomp"] if r["type"] in ("lee", "valley") and r["case"] != "ASK_TU03B"]
    print("decomp_lv_perd", len(lv))
    print("decomp_terms", len({r["term"] for r in d["decomp"]}))
    print("scan_params", len({s["param"] for s in d["scan"]}))
    print("base_variants", len({"potential", "potential_jh"} & set(d["variants"])))
    print("new_variants", len(set(d["variants"]) - {"potential", "potential_jh"}))
    print("masts_new", sum(1 for m in d["masts"] if m["variant"] not in ("potential", "potential_jh")))
    print("summary_lv", sum(1 for s in d["summary"] if s["type"] in ("lee", "valley") and s["n"] > 0
                            and s["ref_kind"] == "picard_nom"))


def rotor(d):
    print("rows_menke", sum(1 for r in d["rows"] if r.get("L_menke") is not None))
    print("rows_cases", len({r["case"] for r in d["rows"]}))
    print("ridges", len(d["ridges"]))


def timing(d):
    print("rows", len(d["rows"]))
    print("windows", len({r["window_dx"] for r in d["rows"]}))
    print("stages", len({r["stage"] for r in d["rows"]}))


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("ground", "rotor", "timing"):
        print(__doc__)
        sys.exit(2)
    {"ground": ground, "rotor": rotor, "timing": timing}[sys.argv[1]](load(sys.argv[2]))
