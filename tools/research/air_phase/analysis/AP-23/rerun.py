"""AP-23, доработка: пересчёт при ω = 0,5 (холодный старт, max_outer 2000, как пересчёт AP-14) случаев SY-12, где
рекомендованный конфиг отправляет в Пикар блуждающее или неопределённое решение, плюс контроль — сошедшиеся при ω = 1
случаи из полосы ω. Путь решателя — `batch_solver.solve_batch` с `cond_row` (как ENVELOPE_REAL в run_phase.py:
рельеф real/hg_v2, строка условий S2 hg_v2_hgw24; решение «m» — heat 0, «h» — поток тепла из погоды).

    PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
    $PY tools/research/air_phase/analysis/AP-23/rerun.py select          # selection.json (CPU, из кэша run.py prep)
    dp job --lock gpu start ap23-rerun 14400 $PY …/rerun.py solve      # GPU, с продолжением после обрыва

Выход: $AIR_SYNTH_DATA/phase/ap23_rerun/part-*.h5 — `cases` (case, decision 0 m / 1 h, status, iters, spread, …),
`fields` (B, 4, 13, 96, 96) f2 (у «m» θ′ = 0), `inputs/hc`; журнал runs.jsonl.
"""
from __future__ import annotations

import json, os, sys, time
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
AP = HERE.parents[1]
sys.path.insert(0, str(AP))
sys.path.insert(0, str(HERE))
import run as RUN  # noqa: E402
import classifier_ref as CR  # noqa: E402

OUTD = RUN.DATA / "phase" / "ap23_rerun"
SEL = HERE / "selection.json"
N_CTRL = 24
MAX_OUTER = 2000
CHUNK = 16


def select():
    sy = json.load(open(RUN.OUT / "sy12_cls.json"))
    S = {k: np.array([r[k] for r in sy]) for k in ("case", "fr", "u10", "usat", "nbv", "u_over_n", "status_m", "status_h",
                                                    "spread_m", "spread_h", "f_frac", "g_frac")}
    summ = json.load(open(HERE / "summary.json"))
    cfg = CR.cfg_values(summ["recommended_config"])
    full, *_ = RUN.full_freeze(S, cfg)
    om = RUN.omega_v(S, cfg)
    lm = RUN.conv_label(S["status_m"], S["spread_m"], S["usat"])
    lh = RUN.conv_label(S["status_h"], S["spread_h"], S["usat"])
    pic_m = ~full
    pic_h = ~full & (S["f_frac"] < 0.5)
    sel = []
    # доработка по ревью: и случаи, которые рекомендованный конфиг отдаёт механизмам (H, сильное D, F) — все не-ok
    for dec, lab, pic in ((0, lm, pic_m), (1, lh, pic_h)):
        for i in np.nonzero((lab != 0) & ~pic)[0]:
            sel.append(dict(case=int(S["case"][i]), decision=dec, group="mech_" + ("hard" if lab[i] == 2 else "uncertain"),
                            omega_band=bool(om[i] < 1)))
    for dec, lab, pic in ((0, lm, pic_m), (1, lh, pic_h)):
        for grp, m in (("hard", (lab == 2) & pic), ("uncertain", (lab == 1) & pic)):
            for i in np.nonzero(m)[0]:
                sel.append(dict(case=int(S["case"][i]), decision=dec, group=grp, omega_band=bool(om[i] < 1)))
    rng = np.random.default_rng(23)
    ok_band = np.nonzero((lm == 0) & (S["status_m"] == 0) & pic_m & (om < 1))[0]
    for i in rng.choice(ok_band, size=min(N_CTRL, len(ok_band)), replace=False):
        sel.append(dict(case=int(S["case"][i]), decision=0, group="ctrl_ok_band", omega_band=True))
    hard_m = [r for r in sel if r["group"] == "hard" and r["decision"] == 0]
    for r in [hard_m[i] for i in rng.choice(len(hard_m), size=min(8, len(hard_m)), replace=False)]:
        sel.append(dict(r, group="repro_omega1"))           # тот же путь при ω = 1, 1000 итераций: воспроизводит ли S5
    order = {"repro_omega1": 0, "hard": 1, "ctrl_ok_band": 2, "uncertain": 3, "mech_hard": 4, "mech_uncertain": 5}
    sel.sort(key=lambda r: (order[r["group"]], r["case"], r["decision"]))
    from collections import Counter
    info = Counter((r["group"], "mh"[r["decision"]]) for r in sel)
    json.dump(dict(rule="рекомендованный конфиг AP-23 отправляет в Пикар; группы: hard — блуждание ≥ 0,1·U_sat при ω = 1, "
                        "uncertain — 0,05 м/с ≤ разброс < 0,1·U_sat, ctrl_ok_band — сошедшиеся при ω = 1 из полосы ω (24 шт., зерно 23)",
                   numerics=dict(omega_u=0.5, omega_k=0.5, max_outer=MAX_OUTER, start="cold"),
                   counts={f"{g}_{d}": n for (g, d), n in sorted(info.items())}, cases=sel),
              open(SEL, "w"), ensure_ascii=False, indent=0)
    print(dict(info), len(sel))


def _done():
    d = set()
    for p in sorted(OUTD.glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            for c, dd, om in zip(h["cases"]["case"][:], h["cases"]["decision"][:], h["cases"]["omega"][:]):
                d.add((int(c), int(dd), round(float(om), 2)))
    return d


def solve():
    import batch_solver as BS
    import reliefs as RL
    OUTD.mkdir(parents=True, exist_ok=True)
    sel = json.load(open(SEL))["cases"]
    cond = RUN._sy_cond_table()
    # case → (relief_id, cond_id, hc S5)
    where = {}
    for p in sorted(RUN.SY.glob("part-*.h5")):
        with h5py.File(p, "r") as h:
            cs = h["cases"][:]
        for j, c in enumerate(cs):
            where[int(c["case"])] = (str(p), j, int(c["relief_id"]), int(c["cond_id"]))
    done = _done()
    omg = lambda r: 1.0 if r["group"] == "repro_omega1" else 0.5
    todo = [r for r in sel if (r["case"], r["decision"], omg(r)) not in done]
    rids = sorted({where[r["case"]][2] for r in todo})
    g100 = {}
    for rid, (_, g, _, _) in zip(rids, RL.load_corpus(RUN.DATA / "real" / "hg_v2", rids)):
        g100[rid] = np.asarray(g, np.float64)
    part = len(list(OUTD.glob("part-*.h5")))
    log = open(OUTD / "runs.jsonl", "a")
    num05 = BS.Numerics(omega_u=0.5, omega_k=0.5, max_outer=MAX_OUTER)
    num1 = BS.Numerics(max_outer=1000)
    dt = np.dtype([("case", "i8"), ("decision", "i1"), ("omega", "f4"), ("relief_id", "i4"), ("cond_id", "i4"), ("status", "i1"),
                   ("iters", "i4"), ("late_spread60_p90", "f4"), ("resid_final", "f4"), ("seconds", "f4"),
                   ("hc_maxdiff_m", "f4")])
    for k0 in range(0, len(todo), CHUNK):
        chunk = todo[k0:k0 + CHUNK]
        specs = []
        for r in chunk:
            path, j, rid, cid = where[r["case"]]
            row = cond[(rid, cid)]
            ctx = dict(lat=float(row["lat_deg"]), lon=float(row["lon_deg"]), month=int(row["month"]), day=int(row["day"]),
                       hour_local=float(row["hour_local"]), utc_offset=float(row["utc_offset_h"]))
            specs.append(BS.CaseSpec(g100=g100[rid], ctx=ctx, u10=float(row["u10_m_s"]), wdir_from_deg=float(row["wind_from_deg"]),
                                     alpha=float(row["alpha"]), max_profile=float(row["max_profile"]), n_bv_s=None,
                                     z_i_agl_m=None, heat_flux_wm2=0.0 if r["decision"] == 0 else None, dx_m=400.0,
                                     cond_row=row))
        t0 = time.perf_counter()
        res = BS.solve_batch(specs, [num1 if omg(r) == 1.0 else num05 for r in chunk])
        wall = time.perf_counter() - t0
        rec = np.zeros(len(chunk), dt)
        F = np.zeros((len(chunk), 4, 13, 96, 96), np.float16)
        HC = np.zeros((len(chunk), 96, 96), np.float32)
        for i, (r, x) in enumerate(zip(chunk, res)):
            path, j, rid, cid = where[r["case"]]
            with h5py.File(path, "r") as h:
                hc5 = h["inputs/hc"][j]
            hc = np.asarray(x.hc, np.float32)
            st = {"ok": 0, "converged": 0, "max": 1, "diverged": 2}.get(x.status, 1) if isinstance(x.status, str) else int(x.status)
            rec[i] = (r["case"], r["decision"], omg(r), rid, cid, st, int(x.iters), float(x.late_spread60_p90), float(x.resid_final),
                      wall / len(chunk), float(np.abs(hc - hc5).max()))
            f = np.asarray(x.fields, np.float32)
            F[i, :f.shape[0]] = f
            HC[i] = hc
        tmp = OUTD / f"part-{part:05d}.h5.tmp"
        with h5py.File(tmp, "w") as h:
            h.create_dataset("cases", data=rec)
            h.create_dataset("fields", data=F, chunks=(1, 4, 13, 96, 96), compression="gzip", compression_opts=4)
            h.create_dataset("inputs/hc", data=HC, chunks=(1, 96, 96), compression="gzip")
            h.attrs.update(dict(kind="ap23_rerun", omega=0.5, max_outer=MAX_OUTER, start="cold", solve=str(RUN.SY),
                                conditions=str(RUN.SYC), relief_corpus="real/hg_v2", solver_version=str(BS.solver_version()),
                                agl_m=RUN.AGL, layout="[case, канал u v w θ′, высота AGL, j, i]; у «m» θ′ = 0"))
        os.replace(tmp, OUTD / f"part-{part:05d}.h5")
        part += 1
        log.write(json.dumps(dict(part=part - 1, n=len(chunk), wall_s=round(wall, 1), status=rec["status"].tolist(),
                                  iters=rec["iters"].tolist(), hc_maxdiff=float(rec["hc_maxdiff_m"].max()))) + "\n")
        log.flush()
        print(f"{k0 + len(chunk)}/{len(todo)} {wall:.0f} s", flush=True)


if __name__ == "__main__":
    {"select": select, "solve": solve}[sys.argv[1]]()
