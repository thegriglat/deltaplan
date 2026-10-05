#!/usr/bin/env python3
"""Сверка эмуляции build_inventory.py с настоящим .pck (--export-pack).

compare_pck.py <preset> <file.pck>  -> печатает расхождения множеств исходных файлов; json в stdout-конце.
Файл .pck -> исходник: X.import -> X; X.remap -> X; X.gdc -> X.gd; .godot/imported/* -> source_file из .import;
.godot/exported/*, project.binary, .godot/*.cfg|bin -> служебные Godot.
"""
import glob, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "release"))
sys.path.insert(0, HERE)
import build_inventory as bi
from pck_list import list_pck

preset, pck = sys.argv[1], sys.argv[2]
files = [f["path"] for f in list_pck(pck)["files"]]
dest2src = {}
for imp in glob.glob(os.path.join(ROOT, "**", "*.import"), recursive=True):
    rel = os.path.relpath(imp, ROOT).replace(os.sep, "/")
    if rel.startswith(".godot/"):
        continue
    txt = open(imp, encoding="utf-8", errors="replace").read()
    m = re.search(r'^source_file="res://([^"]+)"', txt, re.M)
    for d in re.findall(r'"res://([^"]+)"', (re.search(r"^dest_files=\[(.*?)\]", txt, re.M) or [None, ""])[1] if re.search(r"^dest_files=\[(.*?)\]", txt, re.M) else ""):
        dest2src[d] = m.group(1) if m else rel[:-7]
real, generated = set(), []
for p in files:
    if p.startswith(".godot/imported/") or p in dest2src:
        real.add(dest2src.get(p, "??" + p))
    elif p in bi.GODOT_GENERATED or p.startswith(".godot/exported/"):
        generated.append(p)
    elif p.endswith(".import"):
        real.add(p[:-7])
    elif p.endswith(".remap"):
        real.add(p[:-6])
    elif p.endswith(".gdc"):
        real.add(p[:-4] + ".gd")
    else:
        real.add(p)
emu = set(bi.project_sources(ROOT, bi.parse_presets(ROOT)[preset]))
only_real, only_emu = sorted(real - emu), sorted(emu - real)
print(f"pck файлов {len(files)}, исходных {len(real)}, служебных {len(generated)}; эмуляция {len(emu)}")
print("только в pck:", len(only_real)); [print("  ", p) for p in only_real[:40]]
print("только в эмуляции:", len(only_emu)); [print("  ", p) for p in only_emu[:40]]
json.dump({"preset": preset, "pck_files": len(files), "pck_sources": len(real), "emu": len(emu),
           "only_in_pck": only_real, "only_in_emulation": only_emu}, open(os.path.join(HERE, f"compare_{preset}.json"), "w"), ensure_ascii=False, indent=1)
