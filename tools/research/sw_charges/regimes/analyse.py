"""Сводки по out/regimes: матрицы путаницы, бор против теории, Fr_game,c."""
import json, os, collections, sys
O = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "out", "regimes")
A1 = json.load(open(O + "/A1.json"))["rows"]; A2 = json.load(open(O + "/A2.json"))["rows"]
def grp(rows, f): 
    d = collections.defaultdict(list)
    for r in rows: d[f(r)].append(r)
    return d
def key1(r):
    n = r["case"]; return ("jstart" if "_jstart" in n else "dx40" if "_dx40" in n else r["shape"] + ("6" if "_r6_" in n else ""))
if __name__ == "__main__":
    for k, rs in grp(A1, key1).items():
        print(k, len(rs), "match", sum(r["match"] for r in rs))
        c = collections.Counter((r["regime_sw"], r["regime_theory"]) for r in rs)
        print("  ", dict(c))
    print("wall", sum(r["wall_s"] for r in A1+A2))
