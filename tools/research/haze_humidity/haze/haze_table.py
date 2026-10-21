"""HH-2: таблица видимости по часам, нынешняя и предлагаемая модель дымки.
Повторяет WeatherModel.diurnal_state (Parton–Logan) без вызова Godot. Запуск: python3 haze_table.py
"""
import csv, json, math

# configs/weather_model.json → diurnal
D = dict(peak_after_noon_h=2.5, sunset_fraction=0.65, night_tau_h=2.0, evening_haze_k=1.6)
RANGE_K_JUL = 11.0   # range_k[июль]
VIS_KM = 60.0        # configs/world.json → haze.visibility_km
GAMMA, RH0, RH_MAX = 0.6, 0.40, 0.95   # предложение (см. README)
# сценарии (июль, 15-е): tmax, td — по смыслу климата, не из сетки (её даст HH-1)
PLACES = {
    "dry_steppe":  dict(lat=51.87, lon=85.87, utc=7, tmax=30.0, td=5.0),   # Алтай, межгорная степь
    "humid_valley": dict(lat=54.0, lon=56.0, utc=5, tmax=25.0, td=13.0),   # Башкирия / влажная долина
}

def sun(lat, lon, utc, doy=196):
    noon = 12.0 - (4.0 * lon - 60.0 * utc) / 60.0
    decl = math.radians(23.44) * math.sin(math.tau * (284 + doy) / 365.0)
    c = max(-1, min(1, -math.tan(math.radians(lat)) * math.tan(decl)))
    half = math.degrees(math.acos(c)) / 15.0
    return noon, noon - half, noon + half

def temp(p, hour):
    noon, sr, ss = sun(p["lat"], p["lon"], p["utc"])
    peak = min(noon + D["peak_after_noon_h"], ss - 0.5)
    fs = D["sunset_fraction"]
    if hour <= sr: f = 0.0
    elif hour <= peak: f = math.sin(math.pi/2 * (hour - sr) / max(peak - sr, .1))
    elif hour <= ss: f = fs + (1-fs) * math.cos(math.pi/2 * (hour - peak) / max(ss - peak, .1))
    else: f = fs * math.exp(-(hour - ss) / D["night_tau_h"])
    return p["tmax"] - RANGE_K_JUL * (1 - f), peak, ss

def es(t):  # Магнус, Alduchov–Eskridge 1996, над водой, гПа
    return 6.1094 * math.exp(17.625 * t / (t + 243.04))

def rh(t, td): return min(es(td) / es(t), 1.0)

def haze_current(hour, peak, ss):
    return 1.0 + (D["evening_haze_k"] - 1.0) * max(0.0, min(1.0, (hour - peak) / max(ss - peak, .1)))

def haze_proposed(r):
    r = min(max(r, RH0), RH_MAX)
    return ((1 - r) / (1 - RH0)) ** (-GAMMA)

rows = []
for name, p in PLACES.items():
    for model in ("current", "proposed"):
        for h in range(6, 22):
            t, peak, ss = temp(p, h)
            r = rh(t, p["td"])
            k = haze_current(h, peak, ss) if model == "current" else haze_proposed(r)
            rows.append(dict(place=name, model=model, hour=h, t_c=round(t, 1), td_c=p["td"],
                             rh=round(r, 3), haze_k=round(k, 3), visibility_km=round(VIS_KM / k, 1)))
with open("visibility_by_hour.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)

# f(RH) по Zieger 2013 (Table 2) → gamma при RH0=0.40: f = 4**gamma для 85 %
z = {"CAB_continental_south": 1.86, "CAB_continental_east": 2.25, "CAB_all": 2.38,
     "MEL_all": 2.77, "MHD_polluted": 1.80, "NYA_arctic": 3.41, "JFJ_dust": 1.28}
gam = {k: round(math.log(v) / math.log((1 - 0.85) / (1 - RH0)) ** 1 * -1, 3) for k, v in z.items()}
summary = {"gamma_from_f85": gam, "gamma_used": GAMMA, "rh0": RH0, "rh_max": RH_MAX,
           "f85_model": round(haze_proposed(0.85), 3),
           "sunrise_sunset": {n: [round(x, 2) for x in sun(p["lat"], p["lon"], p["utc"])[1:]] for n, p in PLACES.items()},
           "min_vis_km": {f"{r['place']}/{r['model']}": None for r in rows}}
for n in PLACES:
    for m in ("current", "proposed"):
        v = [r["visibility_km"] for r in rows if r["place"] == n and r["model"] == m]
        summary["min_vis_km"][f"{n}/{m}"] = [min(v), max(v)]
json.dump(summary, open("numbers.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(summary, ensure_ascii=False, indent=1))
for r in rows:
    if r["hour"] in (6, 9, 12, 15, 18, 21): print(r)
