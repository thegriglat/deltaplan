"""PB-1: боковой канал с пилотом-точкой и пилотом-телом — те же опыты, что PD-21 (`pd21_lateral.py`,
импорт без правок) плюс перекладка 30→30, трим, снижение и полный «на себя».

  $PY pb1_lateral.py run [--variants out/pb1/variants.json] [--out out/pb1/lateral.jsonl] [--jobs 12]
  $PY pb1_lateral.py table out/pb1/lateral.jsonl

Варианты (по умолчанию — см. VARIANTS): base — pilot_body="point" (как игра); body — тело по оценкам
params.py; body_lo / body_hi — чувствительность (CdA 0,12 / 0,23, площади кокона −30 % / +30 %,
инерция 14 / 35 кг·м²). Прототип — GameSim (как игра), умолчания «Аппарата» класса, трим, эталонная масса.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import pd21_lateral as L  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.scenarios import run  # noqa: E402

OUT = HERE / "out" / "pb1"
D = math.degrees

VARIANTS = [
    {"name": "base", "over": {}},
    {"name": "body", "over": {"pilot_body": "body"}},
    {"name": "body_lo", "over": {"pilot_body": "body", "body_cda_front": 0.12, "body_width": 0.45 * 0.7,
                                 "body_depth": 0.30 * 0.7, "body_izz": 14.0}},
    {"name": "body_hi", "over": {"pilot_body": "body", "body_cda_front": 0.23, "body_width": 0.45 * 1.3,
                                 "body_depth": 0.30 * 1.3, "body_cd_cross": 1.0, "body_izz": 35.0}},
]


def trim_and_pull(wing, over, over_deg):
    """Трим (30 с руки в нейтрали, среднее за 15–30 с), снижение, полный «на себя» (pitch = −1, 25 с)."""
    s = L.make_v(wing, over, over_deg)
    r = run(s, lambda t, o: Control(), 30.0)
    m = r["t"] > 15
    out = {"trim_kmh": float(r["V"][m].mean() * 3.6), "sink_ms": float(-r["vz"][m].mean()),
           "trim_alpha_deg": float(D(r["alpha"][m].mean())), "trim_theta_deg": float(D(r["theta"][m].mean())),
           "trim_rel_x": float(r["rel_x"][m].mean())}
    s = L.make_v(wing, over, over_deg)
    r = run(s, lambda t, o: Control(pitch=-1.0), 25.0)
    m = r["t"] > 15
    out.update({"full_pull_kmh": float(r["V"][m].mean() * 3.6), "full_pull_sink_ms": float(-r["vz"][m].mean())})
    return out


def measure(wing, over, over_deg):
    out = L.measure(wing, over, over_deg)
    r30 = L.reversal(wing, over, over_deg, bank=30.0)
    out.update({"rev30_t": r30["rev_t"], "rev30_beta_max": r30["rev_beta_max"]})
    out.update(trim_and_pull(wing, over, over_deg))
    return out


def job(a):
    name, wing, over, over_deg = a
    t0 = time.time()
    try:
        r, err = measure(wing, over, over_deg), None
    except Exception:
        r, err = {}, traceback.format_exc()
    return {"name": name, "wing": wing, "over": over, "over_deg": over_deg, "err": err,
            "sec": round(time.time() - t0, 1), **r}


def cmd_run(args):
    variants = json.loads(Path(args.variants).read_text()) if args.variants else VARIANTS
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    done = set()
    if out.exists():
        for ln in out.read_text().splitlines():
            r = json.loads(ln)
            if not r.get("err"):
                done.add((r["name"], r["wing"]))
    wings = args.wings.split(",") if args.wings else L.WINGS
    plan = [(v["name"], w, v.get("over", {}), v.get("over_deg", {})) for v in variants for w in
            v.get("wings", wings) if (v["name"], w) not in done]
    print(f"план: {len(plan)} запусков", flush=True)
    with ProcessPoolExecutor(args.jobs) as ex, out.open("a") as f:
        futs = [ex.submit(job, a) for a in plan]
        for fu in as_completed(futs):
            r = fu.result()
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
            f.flush()
            print(r["name"], r["wing"], r["sec"], "ERR" if r["err"] else "ok", flush=True)
            if r["err"]:
                print(r["err"], flush=True)


def cmd_table(args):
    rows = [json.loads(ln) for f in args.files for ln in Path(f).read_text().splitlines()]
    cols = [("Clβ", "d_Cl_beta", "{:.3f}"), ("Clp", "d_Cl_p", "{:.3f}"), ("Clr", "d_Cl_r", "{:.3f}"),
            ("Cnβ", "d_Cn_beta", "{:.4f}"), ("Cnp", "d_Cn_p", "{:.4f}"), ("Cnr", "d_Cn_r", "{:.4f}"),
            ("CYβ", "d_CY_beta", "{:.3f}"), ("Izz", "Izz_wing", "{:.0f}"), ("ГШ ωn", "dr_wn", "{:.2f}"),
            ("ГШ ζ", "dr_zeta", "{:.2f}"), ("перекл.45 с", "rev_t", "{:.2f}"), ("|β|max", "rev_beta_max", "{:.1f}"),
            ("перекл.30 с", "rev30_t", "{:.2f}"), ("вираж β ЦМ", "turn_beta_cg", "{:.1f}"),
            ("лента", "turn_beta_node", "{:.1f}"), ("Ochi φ7", "ochi_phi7", "{:.1f}"),
            ("трим км/ч", "trim_kmh", "{:.1f}"), ("снижение", "sink_ms", "{:.2f}"), ("на себя км/ч", "full_pull_kmh", "{:.1f}")]
    print("| вариант | крыло | " + " | ".join(c[0] for c in cols) + " |")
    print("|" + "---|" * (len(cols) + 2))
    for r in sorted(rows, key=lambda r: (r["name"], L.WINGS.index(r["wing"]) if r["wing"] in L.WINGS else 9)):
        if r.get("err"):
            print(f"| {r['name']} | {r['wing']} | ошибка |")
            continue
        print(f"| {r['name']} | {r['wing']} | " + " | ".join(L.fmt(r, k, f) for _, k, f in cols) + " |")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("run")
    a.add_argument("--variants", default="")
    a.add_argument("--out", default=str(OUT / "lateral.jsonl"))
    a.add_argument("--jobs", type=int, default=12)
    a.add_argument("--wings", default="")
    b = sp.add_parser("table")
    b.add_argument("files", nargs="+")
    args = ap.parse_args()
    cmd_run(args) if args.cmd == "run" else cmd_table(args)


if __name__ == "__main__":
    main()
