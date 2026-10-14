#!/usr/bin/env python3
"""Быстрая проверка .gd: разбор/типы изменённых файлов в контексте проекта (хук pre-commit).

    tools/check_gd.py [--changed] [--timeout С] [файлы…]

Без файлов — .gd из индекса (что войдёт в коммит); --changed — изменённые против HEAD и новые.
Грузит файлы через tools/check/gd_check.gd под godot --headless. Коды выхода: 0 ок, 1 ошибки разбора, 2 аргументы.
Только stdlib.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def die(msg, code=1):
    print(f"check_gd: {msg}", file=sys.stderr)
    sys.exit(code)


def git(*args, cwd=None):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def toplevel():
    t = git("rev-parse", "--show-toplevel")
    if not t:
        die("не в рабочей копии git")
    return Path(t)


def gd_check_paths(a, top):
    if a.paths:
        return [str(Path(x).resolve().relative_to(top)) for x in a.paths]
    if a.changed:  # рабочая копия против HEAD + новые неотслеживаемые
        out = git("diff", "--name-only", "--diff-filter=ACMR", "HEAD") + "\n" + git("ls-files", "--others", "--exclude-standard")
    else:  # индекс (то, что войдёт в коммит; при git commit -- пути — временный индекс)
        out = git("diff", "--cached", "--name-only", "--diff-filter=ACMR")
    return sorted({x for x in out.splitlines() if x.endswith(".gd")})


def cmd_check_gd(a):
    top = toplevel()
    files = [f for f in gd_check_paths(a, top) if f != "tools/check/gd_check.gd"]  # сам себя грузит — зависает
    if not files:
        print("check_gd: нет изменённых .gd")
        return
    cache = top / ".godot/global_script_class_cache.cfg"
    if not cache.exists():  # без кэша глобальных class_name — сплошь ложные ошибки; полный импорт долгий
        print("check_gd: нет .godot (копия не импортирована) — пропуск; сначала godot --headless --path . --import")
        return
    xdg = tempfile.mkdtemp(prefix="dp-gdcheck-")
    clean = subprocess.run(["git", "diff", "--quiet", "--", "project.godot"], cwd=top).returncode == 0
    t0 = time.time()
    known = set(re.findall(r'&"(\w+)"', cache.read_text(errors="replace")))
    new_cls = {m for f in files for m in re.findall(r"^class_name\s+(\w+)", (top / f).read_text(errors="replace"), re.M)} - known
    try:
        if new_cls:  # новый class_name — обновить кэш (~10 с)
            print(f"check_gd: новые class_name {', '.join(sorted(new_cls))} — обновляю кэш (--import)")
            subprocess.run(["godot", "--headless", "--path", str(top), "--import"], cwd=top, capture_output=True,
                           env=dict(os.environ, XDG_DATA_HOME=xdg), timeout=a.timeout)
        r = subprocess.run(["godot", "--headless", "--path", str(top), "-s", "res://tools/check/gd_check.gd", "--",
                            *[f"res://{f}" for f in files]], cwd=top, capture_output=True, text=True,
                           env=dict(os.environ, XDG_DATA_HOME=xdg), timeout=a.timeout)
    except subprocess.TimeoutExpired:
        die(f"godot не уложился в {a.timeout} с")
    finally:
        shutil.rmtree(xdg, ignore_errors=True)
        if clean:
            subprocess.run(["git", "checkout", "--", "project.godot"], cwd=top, capture_output=True)
    errs, last = [], None
    for ln in (r.stdout + r.stderr).splitlines():
        if ln.startswith("SCRIPT ERROR:"):
            last = ln[len("SCRIPT ERROR:"):].strip()
        elif last and (m := re.search(r"\((res://[^)]+:\d+)\)", ln)) and "tools/check/gd_check.gd" not in m.group(1):
            errs.append(f"{m.group(1)[6:]}: {last}"); last = None
        elif ln.startswith("ERROR: Failed to load script"):
            if last: errs.append(last); last = None
            errs.append(ln[7:])
    errs = list(dict.fromkeys(errs))
    for e in errs:
        print(e)
    print(f"check_gd: {len(files)} файл(ов), {time.time() - t0:.1f} с — " + (f"ОШИБКИ: {len(errs)}" if errs else "ок"))
    if errs:
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(prog="check_gd.py", description="Разбор/типы изменённых .gd в контексте проекта (хук pre-commit).")
    p.add_argument("paths", nargs="*", help="файлы; без них — .gd из индекса (что войдёт в коммит)")
    p.add_argument("--changed", action="store_true", help="вместо индекса — изменённые против HEAD и новые")
    p.add_argument("--timeout", type=int, default=120)
    cmd_check_gd(p.parse_args())


if __name__ == "__main__":
    main()
