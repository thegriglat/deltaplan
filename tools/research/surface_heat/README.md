---
type: "research"
status: "active"
module: "surface-heat"
updated: "2026-10-09"
summary: "SH-3: инструмент замера до/после (контракт SH5) на коде игры — H поля, источники термиков, потолок, подъём на склоне, подветренные зоны, вода; прогон «до»."
related: []
conclusion: ""
data: "tools/research/surface_heat/out/"
applied_in: ""
---
# SH-3: замер «до/после» для surface-heat

Контракт вывода — `dp plan surface-heat --contracts SH5`. Измеряется **игра**, а не Python-эталон:
`Terrain.load_location` → `AirRuntime.load_field` (`AirPlace.domain_case` → фазы + Пикар на GPU →
`WindField` в `Atmosphere`) → `AirThermals.build` по этому полю (`ThermalField._update_air`, синхронно) →
выборки `Atmosphere.air_velocity_at`.

## Запуск
```bash
cd <копия>                                   # нужен GPU (RenderingDevice), окно 320x240; замок не нужен
tools/research/surface_heat/run.sh before    # метка = папка out/<метка>; места/часы по умолчанию — все 9 точек
tools/research/surface_heat/run.sh after --places=altai --hours=12     # часть плана
python3 tools/research/surface_heat/check_schema.py tools/research/surface_heat/out/before
python3 tools/research/surface_heat/compare.py tools/research/surface_heat/out/before tools/research/surface_heat/out/after
python3 tools/research/surface_heat/compare.py --summary tools/research/surface_heat/out/before   # пересобрать summary.csv
```
Долгий прогон — `tools/dp job start <имя> 3000 bash -c 'cd <копия> && tools/research/surface_heat/run.sh <метка>'`.
`run.sh` сам делает `--import`, временный `XDG_DATA_HOME`, возвращает `project.godot`. Готовые
`<место>_h<час>.json` пропускаются (продолжение с места). Параметры `measure.gd` (после `--`):
`--places= --hours= --wind=3 --wdir=<° для всех мест> --radius=10 (км) --lee-hours=12 --lee-sec=120 --node-step=50 --no-lee`.

## Условия
Как у игры по умолчанию (`FlightSettings.defaults()`): 15 июля, ясно, t_max 26 °C; ветер меню 3 м/с на 10 м над
стартом; направление (откуда) — типичное для места: altai 276° (sinyukha_west), ongudai 150° (kayancha_south,
как поле AM-07), aushkul 273° (ridge_west). Часы 9, 12, 15 (местное). Фокус окон 100/50 м — первый старт места.

## Вывод (`out/<метка>/<место>_h<час>.json`, `summary.csv`)
Поля контракта SH5: `location, hour, commit, h_wm2{mean,p10,p50,p90}, h_by_class{имя:{area_frac,mean}},
sources{n,density_km2,strength_ms{mean,p10,p90}}, ceiling_agl_m{p10,p50,p90}, slope_lift[{start,w_ms}],
lee[{site,w_min_ms,sigma_w_ms}], water{area_frac,t_water_c,t_air_c,h_mean_wm2}`. Сверх контракта: `conditions`,
`solver` (итог AirRuntime: время, k притока, U над стартом), `cells`, `wall_s`, p10/p90 в `h_by_class`,
`wstar_ms`, `slope_lift[].by_point`, `lee[].how/wdir_deg/point_agl_m`.

Определения:
- **H** — `WindField.heat_flux()` грубейшего уровня (клетка 400 м) по клеткам круга `--radius` км (10) вокруг
  центра места. Появятся ли новые поля после SH-4/SH-5 (температура воды в `meta.t_water_c`) — читаются, если есть;
  иначе `null`.
- **Класс клетки** — класс большинства узлов решётки 50 м внутри клетки по `Terrain.surface_at` (`SurfaceLayer`:
  вода по каналу G маски 10 м, лес по маске R, крутой склон → скалы `bare`). `area_frac` — доля клеток круга.
- **Источники** — `AirThermals.build`: `n` и `density_km2` — источники в круге / площадь круга (это источники,
  не живые термики: живых ≈ `alive_frac`·n); сила — `w0` (пик ядра, м/с); потолок — `top − высота земли`
  у источника (потолок частицы, без кромки облаков).
- **Подъём на склоне** — `w_mech` поля (`air_velocity_at().y`, турбулентность и термики выключены) на 30 м над землёй в
  50 м перед стартом против ветра; `windward` — старт смотрит в ветер (±60°). Другие точки — `by_point`.
- **Подветренные зоны** — старты, у которых ветер дует с тыла (±60° от heading+180). Если таких нет, на часе из
  `--lee-hours` решается отдельное поле с обратным ветром для первого старта (`how: extra_solve_wdir_*`).
  Минимум `w` по линии ветра ±1 км (шаг 20 м), 10…100 м над землёй, затем σ_w — СКО ряда w (10 Гц, 120 с) в этой
  точке с турбулентностью поля (в отличие от `air_model_baseline/probe.gd`, где аналитика, 20 Гц, 180 с).
- **Вода** — `area_frac` доля клеток круга, где большинство узлов — вода по карте поверхности; `h_mean_wm2` —
  средний H этих клеток (в «до» H клетки считается по растровой маске рек `detail_water.png`, поэтому у озера
  он почти как у суши); `t_water_c` — `null` до SH-4.

## Прогон «до» (ветка до SH-4/SH-5, коммит в json)
9 точек за 193 с (12–36 с на точку: решение поля 2 прохода ≈ 12–16 с + статистика + ряды σ_w).
Сводка — `out/before/summary.csv`. Вода: в aushkul водоём есть (1,6 % круга 10 км, озеро Аушкуль), в altai 2,8 %,
в ongudai нет — синтетический рельеф с озером не понадобился.

## Ограничения
- Оценка по клеткам 400 м и кругу 10 км; поле у стартов вне окон 100/50 м (окна — у первого старта) — грубое.
- Источники — один детерминированный набор (`seed` игры), не сводка по «дню»; силы/плотности живых термиков в
  небе зависят ещё от циклов жизни.
- Лицензии данных: данные мест игры уже в проекте (ASSETS.md); новых внешних данных нет.
