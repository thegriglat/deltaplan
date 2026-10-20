#!/usr/bin/env python3
"""Контрактный тест модуля spin-recovery: заголовки SR-К1..К3, форма runs.jsonl и summary.json (SR-К2), разделы SR-К3.

Запуск: python3 tools/research/spin_recovery/contract_check.py [<out-каталог задачи> | <summary.json> ...]
Без аргументов — только заголовки контракта и разделы документа. Код выхода 0 — PASS.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CONTRACT = ROOT / "docs/contracts/spin-recovery.md"
DOC = ROOT / "docs/research/pendulum/spin-recovery.md"
VERSIONS = {"SR-К1": 2, "SR-К2": 1, "SR-К3": 1}
TAG = f"SR-К2 v{VERSIONS['SR-К2']}"
SECTIONS = (
    "## Гипотеза 0 — ввод и руки (SR-1)",
    "## Стенд и база (SR-2)",
    "## Гипотеза 1 — крутка (SR-2)",
    "## Гипотеза 3 — sport против laminar (SR-2)",
    "## Гипотеза 2 — упоры концов (SR-3)",
    "## Гипотеза 4 — C_L max концов (SR-3)",
)
NUM = (int, float)
# ключ: (типы, допускается null)
ROW = {
    "contract": ((str,), False), "task": ((str,), False), "wing": ((str,), False),
    "variant": ((str,), False), "mode": ((str,), False), "dt": (NUM, False),
    "trim_kmh": (NUM, False), "first": ((str,), False),
    "spin_yaw_dps": (NUM, True), "spin_bank_max_deg": (NUM, True), "spin_sink_max_ms": (NUM, True),
    "recovered": ((bool,), False), "recover_s": (NUM, True), "loss_m": (NUM, True),
    "after_bank_max_deg": (NUM, True), "after_stall_s": (NUM, True), "finite": ((bool,), False),
}
REQ_WINGS = ("sport", "laminar", "training")
REQ_MODES = ("release", "standard")
REQ_MODES_V2 = ("pull_release",)  # SR-К1 v2; SR-1 начата по v1


def check_headers(errors):
    text = CONTRACT.read_text(encoding="utf-8")
    found = {m.group(1): int(m.group(2))
             for m in re.finditer(r"(?m)^## (SR-К\d)\. .* \(v(\d+)\)\s*$", text)}
    for cid, ver in VERSIONS.items():
        if found.get(cid) != ver:
            errors.append(f"контракт: {cid} v{ver} не найден (есть {found.get(cid)})")
    if not DOC.exists():
        errors.append(f"нет {DOC.relative_to(ROOT)}")
        return
    lines = set(DOC.read_text(encoding="utf-8").splitlines())
    for s in SECTIONS:
        if s not in lines:
            errors.append(f"документ: нет раздела «{s}» (SR-К3)")


def check_row(r, where, errors, extra_ok):
    if r.get("contract") != TAG:
        errors.append(f"{where}: contract {r.get('contract')!r} ≠ {TAG!r}")
    for k, (types, nullable) in ROW.items():
        if k not in r:
            errors.append(f"{where}: нет ключа {k}")
            continue
        v = r[k]
        if v is None:
            if not nullable:
                errors.append(f"{where}: {k} = null")
            continue
        if isinstance(v, bool) and bool not in types:
            errors.append(f"{where}: {k} — bool вместо числа")
        elif not isinstance(v, types):
            errors.append(f"{where}: {k} тип {type(v).__name__}")
    if r.get("recovered") is True and (r.get("recover_s") is None or r.get("loss_m") is None):
        errors.append(f"{where}: recovered без recover_s/loss_m")
    if r.get("recovered") is False and (r.get("recover_s") is not None or r.get("loss_m") is not None):
        errors.append(f"{where}: нет выхода, а recover_s/loss_m заданы")
    extra = set(r) - set(ROW) - ({"extra"} if extra_ok else set())
    if extra:
        errors.append(f"{where}: лишние ключи {sorted(extra)}")


def check_dir(d, errors):
    summ = d / "summary.json"
    runs = d / "runs.jsonl"
    for p in (summ, runs, d / "tables.md"):
        if not p.exists():
            errors.append(f"нет {p}")
    if not summ.exists():
        return
    s = json.loads(summ.read_text(encoding="utf-8"))
    pre = f"{summ}:"
    if s.get("contract") != TAG:
        errors.append(f"{pre} contract {s.get('contract')!r}")
    for k, t in (("task", str), ("commit", str), ("cmd", list), ("variants", dict), ("rows", list)):
        if not isinstance(s.get(k), t):
            errors.append(f"{pre} {k} не {t.__name__}")
    rows = s.get("rows") or []
    for i, r in enumerate(rows):
        check_row(r, f"{pre} rows[{i}]", errors, extra_ok=False)
        if r.get("variant") not in (s.get("variants") or {}):
            errors.append(f"{pre} rows[{i}]: вариант {r.get('variant')!r} не описан в variants")
    have = {(r.get("wing"), r.get("mode")) for r in rows
            if r.get("variant") == "game" and abs(float(r.get("dt") or 0) - 1 / 120) < 1e-9}
    modes = REQ_MODES + (() if s.get("task") == "SR-1" else REQ_MODES_V2)
    for w in REQ_WINGS:
        for m in modes:
            if (w, m) not in have:
                errors.append(f"{pre} нет строки game/{w}/{m}/dt=1/120")
    if runs.exists():
        n = 0
        for i, line in enumerate(runs.read_text(encoding="utf-8").splitlines()):
            if not line.strip():
                continue
            n += 1
            try:
                r = json.loads(line)
            except json.JSONDecodeError as e:
                errors.append(f"{runs}:{i + 1}: {e}")
                continue
            check_row(r, f"{runs}:{i + 1}", errors, extra_ok=True)
        if n < len(rows):
            errors.append(f"{runs}: строк {n} < rows сводки {len(rows)}")


def main(argv):
    errors = []
    check_headers(errors)
    for a in argv:
        p = Path(a)
        check_dir(p.parent if p.name == "summary.json" else p, errors)
    for e in errors:
        print("FAIL", e)
    print("contract ok" if not errors else f"contract FAIL ({len(errors)})")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
