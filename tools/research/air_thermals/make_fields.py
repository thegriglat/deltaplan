#!/usr/bin/env python3
"""Поля масштаба 1 для AM-07 (термики из поля): пары «с нагревом / без нагрева» эталоном AM-01
(`tools/research/air3d/air.py`, код не меняется — только вызывается) → формат игры (`WindField`,
как `to_game_field.py`) + то, что нужно масштабу 2 и чего нет в каналах поля:

  meta.heat_array  — поток тепла H (ny, nx), Вт/м² на горизонтальную площадь (вход решателя);
  meta.z_i         — верх слоя перемешивания над морем, м (погода игры, weather.py);
  meta.gam         — dθ̄/dz в центрах уровней (nz), К/м (фон θ̄ решателя);
  meta.u10, wdir   — ветер прогноза (для u*);
  meta.z_lcl       — кромка (конденсация) из погоды, м над морем — для сверки.

Случаи (Онгудай, окно 100 м у Каянчи от области 400 м, как ref_study.window):
  h12  — 12:00, южный-юго-восточный 3 м/с (150°, встречный на старте), ясно;
  h15  — 15:00, то же (солнце с юго-запада: восточные склоны в тени);
  h09  — 9:00, утренняя инверсия (крышка cap) — потолок по инверсии на реальном рельефе.
Каждый случай: область 400 м с нагревом и без → окно 100 м с нагревом и без.

  PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
  flock /tmp/heat_ca_gpu.lock $PY make_fields.py            # все случаи → fields/*.json|bin (вне git)
  $PY make_fields.py --fixture                              # + обрезка для тестов (CPU, из fields/)

Фикстура тестов (32 × 32 столбца у старта, до 40 уровней) — tests/atmosphere/fixtures/air_model/thermals/.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
AIR3D = HERE.parent / "air3d"
sys.path.insert(0, str(AIR3D))

OUT = HERE / "fields"
FIX = HERE.parents[2] / "tests/atmosphere/fixtures/air_model/thermals"
Z0 = 0.1
CASES = dict(h12=12.0, h15=15.0, h09=9.0)
U10, WDIR = 3.0, 150.0


def solve_pair(hour):
    import ref_study as RS
    out = {}
    for heat in (True, False):
        D = RS.domain(400, hour, U10, WDIR, heat=heat)
        r1 = RS.solve(D)
        W = RS.window(D, 100, hour, U10, WDIR, heat=heat)
        r2 = RS.solve(W)
        print(f"  {hour:g}h heat={heat}: область {r1['status']} {r1['iters']}, окно {r2['status']} {r2['iters']}",
              flush=True)
        out[heat] = dict(D=D, W=W)
    return out


def export(S_heat, S_noheat, name, extra_cond):
    u, v, w, th = S_heat.centers()
    _, _, w0, _ = S_noheat.centers()
    g = S_heat.g
    ch = dict(u=u, v=v, w_mech=w0, w_conv=w - w0, theta=th)
    ch = {k: np.nan_to_num(a, nan=0.0) for k, a in ch.items()}
    D = S_heat.case.day
    zc = g.z_bot + (np.arange(g.nz) + 0.5) * g.dz
    meta = dict(format="deltaplan-air-field", version=1, dx=g.dx, dz=g.dz, x0=g.x0, y0=g.y0, z_bot=g.z_bot,
                nx=g.nx, ny=g.ny, nz=g.nz, z0=Z0,
                layout="(nz, ny, nx), индекс (k·ny + j)·nx + i; i — восток, j — север (−Z игры), k — вверх",
                source=["air3d/air.py (эталон AM-01)", S_heat.case.label, S_noheat.case.label],
                cond=dict(hour=D.hour, wind=U10, wdir=WDIR, **extra_cond),
                z_i=float(D.z_i), z_lcl=float(D.z_lcl), z_dry_game=float(D.z_dry_game), u10=U10, wdir=WDIR,
                gam=[float(x) for x in D.gamma(zc)], theta0=300.0,
                weather={k: (v if not isinstance(v, float) or np.isfinite(v) else None) for k, v in D.summary().items()})
    write(OUT / name, meta, ch, S_heat.hc, S_heat.H, S_heat.h_bl)


def write(path, meta, ch, hc, heat, h_bl):
    path.parent.mkdir(parents=True, exist_ok=True)
    parts, arrays, off = [], {}, 0
    items = [(k, a) for k, a in ch.items()] + [("hc", hc), ("heat", heat), ("h_bl", h_bl)]
    for name, a in items:
        a = np.ascontiguousarray(np.asarray(a, "<f4")).ravel()
        arrays[name] = [off, int(a.size)]
        parts.append(a)
        off += a.size
    np.concatenate(parts).tofile(str(path) + ".bin")
    meta = dict(meta, arrays=arrays)
    Path(str(path) + ".json").write_text(json.dumps(meta, ensure_ascii=False, indent=1, allow_nan=False))
    print(" ", path, f"{off * 4 / 1e6:.2f} МБ", flush=True)


def load(path):
    m = json.loads(Path(str(path) + ".json").read_text())
    raw = np.fromfile(str(path) + ".bin", "<f4")
    A = {}
    for k, (o, n) in m["arrays"].items():
        a = raw[o:o + n]
        if k in ("hc", "heat", "h_bl"):
            A[k] = a.reshape(m["ny"], m["nx"])
        else:
            A[k] = a.reshape(m["nz"], m["ny"], m["nx"])
    return m, A


def crop(src, dst, n=32, nzc=40):
    """n × n столбцов у старта Каянча, nzc уровней снизу (обрезка готового файла)."""
    import terrain as T
    m, A = load(src)
    s = T.sites(T.load_detail()[2])["start"]
    ic = int((s["x"] - m["x0"]) / m["dx"])
    jc = int((s["y"] - m["y0"]) / m["dx"])
    i0, j0 = ic - n // 2, jc - n // 2
    ch = {k: A[k][:nzc, j0:j0 + n, i0:i0 + n] for k in ("u", "v", "w_mech", "w_conv", "theta")}
    meta = {k: v for k, v in m.items() if k != "arrays"}
    meta.update(x0=m["x0"] + i0 * m["dx"], y0=m["y0"] + j0 * m["dx"], nx=n, ny=n, nz=nzc, gam=m["gam"][:nzc],
                source=m["source"] + [f"обрезка {n}×{n}×{nzc} у старта"])
    write(dst, meta, ch, A["hc"][j0:j0 + n, i0:i0 + n], A["heat"][j0:j0 + n, i0:i0 + n],
          A["h_bl"][j0:j0 + n, i0:i0 + n])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", action="store_true", help="только обрезка фикстуры из fields/")
    ap.add_argument("--cases", default=",".join(CASES))
    args = ap.parse_args()
    if not args.fixture:
        for key in args.cases.split(","):
            hour = CASES[key]
            print(key, flush=True)
            P = solve_pair(hour)
            export(P[True]["W"], P[False]["W"], f"kayancha_w100_{key}", dict(level="window100"))
            export(P[True]["D"], P[False]["D"], f"ongudai_d400_{key}", dict(level="domain400"))
            del P
    for key in ("h12", "h09"):
        if (OUT / f"kayancha_w100_{key}.json").exists():
            crop(OUT / f"kayancha_w100_{key}", FIX / f"kayancha_w100_{key}")


if __name__ == "__main__":
    main()
