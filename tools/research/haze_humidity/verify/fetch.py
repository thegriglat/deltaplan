"""Прогнозы Open-Meteo (без ключа) -> RAW/raw/<режим>_<модель>/<место>.json. Пауза ≥ 0,3 с между запросами.
Режимы: forecast (api.open-meteo.com, 16 дней вперёд от сегодня), summer (historical-forecast-api, июль 2025).
Запуск: python fetch.py forecast [модель=best_match] | python fetch.py summer [модель=best_match]"""
import json, os, sys, time, urllib.request, urllib.parse
from common import PLACES, RAW

mode = sys.argv[1]; model = sys.argv[2] if len(sys.argv) > 2 else "best_match"
out = f"{RAW}/raw/{mode}_{model}"; os.makedirs(out, exist_ok=True)
base = {"forecast": "https://api.open-meteo.com/v1/forecast", "summer": "https://historical-forecast-api.open-meteo.com/v1/forecast"}[mode]
q = {"hourly": "dew_point_2m,temperature_700hPa", "timezone": "UTC"}
if mode == "forecast":
    q["forecast_days"] = 16
else:
    q["start_date"] = "2025-07-01"; q["end_date"] = "2025-07-31"
if model != "best_match":
    q["models"] = model
n = 0
for name, lat, lon, _ in PLACES:
    f = f"{out}/{name}.json"
    if os.path.exists(f):
        continue
    url = base + "?" + urllib.parse.urlencode({**q, "latitude": lat, "longitude": lon})
    for attempt in range(5):
        try:
            data = urllib.request.urlopen(url, timeout=60).read(); break
        except Exception as e:
            print(name, "ошибка", e); time.sleep(5 * (attempt + 1))
    else:
        raise SystemExit("не удалось " + name)
    open(f, "wb").write(data); n += 1; time.sleep(0.4)
print(mode, model, "загружено", n, "->", out)
