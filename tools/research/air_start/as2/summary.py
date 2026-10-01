#!/usr/bin/env python3
"""AS-2: сводка зонда (probe_test_as2probe.gd.txt) — ряды ветра на 1,5 м у старта и разбор по членам.

summary.py <каталог> <метка> [<метка> …]  → печать таблицы (markdown) и <каталог>/<метка>_summary.csv

Ряд: Ū — модуль среднего вектора горизонтали за 20 с; σu, σv — вдоль/поперёк среднего; σw, w̄;
σθ — СКО направления от среднего; max|θ| — наибольшее отклонение направления от среднего за 20 с;
max|ΔU| — наибольшее изменение модуля горизонтали за 0,5 с (как CF-1, summary2).
Теория (подобие приземного слоя) — для u* в точке u*_pt = κ·U_поле(z)/ln(z/z0), z — высота точки над
землёй (как в модели), z/L по w*, z_i поля: L = −u*³ z_i/(κ w*³) (w* = 0 — нейтраль):
  σw = 1,25 u* (1 + 3|z/L|)^(1/3) (Panofsky et al. 1977; Kaimal & Finnigan 1994, §1.6);
  σu = u* (12 + 0,5 z_i/|L|)^(1/3) в неустойчивом, 2,4 u* в нейтрали (Panofsky et al. 1977;
  Panofsky & Dutton 1984); σv = u* (1,9³ + 0,5 z_i/|L|)^(1/3) (1,9 u* в нейтрали);
  σθ ≈ σv/Ū (Ū — среднее поле в точке).
"""
import csv
import glob
import json
import math
import os
import sys

import numpy as np

KAPPA = 0.4


def series(path):
    r = list(csv.DictReader(open(path)))
    u = np.array([float(x["wu"]) for x in r])
    v = np.array([float(x["wv"]) for x in r])
    w = np.array([float(x["ww"]) for x in r])
    mu, mv = u.mean(), v.mean()
    U = math.hypot(mu, mv)
    e = np.array([mu, mv]) / max(U, 1e-6)
    al = u * e[0] + v * e[1]
    cr = -u * e[1] + v * e[0]
    th = np.degrees(np.arctan2(cr, al))
    sp = np.hypot(u, v)
    n = 5
    return dict(
        U=U, su=al.std(), sv=cr.std(), sw=w.std(), wm=w.mean(), sth=th.std(),
        thmax=np.abs(th).max(), dU=np.abs(sp[n:] - sp[:-n]).max(), rev=float((al < 0).mean()),
    )


def theory(d):
    tb = d["tb"]
    z0 = d["z0"]
    z = max(d["agl"], 1.0)
    uf = d["uf"]
    us = KAPPA * uf / math.log(max(z, 2 * z0) / z0)
    ws = tb["T_WSTAR"]
    zi = tb["T_HMIX"]
    if ws > 0 and zi > 0:
        L = -(us**3) * zi / (KAPPA * ws**3)
        zl = z / L
        ziL = zi / abs(L)
        sw = 1.25 * us * (1 + 3 * abs(zl)) ** (1 / 3)
        su = us * (12 + 0.5 * ziL) ** (1 / 3)
        sv = us * (1.9**3 + 0.5 * ziL) ** (1 / 3)
    else:
        L = math.inf
        zl = 0.0
        sw, su, sv = 1.25 * us, 2.4 * us, 1.9 * us
    return dict(ustar=us, L=L, zl=zl, sw=sw, su=su, sv=sv, sth=math.degrees(sv / max(uf, 0.1)))


def slope_w(d):
    fw = d["fw"]
    g = d["grad_h"]
    return fw[0] * g[0] + fw[2] * g[1]


def main():
    out_dir = sys.argv[1]
    for tag in sys.argv[2:]:
        rows = []
        for line in open(os.path.join(out_dir, f"{tag}_decomp.jsonl")):
            d = json.loads(line)
            loc, kmh = d["case"].split(":")
            name = f"{loc.replace('/', '-')}-{kmh}-{d['seed']}"
            row = dict(case=d["case"], seed=d["seed"], a=d["a"], agl=d["agl"])
            for kind in ["fixed", "idle"]:
                p = os.path.join(out_dir, f"{tag}_{name}_{kind}.csv")
                if os.path.exists(p):
                    for k, v in series(p).items():
                        row[f"{kind}_{k}"] = v
            th = theory(d)
            for k, v in th.items():
                row[f"th_{k}"] = v
            pr = d["mean_prof"]
            u10 = math.hypot(pr["10.0"][0], pr["10.0"][2])
            row.update(
                uf=d["uf"], u10=u10, w_field=d["fw"][1], w_slope=slope_w(d),
                T_USTAR=d["tb"]["T_USTAR"], lS=d["lmix_shear"], wstar=d["tb"]["T_WSTAR"],
                zi=d["tb"]["T_HMIX"], lee_f=d["lee_f"], du=d["du"], rev_ms=d["reverse_ms"],
                s_u=d["sigma"][0], s_w=d["sigma"][1], L_u=d["sigma"][2], L_w=d["sigma"][3],
                su_mech=d["sigma_mech"][0], sw_mech=d["sigma_mech"][1],
                su_conv=d["sigma_conv"][0], sw_conv=d["sigma_conv"][1],
                su_sep=d["sigma_sep"][0], sw_sep=d["sigma_sep"][1], advect=d["advect"],
                s_v=d.get("sigma_v", d["sigma"][0]),
            )
            rows.append(row)
        keys = list(rows[0].keys())
        for r in rows:
            for k in r:
                if k not in keys:
                    keys.append(k)
        with open(os.path.join(out_dir, f"{tag}_summary.csv"), "w", newline="") as f:
            wr = csv.DictWriter(f, fieldnames=keys)
            wr.writeheader()
            for r in rows:
                wr.writerow({k: (f"{v:.4g}" if isinstance(v, float) else v) for k, v in r.items()})
        print(f"\n## {tag}: ряд в неподвижной точке (fixed) и как CF-1 (idle), 1,5 м над стартом")
        print("| старт, км/ч | сид | U10 | Ū поле | u*_pt | T_USTAR | z/L | σw мод/теор | σu мод/теор | σv мод/теор | σθ ряд/теор | w̄ / U·∇h | max|θ| | max|ΔU| 0,5 с | idle: Ū σw σθ max|θ| max|ΔU| |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in rows:
            print(
                f"| {r['case']} | {r['seed']} | {r['u10']:.2f} | {r['uf']:.2f} | {r['th_ustar']:.2f} | {r['T_USTAR']:.2f} | {r['th_zl']:.3f} | "
                f"{r['s_w']:.2f}/{r['th_sw']:.2f} ({r['fixed_sw']:.2f}) | {r['s_u']:.2f}/{r['th_su']:.2f} ({r['fixed_su']:.2f}) | "
                f"{r['s_v']:.2f}/{r['th_sv']:.2f} ({r['fixed_sv']:.2f}) | {r['fixed_sth']:.0f}°/{r['th_sth']:.0f}° | "
                f"{r['fixed_wm']:.2f}/{r['w_slope']:.2f} | {r['fixed_thmax']:.0f}° | {r['fixed_dU']:.2f} | "
                f"{r.get('idle_U', float('nan')):.2f} {r.get('idle_sw', float('nan')):.2f} {r.get('idle_sth', float('nan')):.0f}° {r.get('idle_thmax', float('nan')):.0f}° {r.get('idle_dU', float('nan')):.2f} |"
            )
        print(f"\n## {tag}: разбор σ по членам (модель, в точке)")
        print("| старт, км/ч | сид | σu мех | σw мех | σu конв | σw конв | σu отрыв | σw отрыв | lee_f | обр. поток | L_u | L_w | w* | z_i | advect |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in rows:
            print(
                f"| {r['case']} | {r['seed']} | {r['su_mech']:.2f} | {r['sw_mech']:.2f} | {r['su_conv']:.2f} | {r['sw_conv']:.2f} | "
                f"{r['su_sep']:.2f} | {r['sw_sep']:.2f} | {r['lee_f']:.2f} | {r['rev_ms']:.2f} | {r['L_u']:.0f} | {r['L_w']:.1f} | "
                f"{r['wstar']:.2f} | {r['zi']:.0f} | {r['advect']:.1f} |"
            )


if __name__ == "__main__":
    main()
