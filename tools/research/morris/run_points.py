"""Прогоны плана Морриса: по траекториям (номинал, траектория 0 — все случаи, траектория 1 — …),
так что любой готовый префикс — полные траектории по всем случаям. По строке на (случай, точку) в
out/runs/<случай>.jsonl; готовые пропускаются (серию можно прервать и продолжить). Ошибки и
несошедшиеся прогоны пишутся с меткой, не выбрасываются. Замок GPU — на каждую точку.

  .venv/bin/python run_points.py [--plan out/plan.json] [--cases askervein,ridge,...] [--ids nom,p000] [--max-traj N]
"""
from __future__ import annotations

import argparse
import json
import time
import traceback
from pathlib import Path

import model as M

HERE = Path(__file__).resolve().parent


def done_keys(path):
    keys = set()
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                keys.add(json.loads(line)["id"])
            except (ValueError, KeyError):
                pass
    return keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default=str(HERE / "out" / "plan.json"))
    ap.add_argument("--cases", default=",".join(M.CASES))
    ap.add_argument("--ids", default="")
    ap.add_argument("--max-traj", type=int, default=10 ** 6)
    ap.add_argument("--runs", default=str(HERE / "out" / "runs"))
    a = ap.parse_args()
    plan = json.loads(Path(a.plan).read_text())
    cases = a.cases.split(",")
    ids = set(a.ids.split(",")) if a.ids else None
    rd = Path(a.runs)
    rd.mkdir(parents=True, exist_ok=True)
    done = {c: done_keys(rd / f"{c}.jsonl") for c in cases}
    pts = [p for p in plan["points"] if (ids is None or p["id"] in ids) and p["traj"] < a.max_traj]
    trajs = sorted({p["traj"] for p in pts})
    t_start = time.time()
    n = 0
    for tr in trajs:
        for c in cases:
            for p in (q for q in pts if q["traj"] == tr):
                if p["id"] in done[c]:
                    continue
                row = dict(case=c, id=p["id"], traj=p["traj"], fx=p["fx"])
                t0 = time.perf_counter()
                with M.GpuLock() as lk:
                    try:
                        r = M.CASES[c](p["fx"])
                        row.update(r)
                        st = [v["status"] for v in r["runs"].values()]
                        row["status"] = "ok" if all(s == "ok" for s in st) else ("diverged" if "diverged" in st else "max")
                    except Exception as e:  # noqa: BLE001 — метка, не выбрасываем
                        row.update(status="error", error=f"{type(e).__name__}: {e}", tb=traceback.format_exc()[-2000:])
                        try:
                            import cupy as cp
                            cp.get_default_memory_pool().free_all_blocks()
                        except Exception:  # noqa: BLE001
                            pass
                row["t_wall"] = round(time.perf_counter() - t0 - lk.wait, 2)
                row["lock_wait"] = round(lk.wait, 2)
                with (rd / f"{c}.jsonl").open("a") as f:
                    f.write(json.dumps(row, default=float) + "\n")
                n += 1
                it = sum(v["iters"] for v in row.get("runs", {}).values())
                print(f"[{(time.time() - t_start) / 60:6.1f} мин] {c} {p['id']} (тр. {tr}): {row['status']}, {it} ит., "
                      f"{row['t_wall']:.0f} с", flush=True)
    print(f"готово: {n} прогонов за {(time.time() - t_start) / 3600:.2f} ч")


if __name__ == "__main__":
    main()
