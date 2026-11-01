---
type: "research"
status: "active"
module: "trike-fix"
area: "flight"
updated: "2026-11-02"
summary: "Инструмент и данные TKF-2: отклик дельталёта на штангу (control_run.gd), воспроизведение."
conclusion: "Данные и скрипты замера TKF-К2; вывод в docs/research/trike-fix/control.md."
data: ["tools/research/trike-fix/out/control_summary.json"]
applied_in: []
---
# trike-fix: данные TKF-2 (управление дельталёта)
Файлы с префиксом `control_`; `summary.json` и `coupling_*` (TKF-1) не трогать.

Воспроизведение (из корня копии, профиль `XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")`, после `godot --headless --path . --import`):
```
.dpcli/dpcli lock cpu TKF-2 -- godot --headless --path . res://tools/research/trike-fix/control_run.tscn -- tools/research/trike-fix/spec_main.json tools/research/trike-fix/out/control_main.jsonl
... spec_t3030_g1.json -> out/control_t3030_g1.jsonl   (перезамер 30→30 при газе 1)
... spec_ablate.json   -> out/control_ablate.jsonl      (абляции: предел рук, ход, tau, масса, тяга)
... spec_variants.json -> out/control_variants.jsonl    (варианты правки)
python3 tools/research/trike-fix/control_build.py && python3 tools/research/trike-fix/check_control.py tools/research/trike-fix/out/control_summary.json
python3 tools/research/trike-fix/control_show.py tools/research/trike-fix/out/control_main.jsonl   # печать сводки
```
Скрипт `control_run.gd` — шаговый прогон `PendulumModel` + `TrikeRig`, допущения в заголовке файла. Прогоны ~2-3 мин на пачку.
Источники и ограничения — `docs/research/trike-fix/control.md`. Лицензии данных: свои расчёты; цитаты из Gratton & Newman
(Brunel BURA, открытый доступ) — только числа и ссылки, PDF не хранится.
