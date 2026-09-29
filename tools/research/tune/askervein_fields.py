"""AM-09: поле Askervein (air.py) → формат игры (WindField: .json + .bin) для пробы масштаба 3.

Вырез — прямоугольник, где стоят мачты (RS … за холмом), до 800 м над морем (U_out ищется в 600 м
над рельефом). Нейтрально: w_mech = w, w_conv = 0, θ′ = 0, gam = 0 (N² = 0 известен), z0 = 0,03 м.
Поля — вне git (fields/, ~100 МБ на 12,5 м).

  flock /tmp/heat_ca_gpu.lock .venv/bin/python askervein_fields.py --dx 12.5 --lam_frac 0.1 --z0 0.03 fields/ask_12p5_nom
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

import askervein_runs as R

BOX = (74000.0, 20700.0, 76800.0, 24300.0)   # x0, y0, x1, y1 (координаты карты Askervein, м)
TOP = 800.0


def export(res, out):
    f = res["_field"]
    g, hc = f["g"], f["hc"]
    i0 = int((BOX[0] - g.x0) // g.dx)
    i1 = int((BOX[2] - g.x0) // g.dx) + 1
    j0 = int((BOX[1] - g.y0) // g.dx)
    j1 = int((BOX[3] - g.y0) // g.dx) + 1
    nzc = int(np.searchsorted(g.z, TOP)) + 1
    ch = dict(u=f["u"], v=f["v"], w_mech=f["w"], w_conv=np.zeros_like(f["w"]), theta=np.zeros_like(f["w"]))
    ch = {k: np.nan_to_num(a[:nzc, j0:j1, i0:i1]) for k, a in ch.items()}
    hcc = hc[j0:j1, i0:i1]
    meta = dict(format="deltaplan-air-field", version=1, dx=g.dx, dz=g.dz, x0=g.x0 + i0 * g.dx,
                y0=g.y0 + j0 * g.dx, z_bot=g.z_bot, nx=i1 - i0, ny=j1 - j0, nz=nzc,
                z0=float(res["z0"]), gam=[0.0] * nzc,
                layout="(nz, ny, nx), индекс (k·ny + j)·nx + i; i — восток, j — север (−Z игры), k — вверх",
                source="AM-09 askervein_fields.py", cond=dict(params=res["params"], dx=res["dx"], adv2=res["adv2"],
                                                            status=res["status"], iters=res["iters"]))
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    parts, arrays, off = [], {}, 0
    for name, a in [(k, a.astype("<f4")) for k, a in ch.items()] + [("hc", hcc.astype("<f4"))]:
        a = np.ascontiguousarray(a).ravel()
        arrays[name] = [off, int(a.size)]
        parts.append(a)
        off += a.size
    np.concatenate(parts).tofile(str(out) + ".bin")
    meta["arrays"] = arrays
    Path(str(out) + ".json").write_text(json.dumps(meta, ensure_ascii=False))
    print(out, meta["nx"], meta["ny"], meta["nz"], f"{off * 4 / 1e6:.0f} МБ")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--dx", type=float, default=12.5)
    ap.add_argument("--lam_frac", type=float, default=0.1)
    ap.add_argument("--z0", type=float, default=0.03)
    ap.add_argument("--adv1", action="store_true")
    a = ap.parse_args()
    prm = dict(lam_frac=a.lam_frac, z0=a.z0)
    res = R.run(prm, dx=a.dx, adv2=not a.adv1, keep=True)
    res["z0"] = a.z0
    print(res["status"], res["iters"], f"{res['t']:.0f} с", "HT10", round(res["obs"]["HT"], 3))
    export(res, a.out)
    Path(a.out + ".obs.json").write_text(json.dumps({k: v for k, v in res.items() if k != "_field"}))


if __name__ == "__main__":
    main()
