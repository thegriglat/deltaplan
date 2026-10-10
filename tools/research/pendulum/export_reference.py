"""Эталонные числа прототипа маятника для тестов порта (PD-2): tests/flight/pendulum/reference.json.

Прототип (pendulum/*.py) не меняется — здесь только постановка сценариев приёмки PD-2 для
крыльев training / laminar / sport при эталонной массе, вариант B (рыскание свободно, flex_relief,
эффективное поперечное V из params.py), dt 1/120 с, 4 подшага, 3 звена.

Постановка как в игре: блок `pendulum` крыла (PD-К2) считается при эталонной массе один раз
(dcm0, cd_scale — под паспортный трим), сценарии с другой массой (опыт Ochi) берут его как есть.
В reference.json пишется и сам блок (`blocks.<крыло>`): тесты берут блок из configs/wings, а если
его там ещё нет (PD-1 не влит) — отсюда.

Болтанка — детерминированная сумма синусоид (моды в reference.json → `turbulence`), одинаковая
здесь и в тесте GDScript (оси игры: X — восток, Y — вверх, −Z — север).

Запуск (≈ 5–10 мин на 8 процессах):
  /home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python \
      tools/research/pendulum/export_reference.py [--jobs 8]
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
from pendulum import air, trim  # noqa: E402
from pendulum.model import Control, Sim  # noqa: E402
from pendulum.params import DIHEDRAL_EFF_DEG, FLEX_RELIEF, G, load_params  # noqa: E402
from pendulum.scenarios import BankHold, first_cross, run, settle  # noqa: E402

ROOT = HERE.parents[2]
OUT = ROOT / "tests/flight/pendulum/reference.json"
WINGS = ["training", "laminar", "sport"]
D = math.degrees
RAD = math.radians
SUBSTEPS_PER_S = 480
SUBSTEPS_MIN = 4


def substeps_for(dt: float) -> int:
    return max(SUBSTEPS_MIN, math.ceil(dt * SUBSTEPS_PER_S - 1e-9))


# ----------------------------------------------------------------------------- болтанка
def turbulence_modes(sigma=1.0, n=24, seed=7):
    """Сумма синусоид, оси игры: u(p) = Σ a_i·cos(k_i·p + φ_i); a_i ⊥ k_i; длины волн 4…200 м
    (лог.), спектр ~ фон Карман L 40 м; каждая составляющая — СКО ≈ sigma."""
    rng = np.random.default_rng(seed)
    lam = np.exp(np.linspace(math.log(200.0), math.log(4.0), n))
    ks = 2 * math.pi / lam
    L = 40.0
    dk = np.gradient(ks) * -1.0
    E = (ks * L) ** 4 / (1 + (ks * L) ** 2) ** (17.0 / 6.0)
    amp = np.sqrt(np.abs(E * dk))
    dirs = rng.normal(size=(n, 3))
    dirs /= np.linalg.norm(dirs, axis=1, keepdims=True)
    a = rng.normal(size=(n, 3))
    a -= (a * dirs).sum(1, keepdims=True) * dirs
    a /= np.linalg.norm(a, axis=1, keepdims=True)
    A = a * amp[:, None]
    var = (A ** 2).sum(0) / 2.0
    A *= sigma / math.sqrt(var.mean())
    ph = rng.uniform(0, 2 * math.pi, n)
    K = dirs * ks[:, None]
    return {"k": K.tolist(), "a": A.tolist(), "phase": ph.tolist(), "sigma": sigma, "seed": seed}


def ned_to_game(p):
    return np.stack([p[:, 1], -p[:, 2], -p[:, 0]], 1)


def game_to_ned(v):
    return np.stack([-v[:, 2], v[:, 0], -v[:, 1]], 1)


def turbulence_fn(modes, offset_game=(0.0, 0.0, 0.0)):
    K = np.array(modes["k"])
    A = np.array(modes["a"])
    ph = np.array(modes["phase"])
    off = np.array(offset_game)

    def f(points_ned):
        g = ned_to_game(points_ned) - off[None]
        u = np.cos(g @ K.T + ph[None]) @ A
        return game_to_ned(u)

    return f


# ----------------------------------------------------------------------------- постановка
def block(wing: str) -> dict:
    """Блок pendulum (PD-К2) при эталонной массе — как его посчитает PD-1."""
    p = load_params(wing)
    xh = p.x_hang_game
    d = trim.solve_dcm0(p.with_(x_hang=xh), xh)
    p = p.with_(x_hang=xh, dcm0=d)
    s = Sim(p, yaw_mode="free")
    a, st = trim.solve_trim(s)
    cd_scale = trim.calibrate_cd(s, a)
    a, st = trim.solve_trim(s)
    kn = trim.static_margin(s, st["alpha"], st["V"])
    I = s.mm.inertia_b
    zb = 0.06 + p.upright_len * math.cos(p.upright_tilt)
    xb = xh - p.upright_len * math.sin(p.upright_tilt)
    return {
        "contract": "PD-К2 v1",
        "_doc": "эталон прототипа (tools/research/pendulum/export_reference.py)",
        "sweep_deg": D(p.sweep),
        "root_chord_m": p.root_chord,
        "tip_chord_m": p.tip_chord,
        "washout_deg": D(p.washout),
        "keel_len_m": p.keel_len,
        "crossbar_from_nose_m": p.crossbar_from_nose,
        "hang_from_nose_m": xh,
        "bar_x_from_nose_m": xb,
        "bar_z_m": -zb,
        "cg_x_from_nose_m": float(s.mm.cg_n[0]),
        "cg_z_m": float(-s.mm.cg_n[2]),
        "inertia_kgm2": {"ixx": float(I[0, 0]), "iyy": float(I[1, 1]), "izz": float(I[2, 2]),
                         "ixz": float(I[0, 2])},
        "dcm0": d,
        "cd_scale": cd_scale,
        "ref": {"trim_kmh": st["V"] * 3.6, "sink_ms": st["V"] * math.sin(st["gamma"]),
                "alpha_trim_deg": D(st["alpha"]), "static_margin": kn},
    }


def make(wing: str, blk: dict, m_pilot=None, dt=1 / 120):
    """Sim с параметрами из блока (dcm0, cd_scale не пересчитываются), трим, пилот в равновесии."""
    p = load_params(wing, m_pilot)
    p = p.with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"])
    s = Sim(p, yaw_mode="free", dt=dt, substeps=substeps_for(dt))
    s.cd_scale = blk["cd_scale"]
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    s.trim_state = st
    return s


# ----------------------------------------------------------------------------- сценарии
def sc_trim(wing, blk):
    s = make(wing, blk)
    st = s.trim_state
    r = run(s, lambda t, o: Control(), 30.0)
    m = r["t"] > 15
    return {"reset_V_kmh": st["V"] * 3.6, "reset_sink_ms": st["V"] * math.sin(st["gamma"]),
            "reset_alpha_deg": D(st["alpha"]), "reset_theta_deg": D(st["theta"]),
            "V_kmh": float(r["V"][m].mean() * 3.6), "sink_ms": float(-r["vz"][m].mean()),
            "alpha_deg": float(D(r["alpha"][m].mean())), "theta_deg": float(D(r["theta"][m].mean())),
            "pilot_rel_x": float(r["rel_x"][m].mean()), "pilot_rel_z": float(r["rel_z"][m].mean()),
            "tension_N": float(r["tension"][m].mean())}


def sc_phugoid(wing, blk, dv=3.0):
    s = make(wing, blk)
    s.vel = s.vel * (1 + dv / np.linalg.norm(s.vel))
    s.vn = s.vn + (s.vel - s.vn[-1])
    r = run(s, lambda t, o: Control(), 60.0, every=1)
    t, V = r["t"], r["V"]
    pk = [i for i in range(1, len(V) - 1) if V[i] > V[i - 1] and V[i] >= V[i + 1]]
    per = float(np.median(np.diff(t[pk]))) if len(pk) >= 2 else float("nan")
    Vm = float(np.median(V[-600:]))
    amps = [V[i] - Vm for i in pk]
    ratio = float(amps[1] / amps[0]) if len(amps) >= 2 and amps[0] != 0 else float("nan")
    return {"dv_ms": dv, "period_s": per, "amp_ratio_per_period": ratio, "V_end_kmh": float(V[-1] * 3.6)}


def sc_reversal(wing, blk, bank=45.0):
    s = make(wing, blk)
    bh = BankHold(RAD(bank), kp=6.0, kd=2.5, ki=1.0)
    r0 = run(s, bh, 14.0)
    phi0 = D(r0["phi"][-1])
    r = run(s, lambda t, o: Control(roll=-1.0), 12.0, every=1)
    t = r["t"]
    return {"bank_deg": bank, "hold_s": 14.0, "phi_start": phi0, "t_to_minus": first_cross(t, r["phi"], RAD(-bank)),
            "t_to_zero": first_cross(t, r["phi"], 0.0), "phi_t2": float(D(np.interp(2.0, t, r["phi"]))),
            "beta_max": float(D(np.abs(r["beta"]).max()))}


def sc_pendulum(wing, blk):
    out = {}
    for axis, key in ((1, "lat"), (0, "lon")):
        s = make(wing, blk)
        settle(s, 3.0)
        dv = np.zeros(3)
        dv[axis] = 0.5
        s.vn[-1] = s.vn[-1] + s.R @ dv
        r = run(s, lambda t, o: Control(arms_relaxed=True), 20.0, every=1)
        x = r["rel_y" if axis == 1 else "rel_x"]
        x = x - np.median(x[-240:])
        t = r["t"]
        zc = [t[i] for i in range(1, len(x)) if x[i - 1] < 0 <= x[i]]
        pk = [abs(x[i]) for i in range(1, len(x) - 1) if abs(x[i]) >= abs(x[i - 1]) and abs(x[i]) > abs(x[i + 1])]
        out[f"{key}_period_s"] = float(np.median(np.diff(zc))) if len(zc) >= 3 else float("nan")
        out[f"{key}_ratio_per_period"] = float(pk[2] / pk[0]) if len(pk) >= 3 and pk[0] > 0 else float("nan")
        out[f"{key}_amp0_m"] = float(pk[0]) if pk else float("nan")
    return out


def sc_ochi(wing, blk, force=30.0, t_on=8.5, m_pilot=72.6):
    s = make(wing, blk, m_pilot=m_pilot)
    settle(s, 2.0)
    r = run(s, lambda t, o: Control(force_y=force if t < t_on else None), 12.0, every=1)
    t = r["t"]
    return {"m_pilot": m_pilot, "force_n": force, "t_on_s": t_on, "settle_s": 2.0,
            "phi_7s": float(D(np.interp(7.0, t, r["phi"]))), "phi_max": float(D(r["phi"].max()))}


def sc_turbulence(wing, blk, modes, dt=1 / 120, T=40.0):
    s = make(wing, blk, dt=dt)
    s.air_fn = turbulence_fn(modes)
    hold = BankHold(0.0, kp=1.5, kd=0.8, ki=0.3)
    n = int(round(T / dt))
    phi, rel_y, th, V = [], [], [], []
    o = s.observe()
    blow = False
    for i in range(n):
        s.step(hold(0.0, o))
        o = s.observe()
        if not np.isfinite(o["phi"]) or o["V"] > 80:
            blow = True
            break
        if o["t"] > 10.0:
            phi.append(o["phi"]); rel_y.append(o["rel_y"]); th.append(o["theta"]); V.append(o["V"])
    return {"dt": dt, "T_s": T, "blowup": blow, "std_phi_deg": float(D(np.std(phi))),
            "std_theta_deg": float(D(np.std(th))), "std_rel_y_m": float(np.std(rel_y)),
            "max_abs_phi_deg": float(D(np.max(np.abs(phi)))), "V_mean_kmh": float(np.mean(V) * 3.6),
            "max_stretch_m": float(s.max_stretch)}


def job(args):
    name, wing, blk, extra = args
    if name == "trim":
        return name, wing, sc_trim(wing, blk)
    if name == "phugoid":
        return name, wing, sc_phugoid(wing, blk)
    if name == "reversal":
        return name, wing, sc_reversal(wing, blk)
    if name == "pendulum":
        return name, wing, sc_pendulum(wing, blk)
    if name == "ochi":
        return name, wing, sc_ochi(wing, blk)
    if name.startswith("turbulence"):
        return name, wing, sc_turbulence(wing, blk, extra["modes"], dt=extra["dt"])
    raise ValueError(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args()
    with ProcessPoolExecutor(args.jobs) as ex:
        blocks = dict(zip(WINGS, ex.map(block, WINGS)))
    modes = turbulence_modes()
    plan = []
    for w in WINGS:
        for sc in ("trim", "phugoid", "reversal", "pendulum"):
            plan.append((sc, w, blocks[w], {}))
        plan.append(("turbulence", w, blocks[w], {"modes": modes, "dt": 1 / 120}))
    plan.append(("ochi", "laminar", blocks["laminar"], {}))
    for dt, nm in ((1 / 60, "turbulence_dt60"), (1 / 30, "turbulence_dt30")):
        plan.append((nm, "sport", blocks["sport"], {"modes": modes, "dt": dt}))
    res = {}
    with ProcessPoolExecutor(args.jobs) as ex:
        for name, wing, r in ex.map(job, plan):
            res.setdefault(name, {})[wing] = r
            print(name, wing, json.dumps(r, ensure_ascii=False), flush=True)
    out = {
        "_doc": "Эталон прототипа маятника для тестов PD-2; генерирует tools/research/pendulum/export_reference.py, руками не править",
        "variant": {"yaw_mode": "free", "flex_relief": FLEX_RELIEF, "dihedral_eff_deg": DIHEDRAL_EFF_DEG,
                    "dt": 1 / 120, "substeps_per_s": SUBSTEPS_PER_S, "substeps_min": SUBSTEPS_MIN,
                    "n_links": 3, "n_strips": 16, "rho": 1.225, "hang_length_m": 1.2, "g": G},
        "blocks": blocks,
        "turbulence": modes,
        "scenarios": res,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    print("→", OUT)


if __name__ == "__main__":
    main()
