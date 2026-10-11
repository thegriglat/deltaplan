"""PD-22: пачка вариантов срыва полос в игре (pendulum_compare.gd --pd19) и сводка.

  python tools/research/pendulum/pd22_batch.py plan NAME '<json вариантов>' [--sc spin,turb,landing,dive_all]
         [--seeds 10] [--trace] [--ramps 10] [--after push,keep]
  python tools/research/pendulum/pd22_batch.py run NAME     # godot headless (фоном)
  python tools/research/pendulum/pd22_batch.py sum NAME     # сводка по вариантам

Варианты — свойства PendulumWingStrips: {"name": "plate", "strips": {"stall_vc": false}};
"cd90" — C_N сорванной полосы при 90°. Файлы — tools/research/pendulum/out/pd22/NAME.{plan.json,jsonl}.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / "out" / "pd22"
REF = json.loads((ROOT / "tests/flight/pendulum/reference.json").read_text())


def plan(a):
    OUT.mkdir(parents=True, exist_ok=True)
    fields = {"ref": REF["turbulence"]}
    p8 = json.loads((HERE / "out" / "pd8_plan.json").read_text())["turbulence"]
    for k in list(p8)[: a.seeds]:
        fields[k] = p8[k]
    pl = {"variants": json.loads(a.variants), "scenarios": a.sc.split(","), "turbulence": fields,
          "dts": [120, 60, 30], "trace": a.trace, "spin_ramps": [float(x) for x in a.ramps.split(",")],
          "spin_after": a.after.split(",")}
    (OUT / f"{a.name}.plan.json").write_text(json.dumps(pl))
    print(OUT / f"{a.name}.plan.json")


def run(name):
    env = dict(os.environ, XDG_DATA_HOME=tempfile.mkdtemp())
    cmd = ["systemd-run", "--user", "--scope", "-p", "MemoryMax=12G", "-q", "godot", "--headless", "--path", str(ROOT),
           "res://tools/flight/pendulum_compare.tscn", "--",
           f"--pd19={OUT / f'{name}.plan.json'}", f"--out={OUT / f'{name}.jsonl'}"]
    r = subprocess.run(["timeout", "3000"] + cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    err = [l for l in r.stderr.splitlines() if "ERROR" in l or "SCRIPT" in l or "Parse" in l]
    print("exit", r.returncode, "ошибок", len(err), *err[:8], sep="\n")


def f1(x):
    return "  nan" if x is None or x != x else f"{x:5.1f}"


def summ(name):
    rows = [json.loads(l) for l in (OUT / f"{name}.jsonl").read_text().splitlines() if l.strip()]
    by = defaultdict(list)
    for r in rows:
        by[r["variant"]].append(r)
    for v, rs in by.items():
        print(f"=== {v}")
        for r in rs:
            if r["sc"] == "pd22_spin":
                print(f"  spin {r['wing']:8} ramp {r['ramp_s']:.0f} {r['after']:4}: срыв t {f1(r['t_stall_s'])} с, pitch {r['pitch_at_stall']:.2f}, "
                      f"первой {r.get('first', '—')} ({r.get('n_inner_at_stall', 0)}/{r.get('n_outer_at_stall', 0)}), V {f1(r.get('V_at_stall_kmh'))}; "
                      f"6 с: крен {f1(r.get('bank_at_stall_deg'))}→макс {f1(r['bank_max_deg'])} (мин {f1(r['bank_min_deg'])}), к 6 с {f1(r.get('bank_6s_deg'))}, "
                      f"рыск. ср {f1(r['yaw_rate_mean_dps'])}°/с, Vy макс {f1(r['sink_max_ms'])}, V {f1(r['V_min_kmh'])}–{f1(r['V_max_kmh'])}, "
                      f"α макс {f1(r['alpha_max_deg'])}, доля срыва {r['stall_frac_max']:.2f}, ≥4 полос: внутр {f1(r['t_inner4_s'])} внеш {f1(r['t_outer4_s'])}; "
                      f"потеря 6 с {f1(r.get('h_loss_6s_m'))} м; выход {f1(r['recover_s'])} с, потеря всего {f1(r['h_loss_total_m'])} м, в выходе |крен| макс {f1(r.get('bank_rec_max_deg'))}, V макс {f1(r.get('V_rec_max_kmh'))}")
            if r["sc"] == "pd19_landing":
                print(f"  посадка {r['wing']:8} ветер {r['wind']:.0f}: лучшее {r['score']:.2f} с {r['flare_h']:.2f} м — {r['grade']}, верт {r['v']:.2f}, гор {r['h']:.2f}")
        da = [r for r in rs if r["sc"].startswith("pd19_diveall")]
        for p in ("p100", "p50"):
            d = [r for r in da if r["sc"].endswith(p)]
            if d:
                bad = [r["wing"] for r in d if r["stall_streak_max_s"] >= 10]
                print(f"  diveall {p}: срыв ≥ 10 с {len(bad)}/{len(d)} {bad}; макс срыв подряд {max(r['stall_streak_max_s'] for r in d):.1f} с")
        tb = [r for r in rs if r["sc"] == "pd19_turb"]
        if tb:
            g = defaultdict(list)
            for r in tb:
                g[r["wing"]].append(r)
            for w, lst in g.items():
                ref = [x for x in lst if x["field"] == "ref"]
                ext = [x for x in lst if x["field"] != "ref"]
                n60 = sum(x["max_abs_phi_deg"] >= 60 for x in ext)
                print(f"  turb {w:8}: поле ref макс крен {[round(x['max_abs_phi_deg']) for x in ref]}, СКО {[round(x['std_phi_deg'], 1) for x in ref]}, "
                      f"срыв {[round(x['t_stall_s'], 1) for x in ref]} (≥25 % {[round(x.get('t_stall25_s', 0), 1) for x in ref]}, полн. {[round(x.get('t_stall_full_s', 0), 1) for x in ref]}); "
                      f"доп. поля |крен| ≥ 60° {n60}/{len(ext)}, срыв ср {sum(x['t_stall_s'] for x in ext) / max(len(ext), 1):.2f} с, "
                      f"≥25 % ср {sum(x.get('t_stall25_s', 0) for x in ext) / max(len(ext), 1):.2f}, полн. ср {sum(x.get('t_stall_full_s', 0) for x in ext) / max(len(ext), 1):.2f}, развал {sum(x['blowup'] for x in lst)}")


if __name__ == "__main__":
    if sys.argv[1] == "plan":
        ap = argparse.ArgumentParser()
        ap.add_argument("cmd"); ap.add_argument("name"); ap.add_argument("variants")
        ap.add_argument("--sc", default="spin,turb,landing"); ap.add_argument("--seeds", type=int, default=10)
        ap.add_argument("--trace", action="store_true"); ap.add_argument("--ramps", default="10")
        ap.add_argument("--after", default="push,keep")
        plan(ap.parse_args())
    elif sys.argv[1] == "run":
        run(sys.argv[2])
    else:
        summ(sys.argv[2])
