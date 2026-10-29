---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-P5: на случайном месте не было этапа «Рассчитываем ветер» — игра слала крейту условия без quantum_h, крейт отвергал, фасад молчал."
conclusion: "Причина: Game._air_conditions не передавал quantum_h (обязателен по input.md), DpAir.set_conditions вернул BAD_INPUT, фасад проигнорировал код; READY сразу, поля нет, ветер 0. Починка: quantum_h в условиях игры и FAILED с причиной вместо молчания."
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3/pilot-air.md"]
---

# RW-P5: нет стадии воздуха на случайном месте

## Воспроизведение

Чистый профиль (пустой XDG_DATA_HOME), `tools/loading/load_probe.tscn -- --latlon=42.41194,1.94538`, не headless:
`dp_air: подготовка места начата, поле включено` и сразу `READY за 0.0 с, поле подано`; этапа wind нет.
Отладочная печать кода: `set_conditions rc=1 err=conditions: missing 'quantum_h'`.

## Причина

`Game._air_conditions()` не клал `quantum_h` (контракт input.md: обязателен в прогнозе). Крейт отвергал условия,
`Atmosphere._dp_start` код не проверял: условий в крейте нет, `start_at` не запускает расчёт поля, load_place даёт Ready.
Итог — ни этапа, ни итераций, ветер 0. Упрощённый режим тут ни при чём (в headless `auto` поле выключено — это
отдельно и не ошибка).

## Починка

- `scripts/game/game.gd`: в условия добавлен `quantum_h` (как у `AtmoDay`).
- `scripts/atmosphere/atmosphere.gd`: код `set_conditions` крейта проверяется в `_dp_start` и в `set_conditions`;
  отказ — FAILED с `last_error` в журнале, не молчание.
- Тест `tests/game/test_place_air_stage.gd`: игровой путь Main._fly, этап подготовки ветра виден (полный счёт Пикара на Онгудае — минуты, тест ждёт этап, не READY).

## Где не уверен

- `tests/game/test_place_air_stage.gd`: READY и ветер ≠ 0 в тесте не проверяются (долго); проверено пробником load_probe до починки (READY 0.0 с, rc=1) — после починки этап виден в тесте.
- Прогон целиком на чистом профиле с пилотным местом после починки — см. отчёт.
