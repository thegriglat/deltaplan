# Группа 12 — Сцена игры и управление (`game/`)
Владения группы: `scenes/main.*`, `scenes/game/`, `scripts/game/`, `scripts/core/`, `configs/game.json`,
`configs/controls.json`, `configs/camera.json`, `tests/game/`. Коммит 768d6db (integration) — «промежуточно»:
кабина, разбег W+Shift, позы, мгла — не проверены визуально.
**Фокус (решение пользователя):** геймплей свободного полёта. Задания/тренировки/рекорды — ОТЛОЖЕНО (см. tasks/README.md).

| Волна | Карточка | Модель | Размер | Владения (без пересечений в волне) |
|---|---|---|---|---|
| 1 | [01 Приёмка кабины](01-priemka-kabiny.md) | opus | M | camera_rig, pilot_animator, части game.gd, camera.json, test_cockpit, docs/screenshots/cockpit |
| 1 | [02 Сквозной тест свободного полёта](02-skvoznoj-test-svobodnyj.md) | sonnet | M | test_e2e.gd, autopilot.gd, tools/shots/e2e.sh |
| 2 | [03 Геймплей свободного полёта](03-geimplej-svobodnogo.md) | opus | M | input_controller, camera_rig, game.gd, main.gd, controls/camera.json, test_gameplay |

В волне 1 параллельно идут ui/01 и ui/02 (папки UI). После волны 2 — повторный прогон 12-02 (тот же агент/тест).
Вне объёма: часы симуляции и выбор времени (VR-5), дождь/смог, подключение заданий.
