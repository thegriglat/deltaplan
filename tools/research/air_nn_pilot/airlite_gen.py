#!/usr/bin/env python3
"""Решательная часть случая air-lite — перенос `tools/research/air_lite/gen.py` ветки research/air-lite (7cc7e33).

Не изменено: условия плана (`plan_rows` = тело make_plan: то же зерно, те же id и условия), сетки окон, срезы на
13 высотах AGL, решение «с нагревом / без» (эталон AM-01, `air3d`, код не меняется) и состав массивов случая.
Изменено только обрамление: make_plan не пишет файл, а возвращает план (`plan_rows`, `plan_centers`); run_case
разделён на `solve_case` (массивы float16 + метаданные, как строка runs.jsonl) — запись файла, статусы, замок GPU
и очередь — в `dataset.py`. Цикл `main` (runs.jsonl) не перенесён: источник правды — state.sqlite.
"""
from __future__ import annotations

import fcntl
import math
import time

import numpy as np

import places as P   # подменяет real.location/context — до импорта ref_study не важно (поиск по модулю)

import air as A          # noqa: E402
import real as R         # noqa: E402
import ref_study as RS   # noqa: E402
import synth as SY       # noqa: E402

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


def plan_rows(locs, n_of, seed=20261001):
    """Случайный план (стратифицированный по часу и облачности): ветер 0–8 м/с (каждый 12-й — штиль),
    направление 0–360° непрерывно, t_max 18–34 °C. Один генератор на весь список мест (как make_plan air-lite:
    locs = REAL + SYNTH, n_of(loc) = 110 / 50, seed 20261001 → тот же out/plan.json)."""
    rng = np.random.default_rng(seed)
    rows = []
    for loc in locs:
        n = n_of(loc)
        for k in range(n):
            hour = HOURS[k % 4]
            sky = SKIES[(k // 4) % 3]
            U = 0.0 if k % 12 == 5 else float(np.round(rng.uniform(0.5, 8.0), 2))
            wdir = float(np.round(rng.uniform(0, 360), 1))
            tmax = float(np.round(rng.uniform(18.0, 34.0), 1))
            rows.append(dict(id=f"{loc}_{k:03d}", loc=loc, hour=hour, U10=U, wdir=wdir, t_max=tmax, sky=sky))
    return rows


def plan_centers(locs):
    """Центры окон 100 м (как make_plan air-lite): встроенные — 3 окна, синтетика и процедурные — 1 (старт)."""
    return {loc: P.window_centers(loc, n_total=3 if loc in P.REAL else 1) for loc in locs}


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


def late_points(late_from, late_step, max_outer):
    """Итерации снимков цели «среднее поздних» (П1 v3): late_from, late_from + late_step, …, max_outer (последний —
    всегда предел: конечное состояние несошедшегося решения входит в среднее)."""
    pts = list(range(int(late_from), int(max_outer) + 1, int(late_step)))
    if not pts or pts[-1] != int(max_outer):
        pts.append(int(max_outer))
    return pts


def at60(sl):
    """(C, 13, ny, nx) → (C, ny, nx) на 60 м над рельефом (линейно между уровнями 50 и 75 м)."""
    i50, i75 = AGL.index(50), AGL.index(75)
    return sl[:, i50] + (60.0 - 50.0) / 25.0 * (sl[:, i75] - sl[:, i50])


def late_spread60_p90(snaps, mean, edge):
    """Собственный разброс решения (П1 v3): на 60 м для каждой клетки области без edge клеток у края — RMS по снимкам
    |Δ(u, v)| от среднего, затем 90-й процентиль по клеткам, м/с. snaps — список (C, 13, ny, nx) float64."""
    m60 = at60(mean[:2])
    acc = np.zeros(m60.shape[1:])
    for s in snaps:
        d = at60(s[:2]) - m60
        acc += d[0] ** 2 + d[1] ** 2
    rms = np.sqrt(acc / len(snaps))
    if edge > 0:
        rms = rms[edge:-edge, edge:-edge]
    return float(np.nanpercentile(rms, 90))


def solve_late(D, max_outer, late, heat):
    """Решение области D с целью П1 v3. Снимки поздних состояний — обратным вызовом `cb` решателя (Solver.solve
    вызывает его после каждых check_every итераций, вне счёта; cb только читает поля — траектория итераций та же,
    поэтому снимок на итерации k побитно равен решению с max_outer = k: tests/test_late_mean.py). Решатель не
    правится; инициализация и учёт времени — как ref_study.solve.
    → (r как ref_study.solve + target/late_n/late_spread60_p90/late_its, срезы (C, 13, ny, nx) float64, снимки)."""
    import cupy as cp
    pts = late_points(late["from"], late["step"], max_outer)
    todo = list(pts)
    snaps, its = [], []

    def cb(S, r):
        while todo and r["it"] >= todo[0]:
            todo.pop(0)
            sl = slices(S)
            snaps.append(sl if heat else sl[:3])
            its.append(int(r["it"]))

    cp.cuda.Device().synchronize()
    t0 = time.perf_counter()
    D.init_background()
    cp.cuda.Device().synchronize()
    t_init = time.perf_counter() - t0
    st = D.solve(max_outer=max_outer, cb=cb, **RS.TOL)
    r = dict(status=st, iters=D.outer, t_solve=round(D.wall - D.t_check, 3), t_init=round(t_init, 3))
    if st == "max":
        # снимки по возрастанию итераций; последний — конечное состояние (то же, что slices(D) в v2)
        assert len(snaps) == len(pts), (len(snaps), pts, its)
        mean = np.zeros_like(snaps[0])
        for s in snaps:
            mean += s
        mean /= len(snaps)
        r.update(target="late_mean", late_n=len(snaps), late_its=its,
                 late_spread60_p90=round(late_spread60_p90(snaps, mean, int(late.get("edge_cells", 0))), 5))
        out = mean
    else:   # сошлось (или разошлось) — конечное состояние, как v2
        sl = slices(D)
        out = sl if heat else sl[:3]
        r.update(target="final", late_n=1, late_spread60_p90=0.0)
    return r, out, snaps


RUN_KEYS = ("status", "iters", "t_solve", "t_init")
LATE_KEYS = ("target", "late_n", "late_spread60_p90", "late_its")


def solve_case(c, centers, max_outer=None, late=None, keep_snaps=None):
    """Тело run_case air-lite без записи: → (метаданные случая как строка runs.jsonl без статуса/времени,
    {ключ: массив float16} в порядке air-lite).

    centers = [] — только область (набор terrain, П1 v2): окна решаются после области и её не меняют, поэтому
    d400_* те же, что с окнами (tests/test_region_only.py). max_outer — предел внешних итераций каждого решения
    (None — как air-lite, ref_study.MAXIT = 3000); решение с пределом — то же поле, что полное в момент предела
    (итерации детерминированы), статус «max», если не сошлось (NN-P6, tests/out/maxcap.json).

    late = {from, step, edge_cells} — цель П1 v3 (NN-17): решение области со статусом max → d400_* = среднее снимков на
    итерациях late_points(from, step, max_outer), сошедшееся — конечное состояние (побитно как без late). Только для
    наборов без окон (окна вложены в состояние области — v3 их не определяет). keep_snaps — dict, куда положить
    снимки {d400_h: [...], d400_m: [...]} (float64, для теста)."""
    if late is not None:
        assert not centers, "П1 v3 (late_mean) — только область, без окон"
        assert max_outer is not None, "П1 v3: нужен предел итераций"
    mo = RS.MAXIT if max_outer is None else int(max_outer)
    loc = c["loc"]
    res = dict(runs={})
    arrays = {}
    for tag, heat in (("h", True), ("m", False)):
        g, hc = R.grid_domain(loc, 400)
        cond = R.case(loc, g, hc, c["hour"], c["U10"], c["wdir"], c["t_max"], c["sky"], heat)
        D = R.make(loc, g, hc, cond)
        if late is None:
            r = RS.solve(D, max_outer=mo)
            res["runs"][f"d400_{tag}"] = {k: r[k] for k in RUN_KEYS}
            sl = slices(D)
            arrays[f"d400_{tag}"] = sl if heat else sl[:3]
        else:
            r, arrays[f"d400_{tag}"], snaps = solve_late(D, mo, late, heat)
            res["runs"][f"d400_{tag}"] = {k: r[k] for k in RUN_KEYS + LATE_KEYS if k in r}
            if keep_snaps is not None:
                keep_snaps[f"d400_{tag}"] = snaps
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
            r = RS.solve(Wn, max_outer=mo)
            res["runs"][f"w{iw}_{tag}"] = {k: r[k] for k in RUN_KEYS}
            sl = slices(Wn)
            arrays[f"w{iw}_{tag}"] = sl if heat else sl[:3]
            if heat:
                arrays[f"w{iw}_hc"], arrays[f"w{iw}_H"], arrays[f"w{iw}_hbl"] = Wn.hc, Wn.H, Wn.h_bl
                res[f"w{iw}"] = level_meta(Wn)
            RS.free(Wn)
        RS.free(D)
    return res, {k: np.nan_to_num(np.asarray(v), nan=np.nan).astype(np.float16) for k, v in arrays.items()}
