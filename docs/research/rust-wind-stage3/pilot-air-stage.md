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

`Game._air_conditions()` (game.gd:555-575, до правки без `quantum_h`; теперь строка 568) не клал `quantum_h` (контракт input.md: обязателен в прогнозе). Крейт отвергал условия,
`Atmosphere._dp_start` (на 70e491dcb atmosphere.gd:980 `dp.set_conditions(...)` без проверки кода; сейчас :1019) код не проверял: условий в крейте нет, `start_at` не запускает расчёт поля, load_place даёт Ready.
Итог — ни этапа, ни итераций, ветер 0. Режим `auto` из пользовательского atmosphere.json: на 70e491dcb `_dp_field_wanted` (atmosphere.gd:937-943) в окне даёт true (off — только строка "off"; headless — false), т.е. поле было включено, это подтвердил пробник (`поле включено`). Упрощённый режим тут ни при чём (в headless `auto` поле выключено — это
отдельно и не ошибка).

## Починка

- `scripts/game/game.gd:568`: в условия добавлен `quantum_h` (как у `AtmoDay`).
- `scripts/atmosphere/atmosphere.gd`: код `set_conditions` крейта проверяется. Отказ в `_dp_start` (подготовка места) —
  FAILED + `push_error`; отказ при смене условий на загруженном месте — BAD_INPUT, состояние и прежние условия
  сохраняются (W1). Снят фильтр `phase*` в `debug_raster_names`/`debug_raster`.
- `scripts/atmosphere/wind_field_debug.gd`: `fetch_raster` идёт только через фасад `debug_raster`, обход через `_dp` убран.
- Тесты `tests/game/test_place_air_stage.gd` (2, ~25 с): (1) игровой путь Main._fly на Онгудае — этап подготовки ветра
  виден экрану загрузки (до READY не ждёт: полный счёт Пикара там минуты); (2) малое не запечённое место 25 м с условиями
  вида игры — этап, READY, поле включено, ветер ≠ 0, отказ условий без quantum_h на READY оставляет READY.

## Регрессия и границы

- Строгая проверка quantum_h на границе фасада не включена. Условия без `quantum_h` есть в tests/atmosphere
  (weather_day, wind_profile_simple) и tests/contracts/test_rust_wind_consumers: раньше крейт их отвергал молча
  (ветер 0), теперь отказ виден, и часть проверок падает (по tests_vs_base — 4 новых падения consumers). Правка условий
  в тестах — у RW-P3, не здесь.
- Независимо от задачи падают test_rust_wind_contracts (версии доков) и 2 теста rw7_field.

## Где не уверен

- `tests/game/test_place_air_stage.gd`: полный прогон игры на чистом профиле с пилотным местом после починки не делался
  (минуты счёта Пикара); до починки отказ воспроизведён load_probe (set_conditions rc=1, READY за 0.0 с).
