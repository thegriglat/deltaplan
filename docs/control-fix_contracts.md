# Контракты модуля «control-fix»

Внутренний документ. План — `docs/plan/control-fix.md`, журнал — `docs/plan/control-fix_progress.md`. Контрактный тест — `tests/game/test_control_fix_contracts.gd` (форма стыков; ломается при смене формата без правки контракта). Зафиксировано то, что есть в коде на v1.0.0 (3820bda). Менять интерфейс — только через координатора: версия +1, что изменилось, потребители правятся в том же шаге.

## С1. ControlInput — управление пилота за шаг — v1
Владелец: `scripts/core/control_input.gd`. Источники: `InputController` (CF-2), `Autopilot`, `BotPilot`, сеть. Потребители: `FlightModel.step`, `GroundRun.step` (CF-1), `Glider`, визуал.
- `pitch: float ∈ [−1, 1]` — +1 трапеция от себя (нос вверх), −1 на себя; на земле/в разбеге — угол носа крыла (+ нос вверх).
- `roll: float ∈ [−1, 1]` — +1 вправо. В полёте — крен (режим по `weight_shift`); **на земле — только курс** (стоя/шагом — поворот на месте, на бегу — дуга; крыло не кренит) — по start-fixes К3 v2.
- `weight_shift: bool` — смысл `roll` в полёте; `run: bool` — разбег (только на земле); `walk: float ∈ [−1, 1]` — шаг вперёд/назад.
- Расхождение (записано 01.10): doc-комментарий `roll` в `control_input.gd` («в разбеге — выравнивание крыла») устарел после SF-3; правильный смысл — выше. Исправить комментарий может CF-1 без смены версии.

## С2. InputController → ControlInput — v1
Владелец: `scripts/game/input_controller.gd` (CF-2). Потребитель: `Game.tick` (`input_controller.update(dt)` → `glider.set_input`).
- `update(dt: float) -> ControlInput` — раз за шаг физики; `enabled=false` или `hands_off=true` — нейтральное управление.
- `on_ground: bool` (задаёт `Game` по фазе) — выбор `_update_ground` / `_update_air`.
- Мышь: `set_mouse_captured(on: bool)`, `mouse_captured: bool`, `mouse_mode() -> String ∈ {"look","bar"}` из `configs/controls.json → mouse.mode` (поверх — `user://configs/controls.json`); в `bar` смещение мыши (`InputEventMouseMotion.relative` в `_unhandled_input`) → `roll` (+ вправо) и `pitch` (мышь вверх = от себя), только в воздухе; правая кнопка — временно голова. На земле мышь не используется (v1).
- Изменение: мышь начинает управлять на земле, режим по умолчанию меняется или события берутся не из `_unhandled_input` — версия 2 через координатора.

## С3. Пилот на земле — ссылка
`GroundRun` (стоя/ходьба/разбег, крен на плечах, отрыв, срывы) — контракты модуля start-fixes: `docs/start_fixes_contracts.md` → **К3 v2** (крен на земле, переход в полёт) и **К4 v1** (поза крыла на земле); их тест — `tests/game/test_start_fixes_contracts.gd`. Владелец в этом модуле — CF-1. Смена смысла полей/результатов `GroundRun.step` или ключей `flight.json → ground_bank`/`takeoff` — версия К3 v3 в обоих документах, через координатора.
