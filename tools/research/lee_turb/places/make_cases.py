"""Случаи W8 (стенд dp-stand) и таблица станций LT-4 по местам ~/data/lee_turb/places.

  python3 make_cases.py [--places ~/data/lee_turb/places]
    → cases/perdigao_sw.json, cases/perdigao_ne.json, cases/askervein_tu03b.json, stations.csv, stations_check.md
Станции в кадре места — из <site>_stations.csv (export_place.gd). Точки случая — станции на высотах приборов
над землёй МОДЕЛИ (y = ground_game + высота прибора). Условия — нейтраль: ветер в пресете (скорость на 10 м,
направление), небо overcast + пелена 1, термики и конвективная болтанка выключены.
"""
import csv
import hashlib
import json
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
PLACES = Path.home() / "data/lee_turb/places"
if "--places" in sys.argv:
    PLACES = Path(sys.argv[sys.argv.index("--places") + 1]).expanduser()
PD = ROOT / "tools/research/data/perdigao/cases"
ASK = ROOT / "tools/research/data/askervein/askervein_validation1.txt"
KMH = 3.6

# U10 притока подобран calibrate_u10.py: MEAN модели (formula) на опорной точке = данные (tse04 100 м 8,82; tse13 100 м 8,79;
# RS 10 м 8,895 м/с), невязка ≤ 2 %. Это U10 игровой модели (профиль U10·(z/10)^α, α 0,24), не U10_IN решателя
# tools/research/cases (3,12/3,27/8,8: другой профиль и рост с высотой).
# Направление — по заданию 225°/45° (измеренное на опорной мачте — в extra.wdir_measured).
CASES = {
    "perdigao_sw": dict(
        site="perdigao", case="SW", seed=4001, wdir=225.0, u10=4.37, hour=11.0, wmean=PD / "sw_20170511_windowmean.csv",
        focus="tse04", ref="tse04", u100=8.8244, wdir_measured=216.4779,
        note="SW 2017-05-11 10 UTC (11 ч WEST): ветер через ЮЗ-гряду (tse04) в долину; опора U100 tse04",
    ),
    "perdigao_ne": dict(
        site="perdigao", case="NE", seed=4002, wdir=45.0, u10=4.37, hour=19.0, wmean=PD / "ne_20170427_windowmean.csv",
        focus="tse13", ref="tse13", u100=8.791, wdir_measured=60.7472,
        note="NE 2017-04-27 17-19 UTC (19 ч WEST, середина окна): ветер через СВ-гряду (tse13) в долину; опора U100 tse13",
    ),
    "askervein_tu03b": dict(
        site="askervein", case="TU03B", seed=4003, wdir=210.0, u10=8.04, hour=13.0, wmean=None,
        focus="HT", ref="RS", u100=None, wdir_measured=210.0,
        note="TU-03B 1983-10-03: набегающий ветер 210°, S(RS, 10 м) = 8,895 м/с (askervein_inlet1.txt); холм — вершина HT",
    ),
}
CFG_NAMES = ["atmosphere", "surface_heat", "weather_model"]


def stations(site):
    p = PLACES / f"{site}_stations.csv"
    return {r["station"]: r for r in csv.DictReader(open(p))}


def conditions(c):
    base = json.load(open(ROOT / "configs/weather/weak.json"))
    p = {k: v for k, v in base.items() if not k.endswith("_doc")}
    p.update(
        _doc="LT-4: нейтраль для сверки с измерениями: небо overcast + пелена 1 (прогрев на порядок слабее), термиков и конвективной болтанки нет; ветер — набегающий поток (скорость на 10 м, откуда).",
        wind_speed_kmh=round(c["u10"] * KMH, 3), wind_from_deg=c["wdir"], sky="overcast", cirrus_cover=1.0,
        thermal_mode="static", static_thermals=[], thermal_duty=0.0, background_sink_ms=0.0,
        convective_turbulence_ms=0.0, cb_chance=0.0, wave_strength=0.0, dust_devil_chance=0.0,
        overdevelopment_chance=0.0, thermal_extreme_chance=0.0, street_strength=0.0,
    )
    return {"blend_s": None, "preset": p, "rebuild": False, "speed": 1.0, "start_hour": c["hour"]}


def mast_points(c, st):
    """[(станция, высота_над_землёй, подпись)]: Perdigão — уровни из windowmean; Askervein — validation1."""
    out = []
    if c["wmean"] is not None:
        for r in csv.DictReader(open(c["wmean"])):
            if r["site"] in st:
                out.append((r["site"], float(r["z_agl_m"])))
    else:
        seen = set()
        for r in csv.DictReader(open(ASK)):
            name = r["Name"].replace(" ", "")
            key = (name, r["H(m)"])
            if name in st and key not in seen:
                seen.add(key)
                out.append((name, float(r["H(m)"])))
    return out


def main():
    gen = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    sha = {n: hashlib.sha1((ROOT / f"configs/{n}.json").read_bytes()).hexdigest() for n in CFG_NAMES}
    rows, check = [], []
    (HERE / "cases").mkdir(exist_ok=True)
    for name, c in CASES.items():
        st = stations(c["site"])
        pts = mast_points(c, st)
        points, labels = [], []
        for sname, z in pts:
            r = st[sname]
            points.append([round(float(r["x_game"]), 2), round(float(r["ground_game_m"]) + z, 2), round(float(r["z_game"]), 2)])
            labels.append(f"{sname}_{z:g}m")
        f = st[c["focus"]]
        case = {
            "version": 1, "place": c["site"], "conditions": conditions(c), "seed": c["seed"], "static_thermals": [],
            "configs_sha1": sha, "times_s": [0.0],
            "focuses": [[float(f["x_game"]), float(f["ground_game_m"]), float(f["z_game"]), 1.0]],
            "points": points, "point_tags": ["mast"] * len(points), "terms": None, "generator": gen,
            "extra": {
                "note": c["note"], "case": c["case"], "point_labels": labels, "u10_in": c["u10"],
                "u10_rule": "calibrate_u10.py: MEAN модели formula на опорной точке = данные",
                "ref_station": c["ref"], "u100_ref_obs": c["u100"], "wdir_measured": c["wdir_measured"],
                "focus_station": c["focus"], "neutral": "overcast+cirrus 1, без термиков/конвективной болтанки; стратификацию задаёт Weather места",
            },
        }
        (HERE / "cases" / f"{name}.json").write_text(json.dumps(case, ensure_ascii=False, indent=1) + "\n")
        for sname in dict.fromkeys(s for s, _ in pts):
            r = st[sname]
            rows.append([c["site"], c["case"], sname, r["lat"], r["lon"], r["x_game"], r["z_game"], r["ground_game_m"], r["ground_asl_m"]])
        print(name, len(points), "точек", len(set(s for s, _ in pts)), "станций")
    with open(HERE / "stations.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["site", "case", "station", "lat", "lon", "x_game", "z_game", "ground_game_m", "ground_asl_m"])
        w.writerows(rows)
    for site in ("perdigao", "askervein"):
        d = [float(r[7]) - float(r[8]) for r in rows if r[0] == site]
        names = {r[2] for r in rows if r[0] == site}
        dd = {}
        for r in rows:
            if r[0] == site:
                dd[r[2]] = float(r[7]) - float(r[8])
        v = list(dd.values())
        worst = max(dd, key=lambda k: abs(dd[k]))
        s = (f"{site}: мачт {len(v)}, ground_game − ground_asl: медиана {statistics.median(v):+.1f} м, "
             f"среднее {statistics.mean(v):+.1f} м, максимум по модулю {dd[worst]:+.1f} м ({worst}), "
             f"|Δ| ≤ 10 м у {sum(abs(x) <= 10 for x in v)} из {len(v)}")
        check.append(s)
        print(s)
    (HERE / "stations_check.md").write_text("\n".join("- " + s for s in check) + "\n")


if __name__ == "__main__":
    main()
