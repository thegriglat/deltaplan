#!/usr/bin/env python3
"""Контрактная проверка LM-K1 v1 (docs/contracts/live-menu.md): формат startup.json замера старта."""
import json
import sys

NUM = (int, float)
FIELDS = {
    "variant": str, "run": int, "kind": str, "menu_s": NUM, "menu_frames": int, "menu_median_ms": NUM,
    "menu_worst_ms": NUM, "menu_hitches": int, "menu_hitch_total_ms": NUM, "world_ready_s": NUM,
    "baked": bool, "fly_ms": NUM, "fly_worst_ms": NUM, "fly_hitches": int,
}


def main(path: str) -> int:
    d = json.load(open(path, encoding="utf-8"))
    err = []
    if d.get("version") != 1:
        err.append("version != 1")
    for k in ("build", "display"):
        if not isinstance(d.get(k), str):
            err.append(f"нет {k}")
    runs = d.get("runs")
    if not isinstance(runs, list):
        return print("нет runs") or 1
    count = {"main": [0, 0], "proto": [0, 0]}
    for i, r in enumerate(runs):
        for k, t in FIELDS.items():
            if k not in r:
                err.append(f"runs[{i}]: нет {k}")
            elif r[k] is not None and (isinstance(r[k], bool) and t is not bool or not isinstance(r[k], t)):
                err.append(f"runs[{i}].{k}: тип {type(r[k]).__name__}")
        v, kind = r.get("variant"), r.get("kind")
        if v not in count or kind not in ("cold", "warm"):
            err.append(f"runs[{i}]: variant/kind {v}/{kind}")
            continue
        count[v][0 if kind == "cold" else 1] += 1
        if v == "main" and (r.get("world_ready_s") is not None or r.get("baked") is not None):
            err.append(f"runs[{i}]: у main world_ready_s/baked должны быть null")
    for v, (cold, warm) in count.items():
        if cold < 1 or cold + warm < 3:
            err.append(f"{v}: прогонов {cold} холодных + {warm} тёплых (нужно ≥1 и всего ≥3)")
    for e in err:
        print(e)
    print("OK" if not err else f"FAIL: {len(err)}")
    return 1 if err else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
