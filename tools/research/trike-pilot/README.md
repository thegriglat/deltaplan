---
type: "research"
status: "active"
module: "trike-pilot"
area: "flight"
updated: "2026-10-23"
summary: "Замеры дельталёта: скорость от хода штанги (TP-17), качания на газу и линия тяги (TP-19)."
conclusion: "См. docs/research/trike-pilot/speed-range.md (TP-17) и pitch-oscillation.md (TP-19)."
data: ["tools/research/trike-pilot/speed_curves.json", "tools/research/trike-pilot/tp19_modes.json"]
applied_in: []
related: ["docs/research/trike-pilot/speed-range.md", "docs/research/trike-pilot/pitch-oscillation.md"]
---
# trike-pilot: диапазон скоростей дельталёта штангой (TP-17)

Разбор: `docs/research/trike-pilot/speed-range.md`. Код игры не менялся.

## Файлы
- `speed_sweep.gd`, `speed_sweep_ramp.gd`, `speed_sweep_sigma.gd` — замеры установившейся скорости `PendulumModel` (trike_ixess15 + тележка `configs/tow_tug.json`: 272,25 кг, hang 1,71 м, CdA 0,82, тяга по таблице TT-К1 вдоль оси тележки с наклоном 2°, как `TrikeRig.ext_force`); ход рук растянут до 1,0 м, ввод = ход в метрах.
- `run_sweep.sh` — копирует скрипт во временный тест, запускает headless, пишет jsonl.
- `level_speed.py` → `level_speed.json` — потолок скорости в горизонте по тяге и поляре (без Godot).
- `speed_curves.json` / `speed_curves.csv` — сведённые кривые скорость(ход штанги).

## Воспроизведение (из корня копии)
```
godot --headless --path . --import
tools/research/trike-pilot/run_sweep.sh tools/research/trike-pilot/speed_sweep.gd tools/research/trike-pilot/speed_sweep.jsonl
tools/research/trike-pilot/run_sweep.sh tools/research/trike-pilot/speed_sweep_ramp.gd tools/research/trike-pilot/speed_sweep_ramp.jsonl
tools/research/trike-pilot/run_sweep.sh tools/research/trike-pilot/speed_sweep_sigma.gd tools/research/trike-pilot/speed_sweep_sigma.jsonl
python3 tools/research/trike-pilot/level_speed.py   # из этого каталога
```
Каждая серия ≈ 2 мин (CPU, замок не нужен). `speed_curves.*` собраны из трёх jsonl слиянием (см. документ).

## Источники
BMAA HADS HM16 issue 7 (Tanarg / iXess 15), https://www.bmaa.org/files/hads_hm16_tanarg.pdf — §7(C) Vne 89 kt, §7(D) Va 72 kt, Vso 32 kt, VDF 99 kt; Wikipedia Air Creation Tanarg (912: max 157, cruise 135, stall 55 км/ч) и Skypper (582: max 125 км/ч). Лицензия данных: цифры паспортов — факты, цитируются со ссылкой; Wikipedia CC BY-SA. Внутренние: TT-8 `tools/research/tow-trike/trapeze.json`, VM-1/VM-2 `docs/research/pendulum/pullin-speed.md`, `pitch-nonlinear.md`.

# TP-19: незатухающие качания на газу

Разбор: `docs/research/trike-pilot/pitch-oscillation.md`. Код игры не менялся; в `tests/` ничего не кладётся (отдельная сцена).

## Файлы
- `tp19_runner.gd` + `tp19_runner.tscn` — временные ряды `PendulumModel` (trike_ixess15 + тележка `configs/tow_tug.json`, тяга TT-К1 как `TrikeRig.ext_force`) по списку прогонов; ключи — в шапке скрипта (газ, ход, сила/τ рук, точка приложения тяги `thrust_split`, постоянная тяга, отпущенные руки, шаг, толчок скорости).
- `tp19_spec.json` (причина: газ, ход, выключения), `tp19_spec2.json` (тяга по оси винта, a = 0,727), `tp19_spec3.json` (чувствительность к a).
- `tp19_analyze.py` → `tp19_modes.json` / `tp19_modes.csv`: на прогон — средняя/мин/макс скорость, период, множитель размаха за период (поздний и ранний 15–60 с), ζ, диапазоны α/θ, сила рук, угол стропы, срыв, признак петли/кувырка.
- `tp19_thrust_geometry.json` — плечи тяги относительно подвески (ЦМ тележки, ЦМ аппарата, ось винта) и доли a по `tools/research/tow-trike/cart.py`.
- `tp19_key_series.csv` — прорежённые (2 Гц) ряды ключевых прогонов для графиков (V, α, θ, Vy, сила рук).
- Полные ряды (20 Гц, 12,7 МБ) — локально, не в git: `build/research/trike-pilot/tp19/tp19_series.jsonl` (+ `.gz`); воспроизводятся командами ниже.

## Воспроизведение (из корня копии; каждый запуск Godot — под замком CPU)
```
.dpcli/dpcli lock cpu TP-19 -- godot --headless --path . --import
for n in "" 2 3; do
  .dpcli/dpcli lock cpu TP-19 -- godot --headless --path . res://tools/research/trike-pilot/tp19_runner.tscn -- \
    tools/research/trike-pilot/tp19_spec$n.json build/research/trike-pilot/tp19/series$n.jsonl
done
cat build/research/trike-pilot/tp19/series.jsonl build/research/trike-pilot/tp19/series2.jsonl \
    build/research/trike-pilot/tp19/series3.jsonl > build/research/trike-pilot/tp19/tp19_series.jsonl
python3 tools/research/trike-pilot/tp19_analyze.py build/research/trike-pilot/tp19/tp19_series.jsonl tools/research/trike-pilot
```
Серии: 30 + 23 + 12 прогонов по 150 с, ≈ 2,5 + 2 + 1 мин на CPU. Счёт детерминирован (без ветра).

## Источники (TP-19)
- FAA-H-8083-5 Weight-Shift Control Aircraft Flying Handbook (2008), с. 2-11, 2-18, 6-12 — https://www.faa.gov/regulations_policies/handbooks_manuals/aviation/weight_shift_control_handbook (PDF: https://www.faa.gov/sites/faa.gov/files/regulations_policies/handbooks_manuals/aviation/FAA-H-8083-5.pdf). Документ правительства США, общественное достояние.
- Hamilton P., «Why Fly Weight Shift?», FAA Aviation News, Oct 2004 — https://www.faasafety.gov/files/events/WP/WP15/2009/WP1526348/Why_Fly_Weight_Shift.pdf
- Gratton G. B., PhD thesis «Airworthiness evaluation techniques for small light aeroplanes», Univ. of Southampton — https://bura.brunel.ac.uk/bitstream/2438/708/1/FulltextThesis.pdf (§5, ур. 5-7, 5-9).
- Gratton G., Newman S., «Towards the tumble resistant microlight» — https://bura.brunel.ac.uk/bitstream/2438/705/1/Fulltext.pdf ; «The tumble departure mode in weightshift-controlled microlight aircraft», Proc IMechE G 217 (2003) — https://bura.brunel.ac.uk/bitstream/2438/1233/1/tumble1.pdf
- Wainfan B., Kitplanes «Wind Tunnel» (2016-10-20, 2016-12-23) — https://www.kitplanes.com/?p=9048 , https://www.kitplanes.com/?p=9324

Лицензии: внешние данные не импортировались; из источников — цитаты и факты со ссылкой. Все числа таблиц — собственные замеры модели.
