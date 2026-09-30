"""Эталоны Онгудая для GPU-Пикара (AM-03): вход решения, число итераций эталона, поле у старта Каянча.

Для каждой сетки области (400, 200 м) — вход решения на 12:00 (рельеф hc, поток тепла H до
гашения у края, dθ̄/dz в центрах уровней, z_i) и итерации эталона `air.py` (float32 и, для
400 м / 3 м/с, float64) для ветра 0, 3, 6 м/с с 150° с нагревом и без. Для 400 м / 3 м/с —
решение float64 (с нагревом и без) в 16 × 16 столбцах у старта Каянча в центрах клеток и выборка
как в игре (`to_game_field.game_sample`) над стартом — для сверки `WindField` из GPU.

Формат — как `fixtures.py` (float32 LE .bin + .json со смещениями).

    PY=../heat_ca/.venv/bin/python
    $PY picard_gpu_refs.py     # → tests/atmosphere/fixtures/air_model/picard/ (~3 мин)
"""
from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np

import air as A
import real as R
import to_game_field as TG

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tests/atmosphere/fixtures/air_model/picard"
LOC = "ongudai"
HOUR = 12.0
WDIR = 150.0
WINDS = (0.0, 3.0, 6.0)
TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)


class Pack:
    def __init__(self):
        self.parts, self.arrays, self.off = [], {}, 0

    def add(self, name, a):
        a = np.ascontiguousarray(np.nan_to_num(np.asarray(a, np.float64))).astype("<f4").ravel()
        self.arrays[name] = [self.off, int(a.size)]
        self.parts.append(a)
        self.off += a.size

    def write(self, path, meta):
        np.concatenate(self.parts).tofile(str(path) + ".bin")
        meta = dict(meta, arrays=self.arrays)
        Path(str(path) + ".json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))


def solve(g, hc, U, heat, dtype):
    import cupy as cp
    c = R.case(LOC, g, hc, HOUR, U, WDIR, heat=heat)
    S = R.make(LOC, g, hc, c, dtype=dtype)
    S.init_background()
    st = S.solve(max_outer=3000, **TOL)
    S.finalize()
    cp.cuda.Device().synchronize()
    return S, c, st


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    L = R.location(LOC)
    site = L.sites[R.START[LOC]]
    sx, sy = site["x"], site["y"]
    for dx in (400, 200):
        g, hc = R.grid_domain(LOC, dx)
        c = R.case(LOC, g, hc, HOUR, 3.0, WDIR)
        NZ = g.nz + 2
        zc = g.z_bot + (np.arange(NZ) - 0.5) * g.dz
        P = Pack()
        P.add("hc", hc)
        P.add("H", c.H)
        P.add("gam", c.gam(zc))
        runs = []
        for U in WINDS:
            for heat in (True, False):
                t0 = time.perf_counter()
                S, _, st = solve(g, hc, U, heat, np.float32)
                runs.append(dict(U10=U, heat=heat, dtype="float32", status=st, iters=S.outer,
                                 t_cupy=round(S.wall - S.t_check, 3)))
                print(dx, U, heat, st, S.outer, round(time.perf_counter() - t0, 1), flush=True)
                del S
        meta = dict(loc=LOC, hour=HOUR, wdir=WDIR, dtau_u=A.Params().dtau_per_m * g.dx, params=dict(lam_frac=A.Params().lam_frac, pr_t=A.Params().pr_t), dx=g.dx, dz=g.dz, nx=g.nx, ny=g.ny, nz=g.nz,
                    z_bot=g.z_bot, x0=g.x0, y0=g.y0, z_i=c.z_i, ctx=R.context(LOC),
                    day={k: (None if isinstance(v, float) and not np.isfinite(v) else v) for k, v in c.day.summary().items()}, site=dict(x=sx, y=sy), runs=runs)
        if dx == 400:
            # решение float64 3 м/с с нагревом и без — у старта (16 × 16 столбцов) и выборка как в игре
            SH, _, sth = solve(g, hc, 3.0, True, np.float64)
            SN, _, stn = solve(g, hc, 3.0, False, np.float64)
            runs.append(dict(U10=3.0, heat=True, dtype="float64", status=sth, iters=SH.outer))
            runs.append(dict(U10=3.0, heat=False, dtype="float64", status=stn, iters=SN.outer))
            u, v, w, th = SH.centers()
            _, _, wn, _ = SN.centers()
            ch = dict(u=u, v=v, w_mech=wn, w_conv=w - wn, theta=th)
            ch = {k: np.nan_to_num(a) for k, a in ch.items()}
            gg = dict(dx=g.dx, dz=g.dz, x0=g.x0, y0=g.y0, z_bot=g.z_bot, nx=g.nx, ny=g.ny, nz=g.nz)
            probes = []
            _, hg = TG.game_sample(ch, hc, gg, TG.Z0, sx, sy, 0.0)
            for agl in (10.0, 50.0, 150.0, 400.0):
                fs, _ = TG.game_sample(ch, hc, gg, TG.Z0, sx, sy, hg + agl)
                probes.append(dict(agl=agl, game=[sx, hg + agl, -sy], field=fs))
            n = 16
            i0 = int((sx - g.x0) / g.dx) - n // 2
            j0 = int((sy - g.y0) / g.dx) - n // 2
            for k, a in ch.items():
                P.add("crop_" + k, a[:, j0:j0 + n, i0:i0 + n])
            meta.update(probes=probes, crop=dict(i0=i0, j0=j0, n=n),
                        u_scale=float(np.nanmax(np.sqrt(u ** 2 + v ** 2 + w ** 2))),
                        div_rms=[float(np.sqrt(np.mean(np.square(np.asarray(S.divergence().get())[S.fluid_np[1:-1, 1:-1, 1:-1]]))))
                                 for S in (SH, SN)],
                        heat_budget=SH.heat_budget())
            del SH, SN
        P.write(OUT / f"ongudai_d{dx}_h12", meta)
        print("→", OUT / f"ongudai_d{dx}_h12", flush=True)


if __name__ == "__main__":
    main()
