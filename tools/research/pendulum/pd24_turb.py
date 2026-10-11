"""PD-24: чувствительность болтанки и качания пилота к перекосу пузыря (прототип, поле эталона).
  $PY pd24_turb.py OUT.jsonl '<json вариантов {"имя": {поле Params: значение}}>' [крылья через запятую]
Поле Params «flex_scale» — множитель гибкости класса. Пишет по строке на (вариант, крыло, сценарий)."""
import json
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as E  # noqa: E402
from pendulum import trim  # noqa: E402


def make_over(wing, blk, over, dt):
    p = E.params(wing)
    over = dict(over)
    fs = over.pop("flex_scale", None)
    if fs is not None:
        over["sail_flex"] = p.sail_flex * fs
    p = p.with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"], **over)
    s = E.GameSim(p, yaw_mode="free", dt=dt, substeps=E.substeps_for(dt))
    s.cd_scale = blk["cd_scale"]
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    s.trim_state = st
    return s


def job(a):
    name, over, wing, sc, dt = a
    blk = E.wing_cfg(wing)["pendulum"]
    orig = E.make
    E.make = lambda w, b, m_pilot=None, dt=1 / 120: make_over(w, b, over, dt)
    t0 = time.time()
    try:
        if sc == "turb":
            r = E.sc_turbulence(wing, blk, E.turbulence_modes(), dt=dt)
        else:
            r = E.sc_pendulum(wing, blk)
    finally:
        E.make = orig
    return {"name": name, "wing": wing, "sc": sc, "hz": round(1 / dt), "sec": round(time.time() - t0), **r}


if __name__ == "__main__":
    out, variants = sys.argv[1], json.loads(sys.argv[2])
    wings = (sys.argv[3] if len(sys.argv) > 3 else "training,sport").split(",")
    plan = [(n, o, w, sc, dt) for n, o in variants.items() for w in wings
            for sc, dt in (("turb", 1 / 120), ("turb", 1 / 30), ("pend", 1 / 120))]
    with ProcessPoolExecutor(8) as ex, open(out, "a") as f:
        for fu in as_completed([ex.submit(job, a) for a in plan]):
            r = fu.result()
            f.write(json.dumps(r) + "\n")
            f.flush()
            print(r["name"], r["wing"], r["sc"], r["hz"], r.get("max_abs_phi_deg", r.get("lat_ratio_per_period")), flush=True)
