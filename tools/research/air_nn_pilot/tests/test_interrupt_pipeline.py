#!/usr/bin/env python3
"""Тест прерываний всего конвейера П-2 (NN-P7, §4.6 плана): `run_pilot.sh --smoke` на настоящих местах tiles/v3.

Два корня данных (временные, под $AIR_NN_DATA/pilot/tmp/itest_p2_*; `pilot/tiles` — симлинк на настоящие вырезки, только
чтение; наборы и кеш подготовки в каждом корне считаются с нуля):
  A. непрерванный прогон;
  B. на каждой стадии 2…7 (наборы, подготовка, основная сеть, кривая, оценка, отчёт) — SIGINT (ожидаем код 130,
     мягкая остановка) и повтор той же команды, затем kill -9 (только pilot.py; дети и воркеры умирают по PDEATHSIG)
     и повтор; в конце повтор до отчёта и повтор готового (ничего не пересчитывает).
  Стадия 1 (рельеф, tiles/v3 готов) — мгновенный пропуск; её прерывание (kill -9/повтор → те же файлы) — тест NN-P4/NN-P8.
Сравнение: metrics.json B против A (все числа, кроме времени), файлы наборов побитно (sha256), нет временных файлов.
Убивает только PID, которые запустил сам. Итог → tests/out/interrupt_pipeline.json. Долго (десятки минут, GPU под замком
пилота): запускать фоном (dp job).

  .venv/bin/python tests/test_interrupt_pipeline.py [--keep] [--no-ref]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "tests"))
from pilotnn import common as C  # noqa: E402
import test_interrupt_train as TT  # noqa: E402

REAL = Path(os.environ.get("AIR_NN_DATA") or "/home/greg/air_nn_data")
NAME = "itest"
N_STEPS = 7
STAGE_TIMEOUT = 3600


def run_env(root):
    env = dict(os.environ, AIR_NN_DATA=str(root))
    env.pop("AIRNN_P6_DIR", None)
    return env


def start(root, extra=None):
    return subprocess.Popen([str(HERE / "run_pilot.sh"), "--smoke", "--name", NAME], cwd=HERE, env=dict(run_env(root), **(extra or {})),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Root:
    def __init__(self, label):
        self.path = REAL / "pilot" / "tmp" / f"itest_p2_{label}"
        self.label = label

    def make(self):
        shutil.rmtree(self.path, ignore_errors=True)
        (self.path / "pilot").mkdir(parents=True)
        (self.path / "pilot" / "tiles").symlink_to(REAL / "pilot" / "tiles")   # вырезки П6 — только чтение

    @property
    def base(self):
        return self.path / "pilot" / "smoke_p2"

    @property
    def log(self):
        d = sorted((self.base / "runs").glob(f"????-??-??_{NAME}"))
        return d[0] / "pilot.log" if d else self.base / "runs" / "none" / "pilot.log"

    def header_count(self, k):
        return self.log.read_text().count(f"этап {k} из {N_STEPS}:") if self.log.exists() else 0

    def n_cases(self, name):
        return len(list(self.path.glob(f"pilot/datasets/*/{name}/cases/*.npz")))

    def prog(self, pattern):
        """Наибольший done среди progress.json по маске (от base)."""
        best = 0.0
        for p in self.base.glob(pattern):
            js = C.read_json(p)
            if js:
                best = max(best, float(js.get("done", 0)))
        return best


# стадия → (метка, предикат «пора прерывать» для SIGINT, для kill -9); r — Root, s — число завершённых прерываний на стадии
def stages(r: Root):
    return {
        2: ("наборы", lambda: r.n_cases("smoke") >= 3, lambda: r.n_cases("terrain_smoke") >= 3),
        3: ("подготовка", lambda: r.prog("prep/**/progress.json") >= 2, lambda: r.prog("prep/**/progress.json") >= 4),
        4: ("основная сеть", lambda: r.prog("runs/*/main/progress.json") >= 3, lambda: r.prog("runs/*/main/progress.json") >= 7),
        5: ("кривая", lambda: r.prog("runs/*/curve_*/progress.json") >= 1, lambda: r.prog("runs/*/curve_*/progress.json") >= 3),
        6: ("оценка", lambda: r.prog("reports/*/progress.json") >= 1, lambda: r.prog("reports/*/progress.json") >= 2),
        7: ("отчёт", lambda: True, lambda: True),
    }


def wait_stage(proc, r: Root, k, n_before, pred, timeout=STAGE_TIMEOUT):
    """Ждать заголовок этапа k (новый) и предикат; True — пора; False — процесс завершился раньше."""
    t0 = time.time()
    seen = False
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            return False
        if not seen and r.header_count(k) > n_before:
            seen = True
        if seen and pred():
            return True
        time.sleep(0.1)
    raise TimeoutError(f"этап {k}")


def sha_tree(root: Path):
    out = {}
    for p in sorted(root.glob("pilot/datasets/*/*/cases/*.npz")):
        out[f"{p.parent.parent.name}/{p.name}"] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="не удалять временные корни после теста")
    ap.add_argument("--no-ref", action="store_true", help="не пересчитывать A (взять готовый корень itest_p2_A)")
    a = ap.parse_args()
    log = []
    A, B = Root("A"), Root("B")
    if not a.no_ref:
        A.make()
    B.make()
    t0 = time.time()
    p = start(A.path)
    rc = p.wait(STAGE_TIMEOUT * 2)
    log.append(dict(step="A: непрерванный", rc=rc, t=round(time.time() - t0, 1)))
    print(log[-1], flush=True)
    assert rc == 0, "непрерванный прогон A не дошёл до отчёта"
    for k, (label, p_int, p_kill) in stages(B).items():
        for how, pred in (("SIGINT", p_int), ("kill -9", p_kill)):
            n0 = B.header_count(k)
            p = start(B.path)
            hit = wait_stage(p, B, k, n0, pred)
            if not hit:
                log.append(dict(step=f"этап {k} ({label}): {how}", result="не успел: процесс завершился раньше", rc=p.returncode))
                print(log[-1], flush=True)
                continue
            if how == "SIGINT":
                p.send_signal(signal.SIGINT)
                rc = p.wait(300)
                log.append(dict(step=f"этап {k} ({label}): SIGINT", rc=rc))
                assert rc in (C.EXIT_SIGINT, 0), (k, rc)
            else:
                p.send_signal(signal.SIGKILL)
                p.wait()
                log.append(dict(step=f"этап {k} ({label}): kill -9", rc=p.returncode))
            print(log[-1], flush=True)
            time.sleep(1.0)
    p = start(B.path)
    rc = p.wait(STAGE_TIMEOUT * 2)
    log.append(dict(step="повтор до отчёта", rc=rc))
    print(log[-1], flush=True)
    assert rc == 0
    t1 = time.time()
    rc = start(B.path).wait(600)
    log.append(dict(step="повтор готового прогона", rc=rc, t=round(time.time() - t1, 1)))
    print(log[-1], flush=True)

    def metrics(r: Root):
        rep = sorted((r.base / "reports").glob(f"*{NAME}"))
        assert len(rep) == 1, rep
        return rep[0], json.loads((rep[0] / "metrics.json").read_text())

    repA, MA = metrics(A)
    repB, MB = metrics(B)
    cmp_all = TT.compare(MA, MB)
    ha, hb = sha_tree(A.path), sha_tree(B.path)
    left = [str(x) for r in (B,) for x in r.path.rglob("*.tmp*") if x.is_file()]
    runs_b = list((B.base / "runs").glob(f"*{NAME}"))
    res = dict(log=log, compare=cmp_all, datasets_bitwise_equal=ha == hb, n_dataset_files=len(ha), tmp_left=left,
               runs_dirs=len(runs_b), verdict_a=C.read_json(repA / "manifest.json").get("verdict"),
               verdict_b=C.read_json(repB / "manifest.json").get("verdict"))
    out = HERE / "tests" / "out"
    out.mkdir(exist_ok=True)
    C.atomic_write_json(out / "interrupt_pipeline.json", res)
    print(json.dumps(dict(compare=cmp_all, datasets_bitwise_equal=res["datasets_bitwise_equal"], tmp_left=left,
                          verdict_a=res["verdict_a"], verdict_b=res["verdict_b"]), ensure_ascii=False, indent=1))
    assert res["datasets_bitwise_equal"] and len(runs_b) == 1 and not left
    assert cmp_all["n_missing"] == 0 and cmp_all["n_different"] == 0, cmp_all
    if not a.keep:
        shutil.rmtree(A.path, ignore_errors=True)
        shutil.rmtree(B.path, ignore_errors=True)
    print("ok")


if __name__ == "__main__":
    main()
