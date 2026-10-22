---
type: "research"
status: "active"
module: "trike-pilot"
area: "flight"
updated: "2026-10-23"
summary: "Замеры скорости дельталёта от хода штанги (Godot-скрипты, jsonl, потолок по тяге) для TP-17."
related: ["docs/research/trike-pilot/speed-range.md"]
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
