#!/usr/bin/env python3
"""Контрактный тест модуля pendulum-body-vg: заголовки PB-К1/PB-К2 и форма сводки PB-К2.

Запуск: python3 tools/research/pendulum/pb_contract_check.py <summary.json> [...]
Без аргументов — только заголовки контракта. Код выхода 0 — PASS.
"""
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CONTRACT = ROOT / "docs/contracts/pendulum-body-vg.md"
VERSIONS = {"PB-К1": 1, "PB-К2": 1}
WINGS = ("training", "laminar", "sport")
METRICS = (
    "clp", "cnp", "cn_beta", "cl_beta", "cy_beta", "cnr", "clr",
    "dutch_omega_rad_s", "dutch_zeta",
    "reversal_45_s", "reversal_30_s", "reversal_beta_max_deg",
    "turn30_beta_cg_deg", "turn30_ribbon_deg", "ochi_bank_7s_deg",
    "turb_capsize_n", "turb_runs_n",
    "trim_kmh", "sink_ms", "full_pull_kmh",
)
REQUIRED_VARIANTS = {"PB-1": ("base", "body"), "PB-2": ("base", "vg0", "vg05", "vg1")}


def check_headers(errors):
    text = CONTRACT.read_text(encoding="utf-8")
    found = {m.group(1): int(m.group(2))
             for m in re.finditer(r"(?m)^## (PB-К\d)\. .* \(v(\d+)\)\s*$", text)}
    for cid, ver in VERSIONS.items():
        if found.get(cid) != ver:
            errors.append(f"контракт: {cid} v{ver} не найден (есть {found.get(cid)})")


def check_summary(path, errors):
    d = json.loads(Path(path).read_text(encoding="utf-8"))
    pre = f"{path}:"
    if d.get("contract") != f"PB-К2 v{VERSIONS['PB-К2']}":
        errors.append(f"{pre} contract = {d.get('contract')!r}")
    task = d.get("task")
    if task not in REQUIRED_VARIANTS:
        errors.append(f"{pre} task = {task!r}")
        return
    variants = d.get("variants") or {}
    notes = d.get("notes") or {}
    for v in REQUIRED_VARIANTS[task]:
        if v not in variants:
            errors.append(f"{pre} нет варианта {v}")
    for vname, var in variants.items():
        wings = var.get("wings") or {}
        for w in WINGS:
            if w not in wings:
                errors.append(f"{pre} {vname}: нет крыла {w}")
        for w, m in wings.items():
            for k in METRICS:
                if k not in m:
                    errors.append(f"{pre} {vname}/{w}: нет {k}")
                    continue
                x = m[k]
                if x is None:
                    if not any(key in notes for key in (k, vname, f"{vname}/{w}", f"{vname}/{w}/{k}")):
                        errors.append(f"{pre} {vname}/{w}/{k} = null без причины в notes")
                elif not (isinstance(x, (int, float)) and math.isfinite(x)):
                    errors.append(f"{pre} {vname}/{w}/{k} не число: {x!r}")
    if not d.get("sources"):
        errors.append(f"{pre} пустой sources")
    if not d.get("reproduce"):
        errors.append(f"{pre} пустой reproduce")
    if task == "PB-2" and not d.get("passport"):
        errors.append(f"{pre} PB-2 без passport")


def main(argv):
    errors = []
    check_headers(errors)
    for p in argv:
        try:
            check_summary(p, errors)
        except (OSError, ValueError) as e:
            errors.append(f"{p}: {e}")
    for e in errors:
        print("FAIL", e)
    print("PASS" if not errors else f"FAIL {len(errors)}")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
