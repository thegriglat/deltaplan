#!/usr/bin/env python3
"""P3E8: вариант (0) П-3 (контроль P3E0: кодировка П-2, 100 рельефов, тот же сплит, зерно, эпохи, ранняя остановка),
но обучение и проверка — только на «уверенно сошедшихся» случаях (pilotnn.data.confident; списки — p3/p3e8_conv.py).
Оценка: отложенные системы, группы сошедшиеся / несошедшиеся / уверенно (evaluate: группа conf); P3E0 и P3E1 (v1_wide)
пересчитаны своими сетями тем же кодом; обучающие места — как p3/train_eval.py.

  .venv/bin/python p3/p3e8_conv.py && .venv/bin/python p3/p3e8.py [--only train|eval|train_eval|table]
GPU — замок пилота (GpuLock) кусками внутри train/evaluate. Запуск: dp job start p3e8 <таймаут> ... (без --lock gpu).
"""
from __future__ import annotations

import argparse, copy, json, os, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402

RUN_NAME = "2026-10-04_p3e8"
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
                         holdout_sys={g: pick(m, "holdout_sys", g) for g in ("conv", "nc", "conf")},
                         train={g: pick(t, "train", g) for g in ("conv", "nc", "conf")} if t else None)
    Path(out_json).write_text(json.dumps(res, ensure_ascii=False, indent=1))
    P = lambda x: "—" if x is None else f"{100 * x:.0f} %"   # noqa: E731
    F = lambda x: "—" if x is None else f"{x:.3f}"          # noqa: E731
    L = ["# P3E8 против P3E0 и P3E1: обучение только на уверенно сошедшихся", "",
         "60 м, все клетки области без края; ветер — |Δ(u, v)| с нагревом, м/с; «ок» ветра — П3 (≤ 0,3 м/с или 10 %), "
         "подъём «ок» — |Δw| ≤ 0,1 м/с (без нагрева / с нагревом); ρ — заменимость (П3 v4). «Уверенно» — см. conv_stats.md.", ""]
    hdr = "| сеть | группа | случаев | ветер мед. | ветер p90 | «ок» ветра | подъём «ок» m/h | ρ мед. | ρ p90 |"
    gl = dict(conv="сошедшиеся", nc="несошедшиеся", conf="уверенно сошедшиеся")
    for title, key in (("Отложенные горные системы (г)", "holdout_sys"), ("Обучающие места (60 случаев из обучения curve_100)", "train")):
        L += [f"## {title}", "", hdr, "|---|---|---|---|---|---|---|---|---|"]
        for g in ("conv", "nc", "conf"):
            for name, r in res.items():
                src = r[key] if key == "holdout_sys" else (r["train"] or {})
                x = (src or {}).get(g)
                if not x:
                    continue
                L.append(f"| {name} | {gl[g]} | {x['n_cases']} | {F(x['wind_median'])} | {F(x['wind_p90'])} | {P(x['frac_wind_ok'])} | "
                         f"{P(x['frac_lift_m_ok'])}/{P(x['frac_lift_h_ok'])} | {F(x['rho_median'])} | {F(x['rho_p90'])} |")
        L.append("")
    L += ["## Обучение", "", "| сеть | лучшая проверка | эпоха | эпох |", "|---|---|---|---|"]
    for name, r in res.items():
        L.append(f"| {name} | {r['best_val']['val']:.4f} | {r['best_val']['epoch'] + 1} | {r['epochs']} |")
    L.append("\nПроверка у P3E8 — на другом наборе (только уверенные), с P3E0/P3E1 по значению не сравнивать.")
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
    log = run / "run_p3e8.log"
    info2 = json.loads((p2 / "run_info.json").read_text())
    split = json.loads((p2 / "split.json").read_text())
    t100 = json.loads((p2 / "curve_100" / "task.json").read_text())
    conf = json.loads((run / "conf_ids.json").read_text())
    t0task = json.loads((run0 / "v0_ctrl" / "net" / "task.json").read_text())
    t = copy.deepcopy(t0task)                                  # всё как у P3E0 (v0_ctrl), меняются только списки
    t["train_ids"], t["val_ids"] = conf["train_ids"], conf["val_ids"]
    assert set(t["train_ids"]) <= set(t0task["train_ids"]) and set(t["val_ids"]) <= set(t0task["val_ids"])
    assert t0task["train_ids"] == t100["train_ids"] and t0task["train"]["seed"] == int(p3["seed"])
    t["label"] = "P3E8: (0) на уверенно сошедшихся"
    d = run / "p3e8" / "net"
    d.mkdir(parents=True, exist_ok=True)
    if C.read_json(d / "task.json") != json.loads(json.dumps(t)):
        C.atomic_write_json(d / "task.json", t)
    C.atomic_write_json(run / "p3e8" / "enc.json", t["enc"])

    if a.only in (None, "train"):
        m = C.read_json(d / "manifest.json", {}) or {}
        if not m.get("complete"):
            t0 = time.time()
            rc = sh(["-m", "pilotnn.train", d], log)
            m = C.read_json(d / "manifest.json", {}) or {}
            step_log(run, step="train", name="p3e8", rc=rc, t_s=round(time.time() - t0, 1), epochs=m.get("epochs"),
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

    nets = {"p3e8": d, "v0_ctrl": run0 / "v0_ctrl" / "net", "v1_wide": run0 / "v1_wide" / "net"}
    if a.only in (None, "eval"):
        for n, nd in nets.items():             # те же сети, новая группа conf (E0, E1 — их собственные веса)
            if not (rep / n / "metrics.json").exists():
                rc = evaluate(n, nd, split)
                if rc:
                    return rc
    if a.only in (None, "train_eval"):
        sp = dict(split, train_ids=t100["train_ids"], **{k: [] for k in EMPTY})
        for n, nd in nets.items():
            if not (rep / f"{n}__train" / "metrics.json").exists():
                rc = evaluate(f"{n}__train", nd, sp)
                if rc:
                    return rc
    if a.only in (None, "table"):
        table({"P3E0 (v0_ctrl)": (rep / "v0_ctrl" / "metrics.json", rep / "v0_ctrl__train" / "metrics.json"),
               "P3E1 (v1_wide)": (rep / "v1_wide" / "metrics.json", rep / "v1_wide__train" / "metrics.json"),
               "P3E8 (уверенные)": (rep / "p3e8" / "metrics.json", rep / "p3e8__train" / "metrics.json")},
              rep / "p3e8_vs_e0.md", rep / "p3e8_vs_e0.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
