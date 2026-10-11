"""PD-12: калибровка умолчаний «Аппарата» по классам крыла: сетка V (dihedral_eff) x flex_relief.
Опорные крылья: training (trainer), apogee (soviet), laminar (kingpost), sport (topless).
Метрики (прототип, yaw free, подвеска игры): перекладка 45->45 (с), выход из виража 30 "в центр"
(время до |крен|<5 градусов, иначе крен через 10 с), установившееся усилие рук в вираже 30, опыт Ochi.
Запуск: python calibrate_classes.py [--jobs N] [--wings a,b]  -> out/calib_classes.jsonl (продолжение с места), out/calib_classes.md
"""
from __future__ import annotations
import argparse, json, math, sys, time, traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pendulum import scenarios as S  # noqa: E402
from pendulum.model import Control  # noqa: E402

OUT = HERE / "out"
WINGS = {"training": "trainer", "apogee": "soviet", "laminar": "kingpost", "sport": "topless"}
VS = (-1.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0)
FLEX = (0.1, 0.2, 0.35, 0.6)
D, RAD = math.degrees, math.radians


def measure(wing, v, flex, extra=None):
    kw = {"dihedral": RAD(v), "sail_flex": flex, **{k: x for k, x in (extra or {}).items() if k != "group"}}
    out = {}
    rv = S.sc_reversal(wing, bank=45.0, **kw)
    out["rev45_s"] = rv["t_to_minus"]
    out["rev45_hold_u"] = rv["u_hold"]
    # выход из виража 30 в центр
    s = S.make(wing, **kw)
    bh = S.BankHold(RAD(30.0), kp=6.0, kd=2.5, ki=1.0)
    r0 = S.run(s, bh, 12.0)
    out["hold30_phi"] = D(r0["phi"][-1])
    out["hold30_force_N"] = float(np.mean(r0["fh_y"][-20:]))
    out["hold30_u"] = float(np.mean(r0["u_roll"][-20:]))
    r1 = S.run(s, lambda t, o: Control(), 20.0, every=2)
    t, ph = r1["t"], r1["phi"]
    idx = np.where(np.abs(ph) < RAD(5))[0]
    out["exit30_t5_s"] = float(t[idx[0]]) if len(idx) else float("nan")
    out["exit30_phi10_deg"] = float(D(np.interp(10.0, t, ph)))
    out["exit30_phi20_deg"] = float(D(ph[-1]))
    out["exit30_phimax_deg"] = float(D(ph.max()))
    try:
        if extra and "group" in extra:
            raise ValueError("verify: без Ochi")
        oc = S.sc_ochi("laminar", force=30.0, **kw)
        out["ochi_phi7_deg"], out["ochi_phi_after_deg"] = oc["phi_7s"], oc["phi_after_mean"]
    except Exception:
        out["ochi_phi7_deg"] = out["ochi_phi_after_deg"] = float("nan")
    return out


def do(job):
    t0 = time.time()
    try:
        r, err = measure(*job[:3], job[3] if len(job) > 3 else None), None
    except Exception:
        r, err = {}, traceback.format_exc()
    return {"wing": job[0], "V": job[1], "flex": job[2], "extra": job[3] if len(job) > 3 else None, "res": r, "err": err, "wall_s": time.time() - t0}


def summarize_verify(jl):
    """Умолчания класса на всех крыльях -> out/calib_verify.md (по классам: min / медиана / max)."""
    import statistics as st
    rows = [json.loads(l) for l in jl.read_text().splitlines()]
    by = {}
    for r in rows:
        by.setdefault(r["extra"]["group"], []).append(r)
    def agg(rs, k):
        v = [r["res"][k] for r in rs if not r["err"] and r["res"].get(k) is not None and r["res"][k] == r["res"][k]]
        return "—" if not v else f"{min(v):.1f} / {st.median(v):.1f} / {max(v):.1f}"
    L = ["# Умолчания классов на всех крыльях (PD-12, прототип)", "",
         "min / медиана / max по крыльям класса. rev45 — перекладка 45->45, с (nan — 45° не достигается полным смещением: исключены из статистики, перечислены); "
         "phi10/phi20 — крен через 10/20 с после «в центр» из виража 30°; F30 — усилие рук в вираже 30°, Н (минус — держать против спирали).", "",
         "| класс | крыльев | rev45, с | phi10, ° | phi20, ° | F30, Н |", "|---|---|---|---|---|---|"]
    for g, rs in by.items():
        L.append(f"| {g} | {len(rs)} | {agg(rs, 'rev45_s')} | {agg(rs, 'exit30_phi10_deg')} | {agg(rs, 'exit30_phi20_deg')} | {agg(rs, 'hold30_force_N')} |")
    L += ["", "Крылья без перекладки 45° или с ошибкой счёта:", ""]
    for r in rows:
        if r["err"]:
            L.append(f"- {r['wing']} ({r['extra']['group']}): ошибка счёта (расходимость)")
        elif r["res"].get("rev45_s") is None or r["res"]["rev45_s"] != r["res"]["rev45_s"]:
            L.append(f"- {r['wing']} ({r['extra']['group']}): 45° полным смещением не достигается за 12 с")
    L += ["", "| крыло | класс | rev45 | phi10 | phi20 | F30 |", "|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (r["extra"]["group"], r["wing"])):
        x = r["res"]
        f = lambda k, n=1: "—" if not x or x.get(k) is None or x[k] != x[k] else f"{x[k]:.{n}f}"  # noqa: E731
        L.append(f"| {r['wing']} | {r['extra']['group']} | {f('rev45_s')} | {f('exit30_phi10_deg',0)} | {f('exit30_phi20_deg',0)} | {f('hold30_force_N',0)} |")
    (OUT / "calib_verify.md").write_text("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--wings", default=",".join(WINGS))
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--verify", action="store_true", help="умолчания класса (GROUP_DEFAULTS из tools/flight/pendulum_params.py) на всех крыльях -> out/calib_verify.jsonl")
    ap.add_argument("--v6", action="store_true", help="проверка верха ползунка: V=6 при flex 0,15/0,2/0,35 на training и apogee -> out/calib_v6.jsonl")
    ap.add_argument("--levers", action="store_true", help="доп. рычаг: cn_beta (флюгерная устойчивость) при V=4 / 0,5")
    a = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    jl = OUT / ("calib_v6.jsonl" if a.v6 else "calib_levers.jsonl" if a.levers else "calib_verify.jsonl" if a.verify else "calib_classes.jsonl")
    done = set()
    if jl.exists():
        for ln in jl.read_text().splitlines():
            d = json.loads(ln)
            if not d["err"]:
                done.add((d["wing"], d["V"], d["flex"]))
    jobs = [(w, v, f) for w in a.wings.split(",") for v in VS for f in FLEX if (w, v, f) not in done]
    if a.levers:
        jobs = [("training", 4.0, f, {"cn_beta": c}) for f in (0.2, 0.35) for c in (0.0, 0.02, 0.035)] + \
               [("sport", 0.5, 0.2, {"cn_beta": c}) for c in (0.0, 0.035)]
    if a.verify:
        sys.path.insert(0, str(HERE.parents[1] / "flight"))
        import pendulum_params as pp
        jobs = []
        for wid in pp.wing_ids():
            g = json.loads((pp.WINGS / f"{wid}.json").read_text())["group"]
            jobs.append((wid, pp.GROUP_DEFAULTS[g]["dihedral_eff_deg"], pp.GROUP_DEFAULTS[g]["sail_flex"], {"group": g}))
    if a.v6:
        jobs = [(w, 6.0, f, {"v6": 1}) for w in ("training", "apogee") for f in (0.15, 0.2, 0.35)]
    if a.levers or a.verify or a.v6:
        done = set()
    if a.quick:
        jobs = jobs[:1]
    print("заданий", len(jobs), flush=True)
    with ProcessPoolExecutor(a.jobs) as ex, jl.open("a") as fo:
        futs = [ex.submit(do, j) for j in jobs]
        for i, fu in enumerate(as_completed(futs)):
            rec = fu.result()
            fo.write(json.dumps(rec, ensure_ascii=False, default=lambda x: None) + "\n"); fo.flush()
            print(i + 1, rec["wing"], rec["V"], rec["flex"], f"{rec['wall_s']:.0f}s", rec["res"] if not rec["err"] else rec["err"][-300:], flush=True)
    if a.verify:
        summarize_verify(jl)
        return
    if a.levers or a.v6:
        return
    rows = [json.loads(l) for l in jl.read_text().splitlines()]
    rows = [r for r in rows if not r["err"]]
    L = ["# Калибровка умолчаний по классам (PD-12)", "",
         "rev45 — перекладка 45->45, с; t5 — время выхода из виража 30 в центр до |крен|<5, с (nan — не вышло); "
         "phi10/phi20 — крен через 10/20 с после «в центр»; F30 — усилие рук в вираже 30, Н; Ochi — крен через 7 с при 30 Н (laminar).", "",
         "| крыло (класс) | V ° | flex | rev45 | t5 | phi10 | phi20 | F30 | hold30 φ | Ochi φ7 |", "|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (list(WINGS).index(r["wing"]), r["V"], r["flex"])):
        x = r["res"]
        f = lambda k, n=1: "nan" if x.get(k) is None or x[k] != x[k] else f"{x[k]:.{n}f}"  # noqa: E731
        L.append(f"| {r['wing']} ({WINGS[r['wing']]}) | {r['V']:g} | {r['flex']:g} | {f('rev45_s')} | {f('exit30_t5_s')} | {f('exit30_phi10_deg',0)} | "
                 f"{f('exit30_phi20_deg',0)} | {f('hold30_force_N')} | {f('hold30_phi',0)} | {f('ochi_phi7_deg',0)} |")
    (OUT / "calib_classes.md").write_text("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
