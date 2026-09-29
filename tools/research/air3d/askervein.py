"""Askervein (Taylor & Teunissen 1987): разгон на вершине HT и вдоль линии A против измерений.

Рельеф — изолинии WAsP .map (tools/research/data/askervein/), треугольная интерполяция на сетку
25 м; ветер 210°, нейтрально (dθ̄/dz = 0, без нагрева), U10 на эталонной мачте RS = 8,9 м/с,
шероховатость z0 = 0,03 м (Taylor & Teunissen), профиль набегающего потока — степенной по RS
(10 м → 40 м: α = 0,17). FSR = S(точка, h)/S(RS, h) − 1 на той же высоте над землёй.

  ../heat_ca/.venv/bin/python askervein.py [--dx 50,25]   → out/ref/askervein.json, out/ref/fig_askervein.png
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

import air as A
import synth as SY

ROOT = Path(__file__).resolve().parents[3]
D = ROOT / "tools/research/data/askervein"
OUT = SY.OUT
RS = (74300.0, 20980.0)
HT = (75387.0, 23735.0)
CP = (75676.0, 23466.0)


def read_map_lines():
    """Надёжнее: построчно (заголовок — отдельная строка с 2–4 числами)."""
    lines = (D / "askervein_elevation-roughness.map").read_text().splitlines()[4:]
    pts = []
    k = 0
    while k < len(lines):
        head = lines[k].split()
        k += 1
        if not head:
            continue
        nh = len(head)
        n = int(float(head[-1]))
        buf = []
        while len(buf) < 2 * n:
            buf += [float(t) for t in lines[k].split()]
            k += 1
        xy = np.array(buf[:2 * n]).reshape(n, 2)
        if nh == 2:
            pts.append(np.column_stack([xy, np.full(n, float(head[0]))]))
        elif nh == 4:
            pts.append(np.column_stack([xy, np.full(n, float(head[2]))]))
    return np.concatenate(pts)


def terrain(dx, L=8000.0):
    import matplotlib.tri as mtri
    P = read_map_lines()
    cx, cy = HT[0] - 600.0, HT[1] - 600.0            # центр области чуть против ветра от вершины
    n = int(round(L / dx)); n += n % 2
    x0, y0 = cx - n * dx / 2, cy - n * dx / 2
    # высоты — в узлах 25 м, затем блочное среднее по клетке
    f = int(round(dx / 12.5))
    xs = x0 + (np.arange(n * f) + 0.5) * dx / f
    ys = y0 + (np.arange(n * f) + 0.5) * dx / f
    tri = mtri.Triangulation(P[:, 0], P[:, 1])
    it = mtri.LinearTriInterpolator(tri, P[:, 2])
    Xf, Yf = np.meshgrid(xs, ys)
    hf = np.asarray(it(Xf, Yf).filled(0.0))
    hc = hf.reshape(n, f, n, f).mean(axis=(1, 3))
    return x0, y0, n, hc


def read_obs():
    rows = list(csv.DictReader(open(D / "askervein_validation1.txt")))
    obs = []
    for r in rows:
        try:
            fsr = float(r["FSR"])
        except ValueError:
            continue
        if fsr <= -900:
            continue
        obs.append(dict(name=r["Name"], x=float(r["X(m)"]), y=float(r["Y(m)"]), h=float(r["H(m)"]), fsr=fsr))
    return obs


def run(dx, adv2=False):
    x0, y0, n, hc = terrain(dx)
    dz = dx / 2
    top = 1500.0
    nz = int(math.ceil(top / dz)) + 1; nz += nz % 2
    g = A.Grid(dx, n, n, dz, -dz, nz, x0, y0)
    prm = A.Params(z0=0.03, alpha=0.17, max_profile=2.0, f_cor=1.22e-4, sponge_side_m=1000.0, adv2=adv2)
    case = A.Case(U10=8.9, wdir=210.0, gam=SY.const_gam(0.0))
    S = SY.run(g, hc, case, prm, max_outer=4000)
    u, v, w, th = S.centers()
    sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
    obs = read_obs()
    from real import bil
    res = dict(dx=dx, adv2=adv2, info=SY.info(S), points=[])
    for o in obs:
        s = bil(g, SY.agl(S, sp, o["h"]), o["x"], o["y"])
        s_ref = bil(g, SY.agl(S, sp, o["h"]), *RS)
        res["points"].append(dict(o, model=s / s_ref - 1))
    ht10 = [p for p in res["points"] if p["name"].startswith("HT") and p["h"] == 10]
    res["HT10_model"] = ht10[0]["model"] if ht10 else None
    res["HT10_obs"] = [p["fsr"] for p in ht10]
    res["RS_U10_model"] = bil(g, SY.agl(S, sp, 10.0), *RS)
    res["hc_max"] = float(hc.max())
    res["fields"] = dict(g=g, hc=hc, sp=sp, S=S)
    print(f"Askervein dx {dx} adv2 {adv2}: {S.status} {S.outer} it, HT 10 м FSR модель {res['HT10_model']:.3f} против "
          f"{res['HT10_obs']}, max h {hc.max():.1f}", flush=True)
    return res


def fig(results):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axs = plt.subplots(1, 3, figsize=(16, 5))
    # линия A (и AA): FSR на 10 м против расстояния от HT
    for r in results:
        pts = [p for p in r["points"] if p["h"] == 10 and (p["name"].startswith("A") and not p["name"].startswith("AA"))]
        d = [math.copysign(math.hypot(p["x"] - HT[0], p["y"] - HT[1]), p["x"] - HT[0]) for p in pts]
        o = np.argsort(d)
        axs[0].plot(np.array(d)[o], np.array([p["model"] for p in pts])[o], "-", label=f"модель {r['dx']:g} м" + (", 2-й пор." if r.get("adv2") else ""))
    pts = [p for p in results[0]["points"] if p["h"] == 10 and (p["name"].startswith("A") and not p["name"].startswith("AA"))]
    d = [math.copysign(math.hypot(p["x"] - HT[0], p["y"] - HT[1]), p["x"] - HT[0]) for p in pts]
    axs[0].plot(d, [p["fsr"] for p in pts], "ko", label="измерения")
    axs[0].set_title("Линия A через HT, 10 м над землёй"); axs[0].set_xlabel("м от HT (ЮЗ −, СВ +)")
    axs[0].set_ylabel("ΔS/S_RS"); axs[0].legend(); axs[0].grid(alpha=0.3)
    # профиль на HT
    for r in results:
        S = r["fields"]["S"]; g = r["fields"]["g"]; sp = r["fields"]["sp"]
        from real import bil
        hs = np.array([2, 3, 5, 8, 10, 15, 24, 34, 50, 80, 120])
        m = [bil(g, SY.agl(S, sp, h), *HT) / bil(g, SY.agl(S, sp, h), *RS) - 1 for h in hs]
        axs[1].plot(m, hs, "-", label=f"модель {r['dx']:g} м" + (", 2-й пор." if r.get("adv2") else ""))
    ht = [p for p in results[0]["points"] if p["name"].startswith("HT")]
    axs[1].plot([p["fsr"] for p in ht], [p["h"] for p in ht], "ko", label="измерения HT")
    axs[1].set_yscale("log"); axs[1].set_xlabel("ΔS/S_RS"); axs[1].set_ylabel("м над землёй")
    axs[1].set_title("Профиль разгона на вершине HT"); axs[1].legend(); axs[1].grid(alpha=0.3)
    r = results[-1]
    g = r["fields"]["g"]; S = r["fields"]["S"]
    s10 = SY.agl(S, r["fields"]["sp"], 10.0)
    im = axs[2].pcolormesh(g.x - HT[0], g.y - HT[1], s10, shading="auto", cmap="viridis")
    axs[2].contour(g.x - HT[0], g.y - HT[1], r["fields"]["hc"], levels=np.arange(10, 130, 20), colors="w", linewidths=0.5)
    axs[2].set_aspect("equal"); axs[2].set_xlim(-2500, 2500); axs[2].set_ylim(-2500, 2500)
    axs[2].set_title(f"Скорость на 10 м, {r['dx']:g} м (ветер 210°)"); fig.colorbar(im, ax=axs[2], label="м/с")
    fig.tight_layout()
    fig.savefig(OUT / "fig_askervein.png", dpi=110)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dx", default="50,25")
    ap.add_argument("--adv2", action="store_true", help="ещё и с поправкой 2-го порядка")
    a = ap.parse_args()
    results = [run(float(d)) for d in a.dx.split(",")]
    if a.adv2:
        results += [run(float(d), adv2=True) for d in a.dx.split(",")]
    fig(results)
    out = [{k: v for k, v in r.items() if k != "fields"} for r in results]
    SY.jdump(out, OUT / "askervein.json")
