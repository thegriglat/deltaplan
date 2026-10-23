---
type: "research"
status: "active"
module: "trike-pilot"
area: "flight"
updated: "2026-10-23"
summary: "TP-23: прогоны связки буксировщик + sport на тросе с подменой линии тяги, хода штанги, площади крыла, тяги и массы."
conclusion: "Разбор: docs/research/trike-pilot/tug-slow-climb.md. Скорость на полном газе определяется высотой линии тяги над ЦМ тележки."
data: ["tools/research/trike-pilot/tug/results.json"]
applied_in: []
related: ["docs/research/trike-pilot/tug-slow-climb.md"]
---
# TP-23: прототип «буксировщик на полном газе»

Код игры, конфиги, тесты не менялись. Разбор — `docs/research/trike-pilot/tug-slow-climb.md`.

## Файлы
- `tug_runner.gd/.tscn` — копия `tests/game/test_tow_trike_climb.gd` (TT-К4, sport на тросе aerotow, до 300 м) с подменой чисел через `ovr` в spec.
- `spec2.json`, `spec3.json`, `spec1.json` — прогоны; `out1..3.jsonl` — результаты, `out0.jsonl` — база без правки тяги (тяга в ЦМ тележки, как в `feature/trike-pilot`); `results.json` — всё сведено.

## Воспроизведение (из корня копии)
1. Тяга по оси винта живёт в ветке TP-20 (`trike-pilot/TP-20`, ещё не слита): временно `git show trike-pilot/TP-20:scripts/flight/trike_rig.gd > scripts/flight/trike_rig.gd` (не коммитить, потом `git checkout scripts/flight/trike_rig.gd`). Раннер сам кладёт `cart.prop_axis_below_hang_m` = 1,238, если в `ovr` его нет.
2. `.dpcli/dpcli lock cpu tp23 -- godot --headless --path . --import`
3. `.dpcli/dpcli lock cpu tp23 -- godot --headless --path . res://tools/research/trike-pilot/tug/tug_runner.tscn -- tools/research/trike-pilot/tug/spec3.json tools/research/trike-pilot/tug/out3.jsonl` (≈ 1 мин на прогон).

Ключи spec: `ovr` — `"<конфиг>.<путь>": значение` (например `tow_tug.cart.prop_axis_below_hang_m`), `thrust_k` — множитель таблицы тяги, `wing_area_k` — площадь крыла при тех же CL/CD (в итоге не годится, см. документ).
Выход: climb_ms, speed_kmh (средние по окну 5 с после выхода в climb до 152 м, как в тесте), tension_n, thrust_n, throttle, bar_i_m.

## Источники и лицензии
Веб-источники — только цитаты фактов со ссылкой (список в документе). Данных не скачивалось.
