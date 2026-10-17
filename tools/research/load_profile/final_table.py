#!/usr/bin/env python3
"""final_table.py → md-таблица медиан to_flying_s / load_max_gap_ms / glider / objects по тегам итогового замера FL-11 (+ load average начала)."""
import json, re, statistics as st
from pathlib import Path
H = Path(__file__).parent
rows = [("final_miss", "miss"), ("final_hit", "hit"), ("final_pool4", "hit, пул 4"), ("final_pool2", "hit, пул 2"),
        ("final_bands1", "hit, полос 1 (запуски hit)"), ("final_bands1b", "hit, полос 1 (ещё 2)")]
print("| тег | место | n | to_flying_s (мед.) | min–max | load_max_gap_ms (мед.) | glider, с | objects, с | wind, с | load avg старта (мин–макс) |\n|---|---|---|---|---|---|---|---|---|---|")
for tag, label in rows:
    d = json.load(open(H / f"{tag}.json"))["runs"]
    for pl in ("ong", "pt"):
        r = [x for x in d if x["place"] == pl and not x["cold"] and not (tag == "final_bands1" and x["air_cache"] == "miss")]
        if not r:
            continue
        la = []
        for x in r:
            f = H / "logs" / f"{tag}_{pl}_{x['run']}.log"
            m = re.search(r"load average: (\d+[,.]\d+)", f.read_text(errors="replace").split("\n")[0])
            la.append(float(m.group(1).replace(",", ".")) if m else float("nan"))
        med = lambda k: st.median(x["stages"].get(k, 0) for x in r)
        t = [x["to_flying_s"] for x in r]
        print(f"| {tag} ({label}) | {pl} | {len(r)} | {st.median(t):.1f} | {min(t):.1f}–{max(t):.1f} | {st.median(x['load_max_gap_ms'] for x in r):.0f} | {med('glider'):.1f} | {med('objects'):.1f} | {med('wind'):.1f} | {min(la):.1f}–{max(la):.1f} |")
