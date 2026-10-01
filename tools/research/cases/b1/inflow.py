"""Б1: данные притока для правила насыщения степенного профиля (z_sat).

Askervein — мачта RS (чашки AES 3–49 м, змей BRE 30–267 м), S(z)/S(10 м).
Perdigão — RHI-лидары DTU (композиты А4, cases/rhi_*.npz): SW — WS1 на гребне tse04 смотрит против ветра (аз. 235°),
NE — WS3 на гребне tse13 смотрит по ветру над долиной (выше ~200 м над гребнем возмущение долины мало).
Горизонтальная скорость ≈ лучевая / (cos угла места · cos(азимут луча − направление ветра)); w не учитывается
(на углах места ≤ 16° вклад w sin(el) ≤ 0,15 м/с). Высота — над равниной притока (средняя земля 1,5–3 км против ветра
по DSM, ≈ 230 м н. у. м. в обоих подслучаях).

  python inflow.py   → out/inflow.json, out/fig_inflow.png
"""
from __future__ import annotations

import csv
import json
import math
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import rules as RU          # noqa: E402
import perdigao as PD       # noqa: E402
import askervein as AK      # noqa: E402

OUT = HERE / "out"
C = ["#2a78d6", "#eb6834", "#1baf7a"]


def upstream_ground(wdir):
    T = PD._terrain10()
    X, Y = np.meshgrid(T["x"], T["y"])
    a = math.radians(wdir)
    s = X * math.sin(a) + Y * math.cos(a)
    t = -X * math.cos(a) + Y * math.sin(a)
    m = (s >= 1500) & (s < 3000) & (np.abs(t) < 1000)
    return float(T["dsm"][m].mean())


def lidar_profile(f, wdir, bins):
    z = np.load(PD.DATA / "cases" / f)
    el = z["elev_deg"].astype(float)
    r = z["range_m"]
    v = z["vel_mean"]
    az = float(z["azimuth_deg"])
    cosd = math.cos(math.radians(az - (wdir + 180.0)))
    X = r[None, :] * np.cos(np.radians(el))[:, None]
    Zr = r[None, :] * np.sin(np.radians(el))[:, None]
    U = np.abs(v / np.cos(np.radians(el))[:, None] / cosd)
    out = []
    for z0, z1 in bins:
        sel = (Zr >= z0) & (Zr < z1) & (X > 200) & (X < 2500) & np.isfinite(U)
        if sel.sum() > 20:
            q = U[sel]
            out.append(dict(z_lidar=0.5 * (z0 + z1), U=float(np.median(q)), q25=float(np.percentile(q, 25)),
                            q75=float(np.percentile(q, 75)), n=int(sel.sum())))
    return out, float(z["lidar_xyz_pt_tm06"][2])


def main():
    OUT.mkdir(exist_ok=True)
    res = {}
    # --- Askervein RS
    rows = [r for r in csv.DictReader(open(AK.DATA)) if r["Name"] == "RS"]
    u10 = [float(r["S(m/s)"]) for r in rows if r["H(m)"] == "10" and "gill" in r["Sensor"]][0]
    prof = sorted((float(r["H(m)"]), float(r["S(m/s)"]) / u10, r["Sensor"]) for r in rows
                  if ("cup" in r["Sensor"] or "kite" in r["Sensor"]) and float(r["H(m)"]) >= 10)
    zs_a = RU.z_sat(AK.U10_IN, AK.NOM["z0"], AK.F_COR)
    kite = {h: s for h, s, k in prof if "kite" in k}
    loc = {f"{a:g}-{b:g}": math.log(kite[b] / kite[a]) / math.log(b / a) for a, b in ((70, 116), (116, 178), (178, 267))}
    res["askervein"] = dict(profile=[dict(z=h, S_U10=s, sensor=k) for h, s, k in prof], local_alpha_kite=loc,
                            z_sat_rule=zs_a, h_mech=RU.h_mech(AK.U10_IN, AK.NOM["z0"], AK.F_COR))
    # --- Perdigão
    bins = [(z, z + 50) for z in range(0, 300, 50)] + [(z, z + 100) for z in range(300, 900, 100)]
    for sub, f in (("sw", "rhi_sw_20170511_WS1.npz"), ("ne", "rhi_ne_20170427_WS3.npz")):
        inp = PD.case_inputs(sub)
        pr, zlid = lidar_profile(f, inp["wdir"], bins)
        g = upstream_ground(inp["wdir"])
        for p in pr:
            p["z_agl_up"] = p["z_lidar"] + zlid - g
        Umax = max(p["U"] for p in pr)
        # насыщение: нижняя высота, где медиана достигает 97 % максимума профиля
        zsat_d = min(p["z_agl_up"] for p in pr if p["U"] >= 0.97 * Umax)
        zs = RU.z_sat(PD.U10_IN[sub], PD.z0_nominal(), PD.F_COR)
        res[f"perdigao_{sub}"] = dict(file=f, lidar_z_asl=zlid, upstream_ground_asl=g, profile=pr, U100_crest=inp["u100"],
                                      z_sat_data_97=zsat_d, z_sat_rule=zs,
                                      h_mech=RU.h_mech(PD.U10_IN[sub], PD.z0_nominal(), PD.F_COR))
    (OUT / "inflow.json").write_text(json.dumps(res, indent=1, ensure_ascii=False))

    fig, ax = plt.subplots(1, 2, figsize=(11, 5))
    a = ax[0]
    for sens, mk, lab in (("cup", "o", "RS чашки"), ("kite", "s", "RS змей")):
        pts = [(s, h) for h, s, k in prof if sens in k]
        a.plot(*zip(*pts), mk, color=C[0] if sens == "cup" else C[1], ms=6, label=lab)
    z = np.linspace(10, 600, 200)
    for al in (0.235,):
        a.plot(np.minimum((z / 10) ** al, (zs_a / 10) ** al), z, "-", color="#555", lw=2,
               label=f"α {al}, z_sat = 0,3h = {zs_a:.0f} м")
        a.plot(np.minimum((z / 10) ** al, 2.0), z, ":", color="#555", lw=2, label="α 0,235, max_profile 2,0 (recal)")
    a.set_xlabel("S(z)/S(10 м)")
    a.set_ylabel("высота над землёй RS, м")
    a.set_title("Askervein TU-03B: приток (RS)")
    a.legend(fontsize=8, loc="upper left")
    a.grid(alpha=0.3)
    a = ax[1]
    for i, sub in enumerate(("ne", "sw")):
        d = res[f"perdigao_{sub}"]
        zz = [p["z_agl_up"] for p in d["profile"]]
        a.plot([p["U"] for p in d["profile"]], zz, "o-", color=C[i], lw=2, ms=6,
               label=f"{sub.upper()} лидар ({d['file'][-7:-4]}), z_sat данных ≈ {d['z_sat_data_97']:.0f} м")
        a.fill_betweenx(zz, [p["q25"] for p in d["profile"]], [p["q75"] for p in d["profile"]], color=C[i], alpha=0.15, lw=0)
        a.axhline(d["z_sat_rule"], color=C[i], ls="--", lw=1.5, label=f"{sub.upper()} z_sat правила {d['z_sat_rule']:.0f} м")
        a.axhline(d["lidar_z_asl"] - d["upstream_ground_asl"], color=C[i], ls=":", lw=1)
    a.set_xlabel("горизонтальная скорость, м/с (медиана, 25–75 %)")
    a.set_ylabel("высота над равниной притока, м")
    a.set_title("Perdigão: над гребнем (RHI; пунктир — высота лидара)")
    a.legend(fontsize=8, loc="lower right")
    a.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(OUT / "fig_inflow.png", dpi=110)
    print(json.dumps({k: {kk: vv for kk, vv in v.items() if kk != "profile"} for k, v in res.items()}, indent=1,
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
