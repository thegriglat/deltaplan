"""AM-09: прогоны эталона масштаба 1 (air.py) на Askervein по сетке параметров → наблюдаемые.

Наблюдаемые (определение то же, что у измерений, Taylor & Teunissen 1985, Zenodo 4095052):
  * FSR на 10 м над землёй вдоль линий A, AA, B: S(точка, 10 м)/S(RS, 10 м) − 1;
  * профиль разгона на HT и CP: S(HT, z)/S(RS, z) − 1 на той же высоте z (чашки AES/FRG).
Схема: 25 м + 2-й порядок (область 4 км, потолок 1000 м) — рабочая сетка прогонов; 12,5 м + 2-й
порядок — эталонная (поправка сетки и её систематика, см. docs/research/air-model-tune.md).

  PY=.venv/bin/python
  flock /tmp/heat_ca_gpu.lock $PY askervein_runs.py design.json out/runs_25.jsonl --dx 25
  (прерванную серию можно продолжить — готовые точки пропускаются)
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "air3d"))

import air as A          # noqa: E402
import askervein as AK   # noqa: E402
import synth as SY       # noqa: E402
from real import bil     # noqa: E402

PROFILE_H = (3.0, 5.0, 8.0, 15.0, 24.0, 34.0)


def obs_points():
    """Точки 10 м (без RS и дублей в одной точке — среднее), σ — полуширина FSRmin/FSRmax данных."""
    rows = list(csv.DictReader(open(AK.D / "askervein_validation1.txt")))
    pts = {}
    for r in rows:
        try:
            fsr, h = float(r["FSR"]), float(r["H(m)"])
        except ValueError:
            continue
        if fsr <= -900 or h != 10.0 or r["Name"].startswith("RS"):
            continue
        if r["Name"].startswith("HT") or r["Name"].startswith("CP"):
            name = r["Name"].split()[0]
        else:
            name = r["Name"]
        lo, hi = float(r["FSRmin"]), float(r["FSRmax"])
        sig = 0.5 * (lo + hi) if lo > 0 and hi > 0 else 0.05
        key = (round(float(r["X(m)"]) / 20), round(float(r["Y(m)"]) / 20)) if name not in ("HT", "CP") else name
        pts.setdefault(key, []).append(dict(name=name, x=float(r["X(m)"]), y=float(r["Y(m)"]), fsr=fsr, sig=sig))
    out = []
    for key, lst in pts.items():
        out.append(dict(name=lst[0]["name"], x=float(np.mean([p["x"] for p in lst])), y=float(np.mean([p["y"] for p in lst])),
                        fsr=float(np.mean([p["fsr"] for p in lst])),
                        sig=float(max(np.mean([p["sig"] for p in lst]), np.std([p["fsr"] for p in lst])))))
    return out


def obs_profiles():
    """Профили к RS на той же высоте: HT (чашки AES), CP (чашки/Gill FRG против чашек RS)."""
    rows = list(csv.DictReader(open(AK.D / "askervein_validation1.txt")))
    rs = {float(r["H(m)"]): float(r["S(m/s)"]) for r in rows if r["Name"] == "RS" and "cup" in r["Sensor"]}
    ht = {float(r["H(m)"]): float(r["S(m/s)"]) for r in rows if r["Name"] == "HT" and "cups" in r["Sensor"]}
    out = []
    for h in PROFILE_H:
        if h in ht and h in rs:
            out.append(dict(name=f"HT_prof{h:g}", h=h, x=AK.HT[0], y=AK.HT[1], fsr=ht[h] / rs[h] - 1, sig=0.05))
    return out


def model_obs(S, g, sp):
    res = {}
    s10 = SY.agl(S, sp, 10.0)
    r10 = bil(g, s10, *AK.RS)
    for p in obs_points():
        res[p["name"]] = bil(g, s10, p["x"], p["y"]) / r10 - 1
    for p in obs_profiles():
        sh = SY.agl(S, sp, p["h"])
        res[p["name"]] = bil(g, sh, p["x"], p["y"]) / bil(g, sh, *AK.RS) - 1
    res["_RS10"] = r10
    return res


def run(prm_over, dx=25.0, adv2=True, L=4000.0, top=1000.0, keep=False):
    x0, y0, n, hc = AK.terrain(dx, L)
    dz = dx / 2
    nz = int(math.ceil(top / dz)) + 1
    nz += nz % 2
    g = A.Grid(dx, n, n, dz, -dz, nz, x0, y0)
    kw = dict(z0=0.03, alpha=0.17, max_profile=2.0, f_cor=1.22e-4, sponge_side_m=1000.0, adv2=adv2)
    kw.update(prm_over)
    prm = A.Params(**kw)
    case = A.Case(U10=8.9, wdir=210.0, gam=SY.const_gam(0.0))
    t0 = time.perf_counter()
    S = SY.run(g, hc, case, prm, max_outer=4000)
    u, v, w, th = S.centers()
    sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
    out = dict(params=prm_over, dx=dx, adv2=adv2, L=L, top=top, status=S.status, iters=S.outer, t=time.perf_counter() - t0,
               obs=model_obs(S, g, sp))
    if keep:
        out["_field"] = dict(g=g, hc=hc, u=u, v=v, w=w, kb=S.kb, S=S)
    else:
        del S
        import cupy
        cupy.get_default_memory_pool().free_all_blocks()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("design", help="JSON: список словарей параметров Params")
    ap.add_argument("out", help="jsonl — дописывается")
    ap.add_argument("--dx", type=float, default=25.0)
    ap.add_argument("--adv1", action="store_true", help="1-й порядок переноса")
    ap.add_argument("--L", type=float, default=4000.0, help="сторона области, м")
    ap.add_argument("--top", type=float, default=1000.0, help="потолок, м")
    ap.add_argument("--max", type=int, default=10 ** 9, help="не больше стольких прогонов за серию")
    a = ap.parse_args()
    design = json.loads(Path(a.design).read_text())
    outp = Path(a.out)
    done = set()
    if outp.exists():
        for line in outp.read_text().splitlines():
            done.add(json.dumps(json.loads(line)["params"], sort_keys=True))
    k = 0
    for prm in design:
        key = json.dumps(prm, sort_keys=True)
        if key in done:
            continue
        r = run(prm, dx=a.dx, adv2=not a.adv1, L=a.L, top=a.top)
        with outp.open("a") as f:
            f.write(json.dumps(r) + "\n")
        print(f"{prm} → {r['status']} {r['iters']} it {r['t']:.1f} с; HT10 {r['obs']['HT']:.3f}", flush=True)
        k += 1
        if k >= a.max:
            break


if __name__ == "__main__":
    main()
