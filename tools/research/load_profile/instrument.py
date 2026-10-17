#!/usr/bin/env python3
"""Временная разметка временем (LP.t/LP.e) кода загрузки в копии — НЕ коммитить в main.

instrument.py <корень копии> [<файл спецификации>]  — применить (идемпотентно не проверяется:
применять к чистому дереву; откат — git checkout -- scripts scenes).
Спецификация — instrument_spec.py рядом: REGIONS = [(файл, метка, начало, якорь|None, конец|None)],
EXPRS = [(файл, старая подстрока, метка)] — выражение оборачивается в LP.w(метка, func(): return ...).
Начало/конец/якорь — префикс строки без отступа. Конец None — после оператора (скобки и блок).
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).with_name("instrument_spec.py")
ns: dict = {}
exec(spec_path.read_text(), ns)


def indent_of(s: str) -> str:
    return s[: len(s) - len(s.lstrip("\t "))]


def stmt_end(lines: list[str], i: int) -> int:
    """Индекс строки после оператора, начинающегося в i."""
    bal = 0
    j = i
    while True:
        code = re.sub(r'"(\\.|[^"\\])*"', '""', lines[j].split("#")[0])
        bal += code.count("(") + code.count("[") + code.count("{")
        bal -= code.count(")") + code.count("]") + code.count("}")
        j += 1
        if bal <= 0:
            break
    if lines[j - 1].split("#")[0].rstrip().endswith(":"):
        ind = len(indent_of(lines[i]))
        while j < len(lines) and (
            not lines[j].strip() or len(indent_of(lines[j])) > ind
        ):
            j += 1
        while not lines[j - 1].strip():
            j -= 1
        if j < len(lines) and len(indent_of(lines[j])) == ind and re.match(r"(elif\b|else\s*:)", lines[j].strip()):
            return stmt_end(lines, j)
    return j


def find(lines: list[str], prefix: str, start: int) -> int:
    for k in range(start, len(lines)):
        if lines[k].strip().startswith(prefix):
            return k
    raise SystemExit(f"не найдено: {prefix!r} после строки {start}")


files: dict[str, list[str]] = {}
n = 0
for f, label, start, anchor, end in ns["REGIONS"]:
    lines = files.setdefault(f, (root / f).read_text().split("\n"))
    a = find(lines, anchor, 0) if anchor else 0
    s = find(lines, start, a)
    e = find(lines, end, s + 1) if end else stmt_end(lines, s)
    var = f"_lp{n}"
    n += 1
    ind_s = indent_of(lines[s])
    ind_e = indent_of(lines[e]) if end else ind_s
    lines.insert(e, f'{ind_e}LP.e("{label}", {var})')
    lines.insert(s, f"{ind_s}var {var} := LP.t()")
for f, old, label in ns.get("EXPRS", []):
    lines = files.setdefault(f, (root / f).read_text().split("\n"))
    text = "\n".join(lines)
    if text.count(old) != 1:
        raise SystemExit(f"{f}: {old!r} встречается {text.count(old)} раз")
    text = text.replace(old, f'LP.w("{label}", func(): return {old})')
    files[f] = text.split("\n")
for f, old, new in ns.get("RAW", []):
    lines = files.setdefault(f, (root / f).read_text().split("\n"))
    text = "\n".join(lines)
    if text.count(old) != 1:
        raise SystemExit(f"{f}: RAW {old[:60]!r} встречается {text.count(old)} раз")
    files[f] = text.replace(old, new).split("\n")
import shutil
tmp = root / "tools" / "lp_tmp"  # tools/research — под .gdignore; временные скрипты — сюда
tmp.mkdir(exist_ok=True)
here = Path(__file__).parent
for name in ("lp.gd", "probe.gd", "probe.tscn"):
    shutil.copy(here / name, tmp / name)
for f, lines in files.items():
    (root / f).write_text("\n".join(lines))
    print("размечен", f)
