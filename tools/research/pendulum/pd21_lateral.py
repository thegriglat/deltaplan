"""PD-21: боковой канал «Маятника» против литературы (Cook & Spottiswoode 2005, Hiway Demon).

Для крыла и варианта параметров (правки Params прототипа) — один набор чисел:
- боковые производные системы около её ЦМ (trim.lateral_derivatives: полосы + эквивалентный киль +
  сопротивление пилота), отдельно полосы без киля;
- голландский шаг: свободный отклик на толчок по рысканию (руки держат нейтраль), полюс по методу
  Прони (наименьшие квадраты, β с шагом 0,1 с) → ωn, ζ;
- спираль: вираж 30° (и 40°) регулятором, затем «в центр» — крен через 5/10/20 с, время до |φ| < 5°,
  показатель по наклону ln|φ| (1–8 с); усилие рук в установившемся вираже;
- ровный вираж 30° мягким регулятором (как test_pendulum_telltale): β у ЦМ крыла и у узла ленты
  (≈ 1 м впереди ЦМ на тросах трапеции: β + r·x/V);
- переложение 45→45 (время, наибольшее |β|);
- крен-мода — оценка Lp/Ixx (крыло + присоединённая масса), λ = Clp·qSb·b/(2V)/Ixx.

Прототип — GameSim (export_reference.py, как игра). Пачка — один прогон:
  $PY pd21_lateral.py run --variants variants.json --out out/pd21_<имя>.jsonl [--jobs 8]
  $PY pd21_lateral.py table out/pd21_<имя>.jsonl            → таблица в stdout (md)
variants.json: [{"name": "base", "over": {}}, {"name": "cnb03", "over": {"cn_beta": 0.03}}, …]
(«over» — поля Params: cn_beta, fin_arm, fin_slope, dihedral (рад), flex_relief, billow_shift_deg, …;
отдельно "over_deg": {"dihedral": 5} — в градусах.)
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
import export_reference as E  # noqa: E402
from pendulum import trim  # noqa: E402
from pendulum.model import Control  # noqa: E402
from pendulum.scenarios import BankHold, first_cross, run, settle  # noqa: E402

D, RAD = math.degrees, math.radians
WINGS = ["training", "laminar", "sport"]
X_NODE = 1.0  # м: узел ленты впереди ЦМ крыла (тросы трапеции; PD-20: «≈ 1 м впереди оси рыскания»)


class ProbeSim(E.GameSim):
    """Зонд (не модель): добавочный рыскающий момент ΔCn = cnp_add·p·b/(2V) — «что если Cnp полос
    был бы как в литературе». Только для чувствительности, в игру не идёт."""

    cnp_add = 0.0

    def wing_aero(self, pos, vel, R, w):
        F, M, info = super().wing_aero(pos, vel, R, w)
        if self.cnp_add:
            p = self.p
            V = max(info["V"], 1.0)
            ph = float((R.T @ w)[0]) * p.span / (2 * V)
            M = M + R @ np.array([0.0, 0.0, self.cnp_add * ph * 0.5 * p.rho * V * V * p.area * p.span])
        return F, M, info


def make_v(wing, over, over_deg=None, m_pilot=None):
    blk = E.wing_cfg(wing)["pendulum"]
    kw = dict(over or {})
    cnp_add = float(kw.pop("cnp_add", 0.0))
    fs = kw.pop("flex_scale", None)
    if fs is not None:
        kw["flex_relief"] = min(1.0, E.wing_cfg(wing)["pendulum"]["apparatus_defaults"]["sail_flex"] * float(fs))
    for k, v in (over_deg or {}).items():
        kw[k] = RAD(v)
    p = E.params(wing, m_pilot).with_(x_hang=blk["hang_from_nose_m"], dcm0=blk["dcm0"], **kw)
    s = ProbeSim(p, yaw_mode="free", dt=1 / 120, substeps=4)
    s.cnp_add = cnp_add
    s.cd_scale = blk["cd_scale"]
    if "dihedral" in kw or "washout" in kw:
        # трим-константа под паспорт при новой геометрии (как pendulum_params.py)
        d = trim.solve_dcm0(p, p.x_hang)
        s.p = p = p.with_(dcm0=d)
    a, st = trim.solve_trim(s)
    s.reset_air(st)
    s.trim_state = st
    return s


def prony(t, x, order=6, wmin=0.3, wmax=3.5):
    """Полюса свободного отклика (наименьшие квадраты AR + вычеты). → список (σ, ω, |вычет|)."""
    dt = t[1] - t[0]
    n = len(x)
    A = np.stack([x[order - k - 1:n - k - 1] for k in range(order)], 1)
    b = x[order:]
    a, *_ = np.linalg.lstsq(A, b, rcond=None)
    z = np.roots(np.concatenate([[1.0], -a]))
    lam = np.log(z.astype(complex)) / dt
    V = np.stack([z ** k for k in range(n)], 0)
    res, *_ = np.linalg.lstsq(V, x.astype(complex), rcond=None)
    out = []
    for l_, r_ in zip(lam, res):
        if l_.imag > 0 and wmin <= l_.imag <= wmax:
            out.append((float(l_.real), float(l_.imag), float(2 * abs(r_))))
    return sorted(out, key=lambda q: -q[2])


def dutch_roll(wing, over, over_deg):
    s = make_v(wing, over, over_deg)
    settle(s, 3.0)
    s.w = s.w + s.R @ np.array([0.0, 0.0, 0.15])  # толчок по рысканию 0,15 рад/с
    r = run(s, lambda t, o: Control(), 16.0, every=12)  # 10 Гц
    t, b = r["t"], r["beta"]
    m = t >= 0.3
    poles = prony(t[m], b[m] - np.median(b[-30:]))
    if not poles:
        return {"dr_wn": float("nan"), "dr_zeta": float("nan"), "dr_poles": []}
    sg, w, _ = poles[0]
    wn = math.hypot(sg, w)
    return {"dr_wn": wn, "dr_zeta": -sg / wn, "dr_sigma": sg, "dr_w": w,
            "dr_beta_max": float(D(np.abs(b).max())), "dr_poles": poles[:3]}


def spiral(wing, over, over_deg, bank):
    s = make_v(wing, over, over_deg)
    bh = BankHold(RAD(bank), kp=6.0, kd=2.5, ki=1.0)
    r0 = run(s, bh, 12.0)
    out = {f"sp{bank}_phi0": float(D(r0["phi"][-1])), f"sp{bank}_hold_N": float(np.mean(r0["fh_y"][-20:])),
           f"sp{bank}_hold_u": float(np.mean(r0["u_roll"][-20:]))}
    r1 = run(s, lambda t, o: Control(), 20.0, every=2)
    t, ph = r1["t"], r1["phi"]
    idx = np.where(np.abs(ph) < RAD(5))[0]
    out[f"sp{bank}_t5"] = float(t[idx[0]]) if len(idx) else float("nan")
    for tt in (5, 10, 20):
        out[f"sp{bank}_phi{tt}"] = float(D(np.interp(tt, t, ph)))
    m = (t >= 1.0) & (t <= 8.0) & (np.abs(ph) > RAD(2))
    out[f"sp{bank}_lambda"] = float(np.polyfit(t[m], np.log(np.abs(ph[m])), 1)[0]) if m.sum() > 10 else float("nan")
    out[f"sp{bank}_beta_mean"] = float(D(np.mean(r1["beta"][:50])))
    return out


def steady_turn(wing, over, over_deg, bank=30.0):
    s = make_v(wing, over, over_deg)
    bh = BankHold(RAD(bank), kp=1.5, kd=0.8, ki=0.3)
    r = run(s, bh, 45.0, every=4)
    m = r["t"] > 40.0
    V, beta, rr = r["V"][m].mean(), r["beta"][m].mean(), r["r"][m].mean()
    return {"turn_phi": float(D(r["phi"][m].mean())), "turn_beta_cg": float(D(beta)),
            "turn_beta_node": float(D(beta + math.atan(rr * X_NODE / V))), "turn_r": float(rr),
            "turn_V_kmh": float(V * 3.6), "turn_hold_N": float(r["fh_y"][m].mean()),
            "turn_u": float(r["u_roll"][m].mean())}


def reversal(wing, over, over_deg, bank=45.0):
    s = make_v(wing, over, over_deg)
    bh = BankHold(RAD(bank), kp=6.0, kd=2.5, ki=1.0)
    run(s, bh, 14.0)
    r = run(s, lambda t, o: Control(roll=-1.0), 12.0, every=1)
    t = r["t"]
    tm = first_cross(t, r["phi"], RAD(-bank))
    m = t <= (tm if math.isfinite(tm) else t[-1])
    return {"rev_t": tm, "rev_t0": first_cross(t, r["phi"], 0.0), "rev_phi_start": float(D(r["phi"][0])),
            "rev_beta_max": float(D(np.abs(r["beta"][m]).max())),
            "rev_beta_max12": float(D(np.abs(r["beta"]).max()))}


def ochi(wing, over, over_deg, force=30.0, t_on=8.5, m_pilot=72.6):
    """Опыт Takamatsu & Ochi 2022 (как export_reference.sc_ochi): усилие вбок 30 Н 8,5 с."""
    s = make_v(wing, over, over_deg, m_pilot=m_pilot)
    settle(s, 2.0)
    r = run(s, lambda t, o: Control(force_y=force if t < t_on else None), 12.0, every=1)
    return {"ochi_phi7": float(D(np.interp(7.0, r["t"], r["phi"]))), "ochi_phi_max": float(D(r["phi"].max()))}


def derivs(wing, over, over_deg):
    s = make_v(wing, over, over_deg)
    st = s.trim_state
    d = trim.lateral_derivatives(s, st)
    s0 = make_v(wing, {**(over or {}), "cn_beta": 0.0}, over_deg)
    d0 = trim.lateral_derivatives(s0, s0.trim_state)
    p = s.p
    V = st["V"]
    q = 0.5 * p.rho * V * V
    Ixx = float(s.I_b[0, 0])
    Lp = d["Cl_p"] * q * p.area * p.span * p.span / (2 * V)
    out = {f"d_{k}": float(v) for k, v in d.items()}
    out.update({f"d0_{k}": float(v) for k, v in d0.items()})
    out.update({"V_trim": V, "q": q, "Izz_wing": float(s.I_b[2, 2]), "Ixx_wing_air": Ixx,
                "Ixx_wing": float(s.I_struct[0, 0]), "roll_lambda": Lp / Ixx,
                "Nbeta": d["Cn_beta"] * q * p.area * p.span,
                "wn_simple": math.sqrt(max(d["Cn_beta"], 0) * q * p.area * p.span / float(s.I_b[2, 2]))})
    return out


def measure(wing, over, over_deg):
    out = {}
    out.update(derivs(wing, over, over_deg))
    out.update(dutch_roll(wing, over, over_deg))
    out.update(spiral(wing, over, over_deg, 30))
    out.update(spiral(wing, over, over_deg, 40))
    out.update(steady_turn(wing, over, over_deg))
    out.update(reversal(wing, over, over_deg))
    if wing == "laminar":
        out.update(ochi(wing, over, over_deg))
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
    variants = json.loads(Path(args.variants).read_text())
    out = Path(args.out)
    done = set()
    if out.exists():
        for ln in out.read_text().splitlines():
            r = json.loads(ln)
            done.add((r["name"], r["wing"]))
    wings = args.wings.split(",") if args.wings else WINGS
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


COLS = [("Cnβ", "d_Cn_beta", "{:.4f}"), ("Cnβ полос", "d0_Cn_beta", "{:.4f}"), ("Clβ", "d_Cl_beta", "{:.3f}"),
        ("CYβ", "d_CY_beta", "{:.3f}"), ("Cnr", "d_Cn_r", "{:.4f}"), ("Clr", "d_Cl_r", "{:.3f}"),
        ("Clp", "d_Cl_p", "{:.3f}"), ("Cnp", "d_Cn_p", "{:.4f}"), ("E спир.", "d_spiral_E", "{:+.4f}"),
        ("Izz", "Izz_wing", "{:.0f}"), ("ωn простая", "wn_simple", "{:.2f}"),
        ("ГШ ωn", "dr_wn", "{:.2f}"), ("ГШ ζ", "dr_zeta", "{:.2f}"), ("крен λ", "roll_lambda", "{:.1f}"),
        ("сп. λ30", "sp30_lambda", "{:+.2f}"), ("30→ 5/10/20 с", None, None), ("до 5°", "sp30_t5", "{:.1f}"),
        ("40→ 10 с", "sp40_phi10", "{:.0f}"), ("вираж 30 β ЦМ/узел", None, None), ("перекл. с", "rev_t", "{:.2f}"),
        ("перекл. |β|max", "rev_beta_max", "{:.0f}"), ("Ochi φ7", "ochi_phi7", "{:.0f}")]


def fmt(r, key, f):
    v = r.get(key)
    if v is None or (isinstance(v, float) and not math.isfinite(v)):
        return "—"
    return f.format(v)


def cmd_table(args):
    rows = [json.loads(ln) for f in args.files for ln in Path(f).read_text().splitlines()]
    print("| вариант | крыло | " + " | ".join(c[0] for c in COLS) + " |")
    print("|" + "---|" * (len(COLS) + 2))
    for r in rows:
        if r.get("err"):
            print(f"| {r['name']} | {r['wing']} | ошибка |")
            continue
        cells = []
        for title, key, f in COLS:
            if title.startswith("30→"):
                cells.append("/".join(fmt(r, f"sp30_phi{t}", "{:.0f}") for t in (5, 10, 20)))
            elif title.startswith("вираж"):
                cells.append(fmt(r, "turn_beta_cg", "{:.1f}") + "/" + fmt(r, "turn_beta_node", "{:.1f}"))
            else:
                cells.append(fmt(r, key, f))
        print(f"| {r['name']} | {r['wing']} | " + " | ".join(cells) + " |")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("run")
    a.add_argument("--variants", required=True)
    a.add_argument("--out", required=True)
    a.add_argument("--jobs", type=int, default=8)
    a.add_argument("--wings", default="")
    b = sp.add_parser("table")
    b.add_argument("files", nargs="+")
    args = ap.parse_args()
    cmd_run(args) if args.cmd == "run" else cmd_table(args)


if __name__ == "__main__":
    main()
