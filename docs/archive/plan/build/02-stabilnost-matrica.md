# 02. Стабильность: матрица крылья × локации × погода

**Цель:** автопилот-полёт N минут по всем крыльям, всем локациям и всем погодам проходит без ошибок в логе.

**Контекст:** scripts/game/autopilot.gd, tests/game/test_game_flight.gd, docs/guide/game.md («Тесты», «Командная строка»), configs/tasks/ongudai_demo.json, configs/game.json, tools/check.sh.
**Папки-владения:** `tests/stability/` (новая), `tools/soak.sh` (новый). Правки чужого кода — только точечные фиксы найденных падений, каждый отдельной строкой в отчёте (иначе — карточка владельцу).

## Шаги
1. `tests/stability/test_matrix.gd`: перебор всех `configs/locations/*` × 3 крыла × 3 погоды (weak/medium/strong) × ветер (into_site) — старт, автопилот, 5 мин симуляции через `game.tick()` в headless-цикле (без реального времени); ErrorCatcher — 0 ошибок/предупреждений.
2. `tools/soak.sh`: запуск собранной Linux-сборки `--autostart --autopilot --time=300` под xvfb на каждое сочетание, код выхода + grep `ERROR`/`SCRIPT ERROR` в логе.
3. Точечно чинить найденные падения в границах допустимого; иначе фиксировать как список для владельца группы.
4. Отчёт-таблица «сочетание → результат (ok/ошибка)».

## Критерий приёмки
- `godot --headless --path . res://tests/run_tests.tscn -- --filter=stability` — 0 упало.
- `tools/soak.sh` по всем сочетаниям — код выхода 0, 0 строк `ERROR` в логах.
- Таблица результатов приложена к отчёту карточки.

**Зависимости:** после сборки Linux (карточка 01) и окончания integration/terrain2/atmosphere/vegetation/sounds. **Модель:** sonnet. **Размер:** M.
