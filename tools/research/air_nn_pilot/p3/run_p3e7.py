#!/usr/bin/env python3
"""P3E7: U-FNO вместо U-Net — обучение на 100 местах (задача E0 = v0_ctrl без изменений, кроме сети), оценка, обучающие,
таблица E0 / E1 / E7.  Запуск: .venv_fno/bin/python p3/run_p3e7.py [--probe]
  --probe — 1 эпоха (каталог probe_v7_fno), без оценки. Готовое пропускается (manifest.json); обучение — с чекпойнта.
GPU — замком пилота внутри train/evaluate (тот же файл, что `dp lock gpu`); сам запуск — `dp job --lock gpu start`."""
from __future__ import annotations

import argparse, copy, json, os, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402

EMPTY = ("holdout_sys_ids", "holdout_place_ids", "holdout_proc_ids", "newcond_ids", "newcond_p6_ids", "newcond_old_ids")
NAME = "v7_fno"


def sh(args, log):
    with open(log, "a") as f:
        f.write(f"\n[{time.strftime('%F %T')}] {' '.join(map(str, args))}\n"); f.flush()
        return subprocess.run([sys.executable, *map(str, args)], cwd=HERE, stdout=f, stderr=subprocess.STDOUT,
                              env=dict(os.environ, PYTHONUNBUFFERED="1")).returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--only", default="", help="train|eval|train_eval|table — один шаг")
    a = ap.parse_args()
    cfg = C.load_config(HERE / "config.yaml")
    e7, p3 = cfg["p3e7"], cfg["p3"]
    base = C.expand(cfg["paths"]["base"], cfg)
    p3run = base / "runs" / e7["p3_run"]
    p2 = base / "runs" / p3["p2_run"]
    tag = e7["run"]
    run, rep = base / "runs" / tag, base / "reports" / tag
    run.mkdir(parents=True, exist_ok=True); rep.mkdir(parents=True, exist_ok=True)
    log = run / "run_p3e7.log"
    name = ("probe_" if a.probe else "") + NAME
    t = json.loads((p3run / "v0_ctrl" / "net" / "task.json").read_text())     # E0: списки, кеш v4, гиперпараметры, зерно 2
    t["train"]["model"] = dict(e7["model"])
    t["label"] = "P3E7: U-FNO, кодировка П-2 (как E0)"
    if a.probe:
        t["train"]["max_epochs"] = 1
    d = run / name / "net"
    d.mkdir(parents=True, exist_ok=True)
    if C.read_json(d / "task.json") != json.loads(json.dumps(t)):
        C.atomic_write_json(d / "task.json", t)
    C.atomic_write_json(run / name / "enc.json", t["enc"])
    todo = a.only or "train,eval,train_eval,table"
    if "train" in todo:
        m = C.read_json(d / "manifest.json", {}) or {}
        if not m.get("complete"):
            print(f"обучение {name} (до {t['train']['max_epochs']} эпох)", flush=True)
            t0 = time.time()
            rc = sh(["-m", "pilotnn.train", d], log)
            m = C.read_json(d / "manifest.json", {}) or {}
            with open(run / "steps.jsonl", "a") as f:
                f.write(json.dumps(dict(t=time.strftime("%F %T"), step="train", name=name, rc=rc, t_s=round(time.time() - t0, 1),
                                        epochs=m.get("epochs"), t_epoch=m.get("t_epoch_median_s"), best=m.get("best")), ensure_ascii=False) + "\n")
            if rc:
                return rc
    if a.probe:
        return 0
    info2 = json.loads((p2 / "run_info.json").read_text())
    split = json.loads((p2 / "split.json").read_text())
    t100 = json.loads((p2 / "curve_100" / "task.json").read_text())

    def prep_eval(r, sp, onnx):
        r.mkdir(parents=True, exist_ok=True)
        C.atomic_write_json(r / "config.json", cfg); C.atomic_write_json(r / "split.json", sp)
        if not (r / "p6.json").exists():
            C.atomic_write_json(r / "p6.json", json.loads((p2 / "p6.json").read_text()))
        C.atomic_write_json(r / "run_info.json", dict(copy.deepcopy(info2), curve=[], main_dir=str(d), onnx_path=str(onnx), name=r.name))
    if "eval" in todo:
        r = run / name
        prep_eval(r, split, r / "model.onnx")
        print("оценка", flush=True)
        rc = sh(["-m", "pilotnn.evaluate", "eval", r, rep / name], log)
        if rc:
            return rc
    if "train_eval" in todo:
        r = run / f"{name}__train"
        prep_eval(r, dict(split, train_ids=t100["train_ids"], **{k: [] for k in EMPTY}), r / "model.onnx")
        print("оценка на обучающих", flush=True)
        rc = sh(["-m", "pilotnn.evaluate", "eval", r, rep / r.name], log)
        if rc:
            return rc
    if "table" in todo:
        rc = sh([HERE / "p3" / "p3e7_table.py", "--rep", rep, "--p3rep", base / "reports" / e7["p3_run"], "--name", name], log)
        print("таблица:", rep / "p3e7.md" if rc == 0 else f"код {rc}", flush=True)
        return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
