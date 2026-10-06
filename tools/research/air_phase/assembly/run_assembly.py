"""P8 v1: счёт сборки по фазам по выборке SY-12 и метрики слоёв против Пикара (CPU, пул процессов).

    run_assembly.py [--out $AIR_SYNTH_DATA/phase/assembly_v1] [--workers 16] [--train-stride 20] [--limit N] [--cfg JSON]

Выборка (детерминированно, правило здесь): все случаи группы holdout (480) + каждый `train_stride`-й обучающий
случай среди тех, где Пикар сошёлся в обоих решениях (status_m = status_h = 0), по порядку `case` S5.
Метрики слоёв (P6 `layer_metrics`, w_mech — w решения «m») и ошибки — только там, где Пикар сошёлся в обоих.
Выход: `part-*.h5` (P8: cases, fields/f (M,4,13,96,96) f2, fields/m (M,3,13,96,96) f2 — без нагрева, дополнительно,
weights (M,K,96,96) u1 ×255, атрибуты contract, phases, cfg, git_commit) и `metrics.jsonl` (по строке на случай:
метрики сборки и Пикара, ошибки по фазам и в швах). Продолжение — пропуск готовых частей.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
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

from assembly import assemble as AS  # noqa: E402
from assembly import mechanisms as M  # noqa: E402
import layer_metrics as LM  # noqa: E402

DATA = Path(os.environ.get("AIR_SYNTH_DATA", str(Path.home() / "air_synth_data")))
SOLVE = DATA / "solve/hg_v2__hgw24__s0-939a467"
COND = DATA / "conditions/hg_v2_hgw24/conditions.h5"
EDGE = 5
LOW = list(range(7))          # уровни 25…300 м — где работают слои
SEAM = 0.8
CHUNK = 25


def git_commit():
    try:
        return subprocess.check_output(["git", "-C", str(HERE), "rev-parse", "--short=8", "HEAD"], text=True).strip()
    except Exception:
        return "unknown"


def load_index():
    rows = []
    for p in sorted(glob.glob(str(SOLVE / "part-*.h5"))):
        with h5py.File(p, "r") as h:
            c = h["cases"][:]
        for r in range(len(c)):
            rows.append((p, r, {n: c[n][r].item() for n in c.dtype.names}))
    return rows


def select(rows, train_stride):
    hold = [x for x in rows if x[2]["group"] == 1]
    tr = [x for x in rows if x[2]["group"] == 0 and x[2]["status_m"] == 0 and x[2]["status_h"] == 0]
    tr = sorted(tr, key=lambda x: x[2]["case"])[::train_stride]
    return sorted(hold + tr, key=lambda x: x[2]["case"])


def cond_table():
    with h5py.File(COND, "r") as h:
        t = h["conditions/table"][:]
    return {(int(r["relief_id"]), int(r["cond_id"])): {n: r[n].item() for n in t.dtype.names} for r in t}


def lm_case(cd, hc, status=0):
    """Строка case для layer_metrics (P6) у реального рельефа: h_m — перепад, slope — p95 |∇h| (400 м)."""
    gy, gx = np.gradient(hc, M.DX)
    return dict(wdir_from_deg=cd["wind_from_deg"], z_i_agl_m=cd["z_i_m"] - float(hc.min()), n_bv=cd["n_bv_s"],
                u10=cd["u10_m_s"], u_sat=cd["u_sat_m_s"], status=status, h_m=float(hc.max() - hc.min()),
                slope=float(np.percentile(np.hypot(gx, gy), 95)), shape="CORPUS")


def errors(P, A, W):
    """Ошибки сборки против Пикара в слое 25–300 м (без края): |Δu_h| и |Δw| по клеткам; по фазе с наибольшим весом
    и в швах (max w_φ < 0,8) против вне; плюс векторная ошибка на 60 м (как S7 SY-11)."""
    I = slice(EDGE, -EDGE)
    du = np.sqrt((P[0] - A[0]) ** 2 + (P[1] - A[1]) ** 2)[LOW][:, I, I]     # (7, n, n)
    dw = np.abs(P[2] - A[2])[LOW][:, I, I]
    wmax = W.max(0)[I, I]
    dom = W.argmax(0)[I, I]
    seam = wmax < SEAM
    cell_u = du.mean(0)
    cell_w = dw.mean(0)
    out = dict(seam_frac=float(seam.mean()))
    for nm, m in (("seam", seam), ("core", ~seam)):
        out[f"du_{nm}_med"] = float(np.median(cell_u[m])) if m.any() else None
        out[f"dw_{nm}_med"] = float(np.median(cell_w[m])) if m.any() else None
        out[f"n_{nm}"] = int(m.sum())
    for k, ph in enumerate(AS.PHASES):
        m = dom == k
        out[f"area_{ph}"] = float(m.mean())
        out[f"du_{ph}_med"] = float(np.median(cell_u[m])) if m.any() else None
    # 60 м: между 50 и 75 м
    t = (60.0 - 50.0) / 25.0
    p60 = (1 - t) * P[:2, 1] + t * P[:2, 2]
    a60 = (1 - t) * A[:2, 1] + t * A[:2, 2]
    e60 = np.sqrt(((p60 - a60) ** 2).sum(0))[I, I]
    out["e60_med"] = float(np.median(e60))
    out["e60_p90"] = float(np.percentile(e60, 90))
    out["e60_cells"] = np.round(np.percentile(e60, [10, 25, 50, 75, 90]), 3).tolist()
    sp = np.sqrt((P[0] ** 2 + P[1] ** 2))[LOW][:, I, I].mean()
    out["speed_pic_mean"] = float(sp)
    out["speed_asm_mean"] = float(np.sqrt(A[0] ** 2 + A[1] ** 2)[LOW][:, I, I].mean())
    out["w_corr_100"] = float(np.corrcoef(P[2, 3, I, I].ravel(), A[2, 3, I, I].ravel())[0, 1])
    return out


def _clean(d):
    return {k: (None if (isinstance(v, float) and not np.isfinite(v)) else v) for k, v in d.items()}


def work(args):
    q, items, out_dir, ctab, commit, cfg = args
    part = Path(out_dir) / f"part-{q:05d}.h5"
    jl = Path(out_dir) / f"metrics-{q:05d}.jsonl"
    if part.exists() and jl.exists():
        return q, 0
    recs, F, Fm, Wt, lines = [], [], [], [], []
    cfg_json = None
    for p, r, cs in items:
        with h5py.File(p, "r") as h:
            hc = h["inputs/hc"][r].astype(np.float64)
            heat = h["inputs/heat_flux"][r].astype(np.float64)
            hbl = h["inputs/hbl"][r].astype(np.float64)
            ok = cs["status_m"] == 0 and cs["status_h"] == 0
            if ok:
                fm = h["fields/m"][r].astype(np.float32)
                fh = h["fields/h"][r].astype(np.float32)
        cd = ctab[(cs["relief_id"], cs["cond_id"])]
        t0 = time.process_time()
        out = AS.assemble(hc, cd, heat=heat, cfg=cfg)
        cpu = time.process_time() - t0
        cfg_json = out["cfg"]
        F.append(out["fields"].astype(np.float16))
        Fm.append(out["fields_m"].astype(np.float16))
        Wt.append(np.round(out["weights"] * 255).astype(np.uint8))
        recs.append((cs["case"], cs["relief_id"], cs["cond_id"], cs["group"], cs["status_m"], cs["status_h"], out["seconds"], cpu))
        line = dict(case=cs["case"], relief_id=cs["relief_id"], cond_id=cs["cond_id"], group=cs["group"],
                    status_m=cs["status_m"], status_h=cs["status_h"], seconds=out["seconds"], cpu_s=cpu,
                    steps=out["steps"], div=out["div"], meta=out["meta"],
                    froude=cd["froude"], u10=cd["u10_m_s"], u_sat=cd["u_sat_m_s"], w_star=cd["w_star_m_s"],
                    hs_w_m2=cd["hs_w_m2"], mechanical=bool(cd["mechanical"]), z_i_agl=cd["z_i_m"] - float(hc.min()),
                    relief_m=float(hc.max() - hc.min()),
                    weights_mean=dict(zip(AS.PHASES, np.round(out["weights"][:, EDGE:-EDGE, EDGE:-EDGE].mean((1, 2)), 4).tolist())))
        if ok:
            c = lm_case(cd, hc)
            mp = LM.layer_metrics(fh, hc, heat, hbl, c, w_mech=fm[2])
            ma = LM.layer_metrics(out["fields"], hc, heat, hbl, c, w_mech=out["fields_m"][2])
            line["lm_pic"] = _clean({k: float(v) for k, v in mp.items()})
            line["lm_asm"] = _clean({k: float(v) for k, v in ma.items()})
            line["err_h"] = errors(fh, out["fields"], out["weights"])
            line["err_m"] = errors(fm, out["fields_m"], out["weights_m"])
            # маски слоёв: совпадение положения (IoU)
            mk_p = LM.layer_masks(fh, hc, heat, c, w_mech=fm[2])
            mk_a = LM.layer_masks(out["fields"], hc, heat, c, w_mech=out["fields_m"][2])
            line["iou"] = {k: LM.iou(mk_p[k], mk_a[k]) for k in mk_p}
        lines.append(json.dumps(line, ensure_ascii=False))
    tmp = part.with_suffix(".tmp")
    dt = np.dtype([("case", "i8"), ("relief_id", "i8"), ("cond_id", "i4"), ("group", "i1"), ("status_m", "i1"),
                   ("status_h", "i1"), ("seconds", "f4"), ("cpu_s", "f4")])
    with h5py.File(tmp, "w") as h:
        h.create_dataset("cases", data=np.array(recs, dt))
        kw = dict(compression="gzip", compression_opts=4, shuffle=True)
        h.create_dataset("fields/f", data=np.stack(F), chunks=(1, 4, 13, 96, 96), **kw)
        h.create_dataset("fields/m", data=np.stack(Fm), chunks=(1, 3, 13, 96, 96), **kw)
        h.create_dataset("weights", data=np.stack(Wt), chunks=(1, len(AS.PHASES), 96, 96), **kw)
        h.attrs["contract"] = "P8 v1"
        h.attrs["phases"] = json.dumps(list(AS.PHASES))
        h.attrs["cfg"] = cfg_json
        h.attrs["git_commit"] = commit
        h.attrs["agl_m"] = M.AGL_M
        h.attrs["solve"] = str(SOLVE)
        h.attrs["note"] = "fields/f — с нагревом [u,v,w,θ′]; fields/m — без нагрева [u,v,w] (дополнительно к P8); weights ×255"
    os.replace(tmp, part)
    jl.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return q, len(items)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(DATA / "phase/assembly_v1"))
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--train-stride", type=int, default=20)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--cfg", default="{}", help="JSON — поправки к assemble.DEFAULT_CFG (варианты)")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    sel = select(load_index(), a.train_stride)
    if a.limit:
        sel = sel[:a.limit]
    ctab = cond_table()
    commit = git_commit()
    cfg = json.loads(a.cfg)
    jobs = [(q, sel[i:i + CHUNK], str(out), ctab, commit, cfg) for q, i in enumerate(range(0, len(sel), CHUNK))]
    (out / "manifest.json").write_text(json.dumps(dict(contract="P8 v1", n_cases=len(sel), train_stride=a.train_stride,
                                                       solve=str(SOLVE), conditions=str(COND), git_commit=commit,
                                                       parts=len(jobs), cfg=cfg, command=" ".join(sys.argv)), ensure_ascii=False, indent=1))
    t0 = time.time()
    from multiprocessing import Pool
    with Pool(a.workers) as pool:
        for q, n in pool.imap_unordered(work, jobs):
            print(f"part {q} cases {n} t={time.time() - t0:.0f}s", flush=True)
    print("done", len(sel), f"{time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    main()
