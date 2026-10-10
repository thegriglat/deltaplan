"""Все замеры прототипа одним прогоном: план → пул процессов → out/results.jsonl (строка на запуск,
продолжение с места) → out/results.json (сводка) и ряды для графиков в out/series.npz.

Запуск:  python run_all.py [--only подстрока] [--jobs N]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pendulum import scenarios as S  # noqa: E402

OUT = HERE / "out"
WINGS = ["training", "laminar", "sport"]
# гибкое крыло (оценка): половина разницы нагрузок консолей снимается круткой паруса; перекос пузыря
RIGID = {"flex_relief": 1.0}  # жёсткое крыло (без крутки паруса) — для сравнения


def plan():
    jobs = []
    for w in WINGS:
        for ym in ("noslip", "free"):
            for sc in ("trim", "reversal", "reversal30", "full_shift", "center", "spiral", "thermal_edge",
                       "turbulence", "turbulence_relaxed", "pendulum", "phugoid", "bar"):
                jobs.append({"id": f"{sc}/{w}/{ym}", "sc": sc, "wing": w, "kw": {"yaw_mode": ym}})
        jobs.append({"id": f"hang_sens/{w}", "sc": "hang_sensitivity", "wing": w, "kw": {}})
        for wind in (0.0, 3.0):
            jobs.append({"id": f"ground_run/{w}/wind{wind:g}", "sc": "ground_run", "wing": w, "kw": {"wind": wind}})
        for sc in ("reversal", "reversal30", "full_shift", "center", "spiral", "thermal_edge", "turbulence", "pendulum"):
            jobs.append({"id": f"{sc}/{w}/free/rigid", "sc": sc, "wing": w, "kw": dict(RIGID)})
        jobs.append({"id": f"reversal/{w}/free/hang_trim0", "sc": "reversal", "wing": w, "kw": {"hang": "trim0"}})
        jobs.append({"id": f"center/{w}/free/hang_trim0", "sc": "center", "wing": w, "kw": {"hang": "trim0"}})
    # калибровка по лётному опыту Takamatsu & Ochi 2022 (усилие рук вбок)
    for force in (20.0, 30.0, 40.0):
        for rel in (0.1, 0.2, 0.35, 1.0):
            for dd in (0.0, 1.0, 2.5):
                jobs.append({"id": f"ochi/F{force:g}/relief{rel:g}/dih{dd:g}", "sc": "ochi", "wing": "laminar",
                             "kw": {"force": force, "flex_relief": rel, "dihedral": math.radians(dd)}})
    # численная схема (спорт, со скольжением)
    for sub in (1, 2, 4, 8, 16):
        for n in (1, 3, 5):
            jobs.append({"id": f"numerics/sport/sub{sub}/N{n}", "sc": "numerics", "wing": "sport",
                         "kw": {"substeps": sub, "n_links": n}})
    for dt in (1 / 60, 1 / 30):
        jobs.append({"id": f"numerics/sport/dt{round(1/dt)}/sub4/N3", "sc": "numerics", "wing": "sport",
                     "kw": {"substeps": 4, "n_links": 3, "dt": dt}})
    # число полос
    for ns in (4, 8, 32):
        for sc in ("reversal", "center"):
            jobs.append({"id": f"strips/{sc}/sport/n{ns}", "sc": sc, "wing": "sport", "kw": {"n_strips": ns}})
    # чувствительность к оценочным параметрам (спорт и учебное, со скольжением)
    sens = {
        "arm_force_max": (150.0, 500.0), "arm_tau": (0.15, 0.5), "cn_beta": (0.03, 0.1),
        "pilot_cda": (0.12,), "apparent_roll": (False,), "shift_y_max": (0.35, 0.55),
        "hang_len": (1.0, 1.4), "strap_compliance": (1e-5, 1.6e-4), "hang_shift": (-0.03, 0.03),
        "flex_relief": (0.1, 0.35, 0.6), "billow_shift_deg": (8.0,),
        "dihedral": (0.0, math.radians(2.5), math.radians(5.0)),
    }
    for w in ("training", "sport"):
        for k, vals in sens.items():
            for v in vals:
                for sc in ("reversal", "center", "spiral"):
                    jobs.append({"id": f"sens/{w}/{k}={v}/{sc}", "sc": sc, "wing": w, "kw": {k: v}})
        for k in ("hang_len",):
            for v in (1.0, 1.4):
                jobs.append({"id": f"sens/{w}/{k}={v}/pendulum", "sc": "pendulum", "wing": w, "kw": {k: v}})
                jobs.append({"id": f"sens/{w}/{k}={v}/turbulence", "sc": "turbulence", "wing": w, "kw": {k: v}})
    return jobs


def do(job):
    sc = job["sc"]
    kw = dict(job["kw"])
    t0 = time.time()
    try:
        if sc == "reversal30":
            r = S.sc_reversal(job["wing"], bank=30.0, **kw)
        elif sc == "turbulence_relaxed":
            r = S.sc_turbulence(job["wing"], relaxed=True, **kw)
        else:
            r = getattr(S, f"sc_{sc}")(job["wing"], **kw)
        err = None
    except Exception:  # noqa: BLE001
        r, err = {}, traceback.format_exc()
    series = {}
    for k in list(r.keys()):
        if k.startswith("series"):
            series[k] = r.pop(k)
    return {"id": job["id"], "sc": sc, "wing": job["wing"], "kw": {k: str(v) for k, v in job["kw"].items()},
            "res": r, "err": err, "wall_s": time.time() - t0}, series


def _clean(x):
    if isinstance(x, dict):
        return {k: _clean(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [_clean(v) for v in x]
    if isinstance(x, (np.floating, float)):
        return None if not math.isfinite(float(x)) else float(x)
    if isinstance(x, np.integer):
        return int(x)
    if isinstance(x, np.bool_):
        return bool(x)
    return x


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 4))
    a = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    jl = OUT / "results.jsonl"
    done = set()
    if jl.exists():
        for line in jl.read_text().splitlines():
            d = json.loads(line)
            if not d.get("err"):
                done.add(d["id"])
    jobs = [j for j in plan() if a.only in j["id"] and j["id"] not in done]
    print(f"заданий {len(jobs)}, готово ранее {len(done)}", flush=True)
    series_dir = OUT / "series"
    series_dir.mkdir(exist_ok=True)
    with ProcessPoolExecutor(a.jobs) as ex, jl.open("a") as f:
        futs = {ex.submit(do, j): j for j in jobs}
        for i, fu in enumerate(as_completed(futs)):
            rec, series = fu.result()
            f.write(json.dumps(_clean(rec), ensure_ascii=False) + "\n")
            f.flush()
            if series:
                flat = {}
                for k, d in series.items():
                    for kk, v in d.items():
                        flat[f"{k}.{kk}"] = np.asarray(v, dtype=np.float32)
                np.savez_compressed(series_dir / (rec["id"].replace("/", "__") + ".npz"), **flat)
            print(f"[{i+1}/{len(jobs)}] {rec['id']} {rec['wall_s']:.0f}s {'ОШИБКА' if rec['err'] else ''}", flush=True)
    # сводка
    allr = {}
    for line in jl.read_text().splitlines():
        d = json.loads(line)
        allr[d["id"]] = d
    (OUT / "results.json").write_text(json.dumps(allr, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
