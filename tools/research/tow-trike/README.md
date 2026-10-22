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

Документ с выводами и источниками — `docs/research/tow/trike-tug.md`. Только stdlib Python 3.

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
