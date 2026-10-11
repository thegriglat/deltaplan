"""PD-19: компактная таблица по вариантам пачки (pd19_<имя>.jsonl): строка на вариант.
dive: wing p100/p50 — срыв подряд макс, с / время, после которого V в 10 % трима (60 = никогда);
phug dv6: последний пик, км/ч; land: штиль max(верт/5, гор/3); turb: число полей с |крен| ≥ 60° / всего, макс крен.
  python tools/research/pendulum/pd19_table.py NAME"""
import json, sys
from collections import defaultdict
from pathlib import Path
rows = [json.loads(l) for l in (Path(__file__).parent / "out" / f"pd19_{sys.argv[1]}.jsonl").read_text().splitlines() if l.strip()]
by = defaultdict(list)
for r in rows:
    by[r["variant"]].append(r)
W = {"training": "T", "laminar": "L", "sport": "S"}
for v, rs in by.items():
    out = []
    d = {(r["wing"], r["sc"]): r for r in rs}
    s = []
    for w in W:
        for p in ("p100", "p50"):
            r = d.get((w, "pd19_dive_" + p))
            if r:
                s.append(f"{W[w]}{p[1:]}:{r['stall_streak_max_s']:.0f}/{r['t_out10_s']:.0f}")
    if s: out.append("dive " + " ".join(s))
    ph = [f"{W[r['wing']]}:{r['peak_amps_kmh'][-1]:.1f}" for r in rs if r["sc"] == "pd19_phug" and r["dv"] == 6]
    if ph: out.append("phug6 " + " ".join(ph))
    ld = [f"{W[r['wing']]}:{r['score']:.2f}" for r in rs if r["sc"] == "pd19_landing" and r["wind"] == 0]
    if ld: out.append("land " + " ".join(ld))
    tb = defaultdict(list)
    for r in rs:
        if r["sc"] == "pd19_turb":
            tb[r["wing"]].append(r["max_abs_phi_deg"])
    if tb: out.append("turb " + " ".join(f"{W[w]}:{sum(x >= 60 for x in l)}/{len(l)},{max(l):.0f}" for w, l in tb.items()))
    print(f"{v:16} " + " | ".join(out))
