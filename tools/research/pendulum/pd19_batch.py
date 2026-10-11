"""PD-19: пачка вариантов модели срыва в игре (pendulum_compare.gd --pd19) и сводка.

  python tools/research/pendulum/pd19_batch.py plan NAME '<json вариантов>' [--sc dive,turb] [--dts 120,60,30] [--seeds 10] [--trace]
  python tools/research/pendulum/pd19_batch.py run NAME     # godot headless (фоном)
  python tools/research/pendulum/pd19_batch.py sum NAME     # сводка по вариантам

Файлы — tools/research/pendulum/out/pd19_<NAME>.{plan.json,jsonl}.
"""
from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / "out"
REF = json.loads((ROOT / "tests/flight/pendulum/reference.json").read_text())


def plan(name, variants, sc, dts, seeds, trace):
    fields = {"ref": REF["turbulence"]}
    if seeds:
        p8 = json.loads((OUT / "pd8_plan.json").read_text())["turbulence"]
        for k in list(p8)[:seeds]:
            fields[k] = p8[k]
    pl = {"variants": variants, "scenarios": sc, "turbulence": fields, "dts": dts, "trace": trace}
    (OUT / f"pd19_{name}.plan.json").write_text(json.dumps(pl))
    print(OUT / f"pd19_{name}.plan.json")


def run(name):
    env = dict(os.environ, XDG_DATA_HOME=tempfile.mkdtemp())
    cmd = ["systemd-run", "--user", "--scope", "-p", "MemoryMax=12G", "-q", "godot", "--headless", "--path", str(ROOT),
           "res://tools/flight/pendulum_compare.tscn", "--",
           f"--pd19={OUT / f'pd19_{name}.plan.json'}", f"--out={OUT / f'pd19_{name}.jsonl'}"]
    r = subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    err = [l for l in r.stderr.splitlines() if "ERROR" in l]
    print("exit", r.returncode, "ошибок", len(err), *err[:5], sep="\n")


def summ(name):
    rows = [json.loads(l) for l in (OUT / f"pd19_{name}.jsonl").read_text().splitlines() if l.strip()]
    by = defaultdict(list)
    for r in rows:
        by[r["variant"]].append(r)
    for v, rs in by.items():
        print(f"=== {v}")
        for r in rs:
            if r["sc"].startswith("pd19_dive_"):
                print(f"  {r['sc'][10:]:4} {r['wing']:9} срыв подряд {r['stall_streak_max_s']:5.1f} с, входов {r['stall_entries']:2}, "
                      f"V вне 10 % до {r['t_out10_s']:5.1f} с, после 20 с V {r['V_min20_kmh']:5.1f}–{r['V_max20_kmh']:5.1f} "
                      f"(трим {r['V_trim_kmh']:.1f}), α макс {r['alpha_max20_deg']:5.1f}, крен макс {r['bank_max_deg']:5.1f}")
        da = [r for r in rs if r["sc"].startswith("pd19_diveall")]
        if da:
            for p in ("p100", "p50"):
                d = [r for r in da if r["sc"].endswith(p)]
                bad = [r for r in d if r["stall_streak_max_s"] >= 10]
                set20 = [r for r in d if r["t_out10_s"] > 20]
                print(f"  diveall {p}: срыв ≥ 10 с {len(bad)}/{len(d)} {[r['wing'] for r in bad]}; макс срыв подряд "
                      f"{max(r['stall_streak_max_s'] for r in d):.1f} с; V не осела за 20 с {len(set20)}/{len(d)}; "
                      f"медиана t_out10 {sorted(r['t_out10_s'] for r in d)[len(d)//2]:.1f}; входов в срыв макс {max(r['stall_entries'] for r in d)}")
        for r in rs:
            if r["sc"] == "pd19_phug":
                print(f"  фугоида {r['wing']:8} dv {r['dv']:.0f}: пики (км/ч от трима) {r['peak_amps_kmh'][:8]}, срыв {r['stall_s']:.1f} с, α {r['alpha_min_deg']:.1f}…{r['alpha_max_deg']:.1f}")
            if r["sc"] == "pd19_landing":
                print(f"  посадка {r['wing']:8} ветер {r['wind']:.0f}: лучшее {r['score']:.2f} с {r['flare_h']:.2f} м — {r['grade']}, верт {r['v']:.2f}, гор {r['h']:.2f}")
            if r["sc"] == "pd19_flare6":
                print(f"  выравн. с 6 м {r['wing']:8} ветер {r['wind']:.0f}: {r['grade']}, верт {r['v']:.2f}, гор {r['h']:.2f}")
        tb = [r for r in rs if r["sc"] == "pd19_turb"]
        if tb:
            g = defaultdict(list)
            for r in tb:
                g[(r["wing"], r["proto_block"], r["hz"])].append(r)
            for k, lst in sorted(g.items()):
                mx = max(x["max_abs_phi_deg"] for x in lst)
                n60 = sum(x["max_abs_phi_deg"] >= 60 for x in lst)
                st = sum(x["t_stall_s"] for x in lst) / len(lst)
                refr = [x for x in lst if x["field"] == "ref"]
                rf = refr[0]["max_abs_phi_deg"] if refr else float("nan")
                print(f"  turb {k[0]:8} {'proto' if k[1] else 'game ':5} 1/{k[2]:3}: |крен| ≥ 60° {n60}/{len(lst)}, макс {mx:6.1f}° "
                      f"(поле ref {rf:6.1f}°), срыв в среднем {st:5.2f} с из 30, растяжение макс {max(x['max_stretch_m'] for x in lst):.3f}, "
                      f"развал {sum(x['blowup'] for x in lst)}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "plan":
        import argparse
        ap = argparse.ArgumentParser()
        ap.add_argument("cmd"); ap.add_argument("name"); ap.add_argument("variants")
        ap.add_argument("--sc", default="dive,turb"); ap.add_argument("--dts", default="120,60,30")
        ap.add_argument("--seeds", type=int, default=10); ap.add_argument("--trace", action="store_true")
        a = ap.parse_args()
        plan(a.name, json.loads(a.variants), a.sc.split(","), [int(x) for x in a.dts.split(",")], a.seeds, a.trace)
    elif cmd == "run":
        run(sys.argv[2])
    elif cmd == "sum":
        summ(sys.argv[2])
