#!/usr/bin/env python3
"""P3E6: вариант (0) П-3 (контроль, кодировка П-2, та же ширина, 100 мест, тот же сплит, зерно, эпохи и ранняя
остановка) + 9 чисел FiLM фоновой стратификации (pilotnn/film_bg.py) → обучение, оценка (отложенные системы и
обучающие места), таблица против (0).

Код: снимок ветки air-nn/NN-P12 (b40cbee, конвейер П-3) + правка `p3/p3e6_nnp12.patch` (train.py: числа фона
к F по enc.film_bg; знак отражения фона +1) + pilotnn/film_bg.py + этот файл — см. README «P3E6».

  .venv/bin/python p3/p3e6.py [--only train|eval|train_eval|table]
Шаги (готовое пропускается): train p3e6 → eval p3e6 → оценка на обучающих местах (p3e6 и v0_ctrl, как
p3/train_eval.py NN-P12) → таблица reports/<run>/p3e6_vs_v0.{md,json}.
GPU — замок пилота (GpuLock) кусками внутри train/evaluate.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402

RUN_NAME = "2026-10-03_p3e6"
EMPTY = ("holdout_sys_ids", "holdout_place_ids", "holdout_proc_ids", "newcond_ids", "newcond_p6_ids", "newcond_old_ids")


def sh(args, log):
    with open(log, "a") as f:
        f.write(f"\n[{time.strftime('%F %T')}] {' '.join(map(str, args))}\n")
        f.flush()
        return subprocess.run([sys.executable, *map(str, args)], cwd=HERE, stdout=f, stderr=subprocess.STDOUT,
                              env=dict(os.environ, PYTHONUNBUFFERED="1")).returncode


def step_log(run, **kw):
    with open(run / "steps.jsonl", "a") as f:
        f.write(json.dumps(dict(t=time.strftime("%F %T"), **kw), ensure_ascii=False) + "\n")


def pick(m, s, g):
    """(сошедшиеся/несошедшиеся) числа набора s из metrics.json."""
    d = ((m["sets"].get(s) or {}).get("net") or {}).get(g)
    if not d:
        return None
    a = d["area"]
    rho = a.get("rho") or {}
    return dict(n_cases=d["n_cases"], wind_median=a["wind"]["median"], wind_p90=a["wind"]["p90"],
                frac_wind_ok=a["frac_wind_ok"], frac_lift_h_ok=a.get("frac_lift_h_ok"),
                frac_lift_m_ok=a.get("frac_lift_m_ok"), rho_median=rho.get("median"), rho_p90=rho.get("p90"))


def table(rows, out_md, out_json):
    res = {}
    for name, (mp, tp) in rows.items():
        m = json.loads(Path(mp).read_text())
        t = json.loads(Path(tp).read_text()) if tp and Path(tp).exists() else None
        res[name] = dict(best_val=m["main"]["best"], epochs=m["main"]["epochs"],
                         holdout_sys=dict(conv=pick(m, "holdout_sys", "conv"), nc=pick(m, "holdout_sys", "nc")),
                         train=dict(conv=pick(t, "train", "conv"), nc=pick(t, "train", "nc"),
                                    all=pick(t, "train", "all")) if t else None)
    Path(out_json).write_text(json.dumps(res, ensure_ascii=False, indent=1))
    P = lambda x: "—" if x is None else f"{100 * x:.0f} %"   # noqa: E731
    F = lambda x: "—" if x is None else f"{x:.3f}"          # noqa: E731
    L = ["# P3E6 против (0): числа фоновой стратификации в FiLM", "",
         "60 м, все клетки области без края; ветер — |Δ(u, v)| с нагревом, м/с; «ок» ветра — П3 (≤ 0,3 м/с или 10 %), "
         "подъём «ок» — |Δw| ≤ 0,1 м/с (без нагрева / с нагревом); ρ — заменимость (П3 v4).", ""]
    hdr = "| сеть | набор | случаев | ветер мед. | ветер p90 | «ок» ветра | подъём «ок» m/h | ρ мед. | ρ p90 |"
    for title, key in (("Отложенные горные системы (г)", "holdout_sys"), ("Обучающие места (60 случаев из обучения curve_100)", "train")):
        L += [f"## {title}", "", hdr, "|---|---|---|---|---|---|---|---|---|"]
        for name, r in res.items():
            src = r[key] if key == "holdout_sys" else (r["train"] or {})
            for g, gl in (("conv", "сошедшиеся"), ("nc", "несошедшиеся")):
                x = src.get(g)
                if not x:
                    continue
                L.append(f"| {name} | {gl} | {x['n_cases']} | {F(x['wind_median'])} | {F(x['wind_p90'])} | {P(x['frac_wind_ok'])} | "
                         f"{P(x['frac_lift_m_ok'])}/{P(x['frac_lift_h_ok'])} | {F(x['rho_median'])} | {F(x['rho_p90'])} |")
        L.append("")
    L += ["## Обучение", "", "| сеть | лучшая проверка | эпоха | эпох |", "|---|---|---|---|"]
    for name, r in res.items():
        L.append(f"| {name} | {r['best_val']['val']:.4f} | {r['best_val']['epoch'] + 1} | {r['epochs']} |")
    Path(out_md).write_text("\n".join(L) + "\n")
    print("\n".join(L))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None)
    a = ap.parse_args()
    cfg = C.load_config(HERE / "config.yaml")
    p3 = cfg["p3"]
    base = C.expand(cfg["paths"]["base"], cfg)
    p2 = base / "runs" / p3["p2_run"]
    run0, rep0 = base / "runs" / p3["run"], base / "reports" / p3["run"]
    run, rep = base / "runs" / RUN_NAME, base / "reports" / RUN_NAME
    run.mkdir(parents=True, exist_ok=True)
    rep.mkdir(parents=True, exist_ok=True)
    log = run / "run_p3e6.log"
    info2 = json.loads((p2 / "run_info.json").read_text())
    split = json.loads((p2 / "split.json").read_text())
    t100 = json.loads((p2 / "curve_100" / "task.json").read_text())
    bg = run / "film_bg.npz"
    assert bg.exists(), "сначала p3/p3e6_bg.py"
    # задача: как run_p3.net_task(t100, v0_ctrl) + enc.film_bg
    spec = p3["variants"]["v0_ctrl"]
    t = copy.deepcopy(t100)
    t["train"]["seed"] = int(p3["seed"])
    t["train"]["max_epochs"] = int(p3["max_epochs"])
    enc = dict(inputs=spec["inputs"], outputs=spec["outputs"], pack=0, w_rel_weight=float(p3["w_rel_weight"]))
    t0task = json.loads((run0 / "v0_ctrl" / "net" / "task.json").read_text())
    same = {k: t0task.get(k) == v for k, v in dict(t, label=t0task["label"], enc=enc, prep5_dirs=[]).items()}
    assert all(same.values()), f"задача не совпала с (0): {[k for k, v in same.items() if not v]}"
    enc["film_bg"] = str(bg)
    t.update(label="P3E6: (0) + числа фона θ̄(z) в FiLM", enc=enc, prep5_dirs=[])
    d = run / "p3e6" / "net"
    d.mkdir(parents=True, exist_ok=True)
    if C.read_json(d / "task.json") != json.loads(json.dumps(t)):
        C.atomic_write_json(d / "task.json", t)
    C.atomic_write_json(run / "p3e6" / "enc.json", enc)

    if a.only in (None, "train"):
        m = C.read_json(d / "manifest.json", {}) or {}
        if not m.get("complete"):
            t0 = time.time()
            rc = sh(["-m", "pilotnn.train", d], log)
            m = C.read_json(d / "manifest.json", {}) or {}
            step_log(run, step="train", name="p3e6", rc=rc, t_s=round(time.time() - t0, 1), epochs=m.get("epochs"),
                     t_epoch=m.get("t_epoch_median_s"), best=m.get("best"))
            if rc:
                return rc

    def evaluate(name, main_dir, sp):
        r = run / name
        r.mkdir(parents=True, exist_ok=True)
        C.atomic_write_json(r / "config.json", cfg)
        C.atomic_write_json(r / "split.json", sp)
        if not (r / "p6.json").exists():
            C.atomic_write_json(r / "p6.json", json.loads((p2 / "p6.json").read_text()))
        C.atomic_write_json(r / "run_info.json", dict(copy.deepcopy(info2), curve=[], main_dir=str(main_dir),
                                                      onnx_path=str(r / "model.onnx"), name=name))
        t0 = time.time()
        rc = sh(["-m", "pilotnn.evaluate", "eval", r, rep / name], log)
        step_log(run, step="eval", name=name, rc=rc, t_s=round(time.time() - t0, 1))
        return rc

    if a.only in (None, "eval"):
        rc = evaluate("p3e6", d, split)
        if rc:
            return rc
    if a.only in (None, "train_eval"):
        sp = dict(split, train_ids=t100["train_ids"], **{k: [] for k in EMPTY})
        for name, nd in (("p3e6__train", d), ("v0_ctrl__train", run0 / "v0_ctrl" / "net")):
            rc = evaluate(name, nd, sp)
            if rc:
                return rc
    if a.only in (None, "table"):
        table({"(0) контроль": (rep0 / "v0_ctrl" / "metrics.json", rep / "v0_ctrl__train" / "metrics.json"),
               "P3E6 (0)+фон": (rep / "p3e6" / "metrics.json", rep / "p3e6__train" / "metrics.json")},
              rep / "p3e6_vs_v0.md", rep / "p3e6_vs_v0.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
