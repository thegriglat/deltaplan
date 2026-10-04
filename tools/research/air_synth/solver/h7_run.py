#!/usr/bin/env python3
"""H7 (SY-4): замер цены одного случая решателя P2 на модельных рельефах. Один фоновый прогон, строка на случай в
out_h7/cases.jsonl, продолжение (готовые id пропускаются). GPU-замок: запускать под `dp job --lock gpu start …`
(замок держит запуск, воркеры — внутри него, как в dataset.py пилота) либо с --own-lock (flock /tmp/heat_ca_gpu.lock).

  dp job --lock gpu start h7 3000 env OMP_NUM_THREADS=1 ../../air_nn_pilot/.venv/bin/python h7_run.py --source proto --workers 2
Источник рельефа: --source proto [--npz файл] | corpus --corpus-dir D --ids 1,2,3|auto5 [--conditions DIR_S2] (auto5 — 5 рельефов
с разным mix и перепадом; --conditions — условия из набора S2 вместо plan()).
Условия — как plan_rows P2 (час x облачность по кругу, направление и t_max равномерно), только механический режим:
U10 ~ U[3, 8] м/с, без штилей; 3 условия на рельеф, глобальный номер n: час HOURS[n % 4], облачность SKIES[(n // 4) % 3]
(при 4 рельефах x 3 — все 12 сочетаний). Область 96 x 96 x 400 м, решения h (с нагревом) и m (без), предел итераций и
цель «среднее поздних» — configs/dataset.yaml (terrain.max_outer, terrain.late_mean)."""
from __future__ import annotations

import argparse
import fcntl
import json
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
OUT = HERE / "out_h7"
LOCK = "/tmp/heat_ca_gpu.lock"
HOURS = (9.0, 12.0, 15.0, 20.0)
SKIES = ("clear", "partly", "overcast")
BASE_M = 1000.0    # высота над морем = рельеф + база (как BASE у синтетики пилота: прототип стоит от уровня эрозии 0)


def plan(names, n_cond, seed):
    rng = np.random.default_rng(seed)
    rows = []
    n = 0
    for nm in names:
        for k in range(n_cond):
            rows.append(dict(id=f"{nm}_{k:03d}", loc=nm, hour=HOURS[n % 4], sky=SKIES[(n // 4) % 3],
                             U10=float(np.round(rng.uniform(3.0, 8.0), 2)), wdir=float(np.round(rng.uniform(0, 360), 1)),
                             t_max=float(np.round(rng.uniform(18.0, 34.0), 1))))
            n += 1
    return rows


def pick_ids(corpus_dir, n=5):
    """Детерминированный выбор n рельефов корпуса с разным mix и перепадом: цели (квантиль mix, квантиль перепада) —
    (0,1; 0,1), (0,9; 0,3), (0,5; 0,5), (0,1; 0,9), (0,9; 0,9) (первые n); берётся ближайший по рангам, без повторов."""
    sys.path.insert(0, str(HERE.parent / "corpus"))
    import corpus_io as cio
    c = cio.Corpus(corpus_dir)
    ids = c.ids()
    mix = np.array([c.params(i)["mix"] for i in ids]); rel = np.array([c.summary(i)["relief_m"] for i in ids])
    c.close()
    rk = lambda x: np.argsort(np.argsort(x)) / (len(x) - 1)
    rm, rr = rk(mix), rk(rel)
    out = []
    for qm, qr in [(0.1, 0.1), (0.9, 0.3), (0.5, 0.5), (0.1, 0.9), (0.9, 0.9)][:n]:
        d = (rm - qm) ** 2 + (rr - qr) ** 2
        d[[ids.index(i) for i in out]] = 9
        out.append(ids[int(np.argmin(d))])
    return out


def plan_from_conditions(names, ids, cond_dir, n_cond):
    """Условия из набора S2 (conditions.h5): n_cond на рельеф — собственные условия рельефа (cond_id 0, 1, …); если их меньше
    n_cond, добираются первые условия следующего по списку рельефа (механические, из того же набора). Поля решателя:
    hour_local, sky (код → имя), u10_m_s, wind_from_deg, t_max_c; широта/долгота/дата у модельного места — как у синтетики
    (model_place), поля S2 lat/lon/month/day решателем здесь не используются."""
    sys.path.insert(0, str(HERE.parent / "corpus"))
    import corpus_io as cio
    T = cio.Conditions(cond_dir)
    rows = []
    for k, (nm, rid) in enumerate(zip(names, ids)):
        own = list(T.for_relief(rid))
        borrow = list(T.for_relief(ids[(k + 1) % len(ids)]))
        pick = (own + borrow)[:n_cond]
        for j, r in enumerate(pick):
            rows.append(dict(id=f"{nm}_{j:03d}", loc=nm, hour=float(r["hour_local"]), sky=SKIES[int(r["sky"])], U10=float(r["u10_m_s"]),
                             wdir=float(r["wind_from_deg"]), t_max=float(r["t_max_c"]),
                             src=dict(relief_id=int(r["relief_id"]), cond_id=int(r["cond_id"]), froude=float(r["froude"]), w_star_over_u=float(r["w_star_over_u"]))))
    return rows


def load_source(a):
    import reliefs
    if a.source == "proto":
        return reliefs.load_proto(a.npz)
    return reliefs.load_corpus(a.corpus_dir, resolve_ids(a), a.corpus_io_dir)


def resolve_ids(a):
    return pick_ids(a.corpus_dir, 5) if a.ids == "auto5" else [int(x) for x in a.ids.split(",")]


def dataset_cfg():
    import yaml
    cfg = yaml.safe_load((HERE.parent.parent / "air_nn_pilot/configs/dataset.yaml").read_text())
    tc = cfg["terrain"]
    return int(tc["max_outer"]), dict(**tc["late_mean"], edge_cells=int(tc["late_edge_cells"]))


_W = {}


def _init(args_ns):
    os.environ.setdefault("OMP_NUM_THREADS", "1")
    import model_place as M
    base = BASE_M if args_ns.base_m is None and args_ns.source == "proto" else (args_ns.base_m or 0.0)
    for nm, g100, g400, sc in load_source(args_ns):
        M.register(nm, g100, base)
    import airlite_gen as G
    _W["G"] = G
    _W["mo"], _W["late"] = dataset_cfg()


def _case(c):
    G = _W["G"]
    t0 = time.perf_counter()
    try:
        res, arrays = G.solve_case(c, [], max_outer=_W["mo"], late=_W["late"])
        wall = time.perf_counter() - t0
        runs = res["runs"]
        out = dict(id=c["id"], loc=c["loc"], cond={k: c[k] for k in ("hour", "sky", "U10", "wdir", "t_max")}, wall_s=round(wall, 3),
                   runs={k: v for k, v in runs.items()}, ok=True)
    except Exception as e:   # noqa: BLE001
        out = dict(id=c["id"], loc=c["loc"], ok=False, error=repr(e), wall_s=round(time.perf_counter() - t0, 3))
    out["pid"] = os.getpid()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", choices=("proto", "corpus"), default="proto")
    ap.add_argument("--npz")
    ap.add_argument("--corpus-dir"); ap.add_argument("--ids"); ap.add_argument("--corpus-io-dir")
    ap.add_argument("--conditions", help="каталог набора условий S2 (conditions.h5); без него — условия plan() как у P2")
    ap.add_argument("--base-m", type=float, default=None, help="добавка к высотам, м; по умолчанию 1000 для proto, 0 для corpus (высоты корпуса уже над морем)")
    ap.add_argument("--n-cond", type=int, default=3)
    ap.add_argument("--seed", type=int, default=20261005)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--limit", type=int, default=0, help="только первые N случаев плана (бенчмарк воркеров)")
    ap.add_argument("--own-lock", action="store_true")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    import reliefs
    if a.source == "corpus":
        a.ids = ",".join(map(str, resolve_ids(a)))      # auto5 -> явные номера (воркеры не пересчитывают)
    src = load_source(a)
    if a.conditions:
        rows = plan_from_conditions([s[0] for s in src], resolve_ids(a), a.conditions, a.n_cond)
    else:
        rows = plan([s[0] for s in src], a.n_cond, a.seed)
    if a.limit:
        rows = rows[: a.limit]
    f = out / "cases.jsonl"
    done = set()
    if f.exists():
        done = {json.loads(l)["id"] for l in f.read_text().splitlines() if l.strip() and json.loads(l).get("ok")}
    todo = [r for r in rows if r["id"] not in done]
    (out / "plan.json").write_text(json.dumps(dict(args=vars(a), cases=rows), indent=1, ensure_ascii=False))
    print(f"случаев в плане {len(rows)}, готово {len(done)}, к счёту {len(todo)}", flush=True)
    if not todo:
        return
    lk = None
    if a.own_lock:
        lk = open(LOCK, "w"); fcntl.flock(lk, fcntl.LOCK_EX)
    t0 = time.perf_counter()
    try:
        ctx = mp.get_context("spawn")
        with ctx.Pool(max(a.workers, 1), initializer=_init, initargs=(a,)) as pool, open(f, "a") as fo:
            for r in pool.imap_unordered(_case, todo):
                r["workers"] = a.workers
                fo.write(json.dumps(r, ensure_ascii=False) + "\n"); fo.flush()
                print(r["id"], r.get("wall_s"), {k: (v["status"], v["iters"]) for k, v in r.get("runs", {}).items()}, r.get("error", ""), flush=True)
    finally:
        if lk:
            fcntl.flock(lk, fcntl.LOCK_UN)
    print(f"прогон {time.perf_counter() - t0:.1f} с", flush=True)
    with open(out / "runs.jsonl", "a") as fr:
        fr.write(json.dumps(dict(wall_s=round(time.perf_counter() - t0, 2), workers=a.workers, n=len(todo), limit=a.limit,
                                 source=a.source, ts=time.strftime("%F %T"))) + "\n")


if __name__ == "__main__":
    main()
