---
type: "research"
status: "active"
module: "tow-trike"
area: "flight"
updated: "2026-10-22"
summary: "Скрипты и воспроизведение расчёта параметров буксировщика-дельталёта (TT-1)"
related: ["docs/research/tow/trike-tug.md", "docs/contracts/tow-trike.md"]
---
# tow-trike (TT-1): параметры буксировщика-дельталёта

Документ с выводами и источниками — `docs/research/tow/trike-tug.md`. TT-1 — stdlib Python 3; TT-8 (трапеция) — ещё numpy, Blender 4 (`extract_sit.py`) и Godot (`measure_trim.gd`).

## Воспроизведение (из корня репозитория)
```
python3 tools/research/tow-trike/build.py          # configs/tow_tug.json (блоки TT-К1), thrust_table.csv, wing_trike_ixess15.json
python3 tools/research/tow-trike/check_k1.py       # инварианты TT-К1 (exit 0)
python3 tools/research/tow-trike/climb_estimate.py # climb_ms=..., варианты, проверка по паспорту; пишет climb_estimate.json
```
Файлы: `tugmodel.py` (двигатель, винт, поляра крыла), `cart.py` (масса, ЦМ, CdA тележки), `thrust_table.csv`, `climb_estimate.json/.txt`.

## Данные и лицензии
Данные из публичных спецификаций (Wikipedia — CC BY-SA, взяты только числа; BMAA HADS HM16 — через `tools/research/trike-model/wings.json`; Rotax — паспортные точки из руководства
и форума rotax-owner.com). Исходные тексты не копировались; собственные данные скриптов — часть репозитория. Реестр: `ASSETS.md` не менялся (внешних файлов нет).

## TT-8: трапеция и штанга (TT-К6)
```
blender -b --python tools/research/tow-trike/extract_sit.py     # pilot_sit.json из assets/models/pilot.glb (поза sit)
cp tools/research/tow-trike/measure_trim.gd tests/game/test_tt8_trim.gd   # замер «Маятника» -> trim_pendulum.json (числа перенесены вручную), затем удалить копию и .uid
python3 tools/research/tow-trike/trapeze_calc.py --write        # trapeze.json
python3 tools/research/tow-trike/check_trapeze.py tools/research/tow-trike/trapeze.json   # exit 0
```
Выводы и допущения — `docs/research/tow/trike-tug.md`, раздел «Трапеция и штанга». `pilot_sit.json` — вершины меша пилота (проект), внешних данных нет.
