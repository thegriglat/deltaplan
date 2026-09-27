# Группа 10 — Задания, тренировки, рекорды (`tasks/`)

**ОТЛОЖЕНО (решение пользователя):** сначала проверить геймплей свободного полёта (game/, ui/).
Карточки не составлялись. Логика FR-35…FR-37 готова без нод (docs/tasks.md), в игру не подключена.

Когда вернёмся (план-набросок, не в работу):
1. game: `TaskSession` (RefCounted) — Task/TaskTracker/TrainingMode/FlightRecords по API docs/tasks.md; режим в FlightSettings.
2. game: подключение в `Game.tick`, `set_task`/`set_task_state` на планшет, info итога с `task`/`training`/`new_records`.
3. ui: выбор режима в «Полёт…», итог со временем задания и «Новый рекорд!».
4. tasks: цели тренировок и демо-задания для askarovo и aushkul (сейчас только ongudai, altai).
5. сквозной тест в режимах задание/тренировка (дополнение к game/02).
