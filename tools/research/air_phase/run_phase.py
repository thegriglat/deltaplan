#!/usr/bin/env python3
"""air-phase AP-3: прогон всех серий плана P2 пакетами на GPU с записью P3 (контракт P5 v1, docs/contracts/air-phase.md).

  run_phase.py plan   [--name ap_v1] [--series grid,…] [--out $AIR_SYNTH_DATA/phase]
  run_phase.py run    --plan DIR [--series …] [--batch B] [--limit N] [--out DIR]
  run_phase.py trial  --plan DIR [--out DIR] [--batch B]
  run_phase.py bench  [--plan DIR] [--batch 1,2,4,8,16,32] [--n 32]
  run_phase.py status --plan DIR [--out DIR]
  run_all.sh                       # plan (если нет) + run всех серий; для dp job --lock gpu

Порядок счёта — GRID → SEPARATION → ENVELOPE → ENVELOPE_REAL → SWEEP → RELAX → ERODED: готовые случаи сортируются по
(ранг серии, k, case_id), пакет — первые B случаев группы с тем же шагом сетки (dx_m), что и у первого готового;
так пакет идёт поперёк линий (точка k многих линий — близкие Fr, близкое время сходимости), хвост серии добирается
случаями следующих. Тёплые цепочки (WARM_PREV) — строго по одному случаю линии за раз; состояние последнего случая —
в памяти и в `ckpt/line-<id>.h5` (пишется после части). Продолжение — той же командой: посчитанное = объединение
`cases/case_id` частей; состояние для следующего случая цепочки — из ckpt, если он не новее нужного, иначе предыдущие
случаи цепочки пересчитываются без записи («фантомы») от ckpt или от холодного k = 0.

GPU — один процесс (этот) под общим замком (`dp job --lock gpu …`); CPU-часть (параметры порядка, bubble, сжатие и
запись HDF5, ckpt, progress.jsonl) — процесс-писатель (spawn), очередь не больше 2 пакетов. Код выхода 0 — всё
(в выбранных сериях) посчитано или достигнут --limit; ≠ 0 — ошибка (исключение решателя, NaN) с записью в run.jsonl.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures as cf
import inspect
import json
import multiprocessing as mp
import os
import shutil
import sys
import time
import traceback
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import phase_io as IO  # noqa: E402

pb = IO.pb
MAX_PENDING = 2
CHUNK_MULT = 4      # solve_batch (AP-1) держит B случаев одновременно скользящим окном: вызов из 4B случаев почти без простоя хвоста


def get_solver():
    import batch_solver
    return batch_solver


def default_batch(solver):
    for name in ("DEFAULT_BATCH", "BATCH_DEFAULT", "DEFAULT_B", "B_DEFAULT"):
        if hasattr(solver, name):
            return int(getattr(solver, name))
    return 8


def device_name():
    try:
        import cupy as cp
        p = cp.cuda.runtime.getDeviceProperties(cp.cuda.Device().id)
        n = p["name"]
        return n.decode() if isinstance(n, bytes) else str(n)
    except Exception:
        return "cpu"


def results_dir(out, plan, version, trial=False):
    return Path(out) / f"{plan.name}{'_trial' if trial else ''}__{version}"


def _r(res, key, default=None):
    if isinstance(res, dict):
        return res.get(key, default)
    return getattr(res, key, default)


def _host(a, dtype=None):
    if a is None:
        return None
    a = a.get() if hasattr(a, "get") and not isinstance(a, (dict, np.ndarray)) else a
    a = np.asarray(a)
    return a.astype(dtype) if dtype is not None else a


# ------------------------------------------------------------------ прогон
class Runner:
    def __init__(self, plan_dir, out=None, series=None, batch=None, limit=None, solver=None, only=None, trial=False,
                 inline_writer=False, command="", chunk=None):
        self.plan_dir = Path(plan_dir)
        self.plan, self.sha, self.lines, self.rel, self.cases = IO.load_plan(plan_dir)
        self.solver = solver if solver is not None else get_solver()
        self.version = IO.solver_version(self.solver)
        self.out = Path(out) if out else IO.data_root() / "phase"
        self.dir = results_dir(self.out, self.plan, self.version, trial)
        self.batch = int(batch or default_batch(self.solver))
        self.chunk = int(chunk or CHUNK_MULT * self.batch)     # случаев на вызов solve_batch (= на часть P3)
        try:
            self._batch_kw = "batch" in inspect.signature(self.solver.solve_batch).parameters
        except (TypeError, ValueError):
            self._batch_kw = False
        self.limit = limit
        self.sel = IO.series_filter(series)
        self.only = set(only) if only is not None else None
        self.src = IO.Sources(self.plan, self.rel)
        self.rsrc = IO.RerunSources(self.plan_dir.parent)       # RERUN (P2 v6): исходные планы — соседние каталоги
        self.inline = inline_writer
        self.command = command
        self.by_id = {c.case_id: c for c in self.cases}
        self.by_line = collections.defaultdict(list)
        for c in self.cases:
            self.by_line[c.line_id].append(c)

    # --- что считать
    def _wanted(self, c):
        return c.series in self.sel and (self.only is None or c.case_id in self.only)

    def _init_state(self):
        self.done = {cid: st for cid, (st, _) in IO.done_cases(self.dir).items()}
        self.warm = {}
        for lid, cs in self.by_line.items():
            ln = self.lines[lid]
            if ln.start != pb.WARM_PREV or not any(self._wanted(c) for c in cs):
                continue
            todo = [c.k for c in cs if self._wanted(c) and c.case_id not in self.done]
            if not todo:
                continue
            first = min(todo)
            w = dict(held=-1, state=None, status=0)
            if first > 0:
                ck = IO.read_ckpt(self.dir, lid)
                if ck is not None and ck[1] <= first - 1:
                    w.update(held=ck[1], status=ck[2],
                             state=None if ck[2] == 2 else IO.state_from_dict(ck[3], self.solver))
            self.warm[lid] = w

    def _ready(self):
        """Готовые задачи: (ключ сортировки, Case, phantom)."""
        out = []
        for c in self.cases:
            if c.line_id in self.warm or not self._wanted(c) or c.case_id in self.done:
                continue
            if self.lines[c.line_id].start == pb.WARM_PREV:
                continue
            out.append(c)
        # RERUN: холодные случаи — строго по case_id (построитель нумерует по приоритету исходной серии)
        tasks = [((IO.SERIES_RANK[c.series], 0 if c.series == pb.RERUN else c.k, c.case_id), c, False) for c in out]
        for lid, w in self.warm.items():
            cs = self.by_line[lid]
            k = w["held"] + 1
            if k >= len(cs):
                continue
            c = cs[k]
            need = [x for x in cs[k:] if self._wanted(x) and x.case_id not in self.done]
            if not need:
                continue
            tasks.append(((IO.SERIES_RANK[c.series], c.k, c.case_id), c, c.case_id in self.done))
        tasks.sort(key=lambda t: t[0])
        return tasks

    def _pick(self, tasks):
        if not tasks:
            return []
        dx = self.lines[tasks[0][1].line_id].numerics.dx_m
        return [t for t in tasks if self.lines[t[1].line_id].numerics.dx_m == dx][: self.chunk]

    # --- решатель
    def _spec(self, c):
        ln = self.lines[c.line_id]
        r = self.rel[ln.relief_id]
        if c.series == pb.RERUN:
            ph = IO.rerun_physics(ln, r, c.fr, c.src_case_id, self.src, self.rsrc)
        else:
            ph = IO.case_physics(self.plan, ln, r, c.fr, self.src)
        S = self.solver
        spec = S.CaseSpec(g100=self.src.g100(ln.relief_id), ctx=ph["ctx"], u10=ph["u10"], wdir_from_deg=ph["wdir"],
                          alpha=ph["alpha"], max_profile=ph["max_profile"], n_bv_s=ph["ov_n"], z_i_agl_m=ph["ov_zi"],
                          heat_flux_wm2=ph["ov_heat"], dx_m=float(ln.numerics.dx_m), cond_row=ph["cond_row"])
        return spec, S.Numerics(**IO.numerics_kwargs(ln.numerics)), ph

    def _init_for(self, c):
        if self.lines[c.line_id].start != pb.WARM_PREV or c.k == 0:
            return None, -1
        w = self.warm[c.line_id]
        assert w["held"] == c.k - 1, (c, w["held"])
        if w["state"] is None:
            return None, -1
        return w["state"], self.by_line[c.line_id][c.k - 1].case_id

    def _item(self, c, res, ph, start_cid, sec, m):
        ln = self.lines[c.line_id]
        for k in ("u_sat", "n_bv", "z_i_agl_m", "heat_flux_wm2"):     # величины, выведенные решателем (P4), если он их даёт
            v = _r(res, k)
            if v is not None and np.isfinite(v):
                ph = dict(ph, **{k: float(v)})
        st = IO.STATUS[_r(res, "status")] if isinstance(_r(res, "status"), str) else int(_r(res, "status"))
        tg = _r(res, "target", "final")
        rec = dict(case_id=c.case_id, line_id=c.line_id, k=c.k, series=c.series, relief_id=ln.relief_id, fr=c.fr,
                   froude_table=float(_r(res, "froude_table", np.nan)), u10=ph["u10"], u_sat=ph["u_sat"],
                   wdir_from_deg=ph["wdir"], n_bv=ph["n_bv"], z_i_agl_m=ph["z_i_agl_m"],
                   heat_flux_wm2=ph["heat_flux_wm2"], zi_over_L=float(_r(res, "zi_over_L", 0.0)),
                   dx_m=ln.numerics.dx_m, start_case_id=start_cid, status=st, iters=int(_r(res, "iters", 0)),
                   target=IO.TARGET[tg] if isinstance(tg, str) else int(tg), late_n=int(_r(res, "late_n", 1)),
                   late_spread60_p90=float(_r(res, "late_spread60_p90", 0.0)),
                   resid_final=float(_r(res, "resid_final", 0.0)), resid_rel_final=float(_r(res, "resid_rel_final", 0.0)),
                   seconds=sec, batch_size=m, cond_id=ln.cond_id if ln.conditions else -1,
                   envelope_angle_deg=ln.numerics.envelope_angle_deg, envelope_wall=int(ln.numerics.envelope_wall))
        for k in ("froude_table", "zi_over_L"):
            if not np.isfinite(rec[k]):
                rec[k] = 0.0
        tr = _r(res, "trace") or {}
        trace = dict(iter=_host(tr.get("iter", []), np.int32).ravel(), resid=_host(tr.get("resid", []), np.float32).ravel(),
                     du_max=_host(tr.get("du_max", []), np.float32).ravel())
        trace["fields"] = _host(tr["fields"], np.float32) if trace["iter"].size else np.zeros((0, 3, 2, 96, 96), np.float32)
        win = _r(res, "window")
        if win is not None:
            win = dict(win.items() if isinstance(win, dict) else vars(win).items())
            for k, v in (win.pop("meta", None) or {}).items():     # AP-1: x0_m, y0_m, dx_m, brink_*, fits_15h — в meta
                win.setdefault(k, v)
            win = {k: (_host(v, np.float32) if hasattr(v, "shape") else v) for k, v in win.items()}
        item = dict(rec=rec, fields=_host(_r(res, "fields"), np.float32), hc=_host(_r(res, "hc"), np.float32),
                    heat_flux=_host(_r(res, "heat_flux"), np.float32), hbl=_host(_r(res, "hbl"), np.float32),
                    h_eff=_host(_r(res, "h_eff"), np.float32) if ln.numerics.envelope_angle_deg > 0 else None,
                    trace=trace, window=win, wdir=ph["wdir"], u10=ph["u10"], alpha=ph["alpha"],
                    max_profile=ph["max_profile"], u_sat=ph["u_sat"], n_bv=ph["n_bv"], h_m=ph["h_m"])
        if c.series == pb.SEPARATION:
            item["g100"] = self.src.g100(ln.relief_id)
        return item

    def run(self):
        os.makedirs(self.dir, exist_ok=True)
        self._init_state()
        runlog = self.dir / "run.jsonl"
        dev = device_name()
        IO.jsonl(runlog, dict(event="start", plan=str(self.plan_dir), solver_version=self.version, batch=self.batch,
                              chunk=self.chunk,
                              device=dev, done=len(self.done), command=self.command, git_commit=IO.git_commit()))
        attrs = dict(plan=str(self.plan_dir), plan_sha256=self.sha, solver_version=self.version, device=dev,
                     batch_size=self.batch, git_commit=IO.git_commit(), command=self.command)
        part = IO.next_part_index(self.dir)
        pool = None if self.inline else cf.ProcessPoolExecutor(1, mp_context=mp.get_context("spawn"))
        pending = collections.deque()
        n_real, rc = 0, 0

        def drain(maxlen):
            while len(pending) > maxlen:
                fut = pending.popleft()
                info = fut.result() if pool else fut
                IO.jsonl(runlog, dict(event="written", **info))

        try:
            while True:
                if self.limit is not None and n_real >= self.limit:
                    break
                batch = self._pick(self._ready())
                if not batch:
                    break
                specs, nums, phs, inits, starts = [], [], [], [], []
                for _, c, _ in batch:
                    s, n, ph = self._spec(c)
                    st, sc = self._init_for(c)
                    specs.append(s); nums.append(n); phs.append(ph); inits.append(st); starts.append(sc)
                t0 = time.perf_counter()
                kw = dict(batch=self.batch) if self._batch_kw else {}
                results = self.solver.solve_batch(specs, nums, inits, **kw)
                wall = time.perf_counter() - t0
                m = len(batch)
                items, ckpts, drops = [], [], []
                for (_, c, phantom), res, ph, sc in zip(batch, results, phs, starts):
                    it = self._item(c, res, ph, sc, wall / m, self.batch)
                    st = it["rec"]["status"]
                    if self.lines[c.line_id].start == pb.WARM_PREV:
                        w = self.warm[c.line_id]
                        state = None if st == 2 else _r(res, "state")
                        w.update(held=c.k, status=st, state=state)
                        if c.k == len(self.by_line[c.line_id]) - 1:
                            drops.append(c.line_id)
                            w["state"] = None            # линия досчитана — состояние не нужно (память)
                        else:
                            ckpts.append((c.line_id, c.case_id, c.k, st, None if state is None else IO.state_to_dict(state)))
                    if phantom:
                        continue
                    items.append(it)
                    self.done[c.case_id] = st
                    n_real += 1
                job = dict(dir=str(self.dir), part=part, attrs=dict(attrs, chunk=m), items=items, ckpts=ckpts,
                           drops=drops)
                IO.jsonl(runlog, dict(event="batch", part=part if items else None, size=m, n_write=len(items),
                                      phantoms=m - len(items), wall_s=round(wall, 3),
                                      series=sorted({pb.Series.Name(c.series) for _, c, _ in batch}),
                                      dx_m=self.lines[batch[0][1].line_id].numerics.dx_m,
                                      iters=[int(it["rec"]["iters"]) for it in items],
                                      status=[int(it["rec"]["status"]) for it in items]))
                if items:
                    part += 1
                pending.append(pool.submit(IO.write_batch, job) if pool else IO.write_batch(job))
                drain(MAX_PENDING)
            drain(0)
        except BaseException as e:
            rc = 1
            IO.jsonl(runlog, dict(event="error", error=repr(e), tb=traceback.format_exc()[-4000:]))
            try:
                drain(0)
            except BaseException as e2:
                IO.jsonl(runlog, dict(event="error", error=repr(e2), tb=traceback.format_exc()[-4000:]))
            if isinstance(e, KeyboardInterrupt):
                raise
        finally:
            if pool:
                pool.shutdown(wait=True)
        left = sum(1 for c in self.cases if self._wanted(c) and c.case_id not in self.done)
        IO.jsonl(runlog, dict(event="end", rc=rc, solved=n_real, left=left))
        return rc


# ------------------------------------------------------------------ пробный прогон и оценка
def trial_cases(plan_dir, batch, series=None):
    # batch здесь — число случаев на группу (= chunk полного счёта)
    """Малый набор: на группу (серия, dx) — B случаев, равномерно по отсортированному Fr (холодные линии); у тёплых —
    B линий равномерно × k = 0, 1."""
    plan, _, lines, _, cases = IO.load_plan(plan_dir)
    sel = IO.series_filter(series)
    groups = collections.defaultdict(list)
    for c in cases:
        if c.series in sel:
            groups[(c.series, lines[c.line_id].numerics.dx_m, lines[c.line_id].start)].append(c)
    only = set()
    for (s, dx, start), cs in groups.items():
        if start == pb.WARM_PREV:
            lids = sorted({c.line_id for c in cs})
            pick = {lids[i] for i in np.unique(np.linspace(0, len(lids) - 1, min(batch, len(lids))).round().astype(int))}
            only |= {c.case_id for c in cs if c.line_id in pick and c.k <= 1}
        else:
            cs = sorted(cs, key=lambda c: (c.fr, c.case_id))
            only |= {cs[i].case_id for i in np.unique(np.linspace(0, len(cs) - 1, min(batch, len(cs))).round().astype(int))}
    return only


def estimate(plan_dir, rdir, batch):
    """Оценка полного счёта по частям пробного прогона: по группам (серия, dx) — среднее «стенное время пакета / M»
    (консервативно: пробный пакет разнороден по Fr и ждёт самый медленный случай) и байт на случай."""
    import h5py
    plan, _, lines, _, cases = IO.load_plan(plan_dir)
    full = collections.Counter((pb.Series.Name(c.series), int(lines[c.line_id].numerics.dx_m)) for c in cases)
    g = collections.defaultdict(lambda: dict(sec=[], iters=[], status=[], bytes=0.0, n=0, tau=[]))
    for p in IO.parts(rdir):
        size = p.stat().st_size
        with h5py.File(p, "r") as h:
            c = h["cases"][:]
        m = len(c)
        mx = max(int(c["iters"].max()), 1)
        for r in c:
            key = (pb.Series.Name(int(r["series"])), int(r["dx_m"]))
            d = g[key]
            d["sec"].append(float(r["seconds"])); d["iters"].append(int(r["iters"])); d["status"].append(int(r["status"]))
            d["bytes"] += size / m; d["n"] += 1
            d["tau"].append(float(r["seconds"]) / mx)          # с на случай-итерацию в пакете
    groups, hours, hours_opt, gb = {}, 0.0, 0.0, 0.0
    for key, n_full in sorted(full.items()):
        d = g.get(key)
        if not d or not d["n"]:
            groups[f"{key[0]}/{key[1]}"] = dict(n_full=n_full, n_trial=0)
            continue
        sec = float(np.mean(d["sec"]))
        tau = float(np.median(d["tau"]))
        it = float(np.mean(d["iters"]))
        bpc = d["bytes"] / d["n"]
        eh = sec * n_full / 3600
        eo = tau * it * n_full / 3600
        hours += eh; hours_opt += eo; gb += bpc * n_full / 1e9
        st = collections.Counter(d["status"])
        groups[f"{key[0]}/{key[1]}"] = dict(n_full=n_full, n_trial=d["n"], sec_per_case=round(sec, 2),
                                            iters_mean=round(it, 1), status_ok_max_div=[st[0], st[1], st[2]],
                                            mb_per_case=round(bpc / 1e6, 3), est_hours=round(eh, 2),
                                            est_hours_homogeneous=round(eo, 2), est_gb=round(bpc * n_full / 1e9, 2))
    by_series = collections.Counter()
    sec_series = collections.defaultdict(list)
    for (s, _), n in full.items():
        by_series[s] += n
    for key, d in g.items():
        sec_series[key[0]] += d["sec"]
    return dict(groups=groups, cases_by_series=dict(by_series),
                sec_per_case_by_series={s: round(float(np.mean(v)), 2) for s, v in sec_series.items()},
                full_estimate_hours=round(hours, 2), full_estimate_hours_homogeneous=round(hours_opt, 2),
                full_estimate_gb=round(gb, 2), n_cases=len(cases))


def cmd_trial(a):
    solver = get_solver()
    B = int(a.batch or default_batch(solver))
    chunk = int(a.chunk or CHUNK_MULT * B)
    only = trial_cases(a.plan, chunk, a.series)
    r = Runner(a.plan, a.out, a.series, B, None, solver, only=only, trial=True, command=" ".join(sys.argv), chunk=chunk)
    t0 = time.time()
    rc = r.run()
    est = estimate(a.plan, r.dir, B)
    est.update(solver_version=r.version, batch_size=B, chunk=chunk, device=device_name(), plan=str(a.plan), results=str(r.dir),
               trial_cases=len(only), trial_wall_s=round(time.time() - t0, 1), rc=rc,
               disk_free_gb=round(shutil.disk_usage(r.dir).free / 1e9, 1),
               note="full_estimate_hours — сумма по группам (серия, dx) «стенное время пробного пакета / M» × число "
                    "случаев (пробный пакет разнороден по Fr — консервативно); _homogeneous — по итерациям, если "
                    "пакеты однородны (в полном счёте пакет — точка k многих линий)")
    txt = json.dumps(est, ensure_ascii=False, indent=1)
    (r.dir / "trial.json").write_text(txt, encoding="utf-8")
    (HERE / "out").mkdir(exist_ok=True)
    (HERE / "out" / "trial.json").write_text(txt, encoding="utf-8")
    print(txt)
    return rc


# ------------------------------------------------------------------ bench, status, plan
def cmd_bench(a):
    solver = get_solver()
    if hasattr(solver, "bench") and not a.own:
        return solver.bench([int(x) for x in a.batch.split(",")], a.n)
    plan_dir = a.plan or IO.data_root() / "phase" / "ap_v1"
    r = Runner(plan_dir, a.out, "grid", 1, None, solver, command=" ".join(sys.argv))
    grid = [c for c in r.cases if c.series == pb.GRID]
    kmid = 15
    picks = [c for c in grid if c.k == kmid][: a.n]
    rows = []
    for B in [int(x) for x in a.batch.split(",")]:
        t0 = time.perf_counter()
        for i in range(0, len(picks), B):
            sl = picks[i:i + B]
            sp = [r._spec(c) for c in sl]
            solver.solve_batch([s for s, _, _ in sp], [n for _, n, _ in sp], [None] * len(sl))
        wall = time.perf_counter() - t0
        peak = None
        try:
            import cupy as cp
            peak = cp.get_default_memory_pool().total_bytes() / 1e9
        except Exception:
            pass
        rows.append(dict(batch=B, n=len(picks), wall_s=round(wall, 1), cases_per_hour=round(len(picks) / wall * 3600, 1),
                         pool_gb=peak))
        print(rows[-1], flush=True)
    os.makedirs(r.dir, exist_ok=True)
    (r.dir / "bench.json").write_text(json.dumps(dict(rows=rows, solver_version=r.version, device=device_name()),
                                                 indent=1), encoding="utf-8")
    return 0


def find_results(plan, out, version):
    d = results_dir(out, plan, version)
    if d.exists():
        return d
    cands = sorted(Path(out).glob(f"{plan.name}__*"), key=lambda p: p.stat().st_mtime)
    return cands[-1] if cands else d


def cmd_status(a):
    plan, _, lines, _, cases = IO.load_plan(a.plan)
    out = Path(a.out) if a.out else IO.data_root() / "phase"
    d = find_results(plan, out, IO.solver_version())
    done = IO.done_cases(d) if d.exists() else {}
    tot, ok = collections.Counter(), collections.Counter()
    st = collections.Counter()
    for c in cases:
        s = pb.Series.Name(c.series)
        tot[s] += 1
        if c.case_id in done:
            ok[s] += 1
            st[done[c.case_id][0]] += 1
    size = sum(p.stat().st_size for p in IO.parts(d)) if d.exists() else 0
    print(f"результаты: {d}{'' if d.exists() else ' (нет)'}")
    for s in IO.SERIES_ORDER:
        if tot[s]:
            print(f"  {s:14s} {ok[s]:5d} / {tot[s]:5d}")
    n_ok, n_tot = sum(ok.values()), len(cases)
    print(f"  всего          {n_ok:5d} / {n_tot:5d}   статусы ok/max/div: {st[0]}/{st[1]}/{st[2]}")
    print(f"  объём частей: {size / 1e9:.2f} ГБ; ckpt: {len(list((d / 'ckpt').glob('*.h5'))) if (d / 'ckpt').exists() else 0}")
    prog = d / "progress.jsonl"
    if prog.exists() and n_ok:
        import datetime
        rows = [json.loads(x) for x in prog.read_text(encoding="utf-8").splitlines()[-300:] if x.strip()]
        if len(rows) >= 2:
            t = [datetime.datetime.fromisoformat(r["t"]) for r in rows]
            span = (t[-1] - t[0]).total_seconds()
            if span > 0:
                rate = (len(rows) - 1) / span
                left = n_tot - n_ok
                print(f"  темп (последние {len(rows)}): {rate * 3600:.0f} случаев/ч; ETA ≈ {left / rate / 3600:.1f} ч "
                      f"(по темпу текущих серий; медленные Fr и окно 100 м — иначе); MB/случай {size / n_ok / 1e6:.2f}")
    if (d / "run.jsonl").exists():
        last = (d / "run.jsonl").read_text(encoding="utf-8").splitlines()[-1]
        print(f"  run.jsonl, последняя запись: {last[:300]}")
    return 0


def cmd_plan(a):
    import plan_build
    plan, _ = plan_build.build_plan(name=a.name, out=a.out, series=a.series or plan_build.SERIES_ALL)
    print(f"план: {Path(a.out or IO.data_root() / 'phase') / a.name}, случаев {plan.n_cases}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan"); p.add_argument("--name", default="ap_v1"); p.add_argument("--series"); p.add_argument("--out")
    p = sub.add_parser("run"); p.add_argument("--plan", required=True); p.add_argument("--series"); p.add_argument("--batch", type=int)
    p.add_argument("--limit", type=int); p.add_argument("--out"); p.add_argument("--chunk", type=int)
    p = sub.add_parser("trial"); p.add_argument("--plan", required=True); p.add_argument("--out"); p.add_argument("--batch", type=int)
    p.add_argument("--chunk", type=int)
    p.add_argument("--series")
    p = sub.add_parser("bench"); p.add_argument("--plan"); p.add_argument("--batch", default="1,2,4,8,16,32")
    p.add_argument("--n", type=int, default=32); p.add_argument("--out"); p.add_argument("--own", action="store_true")
    p = sub.add_parser("status"); p.add_argument("--plan", required=True); p.add_argument("--out")
    a = ap.parse_args(argv)
    if a.cmd == "plan":
        return cmd_plan(a)
    if a.cmd == "run":
        return Runner(a.plan, a.out, a.series, a.batch, a.limit, command=" ".join(sys.argv), chunk=a.chunk).run()
    if a.cmd == "trial":
        return cmd_trial(a)
    if a.cmd == "bench":
        return cmd_bench(a)
    return cmd_status(a)


if __name__ == "__main__":
    sys.exit(main())
