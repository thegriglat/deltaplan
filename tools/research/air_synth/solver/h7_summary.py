#!/usr/bin/env python3
"""Итог H7: out_h7/cases.jsonl (+ кривая воркеров из out_h7/bench_w*/) -> out_h7/h7_cost.json и h7_cases.csv.
  ../../air_nn_pilot/.venv/bin/python h7_summary.py [--dir out_h7]"""
import argparse, csv, json, subprocess
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
# P2 (README пилота, проба t_* на 2 воркерах): сошедшиеся ≈ 6,9 с, со всеми ≈ 43 с на случай (max-случаи), 16 % решений не сошлись
P2 = dict(source="air_nn_pilot/README.md, раздел «Воркеры» (проба terrain, 10 мест × 2 условия, 2 воркера, RTX 4070 SUPER)",
          sec_per_case_converged=6.94, sec_per_case_with_max=43.0, nonconverged_solutions_fraction=5 / 32,
          nonconverged_cases_fraction=3 / 16, max_outer=1000)


def load(d):
    f = Path(d) / "cases.jsonl"
    rows = {}
    for l in f.read_text().splitlines():
        if l.strip():
            r = json.loads(l)
            if r.get("ok"):
                rows[r["id"]] = r
    return list(rows.values())


def pct(x, q):
    return float(np.percentile(x, q)) if len(x) else None


def stats(rows):
    wall = [r["wall_s"] for r in rows]
    sols = [(k, v) for r in rows for k, v in r["runs"].items()]
    iters = [v["iters"] for _, v in sols]
    st = [v["status"] for _, v in sols]
    nonconv = [r for r in rows if any(v["status"] != "ok" for v in r["runs"].values())]
    conv = [r for r in rows if all(v["status"] == "ok" for v in r["runs"].values())]
    return dict(n_cases=len(rows), wall_s_median=pct(wall, 50), wall_s_p90=pct(wall, 90), wall_s_mean=float(np.mean(wall)),
                wall_s_converged_cases_mean=float(np.mean([r["wall_s"] for r in conv])) if conv else None,
                wall_s_nonconverged_cases_mean=float(np.mean([r["wall_s"] for r in nonconv])) if nonconv else None,
                n_solutions=len(sols), status_counts={s: st.count(s) for s in sorted(set(st))},
                nonconverged_solutions_fraction=sum(s != "ok" for s in st) / len(st),
                nonconverged_cases_fraction=len(nonconv) / len(rows), iters_median=pct(iters, 50), iters_p90=pct(iters, 90), iters_max=max(iters))


def throughput(d):
    f = Path(d) / "runs.jsonl"
    if not f.exists():
        return None
    runs = [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
    return runs


if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default=str(HERE / "out_h7")); a = ap.parse_args()
    d = Path(a.dir)
    rows = load(d)
    s = stats(rows)
    by = {}
    for r in rows:
        for k, v in r["runs"].items():
            by.setdefault(k, []).append(v)
    per_sol = {k: dict(t_solve_median=pct([x["t_solve"] + x["t_init"] for x in v], 50), t_solve_p90=pct([x["t_solve"] + x["t_init"] for x in v], 90),
                       iters_median=pct([x["iters"] for x in v], 50), iters_max=max(x["iters"] for x in v),
                       nonconverged=sum(x["status"] != "ok" for x in v), n=len(v),
                       late_spread60_p90_max=max([x.get("late_spread60_p90", 0.0) for x in v]))
               for k, v in by.items()}
    # производительность: последний прогон с полным планом при workers = N
    tp = throughput(d) or []
    main_run = max([t for t in tp if not t.get("limit")], key=lambda t: t["n"], default=None)
    out = dict(solver_version=None, device="RTX 4070 SUPER, 20 потоков CPU", device_workers=None, source=None, **{"sec_per_case_median": s["wall_s_median"]},
               sec_per_case_p90=s["wall_s_p90"], stats=s, per_solution=per_sol, p2_comparison=P2)
    try:
        sys_path = str(HERE); import sys; sys.path.insert(0, sys_path); import model_place as M
        out["solver_version"] = M.solver_version()
    except Exception as e:  # noqa: BLE001
        out["solver_version"] = f"? {e!r}"
    plan = json.loads((d / "plan.json").read_text()) if (d / "plan.json").exists() else {}
    out["source"] = plan.get("args", {}).get("source")
    # кривая воркеров (бенчмарки на одном подмножестве) + основной прогон
    curve = []
    for b in sorted(d.glob("bench_w*")):
        rr = throughput(b)
        if rr:
            t = rr[-1]; rs = load(b)
            curve.append(dict(workers=t["workers"], n=t["n"], run_wall_s=t["wall_s"], sec_per_case_throughput=t["wall_s"] / t["n"],
                              sec_per_case_wall_median=stats(rs)["wall_s_median"], ids=sorted(r["id"] for r in rs)))
    if main_run:
        out["device_workers"] = main_run["workers"]
        thr = main_run["wall_s"] / main_run["n"]
        out["throughput"] = dict(workers=main_run["workers"], run_wall_s=main_run["wall_s"], n=main_run["n"], sec_per_case_throughput=thr,
                                 cases_per_day=86400 / thr, cases_per_week=7 * 86400 / thr)
        out["cases_per_day"] = 86400 / thr; out["cases_per_week"] = 7 * 86400 / thr
        out["gpu_busy_fraction_note"] = "один GPU под замком; массовый счёт — только после шлюза пользователя"
    if main_run and main_run["n"] == 12:
        curve.append(dict(workers=main_run["workers"], n=12, run_wall_s=main_run["wall_s"], sec_per_case_throughput=main_run["wall_s"] / 12,
                          sec_per_case_wall_median=s["wall_s_median"], ids=sorted(r["id"] for r in rows), note="основной прогон (холодный старт CuPy)"))
    out["workers_curve"] = sorted(curve, key=lambda c: c["workers"])
    if curve:
        b = min(curve, key=lambda c: c["sec_per_case_throughput"])
        out["best_workers"] = dict(workers=b["workers"], sec_per_case_throughput=b["sec_per_case_throughput"],
                                   cases_per_day=86400 / b["sec_per_case_throughput"], cases_per_week=7 * 86400 / b["sec_per_case_throughput"])
    out["converged_fraction"] = 1 - s["nonconverged_solutions_fraction"]
    out["iters"] = dict(median=s["iters_median"], p90=s["iters_p90"], max=s["iters_max"])
    (d / "h7_cost.json").write_text(json.dumps(out, indent=1, ensure_ascii=False))
    with open(d / "h7_cases.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["id", "hour", "sky", "U10", "wall_s", "h_status", "h_iters", "h_t", "m_status", "m_iters", "m_t"])
        for r in sorted(rows, key=lambda r: r["id"]):
            h, m = r["runs"]["d400_h"], r["runs"]["d400_m"]
            w.writerow([r["id"], r["cond"]["hour"], r["cond"]["sky"], r["cond"]["U10"], r["wall_s"], h["status"], h["iters"],
                        round(h["t_solve"] + h["t_init"], 2), m["status"], m["iters"], round(m["t_solve"] + m["t_init"], 2)])
    print(json.dumps({k: out.get(k) for k in ("sec_per_case_median", "sec_per_case_p90", "converged_fraction", "cases_per_day", "cases_per_week", "device_workers")}, ensure_ascii=False))
