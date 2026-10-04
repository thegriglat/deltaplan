"""AN-2: оценка ann2 против P2 на тех же случаях и клетках (A3 v1).
`evaluate.py --run <имя>` → таблица в stdout, `metrics.json` и `eval.md` в каталоге прогона.
Точки: все клетки области без edge_cells на 60 м над рельефом (линейно между 50 и 75 м), как П3 v2; ann2 — на полной
карте 96² целиком (без вырезок), без отражения; решение с нагревом — условия «нагрев», решение без нагрева — условия
«без нагрева» (нулевая карта потока тепла, числа нагрева = 0).  P2 — сеть `runs/2026-10-03_p2b` (код — pilotnn).
Метрики — по клеткам группы: ошибка ветра |Δ(u,v)| с нагревом (медиана, p90), относительная |Δ|/|V| (медиана),
ρ15 = |Δ|/max(0,15·|V|; 0,01 м/с) (медиана, p90), доли ок15 (ρ15 ≤ 1) и ок10 (|Δ| ≤ max(0,10·|V|; 0,01)), подъём |Δw|
с нагревом и без (медианы). Самопроверка: медиана ошибки P2 на (г) против отчёта P2 (`p2_selfcheck_diff`).
A3 v2 (AN-4): `--run <имя> [--also <прогон> …]` — ann2 (точка best.pt, если есть), прочие прогоны ann2 и P2 на одних клетках;
группы — по механическим случаям (A1 v2, regime.py) + строка «(г) конвективные» (все отложенные (г) конвективные случаи) для всех
сетей; `criterion_10_15: выполнен|нет` — медиана относительной ошибки ann2 на (г) механических ≤ 0,15 (цель ≤ 0,10), отдельно
от `better_than_p2`. Самопроверка P2 — на прежней группе (г) всех случаев.
`--smoke` ограничивает число случаев групп (б), (б′), (а), обучающих (по 40); (г) — всегда полная.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch

import data as D
import model as M
import phys
import regime as RG
from pilotnn import evaluate as E, prep as P  # noqa: E402
from pilotnn.data import Datasets, case_groups  # noqa: E402
from pilotnn.train import enc_of, load_arrays_enc  # noqa: E402

EDGES = (0, 2, 4, 6)
MIN_V = 0.01          # м/с, порядок шума решателя (AN-1)
GROUPS = [  # (ключ, название, наборы, фильтр)
    ("g_all", "(г) все механические", ("holdout_sys",), "mech"),
    ("g_conv", "(г) сошедшиеся", ("holdout_sys",), "conv"),
    ("g_nc", "(г) несошедшиеся", ("holdout_sys",), "nc"),
    ("g_u0", "(г) U10 0–2", ("holdout_sys",), ("u", 0)), ("g_u1", "(г) U10 2–4", ("holdout_sys",), ("u", 1)),
    ("g_u2", "(г) U10 4–6", ("holdout_sys",), ("u", 2)), ("g_u3", "(г) U10 ≥ 6", ("holdout_sys",), ("u", 3)),
    ("g_cv", "(г) конвективные (w*/U > порога)", ("holdout_sys",), "cv"),
    ("b", "(б) Онгудай", ("holdout_place",), None), ("b2", "(б′) отложенные процедурные", ("holdout_proc",), None),
    ("a", "(а) новые условия", ("newcond_p6", "newcond_old"), None), ("tr", "обучающие", ("train",), None),
    ("g_everything", "(г) все случаи (самопроверка P2)", ("holdout_sys",), "everything")]


def ubin(u):
    return int(np.searchsorted(EDGES, u, side="right") - 1)


@torch.no_grad()
def ann2_h60(model, X, F, metas, heated, dev, lw):
    """Предсказание ann2 на 60 м: (B, 4, ny, nx) u, v, w, θ′ в исходной системе."""
    par = np.stack([phys.case_par(m) for m in metas]); prof = np.stack([phys.profile_input(p, phys.bg_theta_of(m)) for p, m in zip(par, metas)])
    inp = D.eval_inputs(X, F, par, prof, heated, dev, N=np.array([RG.n_bl(m) for m in metas], np.float32))
    B, _, H, W = inp["maps"].shape
    eta = torch.tensor([50.0, 75.0], device=dev).view(1, 2, 1, 1).expand(B, 2, H, W)
    o = model(inp["maps"], inp["scal"], inp["prof"], inp["par"], eta)[:, :, :4].cpu().numpy()   # (B,2,4,H,W)
    out = []
    for i, m in enumerate(metas):
        ph = phys.to_physical(o[i].transpose(1, 0, 2, 3), m, [50.0, 75.0])           # (4,2,ny,nx)
        out.append(lw[1] * ph[:, 0] + lw[2] * ph[:, 1])
    return np.stack(out)


def stats(cells):
    """cells: dict массивов по клеткам группы (dw, vt, dwh, dwm) → числа."""
    dw, vt = cells["dw"], cells["vt"]
    rho = dw / np.maximum(0.15 * vt, MIN_V)
    return dict(n_cells=int(dw.size), wind_median=float(np.median(dw)), wind_p90=float(np.percentile(dw, 90)),
                rel_median=float(np.median(dw / np.maximum(vt, MIN_V))), rho15_median=float(np.median(rho)),
                rho15_p90=float(np.percentile(rho, 90)), ok15=float(np.mean(rho <= 1.0)),
                ok10=float(np.mean(dw <= np.maximum(0.10 * vt, MIN_V))),
                lift_h_median=float(np.median(cells["dlh"])), lift_m_median=float(np.median(cells["dlm"])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--also", nargs="*", default=[], help="прочие прогоны ann2 на тех же клетках (AN-3: an3_pilot)")
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--n_small", type=int, default=40)
    args = ap.parse_args()
    dev = torch.device(args.device)
    run = D.RUNS / args.run
    nets = {}
    for rn in [args.run] + list(args.also):
        f = D.RUNS / rn / ("best.pt" if (D.RUNS / rn / "best.pt").exists() else "model.pt")
        nets[f"ann2:{rn}"], ckx = M.load_run(f, dev)
        nets[f"ann2:{rn}"].point = f"{f.name} (шаг {ckx.get('step')})"
        if rn == args.run:
            ck = ckx
    names = tuple(nets) + ("P2",)
    print("точки:", {k: v.point for k, v in nets.items()}, flush=True)
    cfg = D.p2_config(); ec = cfg["eval"]
    info, split = D.p2_info(), D.p2_split()
    dss = Datasets([(d["name"], d["root"]) for d in info["datasets"]])
    rows = {r["id"]: r for r in dss.case_rows()}
    agl = dss.agl
    lw0 = E.level_weights(agl, ec["agl_key_m"])
    t = (ec["agl_key_m"] - 50.0) / 25.0
    lw_ann = (None, 1 - t, t)
    p2net, task = E.load_net(Path(info.get("main_dir") or D.P2_RUN / "main"), dev)
    enc = enc_of(task); prep = info["prep_dirs"]
    e = ec["edge_cells"]; s = (Ellipsis, slice(e, -e or None), slice(e, -e or None))
    rng = np.random.default_rng(0)
    sets = {k: list(split[k + "_ids"]) for k in ("holdout_sys", "holdout_place", "holdout_proc", "newcond_p6", "newcond_old")}
    # A1 v2: кроме (г) — только механические случаи (в (г) конвективные считаются отдельной строкой)
    for k in sets:
        if k != "holdout_sys":
            sets[k] = [i for i in sets[k] if RG.regime(i) == "mech"]
    tr = [i for i in split["train_ids"] if RG.regime(i) == "mech"]
    sets["train"] = sorted(rng.choice(tr, ec["max_train_eval"], replace=False).tolist())
    if args.smoke:
        for k in sets:
            sets[k] = sets[k][:args.n_small] if k != "holdout_sys" else sets[k][:3 * args.n_small]
    per_case = {k: [] for k in sets}       # по набору: список (случай, gh, U10, {модель: клетки})
    t0 = time.time()
    for sname, ids in sets.items():
        for i0 in range(0, len(ids), 32):
            part = ids[i0:i0 + 32]
            X, F, _, _, metas = load_arrays_enc(prep, enc, part, with_y=False)
            Yp = E.predict(p2net, X, F, dev)
            ahm = {nm: (ann2_h60(n_, X, F, metas, True, dev, lw_ann), ann2_h60(n_, X, F, metas, False, dev, lw_ann))
                   for nm, n_ in nets.items()}
            for i, cid in enumerate(part):
                row = rows[cid]; z = dss.load(cid); gr = case_groups(row)
                th = E.at_level(z["d400_h"].astype(np.float64), lw0)[s]; tm = E.at_level(z["d400_m"].astype(np.float64), lw0)[s]
                pf = E.to_phys_net(Yp[i], metas[i], agl, enc, z["d400_hc"].astype(np.float64))
                preds = dict(P2=(E.at_level(pf["h"], lw0)[s], E.at_level(pf["m"], lw0)[s]))
                for nm, (ah, am) in ahm.items():
                    preds[nm] = (ah[i][s], am[i][s])
                vt = np.hypot(th[0], th[1]); cc = {}
                for nm, (ph, pm) in preds.items():
                    cc[nm] = dict(dw=np.hypot(ph[0] - th[0], ph[1] - th[1]).ravel(), vt=vt.ravel(),
                                  dlh=np.abs(ph[2] - th[2]).ravel(), dlm=np.abs(pm[2] - tm[2]).ravel())
                per_case[sname].append(dict(id=cid, gh=gr["gh"], U10=float(row["U10"]), reg=RG.regime(cid), cells=cc))
        print(f"{sname}: {len(ids)} случаев, {time.time() - t0:.0f} с", flush=True)
    res = {}
    for key, title, snames, flt in GROUPS:
        cs = [c for sn in snames for c in per_case[sn]]
        if flt == "cv":
            cs = [c for c in cs if c["reg"] == "conv"]
        elif flt == "everything":
            pass
        else:
            cs = [c for c in cs if c["reg"] == "mech"]
        if flt in ("conv", "nc"):
            cs = [c for c in cs if c["gh"] == flt]
        elif isinstance(flt, tuple):
            cs = [c for c in cs if ubin(c["U10"]) == flt[1]]
        if not cs:
            continue
        res[key] = dict(title=title, n_cases=len(cs))
        for nm in names:
            cat = {k: np.concatenate([c["cells"][nm][k] for c in cs]) for k in ("dw", "vt", "dlh", "dlm")}
            res[key][nm] = stats(cat)
    # самопроверка P2 против отчёта
    rep = json.loads((D.P2_REPORT / "metrics.json").read_text())["sets"]["holdout_sys"]["net"]
    ref = dict(conv=rep["conv"]["area"]["wind"]["median"], all=rep["all"]["area"]["wind"]["median"])
    # конв. «сошедшиеся» у v1 — по всем случаям (г): пересчёт из групп по случаям без фильтра режима
    allc = per_case["holdout_sys"]
    def med(cs):
        return float(np.median(np.concatenate([c["cells"]["P2"]["dw"] for c in cs])))
    mine = dict(conv=med([c for c in allc if c["gh"] == "conv"]), all=med(allc))
    diff = {k: abs(mine[k] - ref[k]) for k in ref}
    out = dict(run=args.run, smoke=args.smoke, point="60 м AGL (50–75 м), без edge_cells=%d" % e, groups=res,
               selfcheck=dict(ref=ref, p2=mine, diff=diff), p2_selfcheck_diff=max(diff.values()),
               train_config={k: ck["config"].get(k) for k in ("steps", "batch", "lr", "params", "commit", "head", "regime", "fr_old")},
               points={k: v.point for k, v in nets.items()}, wsu_thr=RG.WSU_THR,
               time_s=time.time() - t0)
    (run / "metrics.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    hdr = ("| группа | случаев | модель | ошибка м/с мед (p90) | отн. мед | ρ15 мед (p90) | ок15 | ок10 | подъём с/без нагрева мед |\n"
           "|---|---|---|---|---|---|---|---|---|")
    lines = [hdr]
    for key, g in res.items():
        for nm in names:
            r = g[nm]
            lines.append(f"| {g['title']} | {g['n_cases']} | {nm} | {r['wind_median']:.3f} ({r['wind_p90']:.3f}) | "
                         f"{r['rel_median']:.2f} | {r['rho15_median']:.2f} ({r['rho15_p90']:.2f}) | {100 * r['ok15']:.0f} % | "
                         f"{100 * r['ok10']:.0f} % | {r['lift_h_median']:.3f} / {r['lift_m_median']:.3f} |")
    g0 = res["g_all"]
    me, p2 = g0[f"ann2:{args.run}"], g0["P2"]
    crit = "выполнен" if me["rel_median"] <= 0.15 else "нет"
    goal = "выполнена" if me["rel_median"] <= 0.10 else "нет"
    better = "да" if (me["wind_median"] < p2["wind_median"]) else "нет"
    out["criterion_10_15"] = dict(verdict=crit, goal_10=goal, rel_median=me["rel_median"], p2_rel_median=p2["rel_median"])
    out["better_than_p2"] = dict(verdict=better, wind_median=me["wind_median"], p2_wind_median=p2["wind_median"],
                                 gain_pct=100 * (1 - me["wind_median"] / p2["wind_median"]))
    (run / "metrics.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    md = (f"# Оценка ann2 против P2 — прогон {args.run}{' (smoke)' if args.smoke else ''}\n\nТочки: {out['point']}; ann2 — на полной "
          f"карте 96²; сети: {out['points']}; механические случаи: w*/U ≤ {RG.WSU_THR}.\n\n" + "\n".join(lines) + f"\n\nСамопроверка P2: медиана на (г) сошедшиеся {mine['conv']:.4f} против отчёта "
          f"{ref['conv']:.4f}; все {mine['all']:.4f} против {ref['all']:.4f}.\n")
    md += (f"\ncriterion_10_15: {crit} — медиана относительной ошибки ann2 на (г) механических {me['rel_median']:.3f} "
           f"(допустимо ≤ 0,15; цель ≤ 0,10: {goal}); P2 {p2['rel_median']:.3f}\n"
           f"better_than_p2: {better} — медиана |Δ| на (г) механических {me['wind_median']:.3f} против {p2['wind_median']:.3f} м/с "
           f"({100 * (1 - me['wind_median'] / p2['wind_median']):.1f} %)\n")
    (run / "eval.md").write_text(md)
    print(md.split("\n\nСамопроверка")[-1])
    import shutil
    od = Path(__file__).resolve().parent / "out" / args.run
    od.mkdir(parents=True, exist_ok=True)
    for fn in ("eval.md", "metrics.json", "config.json", "train_log.csv"):
        if (run / fn).exists():
            shutil.copy(run / fn, od / fn)
    print("\n".join(lines))
    print(f"p2_selfcheck_conv {mine['conv']:.4f} ref {ref['conv']:.4f}; p2_selfcheck_all {mine['all']:.4f} ref {ref['all']:.4f}")
    print(f"p2_selfcheck_diff {out['p2_selfcheck_diff']:.5f}")


if __name__ == "__main__":
    main()
