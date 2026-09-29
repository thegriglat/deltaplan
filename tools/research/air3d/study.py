#!/usr/bin/env python3
"""3D-Пикар на рельефе Онгудая: время, сходимость, тёплый старт, интерполяция по часам, размер.

  ../heat_ca/.venv/bin/python study.py conv    [--dx 400,200]  → out/conv.json          (ошибка против итераций)
  ../heat_ca/.venv/bin/python study.py matrix  [--dx 400,200]  → out/matrix.json        (часы × ветер × нагрев)
  ../heat_ca/.venv/bin/python study.py warm    [--dx 200]      → out/warm.json          (тёплый старт)
  ../heat_ca/.venv/bin/python study.py cells                   → out/cells.json         (400/200/100/50 м)
  ../heat_ca/.venv/bin/python study.py size                    → out/size.json          (размер полей)
Замеры времени — под общим замком GPU: flock /tmp/heat_ca_gpu.lock ...
Поля — fields/*.npz (fp16, вне git), маленькие — out/fields/*.npz.
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import sys
import time

import numpy as np

import common as C
import solver as S

OUT = C.OUT


def rel(a, b):
    m = ~(np.isnan(a) | np.isnan(b))
    return float(np.sqrt(np.sum((a - b)[m] ** 2) / max(np.sum(b[m] ** 2), 1e-30)))


def maxabs(a, b):
    m = ~(np.isnan(a) | np.isnan(b))
    return float(np.max(np.abs(a - b)[m]))


def field_err(F, R):
    names = ("u", "v", "w", "th")
    return {n: dict(rel=rel(f, r), max=maxabs(f, r)) for n, f, r in zip(names, F, R)}


def gpu_info():
    import cupy as cp
    p = cp.cuda.runtime.getDeviceProperties(0)
    return dict(name=p["name"].decode(), mem_gb=p["totalGlobalMem"] / 2 ** 30)


# ---------------------------------------------------------------------------- conv
def cmd_conv(args):
    """Досчитать далеко (эталон X*), по ходу — снимки; ошибка против итераций и невязки."""
    res = dict(gpu=gpu_info(), cases=[])
    cases = [("calm_h13", S.Cond(hour=13, wind=0)),
             ("U3w_h13", S.Cond(hour=13, wind=3, wdir=270)),
             ("U6w_h13", S.Cond(hour=13, wind=6, wdir=270)),
             ("U3w_noheat", S.Cond(hour=None, wind=3, wdir=270))]
    for dx in args.dx:
        for name, cond in cases:
            g = C.grid_domain(dx)
            A = C.make(g, cond)
            snaps = []
            every = 10 if dx >= 400 else 20

            def cb(A_, r):
                if A_.outer % every == 1 or A_.outer <= 11:
                    snaps.append((A_.outer, r["t"], A_.centers()))
            A.init_background()
            A.solve(tol_mom=0, max_outer=args.max_outer, check_every=10, cb=cb)
            X = A.centers()
            hist = A.hist
            errs = [dict(it=it, t=t, **{k: v for k, v in field_err(F, X).items()}) for it, t, F in snaps]
            # первая итерация, после которой ошибка w (отн. L2) < 1 % и < 0,1 %
            def first(th):
                for e in errs:
                    if e["w"]["rel"] < th and e["u"]["rel"] < th:
                        return e["it"]
                return None
            # итерация, где сработал бы критерий TOL
            tol_it = None
            for r in hist:
                if r["mom_rms"] < C.TOL["tol_mom"] and r["th_rms"] < C.TOL["tol_th"] and r["div_rms"] < C.TOL["tol_div"]:
                    tol_it = r["it"]
                    break
            e_tol = next((e for e in errs if tol_it is not None and e["it"] >= tol_it), None)
            case = dict(dx=dx, name=name, cond=cond.__dict__, prm=dict(C.PRM), iters=A.outer, wall=A.wall - A.t_check,
                        it_per_s=A.outer / max(A.wall - A.t_check, 1e-9), hist=hist, errs=errs,
                        it_1pc=first(0.01), it_01pc=first(0.001), tol_it=tol_it, err_at_tol=e_tol,
                        budget=A.heat_budget(), keys=C.key_numbers(A, X), mem_mb=A.mem_mb())
            print(f"{dx:.0f} м {name}: {A.outer} итер. {case['wall']:.2f} с; 1 % на {case['it_1pc']}, 0,1 % на "
                  f"{case['it_01pc']}, критерий на {tol_it} (ошибка w {e_tol['w']['rel'] if e_tol else None})",
                  flush=True)
            res["cases"].append(case)
            del A, snaps
            import cupy as cp
            cp.get_default_memory_pool().free_all_blocks()
    C.jdump(res, OUT / f"conv{args.tag}.json")


# ---------------------------------------------------------------------------- matrix
HOURS = [9, 11, 12, 13, 15, 17]
DIRS8 = [0, 45, 90, 135, 180, 225, 270, 315]
DIRS4 = [0, 90, 180, 270]


def winds():
    return [(0.0, 0.0)] + [(3.0, d) for d in DIRS8] + [(6.0, d) for d in DIRS4]


def light(r):
    """Итог прогона без длинной истории."""
    out = {k: v for k, v in r.items() if k != "hist"}
    out["hist"] = [{k: h[k] for k in ("it", "mom_rms", "mom_max", "th_rms", "div_rms", "t")} for h in r["hist"]]
    return out


def cmd_matrix(args):
    res = dict(gpu=gpu_info(), tol=C.TOL, prm=C.PRM, runs=[])
    for dx in args.dx:
        g = C.grid_domain(dx)
        fdir = C.FIELDS / f"d{int(dx)}"
        fdir.mkdir(exist_ok=True)
        for (U, d) in winds():
            for hour in HOURS + [None]:
                cond = S.Cond(hour=hour, wind=U, wdir=d if U > 0 else 270.0)
                t0 = time.perf_counter()
                A = C.make(g, cond)
                t_setup = time.perf_counter() - t0
                r = C.run(A)
                X = A.centers()
                rec = dict(dx=dx, key=cond.key(), hour=hour, wind=U, wdir=d, t_setup=t_setup,
                           budget=A.heat_budget(), keys=C.key_numbers(A, X), sun=A.sun,
                           cells=int(np.prod(A.shape)), fluid=int(A.n_fluid), **light(r))
                C.save_fields(A, fdir / f"{cond.key()}.npz")
                print(f"{dx:.0f} м {cond.key():18s} {r['status']:8s} {r['iters']:4d} итер. {r['t_solve']:.2f} с "
                      f"(+проверки {r['t_check']:.2f}, подготовка {t_setup:.1f}+{r['t_init']:.2f}) "
                      f"w200 p99 {rec['keys']['w200_p99']:.2f}  баланс {rec['budget']['rel'] or 0:.1e}", flush=True)
                res["runs"].append(rec)
                del A
                import cupy as cp
                cp.get_default_memory_pool().free_all_blocks()
        C.jdump(res, OUT / f"matrix{args.tag}.json")


# ---------------------------------------------------------------------------- warm
def _c(hour, U, d):
    return S.Cond(hour=hour, wind=U, wdir=d if U > 0 else 270.0)


WARM_PAIRS = [
    # (группа, описание, цель, опора)
    ("час", "12 ← 11 (1 ч)", _c(12, 3, 180), _c(11, 3, 180)),
    ("час", "13 ← 11 (2 ч)", _c(13, 3, 180), _c(11, 3, 180)),
    ("час", "15 ← 13 (2 ч)", _c(15, 3, 180), _c(13, 3, 180)),
    ("час", "12 ← 9 (3 ч)", _c(12, 3, 180), _c(9, 3, 180)),
    ("час", "17 ← 13 (4 ч)", _c(17, 3, 180), _c(13, 3, 180)),
    ("час", "штиль 13 ← 11 (2 ч)", _c(13, 0, 0), _c(11, 0, 0)),
    ("час", "штиль 15 ← 12 (3 ч)", _c(15, 0, 0), _c(12, 0, 0)),
    ("направление", "180° ← 135° (45°)", _c(13, 3, 180), _c(13, 3, 135)),
    ("направление", "180° ← 90° (90°)", _c(13, 3, 180), _c(13, 3, 90)),
    ("направление", "180° ← 0° (180°)", _c(13, 3, 180), _c(13, 3, 0)),
    ("направление", "U6 180° ← 90° (90°)", _c(13, 6, 180), _c(13, 6, 90)),
    ("сила", "6 ← 3 м/с", _c(13, 6, 180), _c(13, 3, 180)),
    ("сила", "3 ← 6 м/с", _c(13, 3, 180), _c(13, 6, 180)),
    ("сила", "3 ← 0 (штиль)", _c(13, 3, 180), _c(13, 0, 0)),
    ("нагрев", "U3 полдень ← без нагрева", _c(13, 3, 180), _c(None, 3, 180)),
    ("нагрев", "U3 без нагрева ← полдень", _c(None, 3, 180), _c(13, 3, 180)),
    ("нагрев", "штиль полдень ← без нагрева", _c(13, 0, 0), _c(None, 0, 0)),
    ("нагрев", "U6 полдень ← без нагрева", _c(13, 6, 180), _c(None, 6, 180)),
    ("опора", "U4 160° 14 ч ← U3 180° 13 ч", S.Cond(hour=14, wind=4, wdir=160), _c(13, 3, 180)),
    ("опора", "U4 160° 14 ч ← U3 135° без нагрева", S.Cond(hour=14, wind=4, wdir=160), _c(None, 3, 135)),
    ("опора", "U5 200° 10 ч ← U6 180° 13 ч", S.Cond(hour=10, wind=5, wdir=200), _c(13, 6, 180)),
    ("опора", "U5 200° 10 ч ← U6 180° без нагрева", S.Cond(hour=10, wind=5, wdir=200), _c(None, 6, 180)),
    ("опора", "U2 250° 16 ч ← штиль 13 ч", S.Cond(hour=16, wind=2, wdir=250), _c(13, 0, 0)),
    ("опора", "U2 250° 16 ч ← U3 225° 15 ч", S.Cond(hour=16, wind=2, wdir=250), _c(15, 3, 225)),
]


def fp16_state(st):
    import cupy as cp
    return {k: v.astype(cp.float16).astype(cp.float32) for k, v in st.items()}


def cmd_warm(args):
    import cupy as cp
    res = dict(gpu=gpu_info(), tol=C.TOL, prm=C.PRM, pairs=[])
    for dx in args.dx:
        g = C.grid_domain(dx)
        cold, states = {}, {}

        def solve_cold(cond):
            k = cond.key()
            if k not in cold:
                A = C.make(g, cond)
                r = C.run(A)
                cold[k] = dict(iters=r["iters"], t_solve=r["t_solve"], status=r["status"], X=A.centers())
                states[k] = fp16_state(C.state(A))
                del A
                cp.get_default_memory_pool().free_all_blocks()
            return cold[k]
        for grp, desc, tgt, src in WARM_PAIRS:
            c = solve_cold(tgt)
            solve_cold(src)
            row = dict(dx=dx, group=grp, desc=desc, target=tgt.key(), source=src.key(), cold_iters=c["iters"],
                       cold_t=c["t_solve"])
            for with_p in (True, False):
                A = C.make(g, tgt)
                r = C.run(A, warm=states[src.key()], with_p=with_p)
                X = A.centers()
                e = field_err(X, c["X"])
                tag = "p" if with_p else "nop"
                row[f"warm_{tag}_iters"] = r["iters"]
                row[f"warm_{tag}_t"] = r["t_solve"] + r["t_init"]
                row[f"warm_{tag}_status"] = r["status"]
                row[f"warm_{tag}_err_w"] = e["w"]["rel"]
                del A
                cp.get_default_memory_pool().free_all_blocks()
            # насколько опора сама далека от цели (ошибка «взять опору как есть»)
            e0 = field_err(cold[src.key()]["X"], c["X"])
            row["src_as_is_err"] = {k: v["rel"] for k, v in e0.items()}
            print(f"{dx:.0f} м {grp:12s} {desc:36s} холодный {c['iters']:4d}  тёплый {row['warm_p_iters']:4d} "
                  f"(без p {row['warm_nop_iters']:4d})  опора как есть: w {e0['w']['rel']:.2f}", flush=True)
            res["pairs"].append(row)
        C.jdump(res, OUT / f"warm{args.tag}.json")


# ---------------------------------------------------------------------------- cells
CELL_CONDS = [_c(13, 0, 0), _c(13, 3, 180), _c(13, 3, 135), _c(13, 3, 270), _c(13, 6, 180), _c(None, 3, 180),
              _c(None, 6, 180)]


def cmd_cells(args):
    """Сходимость по клетке: 400 и 200 м по области, окна 100 м (от 200 и от 400) и 50 м (от 100)."""
    import cupy as cp
    res = dict(gpu=gpu_info(), tol=C.TOL, prm=C.PRM, runs=[])
    sdir = OUT / "fields"
    sdir.mkdir(exist_ok=True)
    for cond in CELL_CONDS:
        chain = {}
        for name, mk in (("D400", lambda: C.make(C.grid_domain(400.0), cond)),
                         ("D200", lambda: C.make(C.grid_domain(200.0), cond)),
                         ("W100", lambda: C.make(C.grid_window(100.0), cond, parent=chain["D200"])),
                         ("W100p400", lambda: C.make(C.grid_window(100.0), cond, parent=chain["D400"])),
                         ("W50", lambda: C.make(C.grid_window(50.0), cond, parent=chain["W100"]))):
            t0 = time.perf_counter()
            A = mk()
            t_setup = time.perf_counter() - t0
            r = C.run(A)
            X = A.centers()
            k = C.key_numbers(A, X)
            g = A.g
            rec = dict(level=name, key=cond.key(), cond=cond.__dict__, dx=g.dx, dz=g.dz, nx=g.nx, ny=g.ny, nz=g.nz,
                       cells=int(np.prod(A.shape)), fluid=int(A.n_fluid), t_setup=t_setup, keys=k,
                       budget=A.heat_budget(), **light(r))
            print(f"{cond.key():16s} {name:9s} {g.nx}×{g.ny}×{g.nz} {r['status']:8s} {r['iters']:4d} итер. "
                  f"{r['t_solve']:.2f} с  подъём у старта {k['start_w200_max']:.2f}  ветер у старта "
                  f"{k['start_speed50']:.2f}  в седловине {k['saddle_speed50']:.2f}", flush=True)
            res["runs"].append(rec)
            if name == "W100":
                C.save_fields(A, sdir / f"{name}_{cond.key()}.npz")          # в git
            elif name in ("W50", "D200"):
                (C.FIELDS / "cells").mkdir(exist_ok=True)
                C.save_fields(A, C.FIELDS / "cells" / f"{name}_{cond.key()}.npz")   # локально
            if name.startswith("W") or name == "D200" and False:
                pass
            chain[name] = A
        del chain
        cp.get_default_memory_pool().free_all_blocks()
        C.jdump(res, OUT / f"cells{args.tag}.json")


# ---------------------------------------------------------------------------- size
def encodings(F, fluid):
    """Размер одного поля (u, v, w, θ′ в fp16) разными способами, байт."""
    import zlib
    import zstandard as zstd
    arrs = [np.nan_to_num(a).astype(np.float16) for a in F]
    raw = sum(a.nbytes for a in arrs)
    packed = [a[fluid] for a in arrs]                       # только воздух (маска — из рельефа)
    pk = sum(a.nbytes for a in packed)
    zc = zstd.ZstdCompressor(level=19)
    z_raw = sum(len(zc.compress(a.tobytes())) for a in arrs)
    z_pack = sum(len(zc.compress(a.tobytes())) for a in packed)

    def shuffle(a):
        b = a.view(np.uint8).reshape(-1, 2)
        return np.ascontiguousarray(b.T).tobytes()
    z_shuf = sum(len(zc.compress(shuffle(a))) for a in packed)
    zl = sum(len(zlib.compress(a.tobytes(), 9)) for a in arrs)
    # квантование: скорость 0,02 м/с, θ′ 0,02 К → int16, разность по высоте, zstd
    q = []
    for a in F:
        qi = np.round(np.nan_to_num(a) / 0.02).astype(np.int16)
        d = np.diff(qi, axis=0, prepend=np.zeros((1,) + qi.shape[1:], np.int16))
        q.append(len(zc.compress(shuffle(d[fluid]))))
    return dict(raw_fp16=raw, fluid_fp16=pk, zlib_fp16=zl, zstd_fp16=z_raw, zstd_fluid=z_pack,
                zstd_fluid_shuffle=z_shuf, zstd_q002_dz=sum(q))


def load_npz(path):
    d = np.load(path)
    F = [d[k].astype(np.float32) for k in ("u", "v", "w", "th")]
    return F, d


def cmd_size(args):
    import glob
    res = dict(fields=[])
    samples = []
    for dx in (400, 200):
        for key in ("h13_U0_d0", "h13_U3_d180", "h13_U6_d90", "noheat_U3_d180", "h9_U3_d270"):
            samples.append((f"D{dx}", C.FIELDS / f"d{dx}" / f"{key}.npz"))
    for p in sorted(glob.glob(str(OUT / "fields" / "W*_h13_*.npz")) + glob.glob(str(C.FIELDS / "cells" / "W50_h13_*.npz"))):
        samples.append((p.split("/")[-1].split("_")[0], p))
    for level, path in samples:
        try:
            F, d = load_npz(path)
        except FileNotFoundError:
            continue
        fluid = ~((F[0] == 0) & (F[1] == 0) & (F[2] == 0) & (F[3] == 0))
        # маска воздуха восстанавливается из рельефа; для оценки — «не все нули»
        enc = encodings(F, fluid)
        rec = dict(level=level, file=str(path).split("/")[-1], shape=list(F[0].shape), cells=int(F[0].size),
                   fluid=int(fluid.sum()), **enc)
        if "p" in d:
            import zstandard as zstd
            rec["p_zstd_fluid_shuffle"] = len(zstd.ZstdCompressor(level=19).compress(
                np.ascontiguousarray(d["p"][fluid].view(np.uint8).reshape(-1, 2).T).tobytes()))
        print(level, rec["file"], {k: round(v / 2 ** 20, 2) for k, v in enc.items()}, flush=True)
        res["fields"].append(rec)
    C.jdump(res, OUT / "size.json")


# ---------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--dx", default="400")
    ap.add_argument("--max-outer", type=int, default=600)
    ap.add_argument("--tag", default="")
    ap.add_argument("--prm", default="", help="переопределить параметры решателя: dict(...)")
    args = ap.parse_args()
    if args.prm:
        C.PRM.update(eval(args.prm))
    args.dx = [float(x) for x in args.dx.split(",")]
    globals()["cmd_" + args.cmd](args)


if __name__ == "__main__":
    main()
