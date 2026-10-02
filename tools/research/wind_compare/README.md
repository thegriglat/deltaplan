---
type: "research"
status: "closed"
module: ""
updated: "2026-10-01"
summary: "Сравнение поля ветра main и feature/air-model (Онгудай) — Выгрузка из игры (Atmosphere.air_velocity_at / mean_wind_at), не из air.py."
related: []
conclusion: ""
data: "tools/research/wind_compare/"
applied_in: ""
---
# Сравнение поля ветра main и feature/air-model (Онгудай)

Выгрузка из игры (`Atmosphere.air_velocity_at` / `mean_wind_at`), не из air.py. Условия: Онгудай, старт kayancha_south,
12:00, ветер 3 м/с на 10 м с 151°, weather/medium, sky clear (для решателя), сид 20260401, порывы и термики выключены.
Область ±1000 м, шаг 100 м, уровни AGL 10/20/50/100/200/400/600 м.

Воспроизведение (копии: main — `git worktree add --detach ~/deltaplan-cmp-main <коммит>`, air-model — `~/deltaplan-cmp-air`;
в свежей копии нужен `.godot/` из рабочей; GPU под flock, не headless — решатель air-model требует RenderingDevice):

    ./run.sh ~/deltaplan-cmp-main main      # main: аналитика, air_runtime нет
    ./run.sh ~/deltaplan-cmp-air air        # air-model: решатель + окна 100/50 м у старта
    curl -sL -o plotly-3.0.1.min.js https://cdn.plot.ly/plotly-3.0.1.min.js   # MIT, не в git
    python3 build.py <куда>.html

`dump_wind.gd` один и тот же для обеих версий (AirRuntime подключается, если класс есть). Данные: `out/main.json`, `out/air.json`.
Лицензия plotly.js — MIT.

## Седловина и вся гора
Выбор седловины: `./run.sh <копия> ground --ground_only=1 --half=6000 --step=100` (высоты) и поиск по гессиану сглаженного рельефа (σ 150 м);
центр (−1300 м восток, 0 север от старта). Прогоны:

    ./run.sh <копия> saddle_<main|air> --cx=-1300 --cn=0 --half=1000 --step=100
    ./run.sh <копия> mountain_<main|air> --half=5000 --step=400 --gstep=200 --levels=50,100,200,400,800,1200
    python3 build.py base|saddle|mountain

## Сильный ветер (9 м/с на 10 м; в меню игры максимум 12 м/с)
Те же три области: `./run.sh <копия> strong_<main|air> --wind=9`, `saddle_strong_…` и `mountain_strong_…` с теми же `--cx/--half/--step/--levels`,
затем `python3 build.py strong|saddle_strong|mountain_strong`. Возвратное течение (ротор) берётся из той же `air_velocity_at`: в обеих версиях
эвристика подветренной зоны входит в неё и при выключенной турбулентности.

## AM-08в: было / стало (эвристика за гребнем поверх поля)
«Было» — `out/*_air.json` выше (до AM-08в), «стало» — `out/am08v/*_air.json` (main не пересчитывался: аналитика побитно та же).
Сильный ветер ещё раз с болтанкой и диагностикой (`--turb=40` — 40 моментов в точке: min w, σ_w; `--diag=1` — r, dx, lee_f, U_H):
`out/am08v/*_turb_air.json`.

    ./am08v_run.sh /home/greg/deltaplan-wf-am08v      # все 9 прогонов пачкой (готовые пропускает)
    python3 am08v_table.py                            # → am08v/table.md, am08v/table.csv
    python3 am08v_resolved.py                         # → am08v/resolved.md (разрешает ли решатель пузырь отрыва)
    python3 build.py strong <куда>.html am08v         # HTML «стало» (третий аргумент — каталог air в out/)
