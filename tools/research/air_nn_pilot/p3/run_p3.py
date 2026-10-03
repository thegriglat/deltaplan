#!/usr/bin/env python3
"""Опыты П-3 (NN-P12) одним скриптом: кодировка (П2 v5) против ёмкости на данных П-2, затем лучший на 300 местах.

  .venv/bin/python p3/run_p3.py            — весь план (продолжение с места при повторе)
  .venv/bin/python p3/run_p3.py --probe    — проба времени: по 1 эпохе вариантов (0), (1), (4) (каталоги probe_*)
  .venv/bin/python p3/run_p3.py --smoke    — сквозная проверка кода на крошечных списках (свои каталоги *_smoke)

Шаги (готовое пропускается по manifest.json; обучение продолжается с чекпойнта; одна строка на шаг в steps.jsonl):
  1. кеш v5 (prep5: карты 9–26, цель v5 при γ = 0, K, V) для всех случаев деления П-2 — рядом с кешем v4, своё имя;
  2. оценка сетей П-2 (main, curve_100) новым evaluate (заменимость ρ) — веса П-2 только читаются;
  3. варианты (0)–(4) на 100 местах (списки и гиперпараметры curve_100 П-2; зерно p3.seed; γ_a — по обучению
     варианта) → обучение → оценка;
  4. лучший из (1)–(4) по медиане ошибки ветра на 60 м, (г) сошедшиеся (при разнице в пределах разброса
     |(0) − curve_100| — по p90) → обучение на 300 местах (списки main П-2) → оценка;
  5. таблица p3/variants_table.py → reports/<run>/variants.md, variants.json.
GPU — замком пилота (GpuLock, тот же файл, что `dp lock gpu`), кусками внутри train/evaluate.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402
from pilotnn import prep5 as P5  # noqa: E402

PY = sys.executable
_child = None


def _sig(signum, frame):
    if _child is not None and _child.poll() is None:
        _child.send_signal(signum)
    raise SystemExit(130 if signum == signal.SIGINT else 143)


def sh(args, log):
    """Шаг — процессом; вывод — в журнал; → код выхода."""
    global _child
    with open(log, "a") as f:
        f.write(f"\n[{time.strftime('%F %T')}] {' '.join(map(str, args))}\n")
        f.flush()
        _child = subprocess.Popen([PY, *map(str, args)], cwd=HERE, stdout=f, stderr=subprocess.STDOUT,
                                  env=dict(os.environ, PYTHONUNBUFFERED="1"))
        rc = _child.wait()
        _child = None
    return rc


def step_log(run: Path, **kw):
    with open(run / "steps.jsonl", "a") as f:
        f.write(json.dumps(dict(t=time.strftime("%F %T"), **kw), ensure_ascii=False) + "\n")


def write_if_changed(p: Path, obj):
    if C.read_json(p) != json.loads(json.dumps(obj)):
        C.atomic_write_json(p, obj)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--config", default=str(HERE / "config.yaml"))
    a = ap.parse_args()
    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)
    cfg = C.load_config(a.config)
    p3 = cfg["p3"]
    base = C.expand(cfg["paths"]["base"], cfg)
    p2 = base / "runs" / p3["p2_run"]
    tag = p3["run"] + ("_smoke" if a.smoke else "")
    run, rep = base / "runs" / tag, base / "reports" / tag
    run.mkdir(parents=True, exist_ok=True)
    rep.mkdir(parents=True, exist_ok=True)
    log = run / "run_p3.log"
    print(f"П-3: прогон {run}\n  журнал {log}\n  отчёт {rep}", flush=True)
    info2 = json.loads((p2 / "run_info.json").read_text())
    split = json.loads((p2 / "split.json").read_text())
    t100 = json.loads((p2 / "curve_100" / "task.json").read_text())
    t300 = json.loads((p2 / "main" / "task.json").read_text())
    ids_cut = None
    if a.smoke:                                  # крошечные списки: проверка кода, не числа
        t100 = dict(t100, train_ids=t100["train_ids"][:24], val_ids=t100["val_ids"][:8])
        t300 = dict(t300, train_ids=t300["train_ids"][:24], val_ids=t300["val_ids"][:8])
        for k in ("holdout_sys_ids", "holdout_place_ids", "holdout_proc_ids", "newcond_p6_ids", "newcond_old_ids"):
            split[k] = split[k][:6]
        split["train_ids"] = split["train_ids"][:24]
        ids_cut = set(t100["train_ids"] + t100["val_ids"] + t300["train_ids"] + t300["val_ids"]
                      + sum((split[k] for k in ("holdout_sys_ids", "holdout_place_ids", "holdout_proc_ids",
                                                "newcond_p6_ids", "newcond_old_ids", "train_ids")), []))

    # 1. кеш v5
    ch = C.code_hash(*P5.CODE_FILES)[:8]
    prep5_dirs = []
    for d in info2["datasets"]:
        ids = json.loads((p2 / f"prep_ids_{d['name']}.json").read_text())
        if ids_cut is not None:
            ids = [i for i in ids if i in ids_cut]
        if not ids:
            continue
        ver = Path(d["root"]).parent.name
        out = base / "prep" / "p3" / ver / f"{d['name']}_v5_{ch}"
        prep5_dirs.append(str(out))
        m = C.read_json(out / "manifest.json", {}) or {}
        if m.get("complete") and m.get("inputs_hash") == C.sha(sorted(ids)):
            continue
        idf = run / f"prep5_ids_{d['name']}.json"
        C.atomic_write_json(idf, ids)
        print(f"кеш v5 {d['name']}: {len(ids)} случаев → {out}", flush=True)
        t0 = time.time()
        rc = sh(["-m", "pilotnn.prep5", out, d["root"], idf, p3.get("prep_workers", 12)], log)
        step_log(run, step="prep5", ds=d["name"], rc=rc, n=len(ids), t_s=round(time.time() - t0, 1), dir=str(out))
        if rc:
            print(f"кеш v5: код {rc}; см. {log}")
            return rc

    def net_task(src, spec, max_epochs, label):
        t = copy.deepcopy(src)
        tr = t["train"]
        tr["seed"] = int(p3["seed"])
        tr["max_epochs"] = int(max_epochs)
        if spec.get("wide"):
            tr["model"] = dict(tr["model"], channels=list(p3["wide_channels"]))
        enc = dict(inputs=spec["inputs"], outputs=spec["outputs"], pack=0, w_rel_weight=float(p3["w_rel_weight"]))
        if spec["outputs"] == "v5":
            enc["gamma"] = P5.gamma_fit(prep5_dirs, t["train_ids"])
        t.update(label=label, enc=enc, prep5_dirs=prep5_dirs if (spec["inputs"] == "v5" or spec["outputs"] == "v5") else [])
        return t

    def train(name, task):
        d = run / name / "net"
        d.mkdir(parents=True, exist_ok=True)
        write_if_changed(d / "task.json", task)
        C.atomic_write_json(run / name / "enc.json", task["enc"])
        m = C.read_json(d / "manifest.json", {}) or {}
        if m.get("complete"):
            return 0, d
        print(f"обучение {name}: {task['label']} ({len(task['train_ids'])} случаев, до {task['train']['max_epochs']} эпох)",
              flush=True)
        t0 = time.time()
        rc = sh(["-m", "pilotnn.train", d], log)
        m = C.read_json(d / "manifest.json", {}) or {}
        step_log(run, step="train", name=name, rc=rc, t_s=round(time.time() - t0, 1), epochs=m.get("epochs"),
                 t_epoch=m.get("t_epoch_median_s"), best=m.get("best"))
        return rc, d

    def evaluate(name, main_dir):
        r = run / name
        r.mkdir(parents=True, exist_ok=True)
        write_if_changed(r / "config.json", cfg)
        write_if_changed(r / "split.json", split)
        if not (r / "p6.json").exists():
            C.atomic_write_json(r / "p6.json", json.loads((p2 / "p6.json").read_text()))
        ri = dict(copy.deepcopy(info2), curve=[], main_dir=str(main_dir), onnx_path=str(r / "model.onnx"), name=name)
        write_if_changed(r / "run_info.json", ri)
        print(f"оценка {name}", flush=True)
        t0 = time.time()
        rc = sh(["-m", "pilotnn.evaluate", "eval", r, rep / name], log)
        step_log(run, step="eval", name=name, rc=rc, t_s=round(time.time() - t0, 1))
        return rc

    variants = p3["variants"]
    if a.probe:
        for v in ("v0_ctrl", "v1_wide", "v4_io5"):
            rc, d = train(f"probe_{v}", net_task(t100, variants[v], 1, f"проба: {variants[v]['label']}"))
            if rc:
                return rc
        return 0
    E = 1 if a.smoke else int(p3["max_epochs"])
    # 2. сети П-2 (только чтение весов)
    for name, sub in (("p2_main", "main"), ("p2_c100", "curve_100")):
        rc = evaluate(name, p2 / sub)
        if rc:
            return rc
    # 3. варианты на 100 местах
    for v, spec in variants.items():
        rc, d = train(v, net_task(t100, spec, E, spec["label"]))
        if rc:
            return rc
        rc = evaluate(v, d)
        if rc:
            return rc
    # 4. лучший — на 300 местах
    sel = choose_best(rep, list(variants), smoke=a.smoke)
    C.atomic_write_json(rep / "best_choice.json", sel)
    b = sel["best"]
    spec = variants[b]
    e300 = 1 if a.smoke else int(t300["train"]["max_epochs"])
    name300 = f"{b}_300"
    rc, d = train(name300, net_task(t300, spec, e300, f"{spec['label']} — 300 мест"))
    if rc:
        return rc
    rc = evaluate(name300, d)
    if rc:
        return rc
    # 5. таблица
    rc = sh([HERE / "p3" / "variants_table.py", "--run", run, "--rep", rep, "--best300", name300], log)
    step_log(run, step="table", rc=rc)
    print(f"готово: {rep / 'variants.md'}" if rc == 0 else f"таблица: код {rc}", flush=True)
    return rc


def headline(rep: Path, name):
    m = json.loads((rep / name / "metrics.json").read_text())
    a = m["sets"]["holdout_sys"]["net"]["conv"]["area"]["wind"]
    return a["median"], a["p90"]


def choose_best(rep: Path, names, smoke=False):
    """Лучший из (1)–(4): наименьшая медиана; варианты в пределах разброса от зерна (|(0) − curve_100 П-2|) от
    наименьшей — равны, из них — наименьший p90."""
    h = {n: headline(rep, n) for n in names}
    spread = 0.0 if smoke else abs(h["v0_ctrl"][0] - headline(rep, "p2_c100")[0])
    cand = [n for n in names if n != "v0_ctrl"]
    mmin = min(h[n][0] for n in cand)
    tie = [n for n in cand if h[n][0] - mmin <= spread]
    best = min(tie, key=lambda n: (h[n][1], h[n][0]))
    return dict(best=best, spread=spread, median_min=mmin, tie=tie, headline={n: dict(median=v[0], p90=v[1]) for n, v in h.items()})


if __name__ == "__main__":
    sys.exit(main())
