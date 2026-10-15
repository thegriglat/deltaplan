"""PB-1: болтанка σ 1 м/с в прототипе для пилота-точки и пилота-тела — подсчёт переворотов.

Поля — как PD-19/PD-21: эталонное (tests/flight/pendulum/reference.json → turbulence) + 10 зёрен
`out/pd8_plan.json`; шаги 1/120, 1/60, 1/30 с; T = 30 с; переворот — |крен| ≥ 60°. В PD-19 было
ещё ×2 «блока» (блок pendulum крыла из игры и из прототипа) — это различие есть только в игре,
у прототипа блок один: 11 × 3 = 33 прогона на крыло и вариант.

  $PY pb1_turb.py run [--out out/pb1/turb.jsonl] [--jobs 12] [--variants out/pb1/variants.json]
  $PY pb1_turb.py sum out/pb1/turb.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import export_reference as E  # noqa: E402
import pb1_lateral as B  # noqa: E402
from pendulum import trim  # noqa: E402

OUT = HERE / "out" / "pb1"
DTS = (1 / 120, 1 / 60, 1 / 30)
T_S = 30.0


def fields():
    f = {"ref": json.loads((ROOT / "tests/flight/pendulum/reference.json").read_text())["turbulence"]}
    p8 = json.loads((HERE / "out/pd8_plan.json").read_text())["turbulence"]
    for k in list(p8)[:10]:
        f[k] = p8[k]
    return f


def make_over(wing, blk, over, dt):
    p = E.params(wing).with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"], **over)
    s = E.GameSim(p, yaw_mode="free", dt=dt, substeps=E.substeps_for(dt))
    s.cd_scale = blk["cd_scale"]
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    s.trim_state = st
    return s


def job(a):
    name, over, wing, field, modes, dt = a
    blk = E.wing_cfg(wing)["pendulum"]
    orig = E.make
    E.make = lambda w, b, m_pilot=None, dt=1 / 120: make_over(w, b, over, dt)
    t0 = time.time()
    try:
        r, err = E.sc_turbulence(wing, blk, modes, dt=dt, T=T_S), None
    except Exception:
        r, err = {}, traceback.format_exc()
    finally:
        E.make = orig
    return {"name": name, "wing": wing, "field": field, "hz": round(1 / dt), "sec": round(time.time() - t0),
            "err": err, **r}


def cmd_run(args):
    variants = json.loads(Path(args.variants).read_text()) if args.variants else B.VARIANTS
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    done = set()
    if out.exists():
        for ln in out.read_text().splitlines():
            r = json.loads(ln)
            if not r.get("err"):
                done.add((r["name"], r["wing"], r["field"], r["hz"]))
    wings = args.wings.split(",") if args.wings else E.WINGS
    fl = fields()
    plan = [(v["name"], v.get("over", {}), w, fk, fm, dt) for v in variants for w in wings
            for fk, fm in fl.items() for dt in DTS if (v["name"], w, fk, round(1 / dt)) not in done]
    print(f"план: {len(plan)} прогонов", flush=True)
    with ProcessPoolExecutor(args.jobs) as ex, out.open("a") as f:
        for fu in as_completed([ex.submit(job, a) for a in plan]):
            r = fu.result()
            f.write(json.dumps(r) + "\n")
            f.flush()
            print(r["name"], r["wing"], r["field"], r["hz"], r["sec"], "ERR" if r["err"] else round(r["max_abs_phi_deg"], 1), flush=True)


def summarize(path):
    rows = [json.loads(l) for l in Path(path).read_text().splitlines() if l.strip()]
    g = defaultdict(list)
    for r in rows:
        if not r.get("err"):
            g[(r["name"], r["wing"])].append(r)
    out = {}
    for (name, wing), lst in sorted(g.items()):
        n60 = sum(x["max_abs_phi_deg"] >= 60 for x in lst)
        out[(name, wing)] = {"turb_capsize_n": n60, "turb_runs_n": len(lst),
                             "turb_max_phi_deg": max(x["max_abs_phi_deg"] for x in lst),
                             "turb_std_phi_deg": sum(x["std_phi_deg"] for x in lst) / len(lst),
                             "turb_blowup_n": sum(bool(x["blowup"]) for x in lst),
                             "by_hz": {hz: [sum(x["max_abs_phi_deg"] >= 60 for x in lst if x["hz"] == hz),
                                            sum(x["hz"] == hz for x in lst)] for hz in (120, 60, 30)}}
    return out


def cmd_sum(args):
    for (name, wing), v in summarize(args.file).items():
        print(f"{name:8} {wing:9} |крен| ≥ 60°: {v['turb_capsize_n']}/{v['turb_runs_n']} "
              f"(по шагам 120/60/30: {v['by_hz'][120][0]}/{v['by_hz'][60][0]}/{v['by_hz'][30][0]}), "
              f"макс {v['turb_max_phi_deg']:.0f}°, СКО крена ср. {v['turb_std_phi_deg']:.1f}°, развалов {v['turb_blowup_n']}")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("run")
    a.add_argument("--variants", default="")
    a.add_argument("--out", default=str(OUT / "turb.jsonl"))
    a.add_argument("--jobs", type=int, default=12)
    a.add_argument("--wings", default="")
    b = sp.add_parser("sum")
    b.add_argument("file")
    args = ap.parse_args()
    cmd_run(args) if args.cmd == "run" else cmd_sum(args)


if __name__ == "__main__":
    main()
