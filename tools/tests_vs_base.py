#!/usr/bin/env python3
"""GDScript-тесты копии против базы (см. tools/tests_vs_base.sh).

Каждый файл tests/**/test_*.gd — отдельный процесс `godot --headless ... run_tests.tscn -- --file=...`
со своим временным XDG_DATA_HOME и таймаутом. Сравниваются множества падений «файл::тест»
(+ «файл::TIMEOUT» для таймаутов, «файл::не загрузился»). Результат базы кешируется по sha
(build/tests_base/<sha>[-<фильтр>].txt). Новые падения или таймауты → exit 1.

Граница: ignored-бинарники (addons/dp_air/bin) в временную базу берутся из копии, если есть, —
их собирают из копии, не из базы.
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

FAIL_RE = re.compile(r"^\s*FAIL (\S+)::(.+?)\s*$")
SUMMARY_RE = re.compile(r"(\d+) тестов, (\d+) упало")


def git(cwd, *args, check=True):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode:
        sys.exit(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def default_base(copy: Path) -> str:
    branch = git(copy, "branch", "--show-current", check=False)
    m = re.match(r"([^/]+)/", branch)
    if m:
        for cand in (f"feature/{m.group(1)}", "main"):
            if subprocess.run(["git", "rev-parse", "--verify", "-q", cand], cwd=copy,
                              capture_output=True).returncode == 0:
                return cand
    return "main"


def run_godot(path: Path, args, timeout, log: Path):
    """Запуск в своей группе процессов; по таймауту убивается вся группа (по PID, без pkill -f)."""
    prof = tempfile.mkdtemp(prefix="tvb-xdg-")
    env = dict(os.environ, XDG_DATA_HOME=prof)
    try:
        with open(log, "wb") as f:
            p = subprocess.Popen(["godot", "--headless", "--path", str(path), *args], env=env,
                                 stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                p.wait(timeout=timeout)
                return p.returncode, False
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, 9)
                except ProcessLookupError:
                    pass
                p.wait()
                return None, True
    finally:
        shutil.rmtree(prof, ignore_errors=True)


def run_side(name, path: Path, files, jobs, timeout, logroot: Path):
    logdir = logroot / name
    shutil.rmtree(logdir, ignore_errors=True)
    logdir.mkdir(parents=True)
    t0 = time.time()
    print(f"[{name}] импорт ресурсов…", flush=True)
    run_godot(path, ["--import"], 1800, logdir / "_import.log")
    # импорт переписывает project.godot — вернуть
    git(path, "checkout", "--", "project.godot", check=False)
    print(f"[{name}] {len(files)} файлов, -j {jobs}", flush=True)
    fails = set()
    done = [0]

    def one(rel, attempt=1):
        # второй заход (только для упавших файлов): таймаут ×1.5, лог *.retry.log
        log = logdir / (rel.replace("/", "__") + (".log" if attempt == 1 else ".retry.log"))
        code, timed_out = run_godot(path, ["res://tests/run_tests.tscn", "--", f"--file=res://{rel}"],
                                    timeout if attempt == 1 else int(timeout * 1.5), log)
        res = set()
        text = log.read_text(errors="replace")
        base = os.path.basename(rel)
        for line in text.splitlines():
            m = FAIL_RE.match(line)
            if m:
                res.add(f"{rel}::{m.group(2)}")
        if timed_out:
            res.add(f"{rel}::TIMEOUT")
        elif not SUMMARY_RE.search(text):
            # процесс умер без итога (краш/выход) — это падение файла, а не «0 падений»
            res.add(f"{rel}::НЕТ ИТОГА (код {code})")
        if attempt == 1:
            done[0] += 1
        if attempt == 1 and done[0] % 25 == 0:
            print(f"[{name}] {done[0]}/{len(files)}  {time.time() - t0:.0f} с", flush=True)
        return res

    with ThreadPoolExecutor(max_workers=jobs) as ex:
        first = dict(zip(files, ex.map(one, files)))
        # флейки (таймаут от нагрузки машины и т. п.): падение засчитывается, только если повторилось
        bad = [f for f in files if first[f]]
        if bad:
            print(f"[{name}] повтор {len(bad)} упавших файлов…", flush=True)
        for f, r2 in zip(bad, ex.map(lambda f: one(f, 2), bad)):
            stable = first[f] & r2
            for x in sorted(first[f] - r2):
                print(f"[{name}] флейк (при повторе прошёл): {x}", flush=True)
            fails |= stable
    print(f"[{name}] готово за {time.time() - t0:.0f} с, падений: {len(fails)}", flush=True)
    return fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base")
    ap.add_argument("--filter", default="")
    ap.add_argument("-j", type=int, default=8)
    ap.add_argument("--timeout-file", type=int, default=300)
    ap.add_argument("--copy", default=".")
    a = ap.parse_args()
    if a.filter.startswith("--filter="):
        a.filter = a.filter[9:]

    copy = Path(a.copy).resolve()
    base_ref = a.base or default_base(copy)
    base_sha = git(copy, "rev-parse", f"{base_ref}^{{commit}}")
    files = sorted(str(p.relative_to(copy)) for p in (copy / "tests").rglob("test_*.gd")
                   if a.filter in str(p.relative_to(copy)))
    if not files:
        sys.exit(f"нет файлов тестов по фильтру «{a.filter}»")

    logroot = copy / "build" / "tests_vs_base"
    cache_dir = copy / "build" / "tests_base"
    cache_dir.mkdir(parents=True, exist_ok=True)
    key = base_sha + (("-" + hashlib.sha1(a.filter.encode()).hexdigest()[:8]) if a.filter else "")
    cache = cache_dir / f"{key}.txt"
    t0 = time.time()

    print(f"копия: {copy}  база: {base_ref} ({base_sha[:10]})  файлов: {len(files)}", flush=True)
    copy_fails = run_side("копия", copy, files, a.j, a.timeout_file, logroot)

    if cache.exists():
        print(f"[база] из кеша {cache.relative_to(copy)}", flush=True)
        base_fails = {l for l in cache.read_text().splitlines() if l}
    else:
        wt = copy.parent / f".tests-base-{base_sha[:10]}"
        if wt.exists():
            git(copy, "worktree", "remove", "--force", str(wt), check=False)
            shutil.rmtree(wt, ignore_errors=True)
        git(copy, "worktree", "add", "--detach", str(wt), base_sha)
        try:
            bin_src = copy / "addons" / "dp_air" / "bin"
            if bin_src.is_dir():
                shutil.copytree(bin_src, wt / "addons" / "dp_air" / "bin", dirs_exist_ok=True)
            # кеш импорта копии (.godot) — база переимпортирует только отличающееся
            if (copy / ".godot").is_dir() and not (wt / ".godot").exists():
                subprocess.run(["cp", "-a", "--reflink=auto", str(copy / ".godot"), str(wt / ".godot")])
            base_files = [f for f in files if (wt / f).exists()]
            base_fails = run_side("база", wt, base_files, a.j, a.timeout_file, logroot)
        finally:
            git(copy, "worktree", "remove", "--force", str(wt), check=False)
            shutil.rmtree(wt, ignore_errors=True)
            git(copy, "worktree", "prune", check=False)
        cache.write_text("".join(f"{x}\n" for x in sorted(base_fails)))

    new = sorted(copy_fails - base_fails)
    fixed = sorted(base_fails - copy_fails)
    for x in new:
        print(f"НОВОЕ   {x}")
    for x in fixed:
        print(f"ИСПРАВЛЕНО {x}")
    print(f"стена: {time.time() - t0:.0f} с")
    print(f"копия: {len(copy_fails)} падений; база: {len(base_fails)}; "
          f"новых падений: {len(new)}; исправлено: {len(fixed)}")
    sys.exit(1 if new else 0)


if __name__ == "__main__":
    main()
