"""PD-8: прототип в том же протоколе сценариев, что tools/flight/pendulum_compare.gd (игра).

Прототип — GameSim из export_reference.py (правки игры: ноги, экранный эффект, C_L max по поляре),
рыскание свободно, умолчания «Аппарата» класса, блок pendulum (dcm0, cd_scale, подвеска) — из
configs/wings (как у игры), шаг 1/120 с.

  .venv/bin/python tools/research/pendulum/pd8_proto.py plan  [--seeds 10]   # out/pd8_plan.json (поля болтанки)
  .venv/bin/python tools/research/pendulum/pd8_proto.py run   [--jobs 6]     # out/pd8_proto.jsonl
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import export_reference as X  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.params import G  # noqa: E402
from pendulum.scenarios import BankHold, first_cross, run  # noqa: E402

OUT = HERE / "out"
WINGS = X.WINGS
D = np.degrees
RAD = math.radians


def blk_of(w):
    return X.wing_cfg(w)["pendulum"]


def sc_reversal(w, bank):
    r = X.sc_reversal(w, blk_of(w), bank=float(bank))
    return {k: r[k] for k in ("phi_start", "t_to_minus", "t_to_zero", "phi_t2")}


def sc_fullshift(w):
    s = X.make(w, blk_of(w))
    r = run(s, lambda t, o: Control(roll=1.0), 15.0, every=1)
    return {f"phi_{x}s": float(D(np.interp(x, r["t"], r["phi"]))) for x in (1, 2, 4, 6, 10, 15)}


def sc_center30(w):
    s = X.make(w, blk_of(w))
    r0 = run(s, BankHold(RAD(30.0), kp=6.0, kd=2.5, ki=1.0), 14.0)
    r = run(s, lambda t, o: Control(), 25.0, every=1)
    return {"phi_start": float(D(r0["phi"][-1])), "phi_10s": float(D(np.interp(10.0, r["t"], r["phi"]))),
            "phi_20s": float(D(np.interp(20.0, r["t"], r["phi"])))}


def sc_hold(w, relaxed):
    s = X.make(w, blk_of(w))
    r = run(s, lambda t, o: Control(arms_relaxed=relaxed), 60.0, every=1)
    m = r["t"] > 10
    th = D(r["theta"][m])
    return {"theta_deg": float(np.median(th)), "theta_range_deg": float(th.max() - th.min()),
            "V_kmh": float(np.median(r["V"][m]) * 3.6), "max_abs_phi_deg": float(D(np.abs(r["phi"][m]).max())),
            "heading_drift_deg": float(D(r["psi"][-1] - r["psi"][m][0]))}


DIVE_VARIANTS = [(-1.0, 1.0), (-1.0, 2.0), (-0.5, 3.0), (-0.5, 6.0), (-0.25, 6.0)]


def sc_dive(w, pitch=-1.0, hold=3.0, T=120.0):
    """Протокол как PendulumCompare._dive (pendulum_compare.gd)."""
    s = X.make(w, blk_of(w))
    st = s.trim_state
    th_trim = float(D(st["theta"]))
    v_trim = float(st["V"] * 3.6)
    r = run(s, lambda t, o: Control(pitch=pitch if t < hold else 0.0), T, every=1)
    t = r["t"]
    W = s.p.m_pilot * G
    n = r["tension"] / W
    th = D(r["theta"])
    V = r["V"] * 3.6
    after = t >= hold
    ia = np.where(after)[0]
    below = np.where(after & (th < th_trim - 2.0))[0]
    t_rec = 0.0
    if len(below):
        up = np.where((np.arange(len(t)) > below[0]) & after & (th >= th_trim - 2.0))[0]
        t_rec = float(t[up[0]] - hold) if len(up) else float("nan")
    out_of = np.where(after & ((np.abs(th - th_trim) > 3.0) | (np.abs(V - v_trim) > 0.05 * v_trim)))[0]
    k20 = t <= 20.0
    ser = [[round(float(t[i]), 3), round(float(th[i]), 2), round(float(V[i]), 2), round(float(n[i]), 3)]
           for i in np.where(k20)[0][::12]]
    return {"pitch": pitch, "hold_s": hold, "theta_trim_deg": th_trim, "V_trim_kmh": v_trim,
            "theta_min_deg": float(th.min()), "V_max_kmh": float(V.max()), "n_pull_max": float(n[~after].max()),
            "n_out_max": float(n[after].max()), "t_recover_s": t_rec, "theta_max_after_deg": float(th[ia].max()),
            "V_min_after_kmh": float(V[ia].min()), "t_settle_s": float(t[out_of[-1]] - hold) if len(out_of) else 0.0,
            "theta_end_deg": float(th[-1]), "V_end_kmh": float(V[-1]), "alpha_end_deg": float(D(r["alpha"][-1])),
            "stall_end": float(r["stall_frac"][-1]), "bank_end_deg": float(D(r["phi"][-1])), "series": ser}


def sc_turb(w, modes, dt=1 / 120, T=60.0):
    s = X.make(w, blk_of(w), dt=dt)
    s.air_fn = X.turbulence_fn(modes)
    hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)
    n = int(round(T / dt))
    phi, ry, th = [], [], []
    psi10 = None
    o = s.observe()
    blow = False
    for i in range(n):
        s.step(hold(0.0, o))
        o = s.observe()
        if not np.isfinite(o["phi"]) or o["V"] > 80:
            blow = True
            break
        if o["t"] > 10.0:
            if psi10 is None:
                psi10 = o["psi"]
            phi.append(o["phi"]); ry.append(o["rel_y"]); th.append(o["theta"])
    return {"blowup": blow, "std_phi_deg": float(D(np.std(phi))), "std_theta_deg": float(D(np.std(th))),
            "std_rel_y_m": float(np.std(ry)), "max_abs_phi_deg": float(D(np.max(np.abs(phi)))),
            "max_stretch_m": float(s.max_stretch), "heading_drift_deg": float(D(o["psi"] - psi10))}


def job(a):
    sc, w, extra = a
    if sc == "trim":
        r = X.sc_trim(w, blk_of(w))
        r = {k: r[k] for k in ("V_kmh", "sink_ms", "alpha_deg", "theta_deg")} | {"tension_N": r["tension_N"]}
    elif sc == "phugoid":
        r = X.sc_phugoid(w, blk_of(w)); r = {"period_s": r["period_s"], "amp_ratio": r["amp_ratio_per_period"]}
    elif sc.startswith("reversal"):
        r = sc_reversal(w, sc[8:])
    elif sc == "fullshift":
        r = sc_fullshift(w)
    elif sc == "center30":
        r = sc_center30(w)
    elif sc == "pendulum":
        r = X.sc_pendulum(w, blk_of(w))
        r = {k.replace("_ratio_per_period", "_ratio"): v for k, v in r.items() if "amp0" not in k}
    elif sc == "ochi":
        r = X.sc_ochi(w, blk_of(w)); r = {"phi_7s": r["phi_7s"], "phi_max": r["phi_max"]}
    elif sc.startswith("ground_run_w"):
        r = X.sc_ground_run(w, blk_of(w), wind=float(sc[12:]))
        r = {k: r.get(k, float("nan")) for k in ("t_liftoff", "x_liftoff", "v_liftoff_kmh")}
    elif sc == "hold_neutral":
        r = sc_hold(w, False)
    elif sc == "hold_relaxed":
        r = sc_hold(w, True)
    elif sc == "dive":
        r = sc_dive(w)
    elif sc.startswith("dive_a"):
        a_, t_ = sc[6:].split("_t")
        r = sc_dive(w, -int(a_) / 100.0, float(t_))
    elif sc == "turb":
        r = sc_turb(w, extra["modes"], extra["dt"]); r["seed"] = extra["seed"]
    else:
        raise ValueError(sc)
    return {"sc": sc, "wing": w, "dt": extra.get("dt", 1 / 120), **r}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["plan", "run"])
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--seeds", type=int, default=10)
    a = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    plan_path = OUT / "pd8_plan.json"
    if a.cmd == "plan":
        plan = {"_doc": "PD-8: поля болтанки σ 1 м/с (export_reference.turbulence_modes), зёрна 1..N",
                "turbulence": {str(sd): X.turbulence_modes(sigma=1.0, seed=sd) for sd in range(1, a.seeds + 1)}}
        plan_path.write_text(json.dumps(plan))
        print("→", plan_path)
        return
    plan = json.loads(plan_path.read_text())
    jobs = []
    for w in WINGS:
        for sc in ("trim", "phugoid", "reversal45", "reversal30", "fullshift", "center30", "pendulum",
                   "ground_run_w0", "ground_run_w3", "ground_run_w6", "hold_neutral", "hold_relaxed", "dive"):
            jobs.append((sc, w, {}))
        for pch, hd in DIVE_VARIANTS:
            jobs.append((f"dive_a{round(-100 * pch)}_t{round(hd)}", w, {}))
    jobs.append(("ochi", "laminar", {}))
    for sd, modes in plan["turbulence"].items():
        for dt in (1 / 120, 1 / 60):
            jobs.append(("turb", "laminar", {"modes": modes, "seed": int(sd), "dt": dt}))
    with ProcessPoolExecutor(a.jobs) as ex, open(OUT / "pd8_proto.jsonl", "w") as f:
        for r in ex.map(job, jobs):
            f.write(json.dumps(r, ensure_ascii=False) + "\n"); f.flush()
            print(r["sc"], r["wing"], flush=True)


if __name__ == "__main__":
    main()
