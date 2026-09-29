"""Askervein (Taylor & Teunissen 1987): разгон на вершине HT и вдоль линии A против измерений.

Рельеф — изолинии WAsP .map (tools/research/data/askervein/), треугольная интерполяция на сетку
25 м; ветер 210°, нейтрально (dθ̄/dz = 0, без нагрева), U10 на эталонной мачте RS = 8,9 м/с,
шероховатость z0 = 0,03 м (Taylor & Teunissen), профиль набегающего потока — степенной по RS
(10 м → 40 м: α = 0,17). Разгон модели ΔS = S(точка, h)/S(RS, h) − 1 на той же высоте над землёй.

Внимание: FSR в askervein_validation1.txt — S(точка, h)/S(RS, 10 м) − 1 (к RS на 10 м для всех высот);
для профиля измерения пересчитаны к RS на той же высоте (чашки RS и HT на 3, 5, 8, 15, 24, 34 м).
Независимый эталон внешнего слоя — линейное потенциальное обтекание (FFT, Джексон–Хант: û = U k_s²/|k| ĥ
e^{−|k|z}) и оно же с поправкой среднего слоя на сдвиг (Хант–Лейбович–Ричардс 1988):
ΔS(z) ≈ σ(z)·[ln(h_m/z0)/ln(z/z0)]², h_m·ln^½(h_m/z0) = L.

  ../heat_ca/.venv/bin/python askervein.py [--dx 50,25] [--adv2]   → out/ref/askervein.json, fig_askervein.png
  ../heat_ca/.venv/bin/python askervein.py --dx 25,12.5 --L 4000 --top 1000 --tag 4km   → askervein_4km.json, fig_askervein_4km.png
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
    if L < 6000.0:
        cy = HT[1] - 900.0                           # малая область: RS (3 км к ЮЮЗ) внутри (в губке притока)
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


def obs_profile():
    """Измеренный разгон над HT к RS на той же высоте (чашки AES на обеих мачтах; 10 м — анемометры Gill)."""
    rows = list(csv.DictReader(open(D / "askervein_validation1.txt")))
    rs = {float(r["H(m)"]): float(r["S(m/s)"]) for r in rows if r["Name"] == "RS" and "cup" in r["Sensor"]}
    ht = {float(r["H(m)"]): float(r["S(m/s)"]) for r in rows if r["Name"] == "HT" and "cup" in r["Sensor"]}
    out = [(h, ht[h] / rs[h] - 1) for h in sorted(ht) if h in rs]
    g = {r["Name"]: float(r["S(m/s)"]) for r in rows if r["Sensor"].strip().startswith("AES") and "gill" in r["Sensor"]
         and float(r["H(m)"]) == 10 and r["Name"] in ("RS", "HT")}
    out.append((10.0, g["HT"] / g["RS"] - 1))
    return sorted(out)


HS_LIN = np.array([2, 3, 5, 8, 10, 15, 24, 34, 50, 80, 120, 200], float)


def half_length():
    """L — полудлина холма на половине высоты вдоль ветра (среднее наветренной и подветренной), м; H — высота."""
    import matplotlib.tri as mtri
    P = read_map_lines()
    it = mtri.LinearTriInterpolator(mtri.Triangulation(P[:, 0], P[:, 1]), P[:, 2])
    ex, ey = 0.5, math.sqrt(3) / 2
    s = np.arange(-2000, 2001, 10.0)
    h = np.array([float(it(HT[0] + t * ex, HT[1] + t * ey)) for t in s])
    base = float(it(*RS))
    Hh = float(it(*HT)) - base
    up = -s[(s < 0) & (h < base + Hh / 2)].max()
    dn = s[(s > 0) & (h < base + Hh / 2)].min()
    return 0.5 * (up + dn), Hh


def linear_ref(dx=12.5, z0=0.03):
    """Независимый эталон: линейное потенциальное обтекание рельефа (FFT) и оно же со сдвигом среднего слоя.
    Возвращает dict(h, HT, CP, HT_shear, CP_shear, L, H, h_m)."""
    x0, y0, n, hc = terrain(dx)
    h = hc - np.median(hc)
    N = 2 * n
    m = int(1000 / dx)
    w = np.ones(n); w[:m] = np.sin(0.5 * np.pi * np.arange(m) / m) ** 2; w[-m:] = w[:m][::-1]
    H = np.zeros((N, N)); H[:n, :n] = h * np.outer(w, w)
    k = 2 * np.pi * np.fft.fftfreq(N, dx)
    KX, KY = np.meshgrid(k, k)
    kk = np.hypot(KX, KY); kk[0, 0] = 1.0
    ks = 0.5 * KX + math.sqrt(3) / 2 * KY
    Hh = np.fft.fft2(H)
    g = A.Grid(dx, n, n, dx / 2, 0.0, 2, x0, y0)
    from real import bil
    res = dict(h=HS_LIN.tolist(), HT=[], CP=[])
    for z in HS_LIN:
        u = np.real(np.fft.ifft2(ks ** 2 / kk * Hh * np.exp(-kk * z)))[:n, :n]
        r = bil(g, u, *RS)
        res["HT"].append((1 + bil(g, u, *HT)) / (1 + r) - 1)
        res["CP"].append((1 + bil(g, u, *CP)) / (1 + r) - 1)
    L, Hh_ = half_length()
    hm = L
    for _ in range(50):
        hm = L / math.sqrt(math.log(hm / z0))
    amp = np.maximum((math.log(hm / z0) / np.log(HS_LIN / z0)) ** 2, 1.0)
    res["HT_shear"] = (np.array(res["HT"]) * amp).tolist()
    res["CP_shear"] = (np.array(res["CP"]) * amp).tolist()
    res.update(L=L, H=Hh_, h_m=hm, dx=dx)
    return res


def run(dx, adv2=False, L=8000.0, top=1500.0):
    x0, y0, n, hc = terrain(dx, L)
    dz = dx / 2
    nz = int(math.ceil(top / dz)) + 1; nz += nz % 2
    g = A.Grid(dx, n, n, dz, -dz, nz, x0, y0)
    prm = A.Params(z0=0.03, alpha=0.17, max_profile=2.0, f_cor=1.22e-4, sponge_side_m=1000.0, adv2=adv2)
    case = A.Case(U10=8.9, wdir=210.0, gam=SY.const_gam(0.0))
    S = SY.run(g, hc, case, prm, max_outer=4000)
    u, v, w, th = S.centers()
    sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
    obs = read_obs()
    from real import bil
    res = dict(dx=dx, adv2=adv2, L=L, top=top, info=SY.info(S), points=[])
    for o in obs:
        s = bil(g, SY.agl(S, sp, o["h"]), o["x"], o["y"])
        s_ref = bil(g, SY.agl(S, sp, o["h"]), *RS)
        res["points"].append(dict(o, model=s / s_ref - 1))
    ht10 = [p for p in res["points"] if p["name"].startswith("HT") and p["h"] == 10]
    res["HT10_model"] = ht10[0]["model"] if ht10 else None
    res["HT10_obs"] = [p["fsr"] for p in ht10]
    res["RS_U10_model"] = bil(g, SY.agl(S, sp, 10.0), *RS)
    res["hc_max"] = float(hc.max())
    res["hc_HT"] = bil(g, hc, *HT)
    # разгон к RS на той же высоте над землёй; разброс в круге 150 м вокруг HT (ступенчатый рельеф:
    # первая воздушная клетка то на 5, то на 25 м над рельефом — выборка «на 10 м» зависит от места)
    X, Y = np.meshgrid(g.x, g.y)
    near = np.hypot(X - HT[0], Y - HT[1]) < 150.0
    res["by_height"] = []
    for h in (10.0, 30.0, 60.0, 100.0):
        s_h = SY.agl(S, sp, h)
        r = bil(g, s_h, *RS)
        f = np.where(near, s_h / r - 1, np.nan)
        res["by_height"].append(dict(h=h, HT=bil(g, s_h, *HT) / r - 1, CP=bil(g, s_h, *CP) / r - 1,
                                     HT_r150_min=float(np.nanmin(f)), HT_r150_max=float(np.nanmax(f)), RS=r))
    from types import SimpleNamespace
    res["fields"] = dict(g=g, hc=hc, sp=sp, S=SimpleNamespace(g=g, hc=S.hc, kb=S.kb))   # без массивов GPU
    del S
    import cupy
    cupy.get_default_memory_pool().free_all_blocks()
    print(f"Askervein dx {dx} adv2 {adv2}: {res['info']['status']} {res['info']['iters']} it, HT 10 м FSR модель {res['HT10_model']:.3f} против "
          f"{res['HT10_obs']}, max h {hc.max():.1f}", flush=True)
    return res


def fig(results, tag=""):
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
    lin = results[0]["linear"]
    axs[1].plot(lin["HT"], lin["h"], "k--", lw=1, label="линейное потенциальное (FFT)")
    axs[1].plot(lin["HT_shear"], lin["h"], "k:", lw=1.2, label="линейное + сдвиг среднего слоя")
    ob = obs_profile()
    axs[1].plot([o[1] for o in ob], [o[0] for o in ob], "ko", label="измерения HT (к RS на той же высоте)")
    axs[1].set_yscale("log"); axs[1].set_xlabel("ΔS/S_RS"); axs[1].set_ylabel("м над землёй")
    axs[1].set_title("Профиль разгона на вершине HT"); axs[1].legend(); axs[1].grid(alpha=0.3)
    r = results[-1]
    g = r["fields"]["g"]; S = r["fields"]["S"]
    s10 = SY.agl(S, r["fields"]["sp"], 10.0)
    im = axs[2].pcolormesh(g.x - HT[0], g.y - HT[1], s10, shading="auto", cmap="viridis")
    axs[2].contour(g.x - HT[0], g.y - HT[1], r["fields"]["hc"], levels=np.arange(10, 130, 20), colors="w", linewidths=0.5)
    axs[2].plot([0, CP[0] - HT[0], RS[0] - HT[0]], [0, CP[1] - HT[1], RS[1] - HT[1]], "r+", ms=10)
    axs[2].set_aspect("equal"); axs[2].set_xlim(-2500, 2500); axs[2].set_ylim(-2500, 2500)
    axs[2].set_title(f"Скорость на 10 м, {r['dx']:g} м (ветер 210°)"); fig.colorbar(im, ax=axs[2], label="м/с")
    fig.tight_layout()
    fig.savefig(OUT / f"fig_askervein{tag}.png", dpi=110)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dx", default="50,25")
    ap.add_argument("--adv2", action="store_true", help="ещё и с поправкой 2-го порядка")
    ap.add_argument("--L", type=float, default=8000.0, help="сторона области, м")
    ap.add_argument("--top", type=float, default=1500.0, help="потолок, м")
    ap.add_argument("--tag", default="", help="суффикс файлов (askervein_<tag>.json)")
    a = ap.parse_args()
    tag = f"_{a.tag}" if a.tag else ""
    results = [run(float(d), L=a.L, top=a.top) for d in a.dx.split(",")]
    if a.adv2:
        results += [run(float(d), adv2=True, L=a.L, top=a.top) for d in a.dx.split(",")]
    lin = linear_ref()
    for r in results:
        r["linear"] = lin
        r["obs_profile_same_height"] = obs_profile()
    fig(results, tag)
    out = [{k: v for k, v in r.items() if k != "fields"} for r in results]
    SY.jdump(out, OUT / f"askervein{tag}.json")
