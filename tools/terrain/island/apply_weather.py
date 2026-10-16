"""TI-5: записать наборы погоды стартов (weather_sets.json) в configs/locations/training_island.json без пересборки
острова (то же, что делает build_island.config). python3 tools/terrain/island/apply_weather.py"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CFG = ROOT / "configs/locations/training_island.json"


def weather_sets():
    return {k: v for k, v in json.loads((HERE / "weather_sets.json").read_text()).items() if not k.startswith("_")}


def add_weather(start_sites):
    ws = weather_sets()
    for s in start_sites:
        if s["id"] in ws:
            s["weather"] = dict(ws[s["id"]])
    return start_sites


def main():
    cfg = json.loads(CFG.read_text())
    add_weather(cfg["start_sites"])
    CFG.write_text(json.dumps(cfg, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("weather:", ", ".join(s["id"] for s in cfg["start_sites"] if "weather" in s))


if __name__ == "__main__":
    main()
