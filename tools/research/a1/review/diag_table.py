"""А1.3: сводка вариантов diag200 (out/diag200_*.json) — статус, итерации, невязки на последних проверках,
где максимум невязки θ′. Запуск: python3 diag_table.py"""
from __future__ import annotations

import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "out"
print("| вариант | статус | итер. | th_rms последняя | th_rms min…max, последние 15 проверок | thd_rms посл. | mom_rms посл. | argmax θ′ (k, j, i), м над землёй |")
print("|---|---|---|---|---|---|---|---|")
for p in sorted(OUT.glob("diag200_*.json")):
    d = json.loads(p.read_text())
    h = d["hist"]
    last = h[-1]
    tail = h[-15:]
    lo, hi = min(x["th_only_rms"] for x in tail), max(x["th_only_rms"] for x in tail)
    print(f"| {d['variant']}{' (air.py до А1)' if p.stem.startswith('diag200_old_') else ''} ({d['dtype']}) | {d['status']} | {d['iters']} | {last['th_only_rms']:.2e} | "
          f"{lo:.2e}…{hi:.2e} | {last['thd_only_rms']:.2e} | {last['mom_rms']:.2e} | {last['argmax']}, {last['z_argmax'] and round(last['z_argmax'])} |")
