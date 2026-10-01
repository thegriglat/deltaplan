#!/usr/bin/env python3
"""Сводка пачки WPC-3 (контракт К6): tools/research/wing_physics_check/out/penetration.csv.

python3 tools/flight/wind_penetration_table.py [--merge части.csv ...] [--csv penetration.csv]
  --merge — сначала собрать части (build/wpc3/parts/*.csv) в penetration.csv (ключ — key).
Пишет рядом с csv penetration_summary.md (таблицы) и penetration_by_wing.csv (крыло × ветер × трапеция
× старт → путевая против ветра на 30/100/200 м; − — сносит назад).
"""
import csv
import json
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tools/research/wing_physics_check/out"
HEADER = ("key,series,location,start,mode,wing,pilot_mass_kg,wind_set_ms,pitch,agl0_m,duration_s,"
          "gs_into_wind_ms,airspeed_ms,vz_ms,wind_h_ms,wind_w_ms,agl_end_m,climb_m,note").split(",")
GROUPS = ["soviet", "trainer", "kingpost", "topless"]


def args():
    a = sys.argv[1:]
    csv_path = OUT / "penetration.csv"
    merge = []
    i = 0
    while i < len(a):
        if a[i] == "--csv":
            csv_path = Path(a[i + 1])
            i += 2
        elif a[i] == "--merge":
            i += 1
            while i < len(a) and not a[i].startswith("--"):
                merge.append(Path(a[i]))
                i += 1
        else:
            sys.exit("неизвестный ключ " + a[i])
    return csv_path, merge


def read(path):
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        assert r.fieldnames == HEADER, f"{path}: заголовок не К6"
        return list(r)


def do_merge(csv_path, parts):
    rows = {}
    for p in ([csv_path] if csv_path.exists() else []) + parts:
        for r in read(p):
            rows[r["key"]] = r
    order = {"analytic": 0, "field": 1}
    out = sorted(rows.values(), key=lambda r: (order.get(r["mode"], 9), r["series"], r["location"],
                                                r["wing"], float(r["wind_set_ms"]),
                                                -float(r["pitch"]), float(r["agl0_m"])))
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, HEADER, quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
        w.writeheader()
        w.writerows(out)
    print(f"собрано {len(out)} строк → {csv_path}")


def groups():
    g = {}
    for p in (ROOT / "configs/wings").glob("*.json"):
        g[p.stem] = json.loads(p.read_text()).get("group", "?")
    return g


def f(x, d=1):
    return "—" if x is None else f"{x:+.{d}f}"


def mean(xs):
    xs = [x for x in xs if x is not None]
    return st.mean(xs) if xs else None


def num(r, k):
    return float(r[k]) if r[k] != "" else None


def main():
    csv_path, parts = args()
    if parts:
        do_merge(csv_path, parts)
    rows = read(csv_path)
    grp = groups()
    md = [f"# Пачка WPC-3: путевая против ветра и динамик\n",
          f"Данные: `{csv_path.resolve().relative_to(ROOT)}` ({len(rows)} строк, контракт К6). "
          "Путевая — средняя за последние 30 с вдоль направления «в ветер», м/с (− — сносит "
          "назад); ветер в точке `wind_h` — модуль горизонтального ветра там же. Масса пилота "
          "85 кг. Воспроизвести: `tools/flight/wind_penetration_batch.sh`, сводка — "
          "`python3 tools/flight/wind_penetration_table.py`.\n"]
    pen = [r for r in rows if r["series"] == "penetration"]
    ridge = [r for r in rows if r["series"] == "ridge"]
    modes = sorted({r["mode"] for r in rows}, key=lambda m: m != "analytic")
    agls = sorted({float(r["agl0_m"]) for r in pen})
    pitches = sorted({float(r["pitch"]) for r in pen}, reverse=True)

    # 1. по группам × старт: путевая (min по крыльям группы / среднее) и ветер в точке
    for mode in modes:
        md.append(f"\n## Путевая против ветра по группам крыльев — {mode}\n")
        md.append("Ячейка: среднее по крыльям группы (наименьшее), м/с; в скобках после старта — "
                  "средний ветер в точке wind_h на 30/100/200 м.\n")
        hdr = "| старт | ветер, м/с | трапеция | группа | " + " | ".join(
            f"{a:.0f} м" for a in agls) + " |"
        md.append(hdr)
        md.append("|" + "---|" * (4 + len(agls)))
        cell = defaultdict(list)
        wind = defaultdict(list)
        for r in pen:
            if r["mode"] != mode:
                continue
            k = (r["location"] + "/" + r["start"], float(r["wind_set_ms"]), float(r["pitch"]),
                 grp.get(r["wing"], "?"), float(r["agl0_m"]))
            cell[k].append(num(r, "gs_into_wind_ms"))
            wind[k[:2] + (float(r["agl0_m"]),)].append(num(r, "wind_h_ms"))
        sites = sorted({k[0] for k in cell})
        for s in sites:
            for wv in sorted({k[1] for k in cell if k[0] == s}):
                wtxt = "/".join(f"{mean(wind[(s, wv, a)]):.1f}" if mean(wind[(s, wv, a)]) else "—"
                                for a in agls)
                for p in pitches:
                    for g in GROUPS + ["?"]:
                        vals = [cell.get((s, wv, p, g, a)) for a in agls]
                        if not any(vals):
                            continue
                        cs = []
                        for v in vals:
                            v = [x for x in (v or []) if x is not None]
                            cs.append(f"{st.mean(v):+.1f} ({min(v):+.1f})" if v else "—")
                        md.append(f"| {s} (ветер {wtxt}) | {wv:g} | {p:g} | {g} | "
                                  + " | ".join(cs) + " |")

    # 2. сносит назад: строки с путевой < 0
    md.append("\n## Где сносит назад (путевая < 0)\n")
    back = defaultdict(list)
    for r in pen:
        g = num(r, "gs_into_wind_ms")
        if g is not None and g < 0:
            back[(r["mode"], r["location"] + "/" + r["start"], float(r["wind_set_ms"]),
                  float(r["pitch"]), float(r["agl0_m"]))].append((r["wing"], g, num(r, "wind_h_ms")))
    md.append("| режим | старт | ветер, м/с | трапеция | высота, м | крыльев | путевая, м/с (мин) | "
              "ветер в точке, м/с | крылья |")
    md.append("|" + "---|" * 9)
    total = defaultdict(int)
    for r in pen:
        total[(r["mode"], r["location"] + "/" + r["start"], float(r["wind_set_ms"]),
               float(r["pitch"]), float(r["agl0_m"]))] += 1
    for k in sorted(back):
        v = back[k]
        names = ", ".join(sorted(w for w, _, _ in v)) if len(v) <= 8 else f"{len(v)} крыльев"
        md.append(f"| {k[0]} | {k[1]} | {k[2]:g} | {k[3]:g} | {k[4]:.0f} | {len(v)}/{total[k]} | "
                  f"{min(g for _, g, _ in v):+.1f} | {mean([h for _, _, h in v]):.1f} | {names} |")

    # 3. динамик
    md.append("\n## Динамик: бот-восьмёрка у гребня, 3 мин, трим\n")
    md.append("Средний вариометр = набор / время полёта, м/с; набор, м; «земля» — сколько крыльев "
              "коснулись земли раньше 3 мин.\n")
    md.append("| режим | старт | ветер, м/с | группа | крыльев | вариометр, м/с (мин…макс) | "
              "набор, м (мин…макс) | земля |")
    md.append("|" + "---|" * 8)
    dyn = defaultdict(list)
    for r in ridge:
        dyn[(r["mode"], r["location"] + "/" + r["start"], float(r["wind_set_ms"]),
             grp.get(r["wing"], "?"))].append(r)
    for k in sorted(dyn, key=lambda k: (k[0] != "analytic", k[1], k[2], GROUPS.index(k[3])
                                        if k[3] in GROUPS else 9)):
        v = dyn[k]
        vs = [float(r["climb_m"]) / float(r["duration_s"]) for r in v]
        cl = [float(r["climb_m"]) for r in v]
        land = sum("земля" in r["note"] for r in v)
        md.append(f"| {k[0]} | {k[1]} | {k[2]:g} | {k[3]} | {len(v)} | {st.mean(vs):+.2f} "
                  f"({min(vs):+.2f}…{max(vs):+.2f}) | {st.mean(cl):+.0f} ({min(cl):+.0f}…"
                  f"{max(cl):+.0f}) | {land} |")
    (csv_path.parent / "penetration_summary.md").write_text("\n".join(md) + "\n")

    # 4. крыло × ветер × трапеция × старт → путевая на высотах (csv)
    by = defaultdict(dict)
    for r in pen:
        k = (r["mode"], r["wing"], grp.get(r["wing"], "?"), r["location"] + "/" + r["start"],
             r["wind_set_ms"], r["pitch"])
        by[k][float(r["agl0_m"])] = r["gs_into_wind_ms"]
    with open(csv_path.parent / "penetration_by_wing.csv", "w", newline="") as fo:
        w = csv.writer(fo, lineterminator="\n")
        w.writerow(["mode", "wing", "group", "site", "wind_set_ms", "pitch"]
                   + [f"gs_{a:.0f}m" for a in agls])
        for k in sorted(by):
            w.writerow(list(k) + [by[k].get(a, "") for a in agls])
    print("\n".join(md))


if __name__ == "__main__":
    main()
