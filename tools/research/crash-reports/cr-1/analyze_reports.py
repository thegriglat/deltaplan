#!/usr/bin/env python3
"""CR-1: агрегаты по отчётам группы A (#4-#10). Читает ~/.cache/dp-crash-reports/cr<N>.json
(gh issue view N -R thegriglat/deltaplan-reports --json title,body,createdAt), пишет summary.json
только с числами и именами ошибок (без координат, мест, CPU/RAM). Запуск: python3 -I analyze_reports.py"""
import json, os, re, collections

SRC = os.path.expanduser("~/.cache/dp-crash-reports")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "summary.json")
res = {}
for n in range(4, 11):
    p = os.path.join(SRC, f"cr{n}.json")
    if not os.path.exists(p):
        continue
    body = json.load(open(p, encoding="utf-8"))["body"]
    lines = body.split("\n")
    stage = re.search(r"- стадия: (\S+)", body)
    wm = re.search(r"- wind_model: (\S+)", body)
    vram = re.search(r"VRAM[^:]*: (\d+) МБ", body)
    codes = collections.Counter(re.findall(r"error (0x[0-9a-f]+)", body))
    sizes = [int(x) for x in re.findall(r"create buffer of size: (\d+)", body)]
    first = next((i for i, l in enumerate(lines) if "0x887a0005" in l), -1)
    res[n] = {
        "stage": stage.group(1) if stage else "",
        "wind_model": wm.group(1) if wm else "",
        "vram_mb": int(vram.group(1)) if vram else None,
        "error_codes": dict(codes),
        "buffer_create_failures": len(sizes),
        "min_size": min(sizes) if sizes else None,
        "max_size": max(sizes) if sizes else None,
        "distinct_sizes": len(set(sizes)),
        "vulkan_init_failed": "VK_KHR_surface not found" in body,
        "d3d12_fallback": "switching to Direct3D 12" in body,
        "buffer_update_errors": body.count("buffer_update (servers"),
        "uniform_set_create_errors": body.count("uniform_set_create (servers"),
    }
json.dump(res, open(OUT, "w"), ensure_ascii=False, indent=1)
print(json.dumps(res, ensure_ascii=False)[:600])
