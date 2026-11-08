"""SWG-1: таблица «до» и диагностика слоя у земли.

  py -m ground.run_before repro            # воспроизведение SWD5 на старых точках (out/swg-1/repro.json)
  py -m ground.run_before base             # плотные точки: s по стадиям (bg, потенциал, +JH) → out/swg-1/raw/base_<case>.json
  py -m ground.run_before scan             # сканы σ, z0, фон → out/swg-1/raw/scan_<имя>_<case>.json
  py -m ground.run_before head             # зоны отрыва Хеда → out/swg-1/raw/head_<case>.json
  py -m ground.run_before assemble         # ground.json (SWG2) + tables.md
Каждая стадия пишет кеш в out/swg-1/raw/ и пропускает готовое (--force — пересчитать).
"""
from __future__ import annotations

import json
import sys
import time

import numpy as np

from . import common as K
from . import evaluate as E
from . import model as M

RAW = K.OUT_TASK / "raw"
SCANS = {                                # имя → (kwargs для stages, param, value); порядок — порядок счёта
    "z0_lnmean": (dict(z0_mode="lnmean"), "z0_rule_lnmean", 1.0),
    "bg_power": (dict(bg_kind="power"), "bg_power_alpha", 0.235),
    "sigma0": (dict(smooth_m=0.0), "smooth_m", 0.0),
    "sigma160": (dict(smooth_m=160.0), "smooth_m", 160.0),
    "sigma80": (dict(smooth_m=80.0), "smooth_m", 80.0),
    "z0_local_jh": (dict(z0_mode="local_jh"), "z0_rule_local_jh", 1.0),
    "bgsm100": (dict(bg_smooth=100.0), "bg_smooth_m", 100.0),
    "bgsm500": (dict(bg_smooth=500.0), "bg_smooth_m", 500.0),
}


def jdump(path, d):
    K.dump_json(path, d)


def scan_subset(pl):
    """lee/valley на 10 и 50 м через одну (равномерно по порядку строк SWG1 внутри (тип, высота)) + все мачты.
    Базовые метрики для сравнения считаются по тому же подмножеству (assemble)."""
    out, cnt = [], {}
    for p in pl:
        if p["kind"] == "mast":
            out.append(p)
        elif p["type"] in ("lee", "valley") and p["z_agl"] in (10.0, 50.0):
            k = (p["type"], p["z_agl"])
            cnt[k] = cnt.get(k, 0) + 1
            if cnt[k] % 2 == 1:
                out.append(p)
    return out


def pack(pl, res):
    out = {k: [None if not np.isfinite(v) else float(v) for v in res[k]] for k in res if not k.startswith("_")}
    out["ids"] = [p["id"] for p in pl]
    out["meta"] = {k: v for k, v in res["_meta"].items()}
    return out


def cmd_base(force=False):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in K.CASES:
        f = RAW / f"base_{case}.json"
        if f.exists() and not force:
            continue
        pl = E.case_points(case, refs, pts)
        t = time.time()
        res = E.stages(case, pl, refs, nmax=40)
        print(case, len(pl), "точек", res["_meta"]["groups"], "групп; N", res["_meta"]["N"], f"{time.time() - t:.0f} с", flush=True)
        jdump(f, pack(pl, res))


def cmd_scan(names, force=False):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for name in names:
        kw, _, _ = SCANS[name]
        for case in K.CASES:
            f = RAW / f"scan_{name}_{case}.json"
            if f.exists() and not force:
                continue
            pl = scan_subset(E.case_points(case, refs, pts))
            t = time.time()
            res = E.stages(case, pl, refs, nmax=40, **kw)
            print(name, case, len(pl), "точек", res["_meta"]["groups"], "групп; N", res["_meta"]["N"], f"{time.time() - t:.0f} с", flush=True)
            jdump(f, pack(pl, res))


def cmd_repro(force=False):
    """SWD5 на старых точках (мачты, нормировочная, P_*_0): GRun с фокусом SWD5 (focus_r_mul = 10) против
    out/compare/points.json (variant potential_jh, potential)."""
    import core as C
    f = K.OUT_TASK / "repro.json"
    if f.exists() and not force:
        return
    refs = E.load_refs()
    old = json.load(open(C.OUT / "points.json"))
    out = dict(cases={}, note="s_pan SWD5 из out/compare/points.json против GRun (focus_r_mul 10, ds_min 25, σ 40, z0 медиана)")
    for case in K.CASES:
        keys = C.eval_set(case, refs)
        xy = sorted({(k[0], k[1]) for k in keys})
        run = M.GRun(case, xy, focus_r_mul=10.0)
        a = np.array(keys, float)
        Xa, Ya, Za = run.abs_points(a[:, 0], a[:, 1], a[:, 2])
        p = M.jh_parts(run, Xa, Ya, Za)
        nm = refs["norm"][case]
        kn = C.pkey(nm["x"], nm["y"], nm["z_agl"])
        i_n = keys.index(kn)
        s = {"potential_jh": p["speed"] / p["speed"][i_n], "potential": p["pot_speed"] / p["pot_speed"][i_n]}
        idx = {k: i for i, k in enumerate(keys)}
        diffs = {"potential_jh": [], "potential": []}
        mean = {}
        for r in old["rows"]:
            if r["case"] != case or r["variant"] not in s:
                continue
            i = idx[C.pkey(r["x"], r["y"], r["z_agl"])]
            diffs[r["variant"]].append(abs(s[r["variant"]][i] - r["s_pan"]))
            if r["variant"] == "potential_jh" and r["ref_kind"] == "picard_nom" and r["z_agl"] in (10.0, 50.0):
                mean.setdefault(f"{r['point']}_{r['z_agl']:g}", []).append(s[r["variant"]][i] / r["s_ref"] - 1.0)
        out["cases"][case] = dict(N=run.N, max_abs_ds={k: float(max(v)) for k, v in diffs.items()},
                                  mean_rel={k: float(np.mean(v)) for k, v in mean.items()},
                                  n={k: len(v) for k, v in mean.items()})
        print(case, out["cases"][case], flush=True)
        run.free()
    jdump(f, out)


def cmd_head(force=False):
    from . import head as H
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in K.CASES:
        f = RAW / f"head_{case}.json"
        if f.exists() and not force:
            continue
        pl = E.case_points(case, refs, pts)
        xy = sorted({(p["x"], p["y"]) for p in pl})
        nm = refs["norm"][case]
        run = M.GRun(case, xy + [(nm["x"], nm["y"])], ds_min=50.0, focus_r_mul=1.0)
        run.free()          # A и LU больше не нужны — память GPU под касательные скорости
        seg, nrej = H.zones(run)
        cov = H.covered(seg, [p["x"] for p in pl], [p["y"] for p in pl])
        print(case, "N", run.N, "отрывов", len(seg), "с присоединением", sum(1 for s in seg if s[4]), "отброшено lee_only", nrej, flush=True)
        jdump(f, dict(case=case, N=run.N, n_sep=len(seg), n_reattach=sum(1 for s in seg if s[4]), n_rejected=nrej,
                      seg=[list(map(float, s[:4])) + [bool(s[4])] for s in seg], ids=[p["id"] for p in pl],
                      covered=[bool(c) for c in cov]))
        run.free()


if __name__ == "__main__":
    args = sys.argv[1:]
    force = "--force" in args
    args = [a for a in args if a != "--force"]
    cmd = args[0] if args else ""
    if cmd == "repro":
        cmd_repro(force)
    elif cmd == "base":
        cmd_base(force)
    elif cmd == "scan":
        cmd_scan(args[1:] or list(SCANS), force)
    elif cmd == "head":
        cmd_head(force)
    elif cmd == "assemble":
        from . import assemble
        assemble.main()
    else:
        print(__doc__)
        sys.exit(2)
