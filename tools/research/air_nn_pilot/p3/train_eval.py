#!/usr/bin/env python3
"""Ошибка на обучающих случаях для строк таблицы П-3 (запрос пользователя к NN-P12): учится ли сеть лучше от
кодировки при той же ширине или только от ширины.

Для каждой сети (П-2 main, curve_100, варианты (0)–(4), лучший на 300) — тот же `evaluate.run_eval` (П3 v3, ρ) по
сохранённому чекпойнту best.pt, но набор оценки — только «обучающие»: 60 случаев (зерно деления), выбранных из списка
обучения curve_100 П-2 — он входит в обучение всех строк (100 мест ⊂ 300 мест). Прочие наборы пусты. Оценки — параллельно
(CPU — пул процессов, GPU — замок пилота кусками).
→ reports/<run>/<имя>__train/metrics.json; таблица — variants_table.py.

  .venv/bin/python p3/train_eval.py [--jobs 8]
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402

EMPTY = ("holdout_sys_ids", "holdout_place_ids", "holdout_proc_ids", "newcond_ids", "newcond_p6_ids", "newcond_old_ids")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()
    cfg = C.load_config(HERE / "config.yaml")
    p3 = cfg["p3"]
    base = C.expand(cfg["paths"]["base"], cfg)
    p2 = base / "runs" / p3["p2_run"]
    run, rep = base / "runs" / p3["run"], base / "reports" / p3["run"]
    info2 = json.loads((p2 / "run_info.json").read_text())
    split = json.loads((p2 / "split.json").read_text())
    t100 = json.loads((p2 / "curve_100" / "task.json").read_text())
    sp = dict(split, train_ids=t100["train_ids"], **{k: [] for k in EMPTY})
    best = (C.read_json(rep / "best_choice.json", {}) or {}).get("best")
    nets = {"p2_main": p2 / "main", "p2_c100": p2 / "curve_100"}
    for v in p3["variants"]:
        nets[v] = run / v / "net"
    if best:
        nets[f"{best}_300"] = run / f"{best}_300" / "net"
    todo = []
    for name, d in nets.items():
        if not (d / "ckpt" / "best.pt").exists():
            print(f"нет сети {name}: {d}")
            continue
        r = run / f"{name}__train"
        r.mkdir(parents=True, exist_ok=True)
        C.atomic_write_json(r / "config.json", cfg)
        C.atomic_write_json(r / "split.json", sp)
        if not (r / "p6.json").exists():
            C.atomic_write_json(r / "p6.json", json.loads((p2 / "p6.json").read_text()))
        C.atomic_write_json(r / "run_info.json", dict(copy.deepcopy(info2), curve=[], main_dir=str(d),
                                                      onnx_path=str(r / "model.onnx"), name=r.name))
        todo.append((name, r))

    def one(x):
        name, r = x
        with open(r / "eval.log", "a") as f:
            rc = subprocess.run([sys.executable, "-m", "pilotnn.evaluate", "eval", str(r), str(rep / r.name)], cwd=HERE,
                                stdout=f, stderr=subprocess.STDOUT, env=dict(os.environ, PYTHONUNBUFFERED="1",
                                                                             OMP_NUM_THREADS="2")).returncode
        print(f"{name}: код {rc}", flush=True)
        return rc
    with ThreadPoolExecutor(a.jobs) as ex:
        rcs = list(ex.map(one, todo))
    return max(rcs) if rcs else 1


if __name__ == "__main__":
    sys.exit(main())
