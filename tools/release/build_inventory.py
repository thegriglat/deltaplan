#!/usr/bin/env python3
"""Инвентарь сборки Deltaplan (контракт SA-К1 v1, docs/contracts/steam-assets.md).

    tools/release/build_inventory.py [--preset Linux|Windows|macOS|all] [--out DIR] [--check]
                                     [--mode debug|release] [--root DIR]

Что делает: перечисляет файлы проекта, которые экспорт Godot кладёт в .pck (эмуляция export_filter /
include_filter / exclude_filter из export_presets.cfg, каталогов с .gdignore, импорта ресурсов), файлы
рядом с исполняемым файлом (то, что кладёт экспорт GDExtension и копирует tools/build.sh) и движок.
К каждому файлу подбирает строку ASSETS.md по шаблонам колонки «Файл» (SA-К3) и считает лицензию,
commercial_ok и attribution. Пишет DIR/<preset>.json (по умолчанию build/inventory/). Только стандартная
библиотека Python, без сети и GPU.

Один `item` = один исходный файл проекта. Импортируемые ресурсы (png, ogg, glb, ttf …) в .pck лежат в
виде .godot/imported/*, рядом лежит `<файл>.import`; скрипты — как .gdc + .remap: всё это относится к
одному item исходного файла (`bytes` — размер исходного файла на диске; для рядом-с-exe — размер файла).
Сверка эмуляции с настоящим `--export-pack`: tools/research/steam_license/compare_pck.py.

Коды выхода: 0 — готово (и, с --check, всё покрыто); 1 — --check нашёл непокрытые файлы или commercial_ok != true.
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PRESETS = ("Linux", "Windows", "macOS")

# --- Собственные файлы проекта («own», лицензия MIT (own)) -----------------------------------------------
# Шаблоны путей от корня проекта (fnmatch, `*` пересекает `/`). Под addons/ (сторонние аддоны) правила по
# расширениям не действуют — только явно перечисленные собственные расширения.
OWN_PATTERNS = [
    "*.gd", "*.gdshader", "*.gdshaderinc", "*.glsl", "*.tscn", "*.tres",  # код, шейдеры, сцены
    "configs/*", "locale/*", "scenes/*", "scripts/*",                      # настройки, переводы, код игры
    "project.godot", "ASSETS.md", "assets/sounds/LICENSES.md",              # проект и таблица лицензий
    "data/build_info.json",                                                 # сведения о сборке
]
# Тексты лицензий сторонних материалов рядом с ними (не материалы сами по себе).
LICENSE_TEXT_PATTERNS = ["assets/fonts/*.txt", "addons/*/LICENSE*"]
# Файлы, которые Godot создаёт сам при экспорте.
GODOT_GENERATED = ["project.binary", ".godot/extension_list.cfg", ".godot/global_script_class_cache.cfg",
                   ".godot/uid_cache.bin"]
# Расширения, которые Godot экспортирует как ресурсы без .import (export_filter=all_resources); остальные
# неимпортируемые файлы попадают в .pck только по include_filter.
RESOURCE_EXT = {".ico", ".json", ".gd", ".tscn", ".tres", ".gdshader", ".gdshaderinc", ".res", ".scn", ".gdextension"}

NEG = re.compile(r"\bnc\b|некоммерч|non-commercial|personal|личн", re.I)
POS = re.compile(r"cc0|cc[- ]?by|\bofl\b|\bmit\b|bsd|apache|odbl|copernicus|собственн|microsoft software license", re.I)
ATTR = re.compile(r"cc[- ]?by|odbl|\bofl\b|\bmit\b|bsd|apache|copernicus|атрибуц|microsoft software license", re.I)


# --- export_presets.cfg ---------------------------------------------------------------------------------
def parse_presets(root):
    res, cur = {}, None
    with open(os.path.join(root, "export_presets.cfg"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            m = re.match(r"\[preset\.(\d+)\]$", line)
            if m:
                cur = {"options": {}}
                res[int(m.group(1))] = cur
                continue
            m = re.match(r"\[preset\.(\d+)\.options\]$", line)
            if m:
                cur = res[int(m.group(1))]["options"]
                continue
            m = re.match(r'([\w/]+)=(.*)$', line)
            if m and cur is not None:
                v = m.group(2).strip()
                cur[m.group(1)] = v[1:-1] if v.startswith('"') and v.endswith('"') else v
    return {p["name"]: p for p in res.values()}


def filters(s):
    return [x.strip() for x in s.split(",") if x.strip()]


def fmatch(path, pats):
    p = path.lower()
    return any(fnmatch.fnmatchcase(p, g.lower()) for g in pats)


# --- Файлы проекта ---------------------------------------------------------------------------------------
def read_import(root, rel):
    """.import рядом с файлом: (importer, [dest_files без res://]) или None."""
    p = os.path.join(root, rel + ".import")
    if not os.path.isfile(p):
        return None
    txt = open(p, encoding="utf-8", errors="replace").read()
    m = re.search(r'^importer="([^"]*)"', txt, re.M)
    d = re.search(r"^dest_files=\[(.*?)\]", txt, re.M)
    dests = [x.replace("res://", "") for x in re.findall(r'"([^"]+)"', d.group(1))] if d else []
    return (m.group(1) if m else ""), dests


def walk_project(root, exclude):
    """Все не скрытые файлы проекта вне каталогов с .gdignore и вне exclude_filter (относительные пути, /)."""
    out = []
    for dp, dns, fns in os.walk(root):
        rel = os.path.relpath(dp, root).replace(os.sep, "/")
        rel = "" if rel == "." else rel
        keep = []
        for d in sorted(dns):
            if d.startswith("."):
                continue
            sub = (rel + "/" + d) if rel else d
            if os.path.exists(os.path.join(dp, d, ".gdignore")) or fmatch(sub + "/", exclude):
                continue
            keep.append(d)
        dns[:] = keep
        for fn in sorted(fns):
            if fn.startswith("."):
                continue
            r = (rel + "/" + fn) if rel else fn
            if not fmatch(r, exclude):
                out.append(r)
    return out


def project_sources(root, preset):
    """Файлы проекта, попадающие в .pck: {путь: {'bytes', 'imported'}} (исходные пути)."""
    inc, exc = filters(preset["include_filter"]), filters(preset["exclude_filter"])
    res = {}
    icon = preset["options"].get("application/icon", "").replace("res://", "")
    for r in walk_project(root, exc):
        if r.endswith(".import"):
            continue
        ext = os.path.splitext(r)[1].lower()
        imp = read_import(root, r)
        take = False
        if imp is not None:
            take = imp[0] != "skip"
        elif ext in RESOURCE_EXT or fmatch(r, inc) or r == icon:
            take = True
        if take:
            res[r] = {"bytes": os.path.getsize(os.path.join(root, r)), "imported": imp is not None}
    return res


# --- Файлы рядом с exe и движок --------------------------------------------------------------------------
def parse_gdextension(root, rel):
    """Библиотеки и зависимости .gdextension: [(ключ платформы, [пути от res://])]."""
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        return {}
    base = os.path.dirname(rel)
    libs, section = {}, None
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if line.startswith("["):
            section = line.strip("[]")
            continue
        if line.startswith(";") or "=" not in line:
            continue
        k, v = [x.strip() for x in line.split("=", 1)]
        if section == "libraries":
            libs.setdefault(k, []).append(os.path.normpath(os.path.join(base, v.strip('"'))).replace(os.sep, "/"))
        elif section == "dependencies":
            for dep in re.findall(r'"([^"]+)"\s*:', v):
                libs.setdefault(k, []).append(os.path.normpath(os.path.join(base, dep)).replace(os.sep, "/"))
    return libs


def beside_exe(root, name, mode):
    """[(показываемый путь, путь в проекте для сопоставления с ASSETS.md, размер)]."""
    out = []

    def add(shown, src):
        p = os.path.join(root, src)
        out.append((shown, src, os.path.getsize(p) if os.path.isfile(p) else 0, os.path.isfile(p)))

    # tools/build.sh: cp -r configs build/<платформа>/configs (кроме macOS: внутри .app ломает подпись)
    if name != "macOS":
        for dp, _, fns in os.walk(os.path.join(root, "configs")):
            for fn in sorted(fns):
                src = os.path.relpath(os.path.join(dp, fn), root).replace(os.sep, "/")
                add("<exe>/" + src, src)
    plat = {"Linux": "linux.x86_64", "Windows": "windows.x86_64"}.get(name)
    if name == "Linux":
        out.append(("<exe>/deltaplan.sh", "<godot-generated>", 123, True))
    return out


def engine_size(name, mode):
    tdir = os.path.expanduser("~/.local/share/godot/export_templates/4.7.2.stable")
    f = {"Linux": "linux_%s.x86_64", "Windows": "windows_%s_x86_64.exe", "macOS": "macos.zip"}[name]
    p = os.path.join(tdir, f % mode if "%s" in f else f)
    return os.path.getsize(p) if os.path.isfile(p) else 0


# --- ASSETS.md (SA-К3) -----------------------------------------------------------------------------------
def parse_assets(path):
    """[{'section', 'in_build', 'cells': [5], 'line'}] — строки таблиц ASSETS.md."""
    rows, title, hdr = [], "", False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if line.startswith("## "):
            title, hdr = line[3:].strip(), False
            continue
        if not line.startswith("|"):
            hdr = False
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if not hdr:
            hdr = True
            continue
        if all(re.fullmatch(r":?-+:?", c) for c in cells):
            continue
        rows.append({"section": title, "in_build": "не вход" not in title.lower(), "cells": cells, "line": n})
    return rows


def token_regex(tok):
    """Шаблон SA-К3 -> регулярное выражение (или None, если токен не путь)."""
    if tok.startswith("user://") or tok.startswith("$"):
        return None
    if "/" not in tok and not re.search(r"\.\w{1,6}$", tok) and tok not in ("engine", "<engine>"):
        return None
    t = tok.strip()
    out, i = "", 0
    while i < len(t):
        m = re.match(r"(\d+)…(\d+)", t[i:])
        if m:
            a, b = m.group(1), m.group(2)
            out += "(?:" + "|".join(str(k).zfill(len(a)) for k in range(int(a), int(b) + 1)) + ")"
            i += m.end()
            continue
        c = t[i]
        if c == "{":
            j = t.index("}", i)
            out += "(?:" + "|".join(re.escape(x) for x in t[i + 1:j].split(",")) + ")"
            i = j + 1
        elif t.startswith("<exe>", i):  # SA-К3 v2: буквальный префикс «файл рядом с exe», не сегмент пути
            out += re.escape("<exe>")
            i += 5
        elif c == "<":
            j = t.index(">", i)
            out += "[^/]+"
            i = j + 1
        elif c == "*":
            out += "[^/]*"
            i += 1
        else:
            out += re.escape(c)
            i += 1
    if t.endswith("/"):
        out += ".*"
    elif t.endswith("/*"):  # «каталог/*» — всё внутри, в том числе во вложенных каталогах
        out = out[: -len("[^/]*")] + ".*"
    return re.compile(out + r"\Z")


def row_patterns(row):
    """Регулярные выражения строки: токены колонки «Файл»; «a/b/x.ogg, y.ogg» — y.ogg в каталоге a/b."""
    pats, last_dir = [], ""
    for tok in re.findall(r"`([^`]+)`", row["cells"][0] if row["cells"] else ""):
        for part in [x.strip() for x in tok.split(", ")] if ", " in tok and "{" not in tok else [tok]:
            if "/" in part:
                last_dir = part.rsplit("/", 1)[0] + "/"
            elif last_dir and re.search(r"\.\w{1,6}$", part):
                part = last_dir + part
            rx = token_regex(part)
            if rx:
                pats.append((rx, len(part)))
    return pats


def build_matcher(rows):
    comp = []
    for r in rows:
        for rx, n in row_patterns(r):
            comp.append((rx, n, r))

    def match(path):
        best = None
        for rx, n, r in comp:
            if rx.match(path) and (best is None or n > best[0]):
                best = (n, r)
        return best[1] if best else None
    return match


def judge(license_text):
    """(commercial_ok, attribution) по колонке «Лицензия» (SA-К1)."""
    t = license_text.strip()
    if NEG.search(t):
        ok = False
    elif t in ("—", "-") or POS.search(t):
        ok = True
    else:
        ok = None
    return ok, bool(ATTR.search(t)) and t not in ("—", "-")


# --- Сборка инвентаря ------------------------------------------------------------------------------------
def git_commit(root):
    try:
        return subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def is_own(path):
    if path.startswith("addons/"):
        return False
    return fmatch(path, OWN_PATTERNS)


def make_item(path, kind, nbytes, src, matcher):
    """src — путь в проекте для сопоставления с ASSETS.md."""
    it = {"path": path, "kind": kind, "bytes": nbytes, "assets_md": None, "license": None,
          "commercial_ok": None, "attribution": False, "group": group_of(src)}
    if src == "<godot-generated>" or src in GODOT_GENERATED:
        it.update(assets_md="own", license="MIT (own)", commercial_ok=True)
        return it
    row = matcher(path) if path.startswith("<exe>/") else None  # SA-К3 v2: сначала шаблоны <exe>/<имя>
    row = row or matcher(src)
    if row is not None:
        lic = row["cells"][3] if len(row["cells"]) > 3 else ""
        ok, at = judge(lic)
        it.update(assets_md=row["section"], license=lic, commercial_ok=ok, attribution=at)
        if not row["in_build"]:
            it["note"] = "строка в разделе «не входит в игру», а файл — в сборке"
        return it
    if is_own(src):
        it.update(assets_md="own", license="MIT (own)", commercial_ok=True)
    elif fmatch(src, LICENSE_TEXT_PATTERNS):
        it.update(assets_md="own", license="текст лицензии стороннего материала", commercial_ok=True)
    return it


def group_of(src):
    parts = src.split("/")
    if src.startswith("<"):
        return src
    if parts[0] in ("assets", "data", "addons", "configs") and len(parts) > 2:
        return "/".join(parts[:2])
    return parts[0] if len(parts) > 1 else "(корень)"


def inventory(root, name, mode, assets_rows):
    presets = parse_presets(root)
    preset = presets[name]
    matcher = build_matcher(assets_rows)
    items = []
    for src, info in sorted(project_sources(root, preset).items()):
        items.append(make_item("res://" + src, "pck", info["bytes"], src, matcher))
    for g in GODOT_GENERATED:
        items.append(make_item("res://" + g, "pck", 0, g, matcher))
    for shown, src, size, exists in beside_exe(root, name, mode):
        it = make_item(shown, "beside_exe", size, src, matcher)
        if not exists:
            it["note"] = "файла нет в рабочей копии"
        items.append(it)
    eng = make_item("engine", "engine", engine_size(name, mode), "engine", matcher)
    if eng["assets_md"] is None:
        eng["note"] = "шаблон экспорта Godot 4.7.2 (MIT + сторонние компоненты, COPYRIGHT.txt)"
    items.append(eng)
    # инвариант SA-К1: путь встречается один раз
    seen = {}
    for it in items:
        key = (it["kind"], it["path"])
        assert key not in seen, "дубль " + str(key)
        seen[key] = 1
    return {"version": 1, "preset": name, "commit": git_commit(root), "items": items}


def check(inv):
    bad = []
    for it in inv["items"]:
        if it["assets_md"] is None or it["commercial_ok"] is not True:
            bad.append(it)
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--preset", default="all", choices=list(PRESETS) + ["all"])
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "inventory"))
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--mode", default="debug", choices=["debug", "release"],
                    help="режим экспорта tools/build.sh (debug по умолчанию): какой шаблон движка")
    ap.add_argument("--root", default=ROOT)
    a = ap.parse_args()
    rows = parse_assets(os.path.join(a.root, "ASSETS.md"))
    os.makedirs(a.out, exist_ok=True)
    rc, tot_files, tot_bytes = 0, 0, 0
    for name in (PRESETS if a.preset == "all" else (a.preset,)):
        inv = inventory(a.root, name, a.mode, rows)
        with open(os.path.join(a.out, name + ".json"), "w", encoding="utf-8") as f:
            json.dump(inv, f, ensure_ascii=False, indent=1)
        n, b = len(inv["items"]), sum(i["bytes"] for i in inv["items"])
        bad = check(inv)
        print(f"{name}: файлов {n}, байт {b}, без строки ASSETS.md {sum(1 for i in bad if i['assets_md'] is None)}, "
              f"commercial_ok != true {sum(1 for i in bad if i['assets_md'] is not None)}")
        tot_files, tot_bytes = tot_files + n, tot_bytes + b
        if a.check and bad:
            rc = 1
            groups = {}
            for i in bad:
                groups.setdefault((i["assets_md"] or "—", i["group"]), []).append(i["path"])
            for (sec, g), ps in sorted(groups.items()):
                print(f"  [{name}] {g}: {len(ps)} (напр. {ps[0]}), ASSETS.md: {sec}")
    if a.check and rc == 0:
        print(f"INVENTORY OK files={tot_files} bytes={tot_bytes}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
