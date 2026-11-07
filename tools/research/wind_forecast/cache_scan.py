"""Заголовки записей кеша поля (*.dpac): режим притока (key.inflow), k (inflow_k), ветер. python3 -I cache_scan.py <каталог…>"""
import json, struct, sys, glob, os, collections
def head(p):
    with open(p, "rb") as f:
        if f.read(8) != b"DPAC1\0\0\0":
            return None
        n = struct.unpack("<Q", f.read(8))[0]
        return json.loads(f.read(n))
rows = []
for d in sys.argv[1:]:
    for p in sorted(glob.glob(os.path.join(d, "*.dpac"))):
        h = head(p)
        if h is None:
            continue
        k = h.get("key", {}) or {}
        lm = h.get("levels", [{}])
        ik = None
        try:
            ik = lm[0].get("meta", {}).get("inflow_k")
        except Exception:
            pass
        rows.append({"file": p, "cache": h.get("cache"), "status": h.get("status"), "place": k.get("location"),
                     "inflow": k.get("inflow"), "u10": k.get("u10"), "start": k.get("start"),
                     "inflow_k": h.get("inflow_k", ik), "keys": sorted(k.keys())})
cnt = collections.Counter((r["inflow"], r["inflow_k"]) for r in rows)
print(json.dumps({"n": len(rows), "by_inflow_k": {f"{a}/{b}": c for (a, b), c in cnt.items()}, "rows": rows[:int(os.environ.get('N', '5'))]}, ensure_ascii=False, indent=1))
