---
type: "guide"
status: "active"
module: "core"
updated: "2026-10-14"
summary: "Автоматические отчёты о вылетах: метка сессии, отчёт GitHub issue в deltaplan-reports при следующем запуске, токен, проверка --crash-report-test."
related: []
---
# Отчёты о вылетах

Код: `scripts/core/crash_report.gd` (чистая логика), `scripts/core/crash_reporter.gd` (автозагрузка CrashReporter), тесты — `tests/core/test_crash_report.gd`.

## Как работает
- Старт: файл `user://session.lock` (версия, время, pid, настройки полёта, стадия загрузки, занятая VRAM). Настройки (пресет графики, место, ветер, боты, сеть) дописываются при «Лететь», стадия — по этапам загрузки.
- Штатный выход (закрытие окна, «Выход») удаляет метку. Метка при старте — прошлый запуск оборвался (или игра уже открыта в другом окне — тогда pid жив, метку не трогаем).
- Тогда собирается отчёт: версия, ОС, видеокарта и драйвер, рендер, процессор, RAM, VRAM, настройки, хвост лога прошлого запуска (`user://logs/godot<дата>.log` — самый новый датированный файл; `godot.log` — текущий запуск). Пути пользователя заменяются на `~`, тело ≤ 60 000 знаков (обрезается начало лога).
- Отчёт лежит в `user://crash_report.json`, уходит фоном POST в issues `thegriglat/deltaplan-reports` с меткой `crash`; не вышло (нет сети) — до 3 попыток за все запуски. В меню — строка «Отчёт о вылете отправлен».
- Работает только в экспортной сборке с окном; редактор, headless, `--smoke`, `--autostart`, `--prefetch`, `--screenshot`, `--perf` метку не ведут.

## Токен
Fine-grained PAT (только Issues: write на deltaplan-reports). Лежит вне git: `~/.config/deltaplan/crash_report_token` (или переменная `DELTAPLAN_CRASH_REPORT_TOKEN`). `tools/build.sh` кладёт его в `data/crash_report_token.txt` (в .gitignore, попадает в экспорт). Нет токена — функция выключена, сборка печатает одну строку об этом.

## Проверка
`deltaplan --crash-report-test` отправляет пробный отчёт («Проба …», без метки `crash`) с текущим логом; результат — строка `crash-report-test:` в логе.
