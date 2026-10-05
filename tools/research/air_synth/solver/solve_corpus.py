#!/usr/bin/env python3
"""SY-8/SY-10: счёт решателя P2 по корпусу рельефов × набору условий -> S5 v2/v4 (docs/contracts/air-synth.md).
Решатель и обрамление — как замер H7 (model_place.py S4 + air_nn_pilot/airlite_gen.solve_case: только область 96x96x400 м, решения
h и m, max_outer и цель «среднее поздних» из configs/dataset.yaml). Условия случая — из таблицы S2 (час, облачность, U10, направление,
t_max, lat/lon, пояс, месяц/день) — контекст места решателя подменяется на условия случая. Решатель замок GPU сам не берёт:
запускать под `dp job --lock gpu start <имя> <таймаут> …` (либо --own-lock).

  python solve_corpus.py --relief-corpus ~/air_synth_data/real/p6v3 --conditions ~/air_synth_data/conditions/p6v3_p2c12 --plan real
  python solve_corpus.py --relief-corpus ~/air_synth_data/corpus/fs1_10k --conditions .../fs1_360_p2c12 --plan model
  ... --trial 20      # пробный счёт: 20 случаев равномерно по плану -> <out>__trial
Продолжение после прерывания — той же командой (с первой отсутствующей части). Каталог результата по умолчанию —
$AIR_SYNTH_DATA/solve/<имя корпуса>__<набор условий>__<версия решателя> (имя корпуса: p6v3 / fs1_360 — по --plan и каталогу)."""
from __future__ import annotations

import argparse
import fcntl
import json
import multiprocessing as mp
import os
import subprocess
import sys
import time
from collections import deque
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import s5_io as S5  # noqa: E402

cio = S5.cio
LOCK = "/tmp/heat_ca_gpu.lock"
SKY = {0: "clear", 1: "partly", 2: "overcast"}
SHARD = 100
PROGRESS = HERE / "out_solve" / "progress.json"


def dataset_cfg():
    import yaml
    cfg = yaml.safe_load((HERE.parents[1] / "air_nn_pilot/configs/dataset.yaml").read_text())
    tc = cfg["terrain"]
    return int(tc["max_outer"]), dict(**tc["late_mean"], edge_cells=int(tc["late_edge_cells"]))


def solver_version():
    import model_place
    return model_place.solver_version()


# ------------------------------------------------------------------ работник
_W = {}


def _init():
    os.environ.setdefault("OMP_NUM_THREADS", "1")
    import model_place as M
    import airlite_gen as G
    _W["M"], _W["G"] = M, G
    _W["mo"], _W["late"] = dataset_cfg()


def solve_one(task):
    """task = (case, relief_id, g100 (384,384), cond dict) -> dict с полями и метаданными случая."""
    M, G = _W["M"], _W["G"]
    case, rid, g100, c = task
    t0 = time.perf_counter()
    name = f"c_{rid:06d}"
    M.register(name, np.asarray(g100, np.float64), 0.0)
    ctx = M.context(name)           # горные поправки (ground_context) — по рельефу; остальное — условия случая (S2)
    ctx.update(month=int(c["month"]), day=int(c["day"]), lat=float(c["lat_deg"]), lon=float(c["lon_deg"]),
               utc_offset_h=float(c["utc_offset_h"]))
    cfg = S5.cfg_from_row(c)        # S2 v4 (hgw24): возмущения погоды — подмена конфига Day на время случая; v2/v3 — None, как раньше
    cs = dict(id=f"{name}_{c['cond_id']:03d}", loc=name, hour=float(c["hour_local"]), U10=float(c["u10_m_s"]),
              wdir=float(c["wind_from_deg"]), t_max=float(c["t_max_c"]), sky=SKY[int(c["sky"])] if cfg is None else S5.HG_SKY)
    with S5.weather_override(cfg):
        res, arr = G.solve_case(cs, [], max_outer=_W["mo"], late=_W["late"])
    _, hc = G.R.grid_domain(name, 400)      # hc float32 (arrays от solve_case — float16)
    out = dict(case=case, runs=res["runs"], hc=np.asarray(hc, np.float32), m=arr["d400_m"], h=arr["d400_h"],
               H=arr["d400_H"], hbl=arr["d400_hbl"], seconds=time.perf_counter() - t0)
    return out


# ------------------------------------------------------------------ план и источники
def build_plan(plan_kind, corpus, k_cond, n_train=300, n_holdout=60):
    if plan_kind == "hg":      # места дельтаплана (S5 v4): game, holdout, train по part
        return S5.plan_hg([(i, corpus.place(i)["part"]) for i in corpus.ids()], k_cond)
    if plan_kind == "real":
        rows = [(i, corpus.place(i)["part"]) for i in corpus.ids()]
        return S5.plan_real(rows, k_cond)
    return S5.plan_model(0, n_train, n_holdout, k_cond)


def case_row(case, plan_row, runs, seconds):
    rid, cid, g = plan_row
    rm, rh = runs["d400_m"], runs["d400_h"]
    r = np.zeros((), S5.CASES_DTYPE)
    r["case"], r["relief_id"], r["cond_id"], r["group"] = case, rid, cid, S5.GROUPS[g]
    for s, rr in (("m", rm), ("h", rh)):
        r[f"status_{s}"], r[f"iters_{s}"] = S5.STATUS[rr["status"]], rr["iters"]
        r[f"target_{s}"] = S5.TARGET[rr.get("target", "final")]
        r[f"late_n_{s}"], r[f"late_spread60_p90_{s}"] = rr.get("late_n", 1), rr.get("late_spread60_p90", 0.0)
    r["seconds"] = seconds
    r["rank"] = -1
    return r


def finite_or_diverged(name, a, diverged):
    if np.all(np.isfinite(a)):
        return a
    if diverged:      # разошедшееся решение — статус 2 в таблице; нечисла обнуляются (контракт: NaN в файле — ошибка)
        return np.nan_to_num(a, nan=0.0, posinf=0.0, neginf=0.0)
    raise ValueError(f"{name}: нечисла в сошедшемся/несошедшемся решении")


def assemble(items, plan_rows):
    """items — результаты solve_one по возрастанию case -> аргументы S5.write_part."""
    cases, fm, fh, hc, hf, hb = [], [], [], [], [], []
    for it in items:
        runs = it["runs"]
        dv = runs["d400_m"]["status"] == "diverged" or runs["d400_h"]["status"] == "diverged"
        cases.append(case_row(it["case"], plan_rows[it["case"]], runs, it["seconds"]))
        fm.append(finite_or_diverged("fields/m", it["m"], dv)); fh.append(finite_or_diverged("fields/h", it["h"], dv))
        hc.append(it["hc"]); hf.append(finite_or_diverged("heat_flux", it["H"], dv)); hb.append(finite_or_diverged("hbl", it["hbl"], dv))
    return np.concatenate(cases) if False else np.array(cases, S5.CASES_DTYPE), np.stack(fm), np.stack(fh), np.stack(hc), np.stack(hf), np.stack(hb)


def trial_indices(plan, cmap, n):
    """n случаев плана: корзины (утро < 11 ч / день / вечер ≥ 17 ч) × (U10 < 4 / ≥ 4 м/с), по кругу по корзинам, внутри — равномерно по плану."""
    buckets = {}
    for i, (rid, cid, _) in enumerate(plan):
        r = cmap[(rid, cid)]
        h, u = float(r["hour_local"]), float(r["u10_m_s"])
        buckets.setdefault((0 if h < 11 else (1 if h < 17 else 2), 0 if u < 4 else 1), []).append(i)
    keys = sorted(buckets)
    out, k = [], 0
    while len(out) < n and any(buckets.values()):
        b = buckets[keys[k % len(keys)]]
        k += 1
        if b:
            out.append(b.pop(len(b) // 2 if k <= len(keys) else 0))
    return sorted(out)


# ------------------------------------------------------------------ сводка
def summarize(d):
    """Сводка каталога по частям: готово случаев, доля несошедшихся, время на случай, объём."""
    parts = cio.list_parts(d)
    cs = []
    size = 0
    for k in parts:
        import h5py
        with h5py.File(cio.part_path(d, k), "r") as f:
            cs.append(f["cases"][:])
        size += os.path.getsize(cio.part_path(d, k))
    plan = S5.read_plan(d)
    if not cs:
        return dict(n_plan=len(plan), cases_done=0, parts_done=0, bytes=0, stage_done=[], by_group={})
    c = np.concatenate(cs)
    bg = {}
    for g, code in S5.GROUPS.items():
        tot = sum(1 for p in plan if p[2] == g)
        s = c[c["group"] == code]
        bg[g] = dict(planned=tot, done=int(len(s)))
    calm = c["cond_id"] == 5
    nc = (c["status_m"] != 0) | (c["status_h"] != 0)
    sec = float(c["seconds"].mean())
    wk = 3
    try:
        wk = int(json.load(open(os.path.join(d, "manifest.json")))["workers"])
    except Exception:  # noqa: BLE001
        pass
    return dict(n_plan=len(plan), cases_done=int(len(c)), parts_done=len(parts), bytes=size,
                gb_per_1000_cases=round(size / len(c) * 1000 / 1e9, 3),
                nonconverged_fraction=round(float(nc.mean()), 4), diverged_fraction=round(float(((c["status_m"] == 2) | (c["status_h"] == 2)).mean()), 4),
                seconds_per_case_mean=round(sec, 1), seconds_per_case_calm=round(float(c["seconds"][calm].mean()), 1) if calm.any() else None,
                seconds_per_case_other=round(float(c["seconds"][~calm].mean()), 1) if (~calm).any() else None,
                eta_hours_if_workers_same=round((len(plan) - len(c)) * sec / max(wk, 1) / 3600, 2),
                stage_done=[g for g, v in bg.items() if v["planned"] and v["done"] >= v["planned"]], by_group=bg)


def write_progress(dirs, path=PROGRESS):
    out = {}
    for d in dirs:
        if os.path.exists(os.path.join(d, "plan.json")):
            out[os.path.basename(os.path.normpath(d))] = summarize(d)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    old = json.loads(path.read_text()).get("dirs", {}) if path.exists() else {}
    old.update(out)
    tmp = str(path) + ".tmp"
    json.dump(dict(updated=time.strftime("%F %T"), stage_done=sorted({f"{k}:{g}" for k, v in old.items() for g in v.get("stage_done", [])}),
                   dirs=old), open(tmp, "w"), indent=1, ensure_ascii=False)
    os.replace(tmp, path)


# ------------------------------------------------------------------ главное
def git_commit():
    try:
        return subprocess.check_output(["git", "-C", str(HERE), "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:  # noqa: BLE001
        return ""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--relief-corpus", required=True)
    ap.add_argument("--conditions", required=True)
    ap.add_argument("--plan", choices=("real", "model", "hg"), required=True)
    ap.add_argument("--name", help="имя корпуса в имени каталога (по умолчанию p6v3 / fs1_360)")
    ap.add_argument("--out", help="каталог результата (по умолчанию $AIR_SYNTH_DATA/solve/<имя>)")
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--k-cond", type=int, default=12, help="условий на рельеф (hgw24: 24)")
    ap.add_argument("--n-train", type=int, default=300, help="--plan model: id 0…n-1 — train")
    ap.add_argument("--n-holdout", type=int, default=60, help="--plan model: следующие n — holdout")
    ap.add_argument("--trial", type=int, default=0, help="N случаев равномерно по плану -> <out>__trial")
    ap.add_argument("--own-lock", action="store_true")
    ap.add_argument("--progress", default=str(PROGRESS))
    a = ap.parse_args(argv)

    corpus = cio.Corpus(a.relief_corpus)
    conds = cio.Conditions(a.conditions)
    plan = build_plan(a.plan, corpus, a.k_cond, a.n_train, a.n_holdout)
    cmap = {(int(r["relief_id"]), int(r["cond_id"])): r for r in conds.table}
    missing = [p[:2] for p in plan if tuple(p[:2]) not in cmap]
    if missing:
        raise SystemExit(f"в наборе условий нет {len(missing)} случаев плана, напр. {missing[:3]}")
    ver = solver_version()
    cname = a.name or ("p6v3" if a.plan == "real" else "fs1_360")
    cset = os.path.basename(os.path.normpath(a.conditions))
    cset = cset[len(cname) + 1:] if cset.startswith(cname + "_") else cset      # p6v3_p2c12 -> p2c12
    out = a.out or os.path.join(cio.data_root(), "solve", f"{cname}__{cset}__{ver}")
    if a.trial:
        if "dt_upper_k" in conds.table.dtype.names:    # hgw24: пробные случаи по корзинам час (утро/день/вечер) × ветер (слабый/сильный), по кругу
            plan = [plan[i] for i in trial_indices(plan, cmap, a.trial)]
        else:
            idx = np.unique(np.linspace(0, len(plan) - 1, a.trial).round().astype(int))
            # штиль (cond_id 5) и ясный/тёплый час в пробном — по равномерному шагу попадают; добавить один штиль, если нет
            if not any(plan[i][1] == 5 for i in idx):
                idx[-1] = next(i for i, p in enumerate(plan) if p[1] == 5)
            plan = [plan[i] for i in sorted(set(idx.tolist()))]
        out += "__trial"
    os.makedirs(out, exist_ok=True)
    S5.write_plan(out, plan, dict(relief_corpus=a.relief_corpus, conditions=a.conditions))
    ng = len(plan)
    mo, late = dataset_cfg()
    attrs = dict(shard_size=SHARD, relief_corpus=a.relief_corpus, conditions=a.conditions, solver_version=ver, max_outer=mo,
                 late_from=int(late["from"]), late_step=int(late["step"]), agl_m=np.array(S5.AGL_M, "<i4"), dx_m=400.0, x0_m=-19200.0,
                 y0_m=-19200.0, device="gpu", workers=a.workers)
    cio.clean_tmp(out)
    have = set(cio.list_parts(out))
    todo = [k for k in range((ng + SHARD - 1) // SHARD) if k not in have]
    man = dict(attrs, agl_m=list(S5.AGL_M), n_total=ng, contract=S5.CONTRACT, command=" ".join(sys.argv), git_commit=git_commit(),
               group_codes=S5.GROUP_CODES)
    cio.write_manifest(out, man)
    print(f"{out}: случаев {ng}, частей {len(have)} готово, к счёту {len(todo)}", flush=True)
    if todo:
        tasks = [(k, c) for k in todo for c in range(k * SHARD, min((k + 1) * SHARD, ng))]
        rcache = {}

        def make_task(c):
            rid, cid, _ = plan[c]
            if rid not in rcache:
                if len(rcache) > 64:
                    rcache.clear()
                rcache[rid] = corpus.h100(rid, np.float32)
            return (c, rid, rcache[rid], cio._dec(cmap[(rid, cid)], cmap[(rid, cid)].dtype))
        lk = None
        if a.own_lock:
            lk = open(LOCK, "w"); fcntl.flock(lk, fcntl.LOCK_EX)
        t0 = time.perf_counter()
        try:
            ctx = mp.get_context("spawn")
            with ctx.Pool(max(a.workers, 1), initializer=_init) as pool:
                pend, buf, done_cases = deque(), {}, 0
                it = iter(tasks)
                exhausted = False
                while pend or not exhausted:
                    while not exhausted and len(pend) < 2 * a.workers + 2:
                        try:
                            k, c = next(it)
                        except StopIteration:
                            exhausted = True
                            break
                        pend.append((k, c, pool.apply_async(solve_one, (make_task(c),))))
                    if not pend:
                        break
                    k, c, ar = pend.popleft()
                    r = ar.get()
                    buf.setdefault(k, []).append(r)
                    done_cases += 1
                    st = r["runs"]
                    print(f"case {c} ({plan[c]}) {r['seconds']:.0f} с m={st['d400_m']['status']}/{st['d400_m']['iters']} "
                          f"h={st['d400_h']['status']}/{st['d400_h']['iters']}", flush=True)
                    n_k = min((k + 1) * SHARD, ng) - k * SHARD
                    if len(buf[k]) == n_k:
                        sz = S5.write_part(out, k, *assemble(buf.pop(k), plan), attrs)
                        S5.build_view(out, ng)
                        write_progress([out], a.progress)
                        print(f"часть {k} записана ({sz / 1e6:.0f} МБ), прошло {time.perf_counter() - t0:.0f} с", flush=True)
        finally:
            if lk:
                fcntl.flock(lk, fcntl.LOCK_UN)
    S5.build_view(out, ng)
    write_progress([out], a.progress)
    print("готово", json.dumps(summarize(out), ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
