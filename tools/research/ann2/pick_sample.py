"""AN-1: выбор 12 случаев набора terrain для пересчёта со снимками (детерминированно: ближайшие к целям по U10 внутри класса)."""
import json
from common import OUT
C = [c for c in json.load(open(OUT / "cells_cases.json")) if c["loc"].startswith("t_")]
def cls(c): return "nc" if c["gh"] == "nc" else ("conv-conf" if c["conf"] else "conv-late")
want = [("holdout_sys", "conv-conf", u) for u in (1.0, 3.0, 5.0, 7.0)] + [("holdout_sys", "conv-late", 1.5)] + \
       [("holdout_sys", "nc", u) for u in (0.5, 1.2, 2.5, 5.0)] + [("train", "conv-conf", 4.0), ("train", "conv-conf", 6.5), ("train", "nc", 1.0)]
out, used = [], set()
for s, k, u in want:
    cs = sorted((c for c in C if c["set"] == s and cls(c) == k and c["case"] not in used), key=lambda c: abs(c["U10"] - u))
    c = cs[0]; used.add(c["case"]); out.append(c["case"]); print(s, k, c["case"], c["U10"], c["iters"], c["spread"], round(c["dw_med"], 3))
json.dump(out, open(OUT / "sample.json", "w"))

# расширенная выборка (зерно 1): случайно внутри класса, сверх первых 12
import random
rnd = random.Random(1)
more = []
for s, k, n in (("holdout_sys", "conv-conf", 16), ("holdout_sys", "conv-late", 6), ("holdout_sys", "nc", 14), ("train", "conv-conf", 4), ("train", "nc", 4)):
    pool = sorted(c["case"] for c in C if c["set"] == s and cls(c) == k and c["case"] not in used)
    more += rnd.sample(pool, n)
json.dump(out + more, open(OUT / "sample48.json", "w")); print(len(out + more))
