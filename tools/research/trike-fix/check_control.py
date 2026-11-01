#!/usr/bin/env python3
"""Контрактный тест TKF-К2 v1: схема out/control_summary.json. exit 0 — верна."""
import json, sys, math
def fail(m):
    print("FAIL:", m); sys.exit(1)
d = json.load(open(sys.argv[1]))
if d.get("version") != 1: fail("version")
if not isinstance(d.get("git"), str) or not d["git"]: fail("git")
c = d.get("cases")
if not isinstance(c, dict): fail("cases")
need = {"sport", "training", "trike_0", "trike_0.5", "trike_1"}
if not need <= set(c): fail("нет аппаратов %s" % (need - set(c)))
def num(x, k):
    if not isinstance(x, (int, float)) or isinstance(x, bool) or not math.isfinite(x): fail("%s не число: %r" % (k, x))
for n, v in c.items():
    rr = v.get("roll_rate_dps")
    if not isinstance(rr, dict) or set(rr) != {"0.25", "0.5", "1"}: fail(n + " roll_rate_dps ключи")
    for k, x in rr.items():
        num(x, n + ".roll_rate." + k)
        if not 0 <= x <= 200: fail(n + " roll_rate вне 0..200")
    for k in ("t_30_30_s", "t_45_45_s"):
        num(v.get(k), n + "." + k)
        if not 0.2 <= v[k] <= 60: fail(n + " " + k + " вне диапазона")
    p = v.get("pitch_rate_dps")
    if not isinstance(p, dict) or set(p) != {"push", "pull"}: fail(n + " pitch_rate_dps")
    for k, x in p.items():
        num(x, n + ".pitch." + k)
    if "bar_force_n" not in v: fail(n + " bar_force_n")
    if v["bar_force_n"] is not None: num(v["bar_force_n"], n + ".bar_force_n")
r = d.get("reference")
if not isinstance(r, list) or not r: fail("reference")
for e in r:
    if not all(k in e for k in ("source", "aircraft", "quantity", "value", "unit")): fail("reference поля")
    num(e["value"], "reference.value")
print("OK", len(c), "аппаратов,", len(r), "ссылок")
