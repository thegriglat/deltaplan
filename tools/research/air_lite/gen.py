#!/usr/bin/env python3
"""Обучающий набор облегчённого режима: полные решения эталона AM-01 (air3d/air.py, код не меняется)
по местам (встроенные + синтетика) и условиям (ветер, направление, час, t_max, облачность).

На случай: область 400 м (с нагревом и без — разделение w_mech / w_conv, как у игры) и окна 100 м
(64 × 64, от области) у стартов места (старты ближе 3 км — одно окно; до 3 окон на место — точки наибольшего превышения над окрестностью 2 км).
Из каждого уровня сохраняются срезы на высотах AGL над рельефом сетки (synth.agl):
  m_u, m_v, m_w — решение без нагрева (механика: w_mech), h_u, h_v, h_w, h_th — с нагревом,
  плюс hc, H (поток тепла), h_bl (толщина слоя решателя) → fields/<id>.npz (float16; вне git).
Строка на случай → out/runs.jsonl (итерации, время, статус); готовые пропускаются.
Замок GPU (/tmp/heat_ca_gpu.lock) — на пачку случаев ≤ --batch-s с (5 мин), внутри скрипта: снаружи flock НЕ нужен.

  PY=.venv/bin/python
  $PY gen.py plan                      # → out/plan.json
  $PY gen.py run [--ids a,b] [--limit N]
"""
from __future__ import annotations

import argparse
import fcntl
import json
import math
import time
import traceback
from pathlib import Path

import numpy as np

import places as P   # подменяет real.location/context — до импорта ref_study не важно (поиск по модулю)

import air as A          # noqa: E402
import real as R         # noqa: E402
import ref_study as RS   # noqa: E402
import synth as SY       # noqa: E402

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
FIELDS = HERE / "fields"
LOCK = "/tmp/heat_ca_gpu.lock"
AGL = (25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000)
N_REAL, N_SYNTH = 110, 50
HOURS = (9.0, 12.0, 15.0, 20.0)
SKIES = ("clear", "partly", "overcast")
TYP_TMAX = 26.0   # типичный максимум июля (weather_model.json → typical_max_c, 15.07)


class GpuLock:
    def __enter__(self):
        self.f = open(LOCK, "w")
        t0 = time.perf_counter()
        fcntl.flock(self.f, fcntl.LOCK_EX)
        self.wait = time.perf_counter() - t0
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def make_plan(seed=20261001):
    """Случайный план (стратифицированный по часу и облачности): ветер 0–8 м/с (каждый 12-й — штиль),
    направление 0–360° непрерывно, t_max 18–34 °C."""
    rng = np.random.default_rng(seed)
    rows = []
    for loc in P.REAL + P.SYNTH:
        n = N_REAL if loc in P.REAL else N_SYNTH
        for k in range(n):
            hour = HOURS[k % 4]
            sky = SKIES[(k // 4) % 3]
            U = 0.0 if k % 12 == 5 else float(np.round(rng.uniform(0.5, 8.0), 2))
            wdir = float(np.round(rng.uniform(0, 360), 1))
            tmax = float(np.round(rng.uniform(18.0, 34.0), 1))
            rows.append(dict(id=f"{loc}_{k:03d}", loc=loc, hour=hour, U10=U, wdir=wdir, t_max=tmax, sky=sky))
    centers = {loc: P.window_centers(loc, n_total=3 if loc in P.REAL else 1) for loc in P.REAL + P.SYNTH}
    plan = dict(agl=AGL, centers=centers, cases=rows, seed=seed)
    OUT.mkdir(exist_ok=True)
    (OUT / "plan.json").write_text(json.dumps(plan, ensure_ascii=False, indent=1))
    print(len(rows), "случаев;", {k: len(v) for k, v in centers.items()})


def grid_window(loc, dx, center, n=64, top_above=2000.0):
    cx, cy = center
    cx = round((cx - 0.5 * n * dx) / 25.0) * 25.0 + 0.5 * n * dx
    cy = round((cy - 0.5 * n * dx) / 25.0) * 25.0 + 0.5 * n * dx
    dz = dx / 2
    x0, y0 = cx - n * dx / 2, cy - n * dx / 2
    hc = R.block_mean(loc, x0, y0, dx, n, n)
    zb = math.floor(hc.min() / dz) * dz - dz
    nz = int(math.ceil((hc.max() + top_above - zb) / dz)); nz += nz % 2
    return A.Grid(dx, n, n, dz, zb, nz, x0, y0), hc


def slices(S):
    u, v, w, th = S.centers()
    return np.stack([np.stack([SY.agl(S, F, a) for a in AGL]) for F in (u, v, w, th)])   # (4, nA, ny, nx)


def level_meta(S):
    g = S.g
    return dict(dx=g.dx, dz=g.dz, x0=g.x0, y0=g.y0, nx=g.nx, ny=g.ny, nz=g.nz, z_bot=g.z_bot)


def run_case(c, centers):
    loc = c["loc"]
    res = dict(runs={})
    arrays = {}
    for tag, heat in (("h", True), ("m", False)):
        g, hc = R.grid_domain(loc, 400)
        cond = R.case(loc, g, hc, c["hour"], c["U10"], c["wdir"], c["t_max"], c["sky"], heat)
        D = R.make(loc, g, hc, cond)
        r = RS.solve(D)
        res["runs"][f"d400_{tag}"] = {k: r[k] for k in ("status", "iters", "t_solve", "t_init")}
        sl = slices(D)
        arrays[f"d400_{tag}"] = sl if heat else sl[:3]
        if heat:
            arrays["d400_hc"], arrays["d400_H"], arrays["d400_hbl"] = D.hc, D.H, D.h_bl
            res["d400"] = level_meta(D)
            dsum = cond.day.summary()
            res["day"] = {k: (v if not isinstance(v, float) or math.isfinite(v) else None) for k, v in dsum.items()}
            res["profile"] = dict(alpha=cond.alpha, max_profile=cond.max_profile, stab=cond.stab_class, sun_el=cond.sun_elev,
                                  sun_az=cond.sun[0])
        for iw, ctr in enumerate(centers):
            gw, hw = grid_window(loc, 100, ctr)
            cw = R.case(loc, gw, hw, c["hour"], c["U10"], c["wdir"], c["t_max"], c["sky"], heat)
            Wn = R.make(loc, gw, hw, cw, parent=D)
            r = RS.solve(Wn)
            res["runs"][f"w{iw}_{tag}"] = {k: r[k] for k in ("status", "iters", "t_solve", "t_init")}
            sl = slices(Wn)
            arrays[f"w{iw}_{tag}"] = sl if heat else sl[:3]
            if heat:
                arrays[f"w{iw}_hc"], arrays[f"w{iw}_H"], arrays[f"w{iw}_hbl"] = Wn.hc, Wn.H, Wn.h_bl
                res[f"w{iw}"] = level_meta(Wn)
            RS.free(Wn)
        RS.free(D)
    FIELDS.mkdir(exist_ok=True)
    np.savez_compressed(FIELDS / f"{c['id']}.npz", **{k: np.nan_to_num(np.asarray(v), nan=np.nan).astype(np.float16)
                                                      for k, v in arrays.items()})
    return res


def done_ids(path):
    s = set()
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                s.add(json.loads(line)["id"])
            except (ValueError, KeyError):
                pass
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=("plan", "run"))
    ap.add_argument("--ids", default="")
    ap.add_argument("--limit", type=int, default=10 ** 6)
    ap.add_argument("--log", default=str(OUT / "runs.jsonl"))
    ap.add_argument("--batch-s", type=float, default=300.0)
    a = ap.parse_args()
    if a.cmd == "plan":
        make_plan()
        return
    plan = json.loads((OUT / "plan.json").read_text())
    log = Path(a.log)
    done = done_ids(log)
    ids = set(a.ids.split(",")) if a.ids else None
    todo = [c for c in plan["cases"] if c["id"] not in done and (ids is None or c["id"] in ids)][: a.limit]
    # чередовать места: любой префикс прогона покрывает все места
    todo.sort(key=lambda c: (int(c["id"].rsplit("_", 1)[1]), c["loc"]))
    t_start = time.time()
    n = 0
    while n < len(todo):
        # замок GPU — на пачку случаев не дольше a.batch_s секунд (очередь других агентов проходит между пачками)
        with GpuLock() as lk:
            t_batch = time.perf_counter()
            first = True
            while n < len(todo) and time.perf_counter() - t_batch < a.batch_s:
                c = todo[n]
                row = dict(c)
                t0 = time.perf_counter()
                try:
                    row.update(run_case(c, plan["centers"][c["loc"]]))
                    st = [v["status"] for v in row["runs"].values()]
                    row["status"] = "ok" if all(s == "ok" for s in st) else ("diverged" if "diverged" in st else "max")
                except Exception as e:  # noqa: BLE001
                    row.update(status="error", error=f"{type(e).__name__}: {e}", tb=traceback.format_exc()[-2000:])
                    try:
                        import cupy as cp
                        cp.get_default_memory_pool().free_all_blocks()
                    except Exception:  # noqa: BLE001
                        pass
                row["t_wall"] = round(time.perf_counter() - t0, 2)
                row["lock_wait"] = round(lk.wait, 2) if first else 0.0
                first = False
                with log.open("a") as f:
                    f.write(json.dumps(row, default=float, ensure_ascii=False) + "\n")
                it = sum(v["iters"] for v in row.get("runs", {}).values())
                print(f"[{(time.time() - t_start) / 60:6.1f} мин] {n + 1}/{len(todo)} {c['id']}: {row['status']}, {it} ит., "
                      f"{row['t_wall']:.1f} с", flush=True)
                n += 1
        print(f"  пачка: ждал GPU {lk.wait:.0f} с", flush=True)
    print(f"готово: {len(todo)} случаев за {(time.time() - t_start) / 3600:.2f} ч")


if __name__ == "__main__":
    main()
