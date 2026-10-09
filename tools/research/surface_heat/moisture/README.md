---
type: "research"
status: "closed"
module: "surface-heat"
updated: "2026-10-09"
summary: "Перцентили поля влажности рельефа TerrainRelief.moisture по суше слоя detail на 4 местах (altai, askarovo, aushkul, ongudai) для порогов m_dry/m_norm/m_wet (SH-1)."
related: ["docs/research/surface_params.md"]
conclusion: "Поле центрировано около 0,47 (медиана по 4 местам 0,475), p10 = 0,26, p90 = 0,68; предложено m_dry = 0,25, m_norm = 0,47, m_wet = 0,70."
data: "moisture_percentiles.csv, moisture_percentiles.json"
applied_in: "docs/research/surface_params.md"
---
# Перцентили влажности рельефа (SH-1)

Выборка: узлы сетки 50 м по границам детального слоя (`Terrain.detail_bounds`), суша = класс карты поверхности слоя ≠ water (6);
значение — `Terrain.moisture_at` после `wait_relief()`. ≈ 630 тыс. точек на место.

Воспроизведение (из корня копии; первый раз — `godot --headless --path . --import`; ~2–3 мин):

    XDG_DATA_HOME=$(mktemp -d) godot --headless --path . \
      res://tools/research/surface_heat/moisture/moisture_percentiles.tscn -- step=50

Выход (в каталог скрипта): `moisture_percentiles.csv` (перцентили p1…p99 по местам и общие), `moisture_percentiles.json` (то же + по классам).
Данные места — из репозитория (`data/terrain/<место>`; лицензии — ASSETS.md); внешних загрузок нет.
