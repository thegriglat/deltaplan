# tools/dp — журнал, карточки задач и приёмка

Микроутилита процесса (главная сессия ↔ координатор модуля ↔ исполнитель). Только Python 3, без зависимостей.
Вывод короткий по умолчанию; подробности — `--full`, логи проверок — в `build/dp/<ID>/`.
Коды выхода: 0 ок, 1 ошибка или FAIL, 2 неверные аргументы. Ошибка — одна строка `dp: …`.

## Где лежит
`docs/plan/<модуль>/`:
- `module.json` — план, контракты, ветка, копия модуля;
- `tasks/<ID>.json` — карточка задачи, `tasks/<ID>.report.json` — отчёт исполнителя, `tasks/<ID>.review.json` — последнее ревью;
- `events.jsonl` — события (только дописывание): `{t, by, task, ev, commits?, note?}`;
- `decisions.jsonl` — решения и вопросы пользователю: `{t, by, kind: decision|question, text, why?, id?, answers?}`.

**Дом журнала** — рабочая копия ветки `feature/<модуль>`, если в ней есть `docs/plan/<модуль>/`; иначе текущая копия.
Поэтому `dp` из любой копии (главной, модуля, задачи) читает и пишет один журнал — копию модуля; коммитит его координатор
(`git add docs/plan/<модуль> && git commit -m "…" -- docs/plan/<модуль>`). `DP_LOCAL=1` — только текущая копия.
Автор событий — `--by` или `$DP_ROLE` (`main`, `coordinator`, `engineer`, …). `dp` сам ничего не коммитит и индекс git не трогает.

## Команды
```
dp task new <модуль> <ID> --type dp-engineer --title "…" --goal "…" [--plan-ref "UC-3"] \
    [--contract У2@1] [--scope путь] [--dont-touch путь] [--test ui_controls] \
    [--check ИМЯ "команда" EXPECT] [--from card.json|-] [--force]
dp task show <ID> [--json]        # карточка для исполнителя, ~15 строк
dp event <ID> started|reported|accepted|merged|blocked|cancelled|note [--commit h] [--note "…"]
dp event <модуль> note --note "…" # событие модуля (не задачи)
dp decide <модуль> "<решение>" --by user|coordinator|main [--why "…"] [--task ID] [--answers Q1]
dp decide <модуль> "<вопрос>" --ask      # шлюз: вопрос пользователю → Q1, висит в status до --answers Q1
dp accept <ID> [--only ИМЯ] [--here|--cwd DIR] [-j 4] [--commit h] [--dry] [--no-accept] [--no-review]
dp report <ID> [файл|-]  |  dp report <ID> --show [--full]  |  dp report --template
dp review <ID> --verdict accept|rework --from r.json|- [--note …]  |  --note "итог"  |  dp review <ID> --show [--full]  |  dp review --template
dp status [<модуль>] [--full] [--stale 40]
dp log <модуль|ID> [-n 10] [--full]
dp plan <модуль|файл.md> [<номер|начало заголовка>] [--contracts] [--depth 3] [--max 150]
dp render <модуль> [--out путь|-] [--force]
```

### Карточка (`tasks/<ID>.json`)
`id, module, type, title, goal, plan_ref, contracts[{name, version, ref}], copy, branch, base, scope[], dont_touch[],
accept[], report_extra[], notes`. Править можно и руками (Edit) — это обычный JSON.

Проверка приёмки — `{name, cmd, expect, cwd?, timeout?}` или `{name, tests: "<фильтр>"}` (headless-тесты Godot,
проходит при `0 упало`). `expect`:
- `exit=0` (по умолчанию, если `expect` нет);
- `re:<regex>` — есть в выводе; `!re:<regex>` — нет в выводе;
- `num:<regex с группой> <op><число>`, op: `<= >= == < >` — последнее совпадение, `,` читается как точка;
- `tests` — итог `N тестов, M упало` с M = 0;
- объект: `{"exit":0, "re":"…", "num":"…", "min":…, "max":…}` — все условия сразу.

Команды идут через `bash -c` в копии задачи (если она есть; `--here` — в текущей), с временным `XDG_DATA_HOME`
и `$DP_TASK`; таймаут по умолчанию 900 с.

### Приёмка
`dp accept UC-3` → таблица `PASS/FAIL имя значение`, у FAIL — путь к логу. Все проверки прошли → событие `accepted`,
иначе `checked` с итогом (`--no-accept` — всегда `checked`, `--dry` — без события). У задач `dp-engineer`/`dp-researcher`
всё PASS → тоже `checked` (ждёт ревью; `--no-review` — сразу `accepted`, `--here` после слияния ревью не ждёт).

### Ревью (`dp-reviewer`)
После PASS у engineer/researcher координатор запускает свежего `dp-reviewer` (задание — только «Ревью задачи <ID>», копия, ветка).
Ревьюер сдаёт `dp review <ID> --verdict accept|rework --from - < r.json` (без замечаний — `--note "итог"`).
Схема (`dp review --template`): `verdict` accept|rework, `summary` (1–3 строки), `issues[]` (≤ 7) —
`{file, line, severity: blocker|major|minor, what, fix}`, `rerun[{name, value, pass}]` — что ревьюер перезапустил.
blocker при accept — ошибка. Пишет `tasks/<ID>.review.json` (последнее ревью) и событие `reviewed`
`{verdict, issues: {blocker: n, …}, review: путь}`. `dp status` показывает у задачи `rev:rework 2B1M`
(B blocker, M major, m minor); `dp render` — раздел «Ревью». Дальше решает координатор:
`dp event <ID> accepted --note "по ревью"` или доработка по `dp review <ID> --show`.

### Отчёт исполнителя
`dp report --template` печатает схему: `status` (done|partial|blocked|failed), `summary`, `commits[]`,
`checks[{name, value, pass}]` (при done — по каждой проверке карточки), `not_done[]`, `questions[]`, `images[]`,
`how_to_check`, `dp_feedback`. Неверный отчёт не сохраняется (ошибка — что не так). Сохранённый — событие `reported`.

## Примеры
```
# координатор: карточка и запуск
tools/dp task new ui-controls UC-7 --type dp-engineer --title "Q не на двух действиях" \
  --goal "Q только look_instrument" --plan-ref "UC-7" --contract У1@3 --scope configs/controls.json \
  --test ui_controls --test game --check no_dup "python3 tools/check_keys.py" "re:^дублей 0$"
tools/dp task show UC-7            # → текст в задание исполнителю (или «выполни dp task show UC-7»)
tools/dp event UC-7 started --note "dp-engineer, ~/deltaplan-ui-controls-UC-7"

# исполнитель: раздел плана, а не весь план; отчёт
tools/dp plan ui-controls          # оглавление с номерами и длиной разделов
tools/dp plan ui-controls UC-7     # раздел по началу заголовка (или номеру)
tools/dp plan ui-controls --contracts У1
tools/dp report UC-7 < /tmp/uc7_report.json

# координатор: приёмка и решения
tools/dp report UC-7 --show
tools/dp accept UC-7 -j 4 --commit 1a2b3c4      # engineer: PASS → checked, ждёт ревью; после слияния — с --here
# ревьюер (свежий агент): dp task show / plan / report --show / git diff base...branch → вердикт
tools/dp review UC-7 --verdict rework --from - --by reviewer < /tmp/uc7_review.json
tools/dp review UC-7 --show        # координатор: вердикт и замечания, без чтения кода
tools/dp event UC-7 accepted --note "по ревью"
tools/dp decide ui-controls "Q оставить на свободной камере" --by coordinator --why "дёшево поменять"
tools/dp decide ui-controls "Клавиша Q: прибор или камера вниз?" --ask
tools/dp status ui-controls

# главная сессия
tools/dp status                    # все модули: строка на модуль + незакрытые задачи + вопросы
tools/dp decide ui-controls "Прибор" --by user --answers Q1
tools/dp render ui-controls --out - | less
```

Пример переведённого журнала — `docs/plan/ui-controls/` (из `ui-controls_progress.md`).

## Обратная связь по dp
Чего не хватило, что неудобно — в конце работы: исполнитель — поле `dp_feedback` отчёта, координатор —
`dp event <модуль> note --note "dp: …"`. Собрать: `grep -h 'dp_feedback\|"dp: ' docs/plan/*/events.jsonl`.
