"""P9 v1: счёт «фазы + Пикар» по выборке SY-12 (как AP-17) против холодного Пикара той же версии решателя.

    run_hybrid.py prep  [--out DIR] [--workers 16]          # CPU: классификатор, сборка + G → DIR/_prep/prep-*.h5
    run_hybrid.py gpu   [--out DIR] [--variants cold,hybrid,fallback,cold_omap,timing] [--batch 4]   # GPU, под dp job --lock gpu
    run_hybrid.py final [--out DIR] [--workers 16]          # CPU: сшивка → DIR/part-*.h5 (P9) + metrics-*.jsonl
    run_hybrid.py clean [--out DIR]                         # удалить промежуточное (_prep, raw полей вариантов)

Выборка — `assembly/run_assembly.select` (все 480 holdout + каждый 20-й train, где S5 сошёлся в обоих решениях) — 782 случая.
Варианты GPU (по решениям «m» — без нагрева, «h» — с нагревом; P4 v6):
  cold      — холодный старт, Numerics() (как S5, но нынешняя версия решателя) — эталон итераций и полей;
  hybrid    — шаг 3 P9: init = сборка, omega_map, freeze_mask, omega_fallback (300, 0,5), max_outer 1000;
              полностью механические случаи (Fr < 0,3) не считаются;
  fallback  — то же без карты ω (ω = 1 + запасное правило) — только случаи, где карта ω < 1 (вклад карты);
  cold_omap — холодный старт с той же картой ω и запасным правилом, без заморозки — вклад тёплого старта;
  timing    — 24 случая hybrid «h» по одному (B = 1) — мс на итерацию без соседей по GPU.
Выход GPU: DIR/raw/<вариант>-<часть>.h5 (status, iters, seconds, wall_own, switch, поля f2), продолжение — пропуск готовых частей.
Финал: DIR/part-*.h5 по P9 (cases с iters/status/seconds_gpu/iters_cold/status_cold, fields/f, fields/m — дополнительно,
weights u1 ×255, omega_map u1 ×255, freeze_mask u1, атрибуты contract «P9 v1», cfg, solver_version) и DIR/metrics-*.jsonl —
метрики слоёв P6 (гибрид, холодный нынешний, S5 s0, только механизмы, варианты) по случаю. Холодные поля нынешней версии —
DIR/cold/part-*.h5 (f2; для сравнения и AP-19).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import sys
import time
from pathlib import Path

for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import h5py  # noqa: E402
import numpy as np  # noqa: E402

HERE = Path(__file__).resolve().parent
AP = HERE.parent
sys.path.insert(0, str(AP))

from assembly import run_assembly as RA  # noqa: E402
from hybrid import pipeline as PL  # noqa: E402

DATA = RA.DATA
OUT = DATA / "phase/hybrid_v1"
RELIEF = DATA / "real/hg_v2"
CHUNK = 25
STATUS = {"ok": 0, "max": 1, "diverged": 2}
VARIANTS = ("cold", "hybrid", "fallback", "cold_omap", "timing")
N_TIMING = 24
F2 = dict(compression="gzip", compression_opts=4, shuffle=True)


def selection():
    sel = RA.select(RA.load_index(), 20)
    return sel


def chunks(sel):
    return [(q, sel[i:i + CHUNK]) for q, i in enumerate(range(0, len(sel), CHUNK))]


# ============================================================================== prep (CPU)
def _prep_work(args):
    q, items, out, ctab, commit = args
    path = Path(out) / "_prep" / f"prep-{q:05d}.h5"
    if path.exists():
        return q, 0
    recs = []
    arr = {k: [] for k in ("hc", "heat", "hbl", "init_h", "init_m", "weights", "weights_m", "omega_map", "freeze_h", "freeze_m",
                           "g_w", "g_u", "g_v", "g_th", "g_member")}
    lines = []
    cfg = None
    for p, r, cs in items:
        with h5py.File(p, "r") as h:
            hc = h["inputs/hc"][r].astype(np.float64)
            heat = h["inputs/heat_flux"][r].astype(np.float64)
            hbl = h["inputs/hbl"][r].astype(np.float32)
        cd = ctab[(cs["relief_id"], cs["cond_id"])]
        t0 = time.process_time()
        pr = PL.prepare(hc, heat, cd)
        cpu = time.process_time() - t0
        cfg = pr["cfg"]
        g = pr["g"]
        for k, v in (("hc", hc.astype(np.float32)), ("heat", heat.astype(np.float32)), ("hbl", hbl),
                     ("init_h", pr["init_h"].astype(np.float16)), ("init_m", pr["init_m"].astype(np.float16)),
                     ("weights", np.round(pr["weights"] * 255).astype(np.uint8)),
                     ("weights_m", np.round(pr["weights_m"] * 255).astype(np.uint8)),
                     ("omega_map", pr["omega_map"].astype(np.float32)), ("freeze_h", pr["freeze_h"].astype(np.uint8)),
                     ("freeze_m", pr["freeze_m"].astype(np.uint8)), ("g_w", g["w"].astype(np.float32)),
                     ("g_u", g["u"].astype(np.float16)), ("g_v", g["v"].astype(np.float16)), ("g_th", g["th"].astype(np.float16)),
                     ("g_member", g["member"].astype(np.float16))):
            arr[k].append(v)
        recs.append((cs["case"], cs["relief_id"], cs["cond_id"], cs["group"], cs["status_m"], cs["status_h"], cs["iters_m"],
                     cs["iters_h"], cpu))
        lines.append(json.dumps(dict(case=cs["case"], seconds=pr["seconds"], cpu_s=cpu, info=pr["info"]), ensure_ascii=False,
                                default=float))
    dt = np.dtype([("case", "i8"), ("relief_id", "i8"), ("cond_id", "i4"), ("group", "i1"), ("status_m_s5", "i1"),
                   ("status_h_s5", "i1"), ("iters_m_s5", "i4"), ("iters_h_s5", "i4"), ("cpu_s", "f4")])
    tmp = path.with_suffix(".tmp")
    with h5py.File(tmp, "w") as h:
        h.create_dataset("cases", data=np.array(recs, dt))
        for k, v in arr.items():
            h.create_dataset(k, data=np.stack(v), **F2)
        h.attrs["cfg"] = cfg
        h.attrs["git_commit"] = commit
    os.replace(tmp, path)
    (Path(out) / "_prep" / f"prep-{q:05d}.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return q, len(items)


def stage_prep(out, workers):
    (out / "_prep").mkdir(parents=True, exist_ok=True)
    sel = selection()
    ctab = RA.cond_table()
    commit = RA.git_commit()
    jobs = [(q, it, str(out), ctab, commit) for q, it in chunks(sel)]
    (out / "manifest.json").write_text(json.dumps(dict(contract="P9 v1", n_cases=len(sel), selection="run_assembly.select(train_stride=20)",
                                                       solve_s5=str(RA.SOLVE), conditions=str(RA.COND), relief=str(RELIEF),
                                                       git_commit=commit, parts=len(jobs), cfg=PL.DEFAULT_CFG),
                                                  ensure_ascii=False, indent=1, default=list))
    from multiprocessing import Pool
    t0 = time.time()
    with Pool(workers) as pool:
        for q, n in pool.imap_unordered(_prep_work, jobs):
            print(f"prep {q} cases {n} t={time.time() - t0:.0f}s", flush=True)


# ============================================================================== gpu
def _load_prep(out, q):
    with h5py.File(out / "_prep" / f"prep-{q:05d}.h5", "r") as h:
        d = {k: h[k][:] for k in h.keys()}
    return d


def _relief(ids):
    import reliefs as RL
    got = RL.load_corpus(RELIEF, ids)
    return {i: g[1] for i, g in zip(ids, got)}


def _specs(BS, d, ctab, decs):
    """→ список (k, dec, CaseSpec) для случаев части."""
    g100 = _relief([int(x) for x in d["cases"]["relief_id"]])
    out = []
    for k, c in enumerate(d["cases"]):
        row = ctab[(int(c["relief_id"]), int(c["cond_id"]))]
        for dec in decs:
            sp = BS.CaseSpec(g100=g100[int(c["relief_id"])], ctx={}, u10=float(row["u10_m_s"]), wdir_from_deg=float(row["wind_from_deg"]),
                             alpha=None, max_profile=None, heat_flux_wm2=None if dec == "h" else 0.0, cond_row=row)
            out.append((k, dec, sp))
    return out


def _prep_case(d, k):
    return dict(omega_map=d["omega_map"][k], freeze_h=d["freeze_h"][k].astype(bool), freeze_m=d["freeze_m"][k].astype(bool))


def _gpu_part(BS, out, q, variant, ctab, batch):
    raw = out / "raw" / f"{variant}-{q:05d}.h5"
    if raw.exists():
        return 0
    d = _load_prep(out, q)
    n = len(d["cases"])
    jobs = []
    for k, dec, sp in _specs(BS, d, ctab, ("m", "h")):
        pc = _prep_case(d, k)
        full = bool(pc["freeze_m"].all()) if dec == "m" else bool(pc["freeze_h"].all())
        if variant != "cold" and full:
            continue
        if variant == "fallback" and float(pc["omega_map"].min()) > 1.0 - PL.DEFAULT_CFG["omega_snap"]:
            continue
        kw = PL.numerics_kwargs(dict(pc, omega_map=pc["omega_map"]), dec, variant="hybrid" if variant == "timing" else variant)
        init = None
        if variant in ("hybrid", "fallback", "timing"):
            init = {"agl": d["init_h"][k].astype(np.float32) if dec == "h" else d["init_m"][k].astype(np.float32)}
        jobs.append((k, dec, sp, BS.Numerics(**kw), init))
    if variant == "timing":
        jobs = [j for j in jobs if j[1] == "h"][:N_TIMING]
    rec = []
    fh = np.zeros((n, 4, 13, 96, 96), np.float16)
    fm = np.zeros((n, 3, 13, 96, 96), np.float16)
    has = np.zeros((n, 2), np.uint8)
    t0 = time.time()
    if jobs:
        B = 1 if variant == "timing" else batch
        if variant == "timing":
            res = []
            for j in jobs:
                res += BS.solve_batch([j[2]], [j[3]], init=[j[4]], batch=1)
        else:
            res = BS.solve_batch([j[2] for j in jobs], [j[3] for j in jobs], init=[j[4] for j in jobs], batch=B)
        for (k, dec, sp, num, init), r in zip(jobs, res):
            rec.append((k, 0 if dec == "m" else 1, STATUS[r.status], r.iters, r.seconds, r.wall_own, r.meta.get("omega_switch_iter", -1),
                        r.meta.get("n_frozen_cols", 0), r.resid_final, r.u_sat))
            if dec == "h":
                fh[k] = r.fields.astype(np.float16); has[k, 1] = 1
            else:
                fm[k] = r.fields[:3].astype(np.float16); has[k, 0] = 1
    dt = np.dtype([("k", "i4"), ("dec", "i1"), ("status", "i1"), ("iters", "i4"), ("seconds", "f4"), ("wall_own", "f4"),
                   ("switch", "i4"), ("n_frozen", "i4"), ("resid", "f4"), ("u_sat", "f4")])
    raw.parent.mkdir(parents=True, exist_ok=True)
    tmp = raw.with_suffix(".tmp")
    with h5py.File(tmp, "w") as h:
        h.create_dataset("runs", data=np.array(rec, dt))
        h.create_dataset("case", data=d["cases"]["case"])
        if variant != "timing":
            h.create_dataset("fields_h", data=fh, chunks=(1, 4, 13, 96, 96), **F2)
            h.create_dataset("fields_m", data=fm, chunks=(1, 3, 13, 96, 96), **F2)
        h.create_dataset("has", data=has)
        h.attrs["variant"] = variant
        h.attrs["solver_version"] = BS.solver_version()
        h.attrs["batch"] = 1 if variant == "timing" else batch
        h.attrs["wall_s"] = time.time() - t0
        h.attrs["device"] = _device()
    os.replace(tmp, raw)
    return len(jobs)


def _device():
    try:
        import cupy as cp
        return cp.cuda.runtime.getDeviceProperties(0)["name"].decode()
    except Exception:
        return "unknown"


def _stub_solve_batch(BS):
    """Заглушка решателя для сухого прогона конвейера на CPU (--stub): поле = init (или нули), status ok, iters 11."""
    def solve(specs, nums, init=None, batch=None):
        res = []
        for sp, nm, it in zip(specs, nums, init or [None] * len(specs)):
            f = np.zeros((4, 13, 96, 96), np.float32)
            if it is not None:
                a = np.asarray(it["agl"], np.float32)
                f[:a.shape[0]] = a
            res.append(BS.CaseResult(status="ok", iters=11, target="final", late_n=1, late_spread60_p90=0.0, resid_final=0.0,
                                     resid_rel_final=0.0, fields=f, hc=None, heat_flux=None, hbl=None, trace={}, state={},
                                     window=None, seconds=0.01, froude_table=0.0, zi_over_L=0.0, u_sat=1.0,
                                     meta=dict(omega_switch_iter=-1, n_frozen_cols=int(np.sum(nm.freeze_mask)) if nm.freeze_mask is not None else 0)))
            res[-1].wall_own = 0.01
        return res
    return solve


def stage_gpu(out, variants, batch, stub=False, limit=0):
    import batch_solver as BS
    if stub:
        BS.solve_batch = _stub_solve_batch(BS)
    ctab = RA.cond_table()
    parts = sorted(int(Path(p).stem.split("-")[1]) for p in glob.glob(str(out / "_prep" / "prep-*.h5")))
    if limit:
        parts = parts[:limit]
    log = out / "gpu.jsonl"
    for v in variants:
        assert v in VARIANTS, v
        qs = parts[:1] if v == "timing" else parts
        for q in qs:
            t0 = time.time()
            nj = _gpu_part(BS, out, q, v, ctab, batch)
            with open(log, "a") as f:
                f.write(json.dumps(dict(variant=v, part=q, jobs=nj, wall_s=time.time() - t0, t=time.strftime("%H:%M:%S"))) + "\n")
            print(f"{v} part {q} jobs {nj} {time.time() - t0:.0f}s", flush=True)


# ============================================================================== final (CPU)
def _runs(path):
    if not path.exists():
        return None
    with h5py.File(path, "r") as h:
        runs = h["runs"][:]
        out = dict(runs={(int(r["k"]), int(r["dec"])): r for r in runs}, solver_version=h.attrs["solver_version"],
                   batch=int(h.attrs["batch"]), wall_s=float(h.attrs["wall_s"]))
        if "fields_h" in h:
            out["fields_h"], out["fields_m"], out["has"] = h["fields_h"], None, h["has"][:]
            out["_h5"] = path
    return out


def _fields(path, k):
    with h5py.File(path, "r") as h:
        return h["fields_h"][k].astype(np.float32), h["fields_m"][k].astype(np.float32), h["has"][k]


def _lm(f, fm, hc, heat, hbl, case):
    import layer_metrics as LM
    m = LM.layer_metrics(f, hc, heat, hbl, case, w_mech=fm[2])
    return {k: (None if not np.isfinite(v) else float(v)) for k, v in m.items()}


def _final_work(args):
    q, out, ctab, commit = args
    out = Path(out)
    part = out / f"part-{q:05d}.h5"
    jl = out / f"metrics-{q:05d}.jsonl"
    if part.exists() and jl.exists():
        return q, 0
    import layer_metrics as LM
    d = _load_prep(out, q)
    R = {v: _runs(out / "raw" / f"{v}-{q:05d}.h5") for v in ("cold", "hybrid", "fallback", "cold_omap")}
    n = len(d["cases"])
    s5 = {}
    sel = {x[2]["case"]: x for x in selection()}
    F, Fm, recs, lines = [], [], [], []
    cold_f, cold_fm = [], []
    solver_version = R["cold"]["solver_version"] if R["cold"] else "unknown"
    for k in range(n):
        c = d["cases"][k]
        cd = ctab[(int(c["relief_id"]), int(c["cond_id"]))]
        hc = d["hc"][k].astype(np.float64); heat = d["heat"][k].astype(np.float64); hbl = d["hbl"][k].astype(np.float64)
        g = dict(w=d["g_w"][k].astype(np.float64), u=d["g_u"][k].astype(np.float64), v=d["g_v"][k].astype(np.float64),
                 th=d["g_th"][k].astype(np.float64), member=d["g_member"][k].astype(np.float64),
                 diag=dict(active=bool(d["g_w"][k].max() > 0)))
        prep = dict(init_h=d["init_h"][k].astype(np.float32), init_m=d["init_m"][k].astype(np.float32), g=g,
                    freeze_h=d["freeze_h"][k].astype(bool), freeze_m=d["freeze_m"][k].astype(bool))
        rc = {dec: R["cold"]["runs"].get((k, dec)) for dec in (0, 1)}
        rh = {dec: R["hybrid"]["runs"].get((k, dec)) for dec in (0, 1)}
        fc_h, fc_m, _ = _fields(R["cold"]["_h5"], k)
        fh_h, fh_m, has = _fields(R["hybrid"]["_h5"], k)
        pic_h = fh_h if has[1] else None
        pic_m = fh_m if has[0] else None
        t0 = time.process_time()
        if pic_h is None and pic_m is None:
            f, fm, sinfo = PL.stitch(None, None, prep, hc)
        else:
            f, fm, sinfo = PL.stitch(pic_h if pic_h is not None else prep["init_h"], pic_m, prep, hc)
        st_cpu = time.process_time() - t0
        F.append(f.astype(np.float16)); Fm.append(fm.astype(np.float16))
        cold_f.append(fc_h.astype(np.float16)); cold_fm.append(fc_m.astype(np.float16))
        it_h = sum(int(rh[x]["iters"]) for x in (0, 1) if rh[x] is not None)
        st_h = max((int(rh[x]["status"]) for x in (0, 1) if rh[x] is not None), default=0)
        sec_h = sum(float(rh[x]["seconds"]) for x in (0, 1) if rh[x] is not None)
        it_c = int(rc[0]["iters"]) + int(rc[1]["iters"])
        st_c = max(int(rc[0]["status"]), int(rc[1]["status"]))
        recs.append((int(c["case"]), int(c["relief_id"]), int(c["cond_id"]), int(c["group"]), it_h, st_h, sec_h, it_c, st_c,
                     int(rh[0]["iters"]) if rh[0] is not None else 0, int(rh[1]["iters"]) if rh[1] is not None else 0,
                     int(rh[0]["status"]) if rh[0] is not None else -1, int(rh[1]["status"]) if rh[1] is not None else -1,
                     int(rc[0]["iters"]), int(rc[1]["iters"]), int(rc[0]["status"]), int(rc[1]["status"]),
                     int(c["status_m_s5"]), int(c["status_h_s5"]), int(c["iters_m_s5"]), int(c["iters_h_s5"])))
        lmc = RA.lm_case(cd, hc)
        line = dict(case=int(c["case"]), relief_id=int(c["relief_id"]), cond_id=int(c["cond_id"]), group=int(c["group"]),
                    froude=cd["froude"], u10=cd["u10_m_s"], u_sat=cd["u_sat_m_s"], hs_w_m2=cd["hs_w_m2"], hour=cd["hour_local"],
                    mechanical=bool(cd["mechanical"]), w_star=cd["w_star_m_s"], relief_m=float(hc.max() - hc.min()),
                    omega=float(d["omega_map"][k].mean()), freeze_h_frac=float(d["freeze_h"][k].mean()),
                    freeze_m_frac=float(d["freeze_m"][k].mean()), g_w_mean=float(d["g_w"][k].mean()),
                    weights_mean=dict(zip(PL.PHASES, np.round(d["weights"][k][:, 5:-5, 5:-5].mean((1, 2)) / 255.0, 4).tolist())),
                    s5=dict(status_m=int(c["status_m_s5"]), status_h=int(c["status_h_s5"]), iters_m=int(c["iters_m_s5"]), iters_h=int(c["iters_h_s5"])),
                    stitch=sinfo.get("stitched", False), stitch_cpu_s=st_cpu)
        for v in ("cold", "hybrid", "fallback", "cold_omap"):
            if R[v] is None:
                continue
            line[v] = {("m", "h")[dec]: dict(status=int(r["status"]), iters=int(r["iters"]), seconds=float(r["seconds"]),
                                             wall_own=float(r["wall_own"]), switch=int(r["switch"]), n_frozen=int(r["n_frozen"]),
                                             resid=float(r["resid"]))
                       for dec in (0, 1) for r in [R[v]["runs"].get((k, dec))] if r is not None}
        # метрики слоёв P6 (решатель только сошедшийся в обоих решениях — как AP-17; гибрид — всегда, с флагом статуса)
        lmc_ok = dict(lmc, status=0)
        line["lm_hyb"] = _lm(f, fm, hc, heat, hbl, lmc_ok)
        line["lm_cold"] = _lm(fc_h, fc_m, hc, heat, hbl, lmc_ok)
        line["lm_mech"] = _lm(prep["init_h"], prep["init_m"], hc, heat, hbl, lmc_ok)
        if c["status_m_s5"] == 0 and c["status_h_s5"] == 0:
            p, r, _ = sel[int(c["case"])]
            with h5py.File(p, "r") as h:
                s5h = h["fields/h"][r].astype(np.float32); s5m = h["fields/m"][r].astype(np.float32)
            line["lm_s5"] = _lm(s5h, s5m, hc, heat, hbl, lmc_ok)
        for v in ("fallback", "cold_omap"):
            if R[v] is not None and R[v]["has"][k].any():
                vh, vm, hv = _fields(R[v]["_h5"], k)
                vh = vh if hv[1] else f
                vm = vm if hv[0] else fm
                line[f"lm_{v}"] = _lm(vh, vm, hc, heat, hbl, lmc_ok)
        mk_c = LM.layer_masks(fc_h, hc, heat, lmc_ok, w_mech=fc_m[2])
        mk_h = LM.layer_masks(f, hc, heat, lmc_ok, w_mech=fm[2])
        line["iou_hyb_cold"] = {kk: LM.iou(mk_c[kk], mk_h[kk]) for kk in mk_c}
        I = slice(5, -5)
        du = np.sqrt((f[0] - fc_h[0]) ** 2 + (f[1] - fc_h[1]) ** 2)[:7][:, I, I]
        line["du_low_med_ms"] = float(np.median(du))
        line["du_low_p90_ms"] = float(np.percentile(du, 90))
        fz = d["freeze_h"][k][I, I].astype(bool)
        line["du_low_frozen_med_ms"] = float(np.median(du[:, fz])) if fz.any() else None
        line["du_low_free_med_ms"] = float(np.median(du[:, ~fz])) if (~fz).any() else None
        lines.append(json.dumps(line, ensure_ascii=False, default=float))
    dt = np.dtype([("case", "i8"), ("relief_id", "i8"), ("cond_id", "i4"), ("group", "i1"), ("iters", "i4"), ("status", "i1"),
                   ("seconds_gpu", "f4"), ("iters_cold", "i4"), ("status_cold", "i1"), ("iters_m", "i4"), ("iters_h", "i4"),
                   ("status_m", "i1"), ("status_h", "i1"), ("iters_cold_m", "i4"), ("iters_cold_h", "i4"), ("status_cold_m", "i1"),
                   ("status_cold_h", "i1"), ("status_m_s5", "i1"), ("status_h_s5", "i1"), ("iters_m_s5", "i4"), ("iters_h_s5", "i4")])
    with h5py.File(out / "_prep" / f"prep-{q:05d}.h5", "r") as h:
        cfg = h.attrs["cfg"]
    tmp = part.with_suffix(".tmp")
    with h5py.File(tmp, "w") as h:
        h.create_dataset("cases", data=np.array(recs, dt))
        h.create_dataset("fields/f", data=np.stack(F), chunks=(1, 4, 13, 96, 96), **F2)
        h.create_dataset("fields/m", data=np.stack(Fm), chunks=(1, 3, 13, 96, 96), **F2)
        h.create_dataset("weights", data=d["weights"], chunks=(1, len(PL.PHASES), 96, 96), **F2)
        h.create_dataset("omega_map", data=np.round(np.clip(d["omega_map"], 0, 1) * 255).astype(np.uint8), **F2)
        h.create_dataset("freeze_mask", data=d["freeze_h"].astype(np.uint8), **F2)
        h.create_dataset("freeze_mask_m", data=d["freeze_m"].astype(np.uint8), **F2)
        h.attrs["contract"] = "P9 v1"
        h.attrs["phases"] = json.dumps(list(PL.PHASES))
        h.attrs["cfg"] = cfg
        h.attrs["solver_version"] = solver_version
        h.attrs["git_commit"] = commit
        h.attrs["agl_m"] = RA.M.AGL_M
        h.attrs["note"] = ("status/iters — пара решений m + h (status — худший; 0 ok, 1 max, 2 diverged; −1 — не считалось, механизм); "
                           "seconds_gpu — стена пакета / число случаев (B = 4); fields/m — без нагрева (дополнительно); "
                           "freeze_mask — решение h, freeze_mask_m — решение m")
    os.replace(tmp, part)
    cdir = out / "cold"
    cdir.mkdir(exist_ok=True)
    ctmp = cdir / f"part-{q:05d}.tmp"
    with h5py.File(ctmp, "w") as h:
        h.create_dataset("case", data=d["cases"]["case"])
        h.create_dataset("fields/h", data=np.stack(cold_f), chunks=(1, 4, 13, 96, 96), **F2)
        h.create_dataset("fields/m", data=np.stack(cold_fm), chunks=(1, 3, 13, 96, 96), **F2)
        h.attrs["solver_version"] = solver_version
        h.attrs["note"] = "холодный Пикар нынешней версии, Numerics() (как S5), статусы — в ../part-*.h5 cases"
    os.replace(ctmp, cdir / f"part-{q:05d}.h5")
    jl.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return q, n


def stage_final(out, workers, limit=0):
    ctab = RA.cond_table()
    commit = RA.git_commit()
    parts = sorted(int(Path(p).stem.split("-")[1]) for p in glob.glob(str(out / "_prep" / "prep-*.h5")))
    if limit:
        parts = parts[:limit]
    jobs = [(q, str(out), ctab, commit) for q in parts]
    from multiprocessing import Pool
    t0 = time.time()
    with Pool(workers) as pool:
        for q, n in pool.imap_unordered(_final_work, jobs):
            print(f"final {q} cases {n} t={time.time() - t0:.0f}s", flush=True)
    runs_summary(out)


def runs_summary(out):
    """runs_summary.json: замер по одному (timing: iters, wall_own) и стена вариантов (gpu.jsonl, сырые части) — до clean."""
    res = dict(variants={})
    for v in VARIANTS:
        walls, n_runs, iters, batch, dev = 0.0, 0, 0, None, None
        timing = []
        for p in sorted(glob.glob(str(out / "raw" / f"{v}-*.h5"))):
            with h5py.File(p, "r") as h:
                r = h["runs"][:]
                walls += float(h.attrs["wall_s"]); batch = int(h.attrs["batch"]); dev = str(h.attrs["device"])
                sv = str(h.attrs["solver_version"])
            n_runs += len(r); iters += int(r["iters"].sum())
            if v == "timing":
                timing += [dict(iters=int(x["iters"]), wall_own=float(x["wall_own"]), status=int(x["status"]), switch=int(x["switch"]),
                                n_frozen=int(x["n_frozen"])) for x in r]
        if n_runs:
            res["variants"][v] = dict(wall_s=walls, runs=n_runs, iters=iters, batch=batch, device=dev, solver_version=sv,
                                      ms_per_iter_batch=1000.0 * walls / max(iters, 1))
        if timing:
            res["timing"] = timing
    (out / "runs_summary.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))


def stage_clean(out):
    shutil.rmtree(out / "_prep", ignore_errors=True)
    for p in glob.glob(str(out / "raw" / "*.h5")):
        os.remove(p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=("prep", "gpu", "final", "clean"))
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--variants", default="cold,hybrid,fallback,cold_omap,timing")
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--stub", action="store_true", help="gpu: заглушка решателя (сухой прогон конвейера на CPU)")
    ap.add_argument("--limit", type=int, default=0, help="gpu/final: только первые N частей")
    ap.add_argument("--prep-from", default="", help="prep: взять готовые _prep из другого каталога (ссылкой) — для сухого прогона")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    if a.stage == "prep" and a.prep_from:
        (out / "_prep").mkdir(exist_ok=True)
        for p in sorted(glob.glob(str(Path(a.prep_from) / "_prep" / "prep-*.h5")))[: a.limit or None]:
            dst = out / "_prep" / Path(p).name
            if not dst.exists():
                os.symlink(p, dst)
    elif a.stage == "prep":
        stage_prep(out, a.workers)
    elif a.stage == "gpu":
        stage_gpu(out, [v for v in a.variants.split(",") if v], a.batch, a.stub, a.limit)
    elif a.stage == "final":
        stage_final(out, a.workers, a.limit)
    else:
        stage_clean(out)


if __name__ == "__main__":
    main()
