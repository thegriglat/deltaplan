#!/usr/bin/env python3
"""Новые/изменённые текстуры ветки против main: размер, compress/mode, mipmaps, дубликаты.
Запуск в корне копии: python3 tex_check.py [база]. Код 1 — нарушение правила VRAM."""
import hashlib, struct, subprocess, sys, os

base = sys.argv[1] if len(sys.argv) > 1 else "main"
names = subprocess.run(["git", "diff", "--name-only", "--diff-filter=AM", f"{base}...HEAD", "--",
                        "*.png", "*.jpg", "*.jpeg", "*.webp"], capture_output=True, text=True).stdout.split()
bad = 0
seen = {}

def size(p):
    with open(p, "rb") as f:
        h = f.read(32)
        if h[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", h[16:24])
        f.seek(2)
        while True:
            m = f.read(2)
            if len(m) < 2 or m[0] != 0xFF:
                return (0, 0)
            ln = struct.unpack(">H", f.read(2))[0]
            if m[1] in (0xC0, 0xC1, 0xC2):
                f.read(1)
                hh, ww = struct.unpack(">HH", f.read(4))
                return (ww, hh)
            f.seek(ln - 2, 1)

for n in names:
    if not os.path.exists(n):
        continue
    w, h = size(n)
    dig = hashlib.sha1(open(n, "rb").read()).hexdigest()
    imp = n + ".import"
    if n.startswith("assets/source/") or n.startswith("site/") or n.startswith("docs/") or n.startswith("tools/"):
        print(f"skip  {n} {w}x{h} (не импортируется)")
        continue
    mode = mip = "-"
    if os.path.exists(imp):
        for line in open(imp, encoding="utf-8"):
            if line.startswith("compress/mode="):
                mode = line.split("=", 1)[1].strip()
            if line.startswith("mipmaps/generate="):
                mip = line.split("=", 1)[1].strip()
    ok = mode == "2" and mip == "true" and max(w, h) <= 512
    dup = seen.get(dig)
    if dup:
        ok = False
    seen[dig] = n
    bad += not ok
    print(f"{'ok  ' if ok else 'FAIL'}  {n} {w}x{h} compress/mode={mode} mipmaps={mip}" + (f" дубликат {dup}" if dup else ""))
print(f"текстур {len(names)}, нарушений {bad}")
sys.exit(1 if bad else 0)
