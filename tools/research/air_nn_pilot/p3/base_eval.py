#!/usr/bin/env python3
"""П3-А: линейная база Б1 против решателя (60 м над рельефом, область без 5 клеток у края — как evaluate.py)
на (г) отложенные горные системы и (б) Онгудай, рядом с профилем притока. Решатель не пересчитывается.

  cd tools/research/air_nn_pilot
  /home/greg/deltaplan/tools/dp lock cpu .venv/bin/python p3/base_eval.py
Выход: p3/base_vs_solver.md, p3/base_vs_solver.json (p3 → мелкое; крупного нет).
"""
from __future__ import annotations

import json
import math
import os
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import base as B  # noqa: E402
from pilotnn import prep as P  # noqa: E402
from pilotnn.data import Datasets, case_groups  # noqa: E402
from pilotnn.evaluate import at_level, level_weights  # noqa: E402

DATA = Path(os.environ.get("AIR_NN_DATA", Path.home() / "air_nn_data"))
SPLIT = DATA / "pilot/runs/2026-10-03_p2b/split.json"
EDGE, A_KEY = 5, 60.0
OK_MS, OK_REL, LIFT_OK = 0.3, 0.10, 0.1
# варианты: имя → kwargs linear_base (None — профиль притока без возмущения)
VARIANTS = {"профиль притока": None, "база, потенциальная": {}, "база + JH-подобная (z_ref 300 м)": dict(pert_ref_z=300.0),
            "база + JH-подобная (z_ref 1000 м)": dict(pert_ref_z=1000.0)}
SETS = {"(г) отложенные горные системы": "holdout_sys_ids", "(б) Онгудай": "holdout_place_ids"}


def phys_base(row, hc, kw):
    meta = P.case_meta(row, hc)
    ub = P.ubg(P.AGL, meta["alpha"], meta["mp"], meta["U10"])
    if kw is None:
        c, s = math.cos(meta["r"]), math.sin(meta["r"])
        z = np.zeros((len(P.AGL), *hc.shape))
        u, v, w = ub[:, None, None] * c + z, ub[:, None, None] * s + z, z
        gx = gy = z
    else:
        hr = np.ascontiguousarray(P.rot_scalar(hc, meta["k"]))
        base = B.linear_base(hr, meta["r"], ub, **kw)
        u, v, w, gx, gy = base["u"], base["v"], base["w"], base["gx"], base["gy"]
    uo, vo = P.rot_vec(u, v, -meta["k"] % 4)
    go = P.rot_vec(gx, gy, -meta["k"] % 4)
    return np.stack([uo, vo, P.rot_scalar(w, -meta["k"] % 4), go[0], go[1]]), ub


def main():
    split = json.loads(SPLIT.read_text())
    dss = Datasets([("main", DATA / "pilot/datasets/s0-3acd749/main"), ("terrain", DATA / "pilot/datasets/s0-1c8c322/terrain")])
    rows = {r["id"]: r for r in dss.case_rows()}
    lw = level_weights(P.AGL, A_KEY)
    s = (Ellipsis, slice(EDGE, -EDGE), slice(EDGE, -EDGE))
    acc = {}
    t_base = []
    for sname, key in SETS.items():
        ids = [i for i in split[key] if i in rows][: int(os.environ.get("LIMIT", 10**9))]
        for n, cid in enumerate(ids):
            row = rows[cid]
            z = dss.load(cid)
            hc = z["d400_hc"].astype(np.float64)
            th, tm = z["d400_h"].astype(np.float64), z["d400_m"].astype(np.float64)
            gr = case_groups(row)
            for vn, kw in VARIANTS.items():
                if kw is not None and vn == "база, потенциальная":
                    t0 = time.perf_counter()
                    pv, ub = phys_base(row, hc, kw)
                    t_base.append((time.perf_counter() - t0) * 1000)
                else:
                    pv, ub = phys_base(row, hc, kw)
                ph, pm = at_level(pv, lw)[s], at_level(pv, lw)[s]
                Th, Tm = at_level(th, lw)[s], at_level(tm, lw)[s]
                vt = np.hypot(Th[0], Th[1])
                dw = np.hypot(ph[0] - Th[0], ph[1] - Th[1])
                dwm = np.hypot(pm[0] - Tm[0], pm[1] - Tm[1])
                ok = dw <= np.maximum(OK_MS, OK_REL * vt)
                # разгон: a = ln(|V|/Ub) на 60 м; объяснённая доля — по сумме квадратов вокруг профиля притока
                u60 = float(P.ubg(A_KEY, float(row["profile"]["alpha"]), float(row["profile"]["max_profile"]), float(row["U10"])))
                a_t = np.log(np.maximum(vt, B.EPS) / max(u60, B.EPS))
                a_b = np.log(np.maximum(np.hypot(ph[0], ph[1]), B.EPS) / max(u60, B.EPS))
                gh, gm = gr["gh"], gr["gm"]
                for g in (gh,):
                    a = acc.setdefault((sname, g, vn), dict(dw=[], dwm=[], ok=[], lh=[], e=[], w2=0.0, k2=0.0, r2=0.0, wk=0.0, a2=0.0, ea2=0.0, vec2=0.0, n=0, cases=0))
                    a["dw"].append(dw.astype(np.float32).ravel()); a["dwm"].append(dwm.astype(np.float32).ravel())
                    a["ok"].append(ok.ravel()); a["lh"].append(np.abs(ph[2] - Th[2]).astype(np.float32).ravel())
                    a["e"].append((np.hypot(ph[0], ph[1]) - vt).astype(np.float32).ravel())
                    kin = Th[0] * ph[3] + Th[1] * ph[4]        # V_решателя·∇h_s (по базе; у профиля притока — 0)
                    a["w2"] += float(np.sum(Th[2] ** 2)); a["k2"] += float(np.sum(kin ** 2))
                    a["r2"] += float(np.sum((Th[2] - kin) ** 2)); a["wk"] += float(np.sum(Th[2] * kin))
                    a["a2"] += float(np.sum(a_t ** 2)); a["ea2"] += float(np.sum((a_t - a_b) ** 2))
                    a["vec2"] += float(np.sum(dw ** 2)); a["n"] += dw.size; a["cases"] += 1
                a = acc.setdefault((sname, "m:" + gm, vn), dict(lm=[], cases=0))
                a["lm"].append(np.abs(pm[2] - Tm[2]).astype(np.float32).ravel()); a["cases"] += 1
            if n % 100 == 0:
                print(sname, n, len(ids), flush=True)
    res = {}
    for (sname, g, vn), a in acc.items():
        if g.startswith("m:"):
            lm = np.concatenate(a["lm"])
            res.setdefault(sname, {}).setdefault(g, {})[vn] = dict(cases=a["cases"], lift_m_med=float(np.median(lm)), lift_m_p90=float(np.percentile(lm, 90)))
            continue
        c = lambda k: np.concatenate(a[k])  # noqa: E731
        dw, dwm, lh, e = c("dw"), c("dwm"), c("lh"), c("e")
        res.setdefault(sname, {}).setdefault(g, {})[vn] = dict(
            cases=a["cases"], cells=int(dw.size), wind_med=float(np.median(dw)), wind_p90=float(np.percentile(dw, 90)),
            wind_vs_m_med=float(np.median(dwm)), wind_ok=float(np.concatenate(a["ok"]).mean()),
            lift_h_med=float(np.median(lh)), lift_h_p90=float(np.percentile(lh, 90)), bias=float(e.mean()),
            accel_explained=1 - a["ea2"] / a["a2"], w_rms=math.sqrt(a["w2"] / a["n"]),
            kin_rms=math.sqrt(a["k2"] / a["n"]), wrel_rms=math.sqrt(a["r2"] / a["n"]), w_on_kin=(a["wk"] / a["k2"] if a["k2"] > 0 else None), vec_rms=math.sqrt(a["vec2"] / a["n"]))
    # доля объяснённого вектора: 1 − Σ|Δ|²(вариант) / Σ|Δ|²(профиль притока)
    for sname, d in res.items():
        for g, dv in d.items():
            if g.startswith("m:"):
                continue
            r0 = dv["профиль притока"]["vec_rms"] ** 2
            for vn, v in dv.items():
                v["vec_explained"] = 1 - v["vec_rms"] ** 2 / r0
    tm_ms = float(np.median(t_base)) if t_base else float("nan")
    out = dict(time_case_ms=dict(median=tm_ms, p90=float(np.percentile(t_base, 90)), n=len(t_base)), results=res,
               a_key_m=A_KEY, edge=EDGE)
    Path(HERE / "p3/base_vs_solver.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    write_md(out)


def write_md(out):
    res = out["results"]
    L = ["# П3-А: линейная база против решателя", "",
         "Ошибка против решателя AM-01 на 60 м над рельефом (линейно между 50 и 75 м), область без 5 клеток у края (как в отчёте П-2). "
         "Ветер — |Δ(u,v)| против решения с нагревом (как в отчёте П-2; база нейтральная); подъём — |Δw| с нагревом. "
         "«Разгон объяснён» — 1 − Σ(a_решателя − a_база)²/Σ a_решателя², a = ln(|V|/Ub(60 м)); «вектор объяснён» — 1 − Σ|Δ|²(вариант)/Σ|Δ|²(профиль притока). "
         "Для сравнения: в отчёте П-2 на (г) сошедшиеся — профиль притока 2,461 (7,858) м/с, сеть П-2 0,624 (1,842) м/с.", "",
         "| набор | группа | вариант | случаев / клеток | ветер, м/с: медиана (p90) | ветер ок | подъём с/н, м/с: медиана (p90) | смещение скорости, м/с | разгон объяснён | вектор объяснён |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for sname, d in res.items():
        for g, nm in (("conv", "сошедшиеся"), ("nc", "несошедшиеся")):
            if g not in d:
                continue
            for vn, v in d[g].items():
                L.append(f"| {sname} | {nm} | {vn} | {v['cases']} / {v['cells']} | {v['wind_med']:.3f} ({v['wind_p90']:.3f}) | "
                         f"{100 * v['wind_ok']:.0f} % | {v['lift_h_med']:.3f} ({v['lift_h_p90']:.3f}) | {v['bias']:+.2f} | "
                         f"{100 * v['accel_explained']:.0f} % | {100 * v['vec_explained']:.0f} % |")
    L += ["", "Подъём без нагрева (по статусу `m`), медиана (p90), м/с:", "", "| набор | группа | вариант | случаев | подъём б/н |", "|---|---|---|---|---|"]
    for sname, d in res.items():
        for g, nm in (("m:conv", "сошедшиеся"), ("m:nc", "несошедшиеся")):
            for vn, v in d.get(g, {}).items():
                L.append(f"| {sname} | {nm} | {vn} | {v['cases']} | {v['lift_m_med']:.3f} ({v['lift_m_p90']:.3f}) |")
    L += ["", "Кинематика вертикали на 60 м (решение с нагревом): w_rel = w − V·∇h_s (Б1). Если решатель следует рельефу 400 м, w_rel ≪ w; "
          "«w на кинематике» — коэффициент регрессии w решателя на V·∇h_s (1 — непротекание по сглаженному уклону).", "",
          "| набор | группа | rms w, м/с | rms V·∇h_s | rms w_rel | w на кинематике |", "|---|---|---|---|---|---|"]
    for sname, d in res.items():
        for g, nm in (("conv", "сошедшиеся"), ("nc", "несошедшиеся")):
            v = d.get(g, {}).get("база, потенциальная")
            if v:
                L.append(f"| {sname} | {nm} | {v['w_rms']:.3f} | {v['kin_rms']:.3f} | {v['wrel_rms']:.3f} | {v['w_on_kin']:.2f} |")
    t = out["time_case_ms"]
    L += ["", f"время на случай, мс: {t['median']:.1f}", "",
          f"(база 96² × 13 высот, 1 поток CPU, медиана по {t['n']} случаям, p90 {t['p90']:.1f} мс; замер при параллельной нагрузке других задач)", "",
          "Воспроизведение: `cd tools/research/air_nn_pilot && /home/greg/deltaplan/tools/dp lock cpu .venv/bin/python p3/base_eval.py`"]
    Path(HERE / "p3/base_vs_solver.md").write_text("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
