#!/usr/bin/env python3
"""AM-08в: таблица «было / стало» по шести выгрузкам Онгудая (air_velocity_at и поле mean_wind_at).

Было — out/<имя>_air.json (cmp/wind-ongudai, до AM-08в), стало — out/am08v/<имя>_air.json.
Уровни AGL ≤ 200 м. Продольная составляющая — вдоль направления ветра (куда дует), м/с.
Зона отрыва — точки, где air «было» и «стало» различаются (> 1 мм/с в любой составляющей): поле
и признак отрыва lee_f у версий одни и те же, а эвристика (рывки, обратный поток) действует ровно
при lee_f > 0 и опасности > 0 и поменялась везде, где действовала; маска одна для «было» и
«стало» (сетки совпадают). air от поля отличается и вне зоны — фоновым опусканием погоды.
Пики с болтанкой — out/am08v/<имя>_turb_air.json (dump_wind --turb=40 --diag=1, только 9 м/с):
min w и σ_w по 40 моментам через 7,3 с в точке (в зоне — по маске выше; σ_w — вся болтанка:
механическая по сдвигу и u* поля и слоя смешения, большее); по точкам с признаком отрыва поля
lee_f > 0,5 и ΔU > 1 м/с — U_H, ΔU и отношения (diag: r, dx, lee_f, U_H из той же атмосферы).

python3 am08v_table.py   → am08v/table.md, am08v/table.csv
"""
import csv
import json
import math
import os

here = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(here, "am08v")
CASES = [
    ("base 3 м/с", "air"),
    ("base 9 м/с", "strong_air"),
    ("saddle 3 м/с", "saddle_air"),
    ("saddle 9 м/с", "saddle_strong_air"),
    ("mountain 3 м/с", "mountain_air"),
    ("mountain 9 м/с", "mountain_strong_air"),
]


def load(path):
    return json.load(open(path)) if os.path.exists(path) else None


def along(d):
    a = math.radians((d["cond"]["wind_from"] + 180.0) % 360.0)
    return math.sin(a), math.cos(a)  # (восток, север) — куда дует


def pct(xs, q):
    s = sorted(xs)
    return s[min(len(s) - 1, int(q * len(s)))] if s else float("nan")


def main():
    rows = []
    for label, name in CASES:
        was = load(os.path.join(here, "out", name + ".json"))
        now = load(os.path.join(here, "out", "am08v", name + ".json"))
        tur = load(os.path.join(here, "out", "am08v", name.replace("_air", "_turb_air") + ".json"))
        if was is None or now is None:
            print("нет данных:", name)
            continue
        assert was["grid"] == now["grid"]
        ex, ey = along(now)
        levels = sorted((int(k) for k in now["levels"] if int(k) <= 200))
        u_ref = None
        if "200" in now["levels"]:
            u_ref = pct([math.hypot(m[0], m[1]) for m in now["levels"]["200"]["mean"]], 0.95)
        for L in levels:
            k = str(L)
            wa, wm = was["levels"][k]["air"], was["levels"][k]["mean"]
            na, nm = now["levels"][k]["air"], now["levels"][k]["mean"]
            n = len(na)
            zone = [i for i in range(n) if max(abs(wa[i][j] - na[i][j]) for j in range(3)) > 1e-3]
            lon = lambda v: v[0] * ex + v[1] * ey
            r = {
                "вариант": label, "agl": L, "точек": n, "в зоне": len(zone),
                "w_min air было": min(v[2] for v in wa),
                "w_min air стало": min(v[2] for v in na),
                "w_min поле было": min(v[2] for v in wm),
                "w_min поле стало": min(v[2] for v in nm),
                "w зона air было": sum(wa[i][2] for i in zone) / len(zone) if zone else float("nan"),
                "w зона air стало": sum(na[i][2] for i in zone) / len(zone) if zone else float("nan"),
                "w зона поле": sum(nm[i][2] for i in zone) / len(zone) if zone else float("nan"),
                "возвр. % было": 100.0 * sum(lon(v) < 0 for v in wa) / n,
                "возвр. % стало": 100.0 * sum(lon(v) < 0 for v in na) / n,
                "возвр. % поле": 100.0 * sum(lon(v) < 0 for v in nm) / n,
                "u_прод min было": min(lon(v) for v in wa),
                "u_прод min стало": min(lon(v) for v in na),
                "u_прод min поле": min(lon(v) for v in nm),
                "U200 p95": u_ref if u_ref is not None else float("nan"),
            }
            if tur is not None and k in tur["levels"] and "turb" in tur["levels"][k]:
                t = tur["levels"][k]["turb"]
                dg = tur["levels"][k].get("diag")
                tz = zone if zone else list(range(n))
                r["болт. w_min зона"] = min(t[i][0] for i in tz)
                r["болт. σ_w зона"] = sum(t[i][1] for i in tz) / len(tz)
                if dg:
                    # по точкам с признаком отрыва поля: ΔU = max(U_H − |U|, 0)·lee_f
                    zz = [i for i in range(n) if dg[i][2] > 0.5]
                    du = {i: max(dg[i][3] - math.hypot(nm[i][0], nm[i][1]), 0.0) * dg[i][2] for i in zz}
                    zz = [i for i in zz if du[i] > 1.0]
                    r["lee_f>0,5 и ΔU>1: точек"] = len(zz)
                    if zz:
                        r["ΔU ср."] = sum(du[i] for i in zz) / len(zz)
                        r["U_H ср."] = sum(dg[i][3] for i in zz) / len(zz)
                        r["σ_w/ΔU ср."] = sum(t[i][1] / du[i] for i in zz) / len(zz)
                        r["min (w_min − w поля)/U_H"] = min((t[i][0] - nm[i][2]) / dg[i][3] for i in zz)
                        r["3σ_w/U_H ср."] = sum(3.0 * t[i][1] / dg[i][3] for i in zz) / len(zz)
            rows.append(r)
    os.makedirs(OUT, exist_ok=True)
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(os.path.join(OUT, "table.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for r in rows:
            w.writerow({k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()})

    def fmt(v):
        if isinstance(v, float):
            return "—" if math.isnan(v) else f"{v:.2f}"
        return str(v)

    md = ["# AM-08в: Онгудай, было / стало (air_velocity_at без болтанки; поле = mean_wind_at)", ""]
    md.append(__doc__.split("\n\n")[1].strip().replace("\n", " "))
    md.append("")
    t1 = ["вариант", "agl", "в зоне", "w_min air было", "w_min air стало", "w_min поле было",
          "w_min поле стало", "w зона air было", "w зона air стало", "w зона поле"]
    t2 = ["вариант", "agl", "возвр. % было", "возвр. % стало", "возвр. % поле",
          "u_прод min было", "u_прод min стало", "u_прод min поле"]
    t3 = ["вариант", "agl", "в зоне", "болт. w_min зона", "болт. σ_w зона",
          "lee_f>0,5 и ΔU>1: точек", "U_H ср.", "ΔU ср.", "σ_w/ΔU ср.", "3σ_w/U_H ср.",
          "min (w_min − w поля)/U_H"]
    for title, cols in (("Вертикаль, м/с", t1), ("Возвратное течение", t2),
                        ("С болтанкой (пики рывков), м/с", t3)):
        sel = [r for r in rows if all(c in r for c in cols)]
        if not sel:
            continue
        md += ["## " + title, "", "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
        md += ["| " + " | ".join(fmt(r[c]) for c in cols) + " |" for r in sel]
        md.append("")
    open(os.path.join(OUT, "table.md"), "w").write("\n".join(md))
    print("\n".join(md))


if __name__ == "__main__":
    main()
