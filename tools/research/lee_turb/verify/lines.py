#!/usr/bin/env python3
"""LT-12: линии разрезов LTS по ветру через станции места. Пишет out/lines.json и out/lines.sh-список (name from to ys).

Линия = направление ветра случая (wind_from_deg из случая стенда), смещение поперёк (cross) - кластеры станций шириной <= 250 м (цепочкой).
Координаты игры: x восток, z юг (север = -z). along = x*dx+z*dz, cross = -x*dz+z*dx, (dx,dz) - куда дует ветер.
"""
import csv, json, math, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
LT = os.path.abspath(os.path.join(HERE, ".."))
CASES = {  # case_json, site, obs case, опорная (гребневая) станция, H для границ (из LTO H_m)
    "perdigao_sw": ("perdigao", "SW", "tse04", 167.7),
    "perdigao_ne": ("perdigao", "NE", "tse13", 147.6),
    "askervein_tu03b": ("askervein", "TU03B", "HT", 116.0),
}
STEP = 10.0
CLUSTER = 250.0


def frame(case_json):
    c = json.load(open(os.path.join(LT, "places", "cases", case_json + ".json")))
    wf = c["conditions"]["preset"]["wind_from_deg"]
    to = math.radians(wf + 180.0)
    return wf, math.sin(to), -math.cos(to)


def build():
    st = list(csv.DictReader(open(os.path.join(LT, "places", "stations.csv"), encoding="utf-8")))
    out = {}
    for cj, (site, oc, crest, H) in CASES.items():
        wf, dx, dz = frame(cj)
        S = [s for s in st if s["site"] == site and s["case"] == oc and s["station"] != "RS"]
        rows = []
        for s in S:
            x, z = float(s["x_game"]), float(s["z_game"])
            rows.append(dict(station=s["station"], x=x, z=z, a=x * dx + z * dz, c=-x * dz + z * dx, g=float(s["ground_game_m"])))
        cr = [r for r in rows if r["station"] == crest][0]
        rows.sort(key=lambda r: r["c"])
        groups = []
        for r in rows:
            if groups and r["c"] - groups[-1][0]["c"] <= CLUSTER:
                groups[-1].append(r)
            else:
                groups.append([r])
        lines = []
        for k, gr in enumerate(groups):
            if crest in [r["station"] for r in gr]:
                cc = cr["c"]
            else:
                cc = 0.5 * (gr[0]["c"] + gr[-1]["c"])
            lines.append(dict(name="%s_L%02d" % (cj, k), cross=cc, members=[r["station"] for r in gr]))
        a0 = min(min(r["a"] for r in rows) - 100.0, cr["a"] - 2 * H)
        a1 = max(max(r["a"] for r in rows) + 100.0, cr["a"] + 8 * H)
        a1 = max(a1, cr["a"] + 14 * H)                     # подножие H ищется на 1500 м по ветру
        gmax = max(r["g"] for r in rows)
        for ln in lines:
            ln["from"] = [round(a0 * dx - ln["cross"] * dz, 1), round(a0 * dz + ln["cross"] * dx, 1)]
            ln["to"] = [round(a1 * dx - ln["cross"] * dz, 1), round(a1 * dz + ln["cross"] * dx, 1)]
            ln["a0"], ln["a1"] = a0, a1
        out[cj] = dict(wind_from=wf, dir=[dx, dz], crest=crest, crest_a=cr["a"], crest_cross=cr["c"], H=H,
                       y0=float(math.floor((min(r["g"] for r in rows) - 60.0) / 10) * 10), y1=float(math.ceil((cr["g"] + 2 * H) / 10) * 10),
                       lines=lines, stations={r["station"]: r for r in rows})
    return out


if __name__ == "__main__":
    o = build()
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    json.dump(o, open(os.path.join(HERE, "out", "lines.json"), "w"), ensure_ascii=False, indent=1)
    for cj, v in o.items():
        print(cj, "H", v["H"], "ys", v["y0"], v["y1"], "lines", len(v["lines"]), [round(l["cross"]) for l in v["lines"]])
