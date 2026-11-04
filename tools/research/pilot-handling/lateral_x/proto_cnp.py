"""PHD-2 (версия б): чувствительность боковых мод к Cnp в прототипе GameSim (ProbeSim из pd21_lateral.py).
Cnp задаётся целью: cnp_add = цель − Cnp базы крыла. Для каждого (крыло, Cnp): производные, голландский шаг (Прони),
спираль 30°, ровный вираж 30°, перекладка 45→45. Плюс линейная 5-состояний модель с теми же производными и
пересчёт набора Kochi 2020 из осей устойчивости в связанные при α трима.
  PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
  $PY proto_cnp.py run --out out/proto_cnp.jsonl [--jobs 6]     (под .dpcli/dpcli lock cpu)
  $PY proto_cnp.py linear --out out/linear_axes.json
"""
from __future__ import annotations
import argparse, json, math, sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
PEN = HERE.parents[1] / "pendulum"
sys.path.insert(0, str(PEN))
import pd21_lateral as L  # noqa: E402
import pb1_analytic as PB  # noqa: E402

TARGETS = {"base": None, "cnp0": 0.0, "cook_p057": 0.0568, "kochi_m068": -0.068}


def job(a):
    wing, tag = a
    base = L.derivs(wing, {}, {})["d_Cn_p"]
    over = {}
    if TARGETS[tag] is not None:
        over = {"cnp_add": TARGETS[tag] - base}
    out = {"wing": wing, "tag": tag, "cnp_base": base, "over": over}
    out.update(L.derivs(wing, over, {}))
    out.update(L.dutch_roll(wing, over, {}))
    out.update(L.spiral(wing, over, {}, 30))
    out.update(L.steady_turn(wing, over, {}))
    out.update(L.reversal(wing, over, {}))
    return out


def cmd_run(args):
    plan = [(w, t) for w in ["training", "laminar", "sport"] for t in TARGETS]
    with ProcessPoolExecutor(args.jobs) as ex, open(args.out, "w") as f:
        for fu in as_completed([ex.submit(job, a) for a in plan]):
            r = fu.result()
            f.write(json.dumps(r, ensure_ascii=False) + "\n"); f.flush()
            print(r["wing"], r["tag"], round(r["dr_wn"], 3), round(r["dr_zeta"], 3), flush=True)


def rot_set(d, alpha, sign):
    """Производные из осей устойчивости (стаб.) в связанные: D_b = T D_s T^T, моменты (L, N), скорости (p, r)."""
    c, s = math.cos(alpha), math.sin(alpha)
    T = np.array([[c, -s * sign], [s * sign, c]])
    Dr = np.array([[d["Cl_p"], d["Cl_r"]], [d["Cn_p"], d["Cn_r"]]])
    Db = T @ Dr @ T.T
    Bb = T @ np.array([d["Cl_beta"], d["Cn_beta"]])
    o = dict(d)
    o.update({"Cl_p": Db[0, 0], "Cl_r": Db[0, 1], "Cn_p": Db[1, 0], "Cn_r": Db[1, 1], "Cl_beta": Bb[0], "Cn_beta": Bb[1]})
    return o


def dr_of(A):
    ev = np.linalg.eigvals(A)
    dr = [m for m in PB.modes(ev) if "wn" in m]
    rl = sorted(float(e.real) for e in ev if abs(e.imag) < 1e-6)
    return dr, rl


def cmd_linear(args):
    """Линейная модель нашего крыла (training/laminar/sport) с нашими производными: база, Cnp=+0,057, и
    производные Kochi 2020 (Cook): как есть (трактуя в связанных осях) и повёрнутые из осей устойчивости на α трима."""
    ck = {"Cn_beta": 0.0275, "Cl_beta": -0.322, "CY_beta": -0.226, "Cl_p": -0.930, "Cl_r": 0.326, "Cn_r": -0.0578, "Cn_p": 0.0568,
          "CY_p": -0.0326, "CY_r": 0.0004}
    res = {}
    for wing in L.WINGS:
        s = L.make_v(wing, {}, {})
        st = s.trim_state
        dd = L.derivs(wing, {}, {})
        d = {k[2:]: v for k, v in dd.items() if k.startswith("d_") and not k.startswith("d0_")}
        p = s.p
        mw, mp = p.m_wing, p.m_pilot
        th = st["theta"]
        alpha = st.get("alpha", None)
        if alpha is None:
            alpha = math.radians(10.0)
        mu = mw * mp / (mw + mp)
        Ixx = dd["Ixx_wing_air"] + mu * 1.44
        Izz = dd["Izz_wing"] + mp * (1.2 * math.sin(th)) ** 2 * mw / (mw + mp)
        V, S, b = dd["V_trim"], p.area, p.span
        out = {"alpha_deg": math.degrees(alpha), "V": V, "Ixx": Ixx, "Izz": Izz, "cases": {}}

        def add(name, dset):
            A = PB.rigid_lateral_A(dset, mw + mp, Ixx, Izz, V, S, b, theta=th)
            dr, rl = dr_of(A)
            out["cases"][name] = {"dutch": dr, "real": rl, "Cn_p": dset["Cn_p"]}
        add("ours", d)
        for tag, tv in (("cnp_+0.057", 0.0568), ("cnp_-0.068", -0.068), ("cnp_0", 0.0)):
            add(tag, {**d, "Cn_p": tv})
        # трактовка: производные игры — в связанных осях; Kochi — в осях устойчивости → в связанные
        for sg, nm in ((+1, "kochi_stab_to_body_a+"), (-1, "kochi_stab_to_body_a-")):
            add(nm, rot_set(ck, alpha, sg))
        # наши производные, повёрнутые в оси устойчивости (если сравнивать в осях Kochi)
        for sg, nm in ((+1, "ours_body_to_stab"), (-1, "ours_body_to_stab_alt")):
            add(nm, rot_set(d, alpha, -sg))
        # Cnp игры + поворот только Cnp: Cn_p^s − Cn_p^b
        res[wing] = out
        out["cnp_ours_rot"] = {nm: out["cases"][nm]["Cn_p"] for nm in out["cases"]}
    Path(args.out).write_text(json.dumps(res, indent=1, ensure_ascii=False))
    for w, o in res.items():
        print(w, "alpha", round(o["alpha_deg"], 1))
        for k, v in o["cases"].items():
            print("  ", k, "Cnp", round(v["Cn_p"], 4), [(round(m["wn"], 2), round(m["zeta"], 2)) for m in v["dutch"]], [round(r, 3) for r in v["real"]])


def cmd_stab(args):
    """Согласованный пересчёт в оси устойчивости: производные, моменты и произведение инерции Ixz поворачиваются
    вместе (проверка инвариантности: моды те же); затем сравнение с набором Kochi 2020 поэлементно."""
    ck = {"Cn_beta": 0.0275, "Cl_beta": -0.322, "CY_beta": -0.226, "Cl_p": -0.930, "Cl_r": 0.326, "Cn_r": -0.0578, "Cn_p": 0.0568,
          "CY_p": -0.0326, "CY_r": 0.0004}
    res = {}
    for wing in L.WINGS:
        s = L.make_v(wing, {}, {})
        st = s.trim_state
        dd = L.derivs(wing, {}, {})
        d = {k[2:]: v for k, v in dd.items() if k.startswith("d_") and not k.startswith("d0_")}
        p = s.p
        mw, mp = p.m_wing, p.m_pilot
        th = st["theta"]
        alpha = math.radians(10.0) if st.get("alpha") is None else st["alpha"]
        mu = mw * mp / (mw + mp)
        Ixx = dd["Ixx_wing_air"] + mu * 1.44
        Izz = dd["Izz_wing"] + mp * (1.2 * math.sin(th)) ** 2 * mw / (mw + mp)
        V, S, b = dd["V_trim"], p.area, p.span
        c, sn = math.cos(alpha), math.sin(alpha)
        A_b = PB.rigid_lateral_A(d, mw + mp, Ixx, Izz, V, S, b, theta=th)
        base, _ = dr_of(A_b)
        out = {"alpha_deg": math.degrees(alpha), "body_modes": base, "stab": {}}
        for sg in (+1, -1):
            ds = rot_set(d, alpha, -sg)  # body -> stab: T^T D T
            Ixx_s = Ixx * c * c + Izz * sn * sn
            Izz_s = Ixx * sn * sn + Izz * c * c
            Ixz_s = sg * (Izz - Ixx) * sn * c
            A_s = PB.rigid_lateral_A(ds, mw + mp, Ixx_s, Izz_s, V, S, b, theta=th - alpha, Ixz=Ixz_s)
            dr, rl = dr_of(A_s)
            out["stab"][f"sign{sg:+d}"] = {"derivs": {k: float(ds[k]) for k in ("Cl_p", "Cl_r", "Cn_p", "Cn_r", "Cl_beta", "Cn_beta")},
                                           "Ixx": Ixx_s, "Izz": Izz_s, "Ixz": Ixz_s, "dutch": dr, "real": rl}
        res[wing] = out
        print(wing, "body", [(round(m["wn"], 3), round(m["zeta"], 3)) for m in base])
        for k, v in out["stab"].items():
            print("  ", k, [(round(m["wn"], 3), round(m["zeta"], 3)) for m in v["dutch"]], {a: round(b_, 4) for a, b_ in v["derivs"].items()})
    # лучший знак — тот, где моды совпадают с телесными; затем поэлементная замена на Kochi в осях устойчивости
    for wing, o in res.items():
        w0 = o["body_modes"][0]["wn"]
        best = min(o["stab"], key=lambda k: abs(o["stab"][k]["dutch"][0]["wn"] - w0) if o["stab"][k]["dutch"] else 9)
        o["best_sign"] = best
        sg = +1 if best == "sign+1" else -1
        s = L.make_v(wing, {}, {})
        dd = L.derivs(wing, {}, {})
        d = {k[2:]: v for k, v in dd.items() if k.startswith("d_") and not k.startswith("d0_")}
        p = s.p; mw, mp = p.m_wing, p.m_pilot
        st = s.trim_state; th = st["theta"]; alpha = math.radians(o["alpha_deg"])
        Ixx_s, Izz_s, Ixz_s = o["stab"][best]["Ixx"], o["stab"][best]["Izz"], o["stab"][best]["Ixz"]
        ds = rot_set(d, alpha, -sg)
        V, S, b = dd["V_trim"], p.area, p.span
        o["swap"] = {}
        keys = ["Cl_p", "Cl_r", "Cn_p", "Cn_r", "Cl_beta", "Cn_beta", "CY_beta"]
        for k in keys + ["all_Kochi"]:
            dsw = dict(ds)
            for kk in (keys if k == "all_Kochi" else [k]):
                dsw[kk] = ck[kk]
            A = PB.rigid_lateral_A(dsw, mw + mp, Ixx_s, Izz_s, V, S, b, theta=th - alpha, Ixz=Ixz_s)
            dr, rl = dr_of(A)
            o["swap"][k] = {"dutch": dr, "real": rl}
        print(wing, "best", best, "swap:", {k: [(round(m["wn"], 2), round(m["zeta"], 2)) for m in v["dutch"]] for k, v in o["swap"].items()})
    Path(args.out).write_text(json.dumps(res, indent=1, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("run"); a.add_argument("--out", required=True); a.add_argument("--jobs", type=int, default=6)
    b = sp.add_parser("linear"); b.add_argument("--out", required=True)
    c = sp.add_parser("stab"); c.add_argument("--out", required=True)
    args = ap.parse_args()
    {"run": cmd_run, "linear": cmd_linear, "stab": cmd_stab}[args.cmd](args)


if __name__ == "__main__":
    main()
