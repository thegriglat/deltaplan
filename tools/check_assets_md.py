#!/usr/bin/env python3
"""Сверка ASSETS.md с реальными файлами в assets/ и data/.

Печатает:
  - файлы в assets/**, data/** без строки в ASSETS.md ("пропуски");
  - строки/паттерны ASSETS.md, не указывающие ни на один реальный файл ("висячие").

Разбор ASSETS.md — эвристический (Markdown-таблицы с путями в backtick'ах),
не полноценный парсер: рассчитан на этот конкретный файл, не на произвольный ввод.

Запуск: python3 tools/check_assets_md.py [--verbose]
Код возврата: 0 — пропусков и висячих строк нет; 1 — есть.
"""
from __future__ import annotations

import fnmatch
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS_MD = ROOT / "ASSETS.md"

SCAN_DIRS = ["assets", "data"]

# Какие расширения считаем "ассетами", подлежащими сверке.
INCLUDE_EXT = {
    ".glb", ".tres", ".ttf", ".otf", ".ogg", ".wav", ".png", ".jpg", ".jpeg",
    ".json", ".gz", ".blend", ".gdshader",
}

# Каталоги/файлы, заведомо вне области ASSETS.md (явно оговорено в самом файле
# или в карточке задачи — не игровые ассеты, а служебные данные).
EXCLUDE_PREFIXES = [
    "data/terrain/reference/",  # весь каталог помечен в ASSETS.md "не входят в игру"
    "assets/sounds/LICENSES.md",  # отдельный файл атрибуций (владение группы sounds)
]

BACKTICK_RE = re.compile(r"`([^`]+)`")
BRACE_RE = re.compile(r"\{([^{}]+)\}")
RANGE_RE = re.compile(r"(\d+)[…–-](\d+)")
KNOWN_EXTS = tuple(INCLUDE_EXT)

# Состояние "текущий каталог" сохраняется МЕЖДУ отдельными backtick-спанами одной
# ячейки таблицы, т.к. в ASSETS.md список файлов часто пишут как
# `dir/a.ext`, `b.ext`, `c.ext` — каждое имя в своих backtick'ах.
_cur_dir = ""


def split_commas_respecting_braces(s: str) -> list[str]:
    parts = []
    depth = 0
    cur = []
    for ch in s:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [p.strip() for p in parts]


def expand_braces(s: str) -> list[str]:
    m = BRACE_RE.search(s)
    if not m:
        return [s]
    out = []
    for opt in m.group(1).split(","):
        out.extend(expand_braces(s[: m.start()] + opt.strip() + s[m.end() :]))
    return out


def expand_ranges(s: str) -> str:
    """«creak_01…06.ogg» → «creak_[0-9][0-9].ogg» (glob по ширине первого числа)."""
    def repl(m: re.Match) -> str:
        width = len(m.group(1))
        return "[0-9]" * width

    return RANGE_RE.sub(repl, s)


def is_path_like(tok: str) -> bool:
    if "assets/" in tok or "data/" in tok:
        return True
    stripped = tok.rstrip("/").lower()
    return stripped.endswith(KNOWN_EXTS)


def extract_patterns(md_text: str) -> tuple[list[str], list[str]]:
    """Возвращает (glob-паттерны файлов, префиксы каталогов) из ASSETS.md."""
    global _cur_dir
    patterns: list[str] = []
    dir_prefixes: list[str] = []
    _cur_dir = ""
    # Обрабатываем построчно: контекст каталога не должен «перетекать» между
    # разными строками таблицы (разными файлами/разделами).
    for line in md_text.splitlines():
        _cur_dir = ""  # каталог-контекст не «перетекает» между строками таблицы
        if "|" not in line:
            continue
        for span in BACKTICK_RE.findall(line):
            span = span.strip()
            if not is_path_like(span):
                continue
            for p in split_commas_respecting_braces(span):
                p = p.replace("<локация>", "*")
                if not p:
                    continue
                if p.startswith("…/"):
                    # «…/power_*.blend» — по соглашению этого файла: исходники (.blend)
                    # лежат в assets/source/<то же поддерево>, а не рядом с .glb
                    src_dir = _cur_dir.replace("assets/models/", "assets/source/", 1)
                    p = src_dir + p[2:]
                if p.endswith("/"):
                    dir_prefixes.append(p if p.startswith(("assets/", "data/")) else _cur_dir + p)
                    continue
                if "/" in p:
                    _cur_dir = p.rsplit("/", 1)[0] + "/"
                    full = p
                elif "*" in p:
                    # голый glob-паттерн («glider_*_sail.png») описывает соглашение об
                    # именовании, а не конкретный каталог — не привязываем к cur_dir,
                    # иначе он «наследует» каталог случайно упомянутого рядом файла.
                    full = p
                else:
                    full = (_cur_dir + p) if _cur_dir else p
                full = expand_ranges(full)
                for expanded in expand_braces(full):
                    patterns.append(expanded)
    return patterns, dir_prefixes


def scan_real_files() -> list[Path]:
    files = []
    for d in SCAN_DIRS:
        base = ROOT / d
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if not p.is_file():
                continue
            if p.suffix.lower() not in INCLUDE_EXT:
                continue
            rel = p.relative_to(ROOT).as_posix()
            if any(rel.startswith(pref) or rel == pref for pref in EXCLUDE_PREFIXES):
                continue
            files.append(p)
    return files


def matches(rel: str, patterns: list[str], dir_prefixes: list[str]) -> bool:
    base = rel.rsplit("/", 1)[-1]
    for pref in dir_prefixes:
        if rel.startswith(pref):
            return True
    for pat in patterns:
        if "/" in pat:
            if fnmatch.fnmatch(rel, pat):
                return True
        else:
            if fnmatch.fnmatch(base, pat):
                return True
    return False


def main() -> int:
    verbose = "--verbose" in sys.argv
    md_text = ASSETS_MD.read_text(encoding="utf-8")
    patterns, dir_prefixes = extract_patterns(md_text)
    real_files = scan_real_files()

    missing = []
    for p in real_files:
        rel = p.relative_to(ROOT).as_posix()
        if not matches(rel, patterns, dir_prefixes):
            missing.append(rel)

    # Для проверки «висячих» строк ищем совпадения по всему репозиторию (не только
    # среди файлов из scan_real_files(), т.к. в ASSETS.md упоминаются и файлы вне
    # assets/, data/ — например scripts/terrain/*.gdshader).
    all_rel_files = {p.relative_to(ROOT).as_posix() for p in ROOT.rglob("*") if p.is_file()}
    is_glob = lambda s: any(c in s for c in "*?[")

    dangling = []
    for pat in patterns:
        if "/" not in pat:
            # голое имя файла — совпадение по базовому имени в любом каталоге
            if not any(fnmatch.fnmatch(r.rsplit("/", 1)[-1], pat) for r in all_rel_files):
                dangling.append(pat)
        elif is_glob(pat):
            if not any(fnmatch.fnmatch(r, pat) for r in all_rel_files):
                dangling.append(pat)
        else:
            if not (ROOT / pat).exists():
                dangling.append(pat)

    print(f"Пропуски (файлы без строки в ASSETS.md): {len(missing)}")
    if missing:
        for m in sorted(missing):
            print(f"  + {m}")

    print(f"Висячие строки (путь в ASSETS.md не найден на диске): {len(dangling)}")
    if dangling:
        for d in sorted(set(dangling)):
            print(f"  - {d}")

    if verbose:
        print(f"\n(паттернов извлечено: {len(patterns)}, каталогов-префиксов: {len(dir_prefixes)}, файлов просканировано: {len(real_files)})")

    return 1 if (missing or dangling) else 0


if __name__ == "__main__":
    raise SystemExit(main())
