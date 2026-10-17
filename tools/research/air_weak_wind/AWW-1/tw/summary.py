"""TW-2: сводка прогонов probe.tscn → runs.csv (строка на прогон).
python3 summary.py <метка> [метка…] > runs.csv
Колонки: метка, вариант, k притока, U на 10 м по журналу (start_speed), горизонталь среднего поля на 10 м
(mean_wind_at) и по уровням (окно 50, окно 100, область 400 м), итераций [без нагрева, с нагревом] области,
доля заморозки фаз, фазы D/F/H, w у старта (полный воздух: среднее/макс за 60 с) на 2, 10, 20 м,
наибольшая вертикальная скорость аппарата для obs1."""
import csv, glob, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
cols = ["tag", "variant", "inflow_k", "u10_log", "u10_mean", "u10_dx50", "u10_dx100", "u10_dx400", "u100_mean",
        "dir10_from_deg", "iters", "frozen_frac", "phase_D", "phase_F", "phase_H",
        "w2_mean", "w2_max", "w10_mean", "w10_max", "w20_mean", "w20_max", "obs1_vy_max", "obs1_air_w_max", "obs1_agl_max", "obs1_ended"]
w = csv.DictWriter(sys.stdout, fieldnames=cols)
w.writeheader()
for tag in sys.argv[1:]:
    for js in sorted(glob.glob(os.path.join(HERE, "out", tag, "*.json"))):
        d = json.load(open(js))
        li = d.get("last_info", {})
        r = {"tag": tag, "variant": os.path.basename(js)[:-5], "inflow_k": li.get("inflow_k"),
             "u10_log": li.get("u_start10"), "iters": li.get("iters"), "frozen_frac": li.get("frozen_frac")}
        pf = li.get("phase_frac") or {}
        for ph in "DFH":
            r["phase_" + ph] = round(pf.get(ph, float("nan")), 3) if pf else ""
        c = d.get("column")
        if c:
            for row in c["rows"]:
                if row["agl"] == 10.0:
                    r["u10_mean"] = round(row["mean_h"], 3)
                    mx, mz = row["mean"][0], row["mean"][1]
                    r["dir10_from_deg"] = round(math.degrees(math.atan2(-mx, mz)) % 360, 0)  # x — восток, z — юг
                    for k, v in row.get("levels", {}).items():
                        r["u10_" + k] = round(math.hypot(v[0], v[1]), 3)
                if row["agl"] == 100.0:
                    r["u100_mean"] = round(row["mean_h"], 3)
        s = d.get("series")
        if s:
            for a in ("2.0", "10.0", "20.0"):
                n = a.split(".")[0]
                r[f"w{n}_mean"] = round(s[a]["w"]["mean"], 3)
                r[f"w{n}_max"] = round(s[a]["w"]["max"], 3)
        o = d.get("obs1")
        if o:
            rows = o["rows"]
            r["obs1_vy_max"] = round(max(x["vy"] for x in rows), 2)
            r["obs1_air_w_max"] = round(max(x["air_w"] for x in rows), 2)
            r["obs1_agl_max"] = round(max(x["agl"] for x in rows), 1)
            r["obs1_ended"] = "|".join(o["ended"]) + f"@{rows[-1]['t']:.1f}s"
        w.writerow(r)
