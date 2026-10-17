---
type: "research"
status: "active"
module: "cloud-field"
area: "air"
updated: "2026-10-17"
summary: "CLF-1: карты поля облачности — день 9→17 ч над Онгудаем, островом и Алматы в 3 погодах; команды, файлы, summary.json"
related: ["docs/research/cloud_field.md", "docs/contracts/cloud-field.md"]
conclusion: "Карты — build/screenshots/cloud-field/CLF-1/; числа — out/summary.json; вывод — docs/research/cloud_field.md"
data: "tools/research/cloud_field/"
applied_in: "scripts/atmosphere/cloud_field.gd"
---
# CLF-1: карты поля облачности — как получены

Модель, законы и вывод — `docs/research/cloud_field.md`. Здесь — команды и файлы.

## Файлы
| файл | что |
|---|---|
| `dump.gd`, `dump.tscn`, `run.sh` | день над местом: `Terrain.load_location` (ongudai, training_island) / `Terrain.load_point(43.2, 76.9)` (almaty) → на каждый час 9…17 поле воздуха как в игре (`AirRuntime.load_field`, фазы + Пикар на GPU; `_solve` — копия из `tools/research/thermal_drainage/dump.gd` ветки `research/thermal-drainage`) → `AirThermals` → `CloudField.set_inputs`; поле облачности интегрируется 9:00→17:00 (поле часа H действует с H − 0,5 до H + 0,5 ч), ход покрытия — раз в 10 мин. Кадры `out/<место>_<погода>_h<11|13|15>.json` (сетка 400 м: рельеф, Φ, потолок частицы, a_u, cover/depth/stage/activity, источники, LCL, ветер основания, рельеф 200 м), ход — `out/<место>_<погода>_series.json` |
| `plot.py` | листы `fig/<место>_<погода>.png` (кадры 11/13/15 ч, разрез поперёк хребта в 13 ч, ход покрытия, источник a_u) и сводка `out/summary.json` (13 ч) |
| `out/summary.json` | в git; слепки `out/*.json` — вне git (`.gitignore`), ~0,5 МБ каждый |

## Погоды
`weak` — прогноз +20 °C, ветер 6 км/ч с 270° (опорный прогноз `configs/weather/weak.json`); `strong` — +31 °C, 18 км/ч с 270°
(`configs/weather/strong.json`); `windy` — +31 °C, 8 м/с (28,8 км/ч) с типичного направления: Онгудай 300°, остров 270°,
Алматы 270° (вдоль главного хребта Заилийского Алатау — синоптический западный перенос на уровне хребта). 15 июля, ясно
(`FlightSettings.defaults()`), старт — первый в списке места (Алматы — центр точки). LCL и остальная погода часа —
`WeatherModel.derive(forecast, ctx, {}, hour)` (точка росы — климатология `configs/weather_model.json`).

## Воспроизведение
```bash
cd <копия>                       # ongudai — в user://locations профиля копии (кеш главной копии или другой копии),
                                 # training_island — в паке, almaty — скачивается тайлами (нужна сеть)
tools/research/cloud_field/run.sh                               # GPU, окно 320×240; ~25–60 с на час поля, 9 ч × 9 дней ≈ 1–1,5 ч
tools/research/cloud_field/run.sh --places=training_island --weathers=weak --h0=11 --h1=12 --frames=12   # проба
PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
$PY tools/research/cloud_field/plot.py --fig /home/greg/deltaplan/build/screenshots/cloud-field/CLF-1   # листы + out/summary.json
```
Тесты модели: `godot --headless --path . res://tests/run_tests.tscn -- --filter=test_cloud_field` (цена шага —
`test_cloud_field_perf`, печатает `cloud_field_step_ms=`).

## Сводка (summary.json, 13 ч)
`cover_frac` — среднее покрытие по сетке (доля неба); `cloud_area_frac`, `n_clouds`, `largest_km` (длина, ширина по
главным осям), `depth_p50_m/p90_m`, `ridge_share/valley_share` (TPI 1 км > 15 / < −15 м) — по столбцам с покрытием
≥ 0,3; `src_under_cloud_ratio` — доля источников термиков под облаком / доля площади облаков (1 — независимы);
`peaks_above_lcl_frac` — доля столбцов, где рельеф выше LCL.
