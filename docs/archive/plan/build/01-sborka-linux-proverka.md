# 01. Сборка Linux и smoke зелёные

**Цель:** `tools/check.sh` (линтер + тесты + сборка Linux + smoke) проходит без ошибок «с нуля», в чистом чекауте.

**Контекст:** tools/check.sh, tools/build.sh, tools/lint.sh, project.godot, export_presets.cfg, TODO.md (строка 48).
**Папки-владения:** tools/check.sh, tools/build.sh, tools/lint.sh, export_presets.cfg (пресет Linux), project.godot (только настройки окна/экспорта). Ошибки в чужом коде — точечный фикс с пометкой в отчёте, либо карточка владельцу, если правка > 20 строк.

## Шаги
1. `git status` чист; прогнать `tools/check.sh` как есть, зафиксировать все падения (линт/тест/сборка/smoke).
2. Починить найденные мелкие ошибки (пути, забытые ресурсы, устаревшие ключи конфигов) в границах своих файлов.
3. Убедиться, что `godot --headless --path . --import` и `tools/build.sh linux --release` отрабатывают на чистой машине (без кэша `.godot/`).
4. Прогнать `tools/lint.sh --format` — форматирование без расхождений (или зафиксировать список нарушителей другим группам).
5. TODO.md: снять «Windows — позже» пометку у строки 48, отметить «Сборка Linux: полная проверка» как `[x]`.

## Критерий приёмки
- `rm -rf .godot build && tools/check.sh` завершается кодом 0 и печатает «ПРОВЕРКА ПРОЙДЕНА».
- `build/linux/deltaplan.x86_64 --headless -- --smoke` печатает `smoke` без ERROR/SCRIPT ERROR в выводе.
- `tools/lint.sh --format` — 0 расхождений в границах владения этой группы.

**Зависимости:** желательно после integration/terrain2/atmosphere/vegetation/sounds (иначе будут их незакрытые ошибки в логе — фиксируем только точечно). **Модель:** sonnet. **Размер:** S.
