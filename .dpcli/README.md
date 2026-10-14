# dpcli — журнал, карточки задач и приёмка

Утилита процесса «главная сессия ↔ координатор модуля ↔ исполнители ↔ ревьюер» для проектов, где работают агенты Claude Code. Хранит журнал модулей (карточки задач, отчёты, события, решения, вопросы пользователю), ведёт ветки и рабочие копии (git worktree), прогоняет проверки приёмки и сливает ветки. Вывод короткий; подробности — `--full`.

Коды выхода: 0 — ок, 1 — ошибка или FAIL, 2 — неверные аргументы. Ошибка — одна строка `dpcli: …`.

## Требования

- python3 ≥ 3.10 (только стандартная библиотека; PyYAML не обязателен — есть встроенный разбор подмножества YAML);
- git;
- опционально: tmux (окна для `job`/`lock`/`accept --bg`); Ollama с моделью `bge-m3` нужна только для смыслового поиска (`search --sem`, `index`) и по умолчанию не используется.

## Установка

1. Скопировать каталог `.dpcli` в корень git-проекта.
2. Выполнить `.dpcli/dpcli init`.

`init` создаёт (всё идемпотентно):

| Что | Где |
|---|---|
| Конфиг из примера (если конфига нет) | `dpcli.yml` |
| Агенты с подставленными плейсхолдерами | `.claude/agents/*.md` |
| Скиллы | `.claude/skills/<имя>/SKILL.md` |
| Описание процесса | `.claude/dpcli-workflow.md` |
| Блок между маркерами `<!-- dpcli:begin -->` … `<!-- dpcli:end -->` | `CLAUDE.md` |
| Разрешение `Bash(.dpcli/dpcli *)` | `.claude/settings.json` |
| Строки `.read_*`, `build/dpcli/` | `.gitignore` |

Режимы `init`:

- повторный запуск безопасен: ничего не меняется, если результат уже актуален; что записал `init`, учтено в `.claude/.dpcli-manifest.json`; такие файлы, изменённые вручную, без `--force` не перезаписываются — выводится сообщение;
- файлы проекта (нет в манифесте) `init` не перезаписывает и не удаляет никогда, даже с `--force`: если в `.claude/agents` уже есть агент с именем агента dpcli — агент dpcli пропускается («пропущен — агент проекта; роль: см. roles в конфиге»); так же скилл с тем же именем и файл процесса. `CLAUDE.md` и `settings.json` — точечные вставки (блок между маркерами, одно разрешение);
- `--force` — перезаписать/удалить изменённые вручную файлы из манифеста;
- `--check` — только проверить, актуально ли настроено (ничего не пишет);
- `--dry-run` — показать, что было бы сделано;
- `--json` | `--yaml` — формат конфига, если он создаётся (по умолчанию `dpcli.yml`).

Точные флаги: `.dpcli/dpcli init -h`.

После `init` закоммитить результат (коммиты делает только главная сессия).

## Конфиг

`dpcli.json` или `dpcli.yml`/`dpcli.yaml` в корне проекта (ищется вверх от текущего каталога до корня git; при обоих json приоритетнее). Все ключи необязательны. Полный список с комментариями и умолчаниями — [`dpcli.example.yml`](dpcli.example.yml). Кратко:

- `project`, `main_branch`, `module_branch` (`feature/{module}`), `task_branch` (`{module}/{task}`);
- `copies_dir`, `module_copy`, `task_copy` — где создаются рабочие копии (подстановки `{project}`, `{module}`, `{task}`, `{copies}`);
- `worktree` — подготовка новых копий (проектная специфика — здесь: `copy` переносит игнорируемые каталоги вроде `.quasar`, `setup` — любая команда подготовки) (см. «Рабочие копии»): `hooks` (`true`), `link` (`[node_modules]`), `copy` (`[.env, .env.*]`), `setup` (команда), `setup_timeout` (1800 с);
- `plan_dir` (`docs/plan`), `contracts_dir` (`docs/contracts`), `docs_dir` (`docs`);
- `checks.env`, `checks.tests` (шаблон команды для проверок `{tests: …}`, `{filter}`), `checks.log_dir` (`build/dpcli`);
- `artifacts_dir`, `reserved_codes`, `gc.ignore_dirs`, `gc.ignore_globs`;
- `sem` (`enabled: false` по умолчанию, `model`, `url`, `cache_dir`, `globs`), `jobs` (`dir`, `tmux_session`, `cpu_slots`), `locks`;
- `agents_dir` (`.dpcli/agents`), `workflow` (`.claude/dpcli-workflow.md`);
- `roles` — роли своих агентов проекта: `{имя: {role: coordinator|executor|reviewer|status, review: bool}}`; реестр агентов = `agents_dir` + `.claude/agents` с `dpcli_role` во frontmatter + `roles` (перекрывает); смотреть — `dpcli agents`;
- `docs` (`extra`, `exclude`, `types`, `statuses`, `max_kb`, `max_kb_mode`, `summary_max`, `registries`).

## Агенты

Определения dpcli — `.dpcli/agents/*.md`: формат агента Claude Code (frontmatter `name, description, model, effort, tools/disallowedTools, skills`) плюс ключи dpcli:

- `dpcli_role`: `coordinator` | `executor` | `reviewer` | `status`;
- `dpcli_review`: `true` | `false` — нужен ли ревьюер после PASS приёмки (для исполнителей).

Поставляются: `dp-coordinator` (opus), `dp-engineer`, `dp-researcher`, `dp-writer` (sonnet), `dp-mechanic` (haiku), `dp-reviewer` (opus), `dp-status` (haiku). Тексты агентов короткие; общие правила — только в описании процесса, агенты на него ссылаются.

Плейсхолдеры `{{cli}}`, `{{workflow}}`, `{{plan_dir}}`, `{{contracts_dir}}`, `{{docs_dir}}`, `{{main_branch}}`, `{{module_branch}}`, `{{project}}` подставляет `init` и кладёт результат в `.claude/agents/`. Агентов проекта `init` не трогает: одноимённый файл в `.claude/agents/` пропускается.

**Свои агенты в ролях процесса:** ключ `roles` в `dpcli.yml` (имя агента → `role`, `review`) или `dpcli_role`/`dpcli_review` во frontmatter. Тип исполнителя в `task new --type …` проверяется по этому реестру; посмотреть — `.dpcli/dpcli agents`.

```yaml
roles:
  my-designer: {role: executor, review: true}
```

**Модели.** Исполнители — sonnet (механика — haiku): с чёткой карточкой (цель, scope, dont_touch, проверки с порогами, контракты) этого достаточно. Opus — только если задача требует проектирования, которое нельзя вынести в план или контракт.

## Протокол сообщений

Агенты не пересказывают журнал, а передают ID и команду; детали читаются командами.

| От → кому | Сообщение |
|---|---|
| главная → координатор | `Модуль <м>: копия <путь>, ветка <ветка>. План: dpcli plan <м>. Новое: dpcli inbox <м>.` |
| координатор → исполнитель | вывод `task brief <ID>` как есть (особенности — в карточку через `task note`) |
| координатор → ревьюер | вывод `task brief <ID> --review` как есть |
| исполнитель → координатор | `<ID> reported` \| `<ID> blocked: <причина ≤15 слов>` \| `<ID> contract: <что поменять>` |
| ревьюер → координатор | `<ID> review accept` \| `<ID> review rework <n>` |
| координатор → главная | `<м>: <n> accepted, <n> в работе; шлюз Q<n>` или `<м> done` |
| главная → пользователь | свободно, по `status` / `digest` |

Решения пользователя попадают координатору через `decide` → `inbox`, а не пересказом. Не хватает сведений — вопрос одной строкой. Подробно — в описании процесса (`.claude/dpcli-workflow.md`, раздел «Протокол сообщений»).

## Флоу работы

1. **Главная сессия** (пользователь + Claude) стоит на фичеветке задачи и создаёт модуль: `.dpcli/dpcli module new payments --code PY --area pro` — ветка модуля **от фичеветки** (база модуля, пишется в `module.json`), рабочая копия и журнал `<plan_dir>/payments/`. Пишет план (`<plan_dir>/payments/…`) и контракты.
2. Запускает **координатора** модуля (агент `dp-coordinator`) в копии модуля.
3. Координатор заводит задачи:
   ```
   .dpcli/dpcli task new payments --type dp-engineer --title "Округление суммы" \
     --goal "Сумма округляется до копеек" --plan-ref "PY-1" \
     --scope src/money.py --test rounding \
     --check no_todo "grep -c TODO src/money.py" "re:^0$"
   .dpcli/dpcli task show PY-1          # карточка; --full — полное задание исполнителю
   .dpcli/dpcli event PY-1 started --note "dp-engineer"
   ```
   `task new` сам создаёт рабочую копию и ветку задачи (`<task_copy>` на `<task_branch>` от ветки модуля, с git-crypt и подготовкой — см. «Рабочие копии»; есть — переиспользует; `--no-copy` — не создавать). Затем координатор запускает **исполнителя** с сообщением — выводом `.dpcli/dpcli task brief PY-1` как есть (одна задача, своя копия).
4. Исполнитель читает план по разделам, работает в своей копии, делает пробный прогон `accept PY-1 --dry` и сдаёт отчёт:
   ```
   .dpcli/dpcli plan payments PY-1
   .dpcli/dpcli report --template PY-1 > r.json   # заполнить
   .dpcli/dpcli report PY-1 < r.json
   ```
   Исполнитель коммитит свои файлы в ветке задачи (`git commit -- <пути>`); слияния веток — координатор и главная сессия (правила — `.claude/dpcli-workflow.md`).
5. Координатор принимает: `.dpcli/dpcli accept PY-1 -j 4`. FAIL — на доработку; PASS у типа с `dpcli_review: true` — состояние `checked` (ждёт ревью, `--no-review` — сразу принято), без ревью — `accepted`.
6. Ревью (свежий `dp-reviewer`): `.dpcli/dpcli review PY-1 --verdict rework --from - < review.json`; координатор смотрит `review PY-1 --show` и решает: `event PY-1 accepted --note "по ревью"` или доработка.
7. Слияние: ветка задачи → ветка модуля (в копии модуля), `.dpcli/dpcli event PY-1 merged --commit <хэш>`; свежее из базы модуля — `.dpcli/dpcli sync payments`; готовый модуль в базу (фичеветку) — сдача: `.dpcli/dpcli deliver payments` (squash, журнал → `decisions.md` и `summary.md`). В `main_branch` фичеветка идёт MR, который вливает человек: `deliver`/`merge` туда — только явным `--into` и только для модуля, заведённого от неё.
8. Уборка: `.dpcli/dpcli gc` (список), `.dpcli/dpcli gc --remove`.

Наблюдение: `.dpcli/dpcli status`, `digest --since today`, `log payments`, `questions`.

## Команды

Справка по любой подкоманде — `.dpcli/dpcli <команда> -h`. Автор событий — `--by`, иначе `$DPCLI_ROLE`, иначе по ветке копии.

### Модули и ветки

```
.dpcli/dpcli module new <модуль> [--from ВЕТКА] [--code PY] [--area A]   # ветка от текущей (или --from) + копия + журнал
.dpcli/dpcli module init <модуль> [--plan П] [--contracts К] [--branch Б] [--copy К] [--code PY] [--area A] [--legacy ПУТЬ]   # только журнал (--area — задать/сменить)
.dpcli/dpcli sync <модуль|ветка> [-m М] [--trailer Т]          # влить базу модуля (фичеветку) в ветку модуля (в её копии)
.dpcli/dpcli merge <ветка|модуль> [--into ВЕТКА] [--push] [--no-index] [-m М] [--trailer Т]   # --no-ff в копии цели; цель по умолчанию: задача → ветка модуля, модуль → его база
.dpcli/dpcli deliver <модуль> [--into ВЕТКА] [-m М] [--force] [--dry]   # сдача: squash ветки модуля, журнал → md
.dpcli/dpcli deliver <модуль> --in-place [--dry]                      # журнал уже в текущей ветке: свернуть в md
.dpcli/dpcli deliver <модуль> --rerender [--from REF] [--area A] [--dry]   # сданный модуль: md заново из журнала в REF, без коммита
.dpcli/dpcli gc [ВЕТКА|МОДУЛЬ …] [--remove]                    # копии и ветки, уже влитые в основную
.dpcli/dpcli copy setup [ПУТЬ]                                 # подготовить копию (хуки, env, node_modules) — идемпотентно
```

#### Рабочие копии

`module new` и `task new` создают копию так, чтобы она сразу была рабочей:

1. `git worktree add --no-checkout`, затем ключи git-crypt из общего `.git` копируются в GIT_DIR копии (`<common>/worktrees/<имя>/git-crypt`; копией, не симлинком) и только потом checkout — иначе smudge-фильтр git-crypt падает. Оставшиеся зашифрованными файлы — предупреждение с подсказкой `git crypt unlock`.
2. Неудача на любом шаге создания (checkout, журнал, коммит `module new`) — копия убирается, созданная ветка удаляется: ветки без копии не остаётся.
3. Подготовка (`worktree.*` конфига; источник — главная копия, первая в `git worktree list`):
   - `hooks: true` — относительный `core.hooksPath` (напр. `.husky/_`, он в `.gitignore` и после checkout пуст) докопировать из главной копии, иначе pre-commit молча не работает. В `accept` этот каталог не считается выходом за `scope`;
   - игнорируемые git пути главной копии (`git ls-files --others --ignored --directory`) по шаблонам: `link` — жёсткими ссылками `cp -al` (на другой ФС — копией), `copy` — копией. Шаблон без `/` — по имени на любой глубине, со `/` — путь от корня. Что в копии уже есть или чей каталог отсутствует в ветке — пропускается. Пустой список (`link: []`) выключает;
   - `setup` — команда проекта (`bash -c`, cwd — новая копия, env `DPCLI_COPY`, `DPCLI_MAIN_COPY`, `DPCLI_BRANCH`, таймаут `setup_timeout`). Ошибка не откатывает копию: печатается хвост вывода и `copy setup` для повтора.

Жёсткие ссылки делят файлы с главной копией: `npm install` в копии может их задеть; меняете зависимости — `rm -rf node_modules && npm ci` в копии. `copy setup [ПУТЬ]` повторяет подготовку на уже существующей копии (докопирует недостающее, своё не перезаписывает).

`sync`, `merge`, `task sync`: незакоммиченный журнал модуля в целевой копии перед слиянием коммитится сам, прочая «грязь» — отказ. Конфликт — слияние отменяется, выводится список файлов.

`gc` пропускает модули с незакрытыми задачами и живыми ветками `<модуль>/*`, грязные копии (изменения в отслеживаемых файлах), копии с неотслеживаемыми файлами-работой и копии, на которые ссылаются симлинки; `--remove` делает `git worktree remove` и `git branch -d`. Игнорируемые git файлы и сгенерированное (`gc.ignore_dirs` — любой каталог с таким именем на любой глубине, `gc.ignore_globs`) удалению не мешают: `--force` для `worktree remove` добавляется только тогда, когда неотслеживаемое целиком из этого набора. Пути с пробелами и кириллицей git читается без кавычек (`-z`, `core.quotepath=off`).

### Задачи

ID задачи: `<КОД>-[этап]<n>[буква]` (`PY-7`, `PY-7a`, `PY-P8`); КОД — `code` модуля (2–4 заглавные латинские, уникален). Без ID `task new` берёт следующий номер модуля (`--stage P` — следующий `<КОД>-P<n>`).

```
.dpcli/dpcli task new <модуль> [ID] --type T --title "…" --goal "…" [--plan-ref "§1"] \
    [--stage P] [--copy К] [--branch Б] [--contract ИМЯ@ВЕРСИЯ] [--scope ПУТЬ] [--dont-touch ПУТЬ] \
    [--test ФИЛЬТР] [--check ИМЯ CMD EXPECT] [--from card.json|-] [--no-copy] [--force]
.dpcli/dpcli task show <ID> [--json] [--full] [--diff]
.dpcli/dpcli task brief <ID> [--review]   # готовое сообщение исполнителю (ревьюеру) — отправлять как есть
.dpcli/dpcli agents                       # реестр агентов: имя, роль, review, источник (dpcli|project|config), модель
.dpcli/dpcli task set <ID> поле=знач поле+=элем поле-=элем [--check ИМЯ CMD EXPECT] [--test Ф] [--drop-check ИМЯ] [--contract ИМЯ@ВЕРСИЯ]
.dpcli/dpcli task note <ID> "правило или заметка"   # дополнение к выданной задаче (видно в task show и inbox <ID>)
.dpcli/dpcli task sync <ID> [--message М] [--trailer Т]   # влить ветку модуля в ветку задачи в её копии
```

Карточка (`<plan_dir>/<модуль>/tasks/<ID>.json`) — обычный JSON: `id, module, type, title, goal, plan_ref, contracts[], copy, branch, base, scope[], dont_touch[], accept[], report_extra[], notes`; можно править руками. Контракт `<имя>.Cx` с именем другого модуля (`app-pro.C5`) в `task show` указывает на `<contracts_dir>/<имя>.md`, а не на файл контрактов текущего модуля. `task set` порядок: сначала `--drop-check`, потом `--check`/`--test` (замена проверки одним вызовом); значение — JSON или строка, для списочных полей строка — список через запятую.

`task brief` отказывает (код 1, список недостающего), если у карточки нет `goal`, `scope` или ни одной проверки — карточка не готова к выдаче; `task new` при таких пропусках предупреждает. `EXPECT` проверок разбирается сразу в `task new`/`task set` (неверный — отказ).

Проверка приёмки — `{name, cmd, expect, cwd?, timeout?}` или `{name, tests: "<фильтр>"}` (команда из `checks.tests`). `EXPECT`:

- `exit=0` (по умолчанию);
- `re:<regex>` — есть в выводе; `!re:<regex>` — нет в выводе;
- `num:<regex с группой> <op><число>`, op: `<= >= == < >` — последнее совпадение, запятая читается как точка;
- `tests` — проверка тестами проекта;
- объект: `{"exit":0, "re":"…", "num":"…", "min":…, "max":…}` — все условия сразу.

Команды идут через `bash -c` в копии задачи (если есть; `--here` — в текущей); таймаут по умолчанию 900 с; в окружении `$DPCLI_TASK`.

### События, решения, вопросы

```
.dpcli/dpcli event <ID|модуль> started|reported|accepted|merged|blocked|cancelled|note [--commit h] [--note "…"]
.dpcli/dpcli decide <модуль> "решение" --by user|coordinator|main [--why "…"] [--task ID] [--plan [РАЗДЕЛ]]
.dpcli/dpcli decide <модуль> "вопрос" --ask             # шлюз: вопрос пользователю → Q1
.dpcli/dpcli decide <модуль> "ответ" --by user --answers Q1
.dpcli/dpcli answer <Qn|модуль/Qn> "ответ" [--module М]  # = decide --by user --answers Qn
.dpcli/dpcli questions [--all] [--module М] [--full]     # открытые вопросы по всем модулям
.dpcli/dpcli inbox <модуль|ID> [--by читатель] [--peek] [--max N] [--full]
.dpcli/dpcli log <модуль|ID> [-n N] [--full] [--no-decisions]
```

`--plan` у `decide` дописывает строку в раздел плана («Решения пользователя» по умолчанию). `inbox` показывает новое с прошлого чтения этим читателем (решения, ответы, правки плана, заметки); читатель — `--by`, иначе `$DPCLI_ROLE`, иначе `coordinator` (для ID — `executor`). Метка чтения — `<plan_dir>/<модуль>/.read_<читатель>` (в `.gitignore`).

### Приёмка, отчёт, ревью

```
.dpcli/dpcli accept <ID> [--only ИМЯ] [--here|--cwd DIR] [-j 4] [--commit h] [--dry] [--no-accept] [--no-review] [--full] [--bg [--timeout СЕК]] [--no-tmux] [--tmux-session S]
.dpcli/dpcli report <ID> [файл|-]  |  report <ID> --show [--full]  |  report --template [ID]
.dpcli/dpcli review <ID> --verdict accept|rework --from r.json|-  |  review <ID> --note "итог"  |  review <ID> --show [--full]  |  review --template
```

`accept` печатает таблицу `PASS/FAIL имя значение`, у FAIL — путь к логу (`checks.log_dir/<ID>/`). Всё PASS → событие `accepted`, иначе `checked` с итогом. У типов с `dpcli_review: true` PASS → `checked` (ждёт ревью; `--no-review` — сразу `accepted`; `--here` после слияния ревью не ждёт). `--dry` — пробный прогон без события; `--only` — одна проверка (в конце сводка по всем); `--bg` — через `job` (долгие проверки), ждать: `.dpcli/dpcli job wait dp-accept-<ID> <сек>`.

Строка `scope` в таблице — детерминированная проверка границ: файлы, изменённые в ветке задачи относительно `base` (`git diff --name-only base...HEAD` + незакоммиченные), должны попадать в `scope` и не попадать в `dont_touch` (пункт — glob или файл/префикс каталога; путь может содержать пробелы: он берётся целиком, если пояснение отделено ` — `, ` - `, ` (` или `: `, либо путь в обратных кавычках; без пояснения годится и вся строка, и первое слово). Нарушение — FAIL со списком файлов (до 10). Пустой `scope` или копия не на ветке задачи — `SKIP`. Журнал модуля (`<plan_dir>/<модуль>/`, вкл. отчёт), `checks.log_dir` и `gc.ignore_*` нарушением не считаются.

Отчёт (`report --template`): `status` (done|partial|blocked|failed), `summary`, `commits[]`, `checks[{name, value, pass}]`, `not_done[]`, `questions[]`, `images[]`, `how_to_check`, `uncertain`, `dp_feedback`, плюс ключи `report_extra` карточки. Неверный отчёт не сохраняется, ошибка говорит, что не так.

Ревью (`review --template`): `verdict` accept|rework, `summary`, `issues[]` (≤ 7) `{file, line, severity: blocker|major|minor, what, fix}`, `rerun[{name, value, pass}]`. blocker при accept — ошибка.

### План, статус, журнал

```
.dpcli/dpcli plan <модуль|файл.md> [<номер|начало заголовка>] [--contracts] [--depth 3] [--max 150]   # оглавление или раздел
.dpcli/dpcli plan edit <модуль|файл.md> <раздел> --append "текст" | --replace СТАРОЕ НОВОЕ [--all] | --set [ФАЙЛ|-]  [--contracts] [--commit]
.dpcli/dpcli status [<модуль>] [--full] [--stale 40] [--since 30m|2h|today]
.dpcli/dpcli digest [--since today|ДАТА|2h]
.dpcli/dpcli render <модуль> [--out путь|-] [--force]    # md-журнал <plan_dir>/<модуль>/journal.md
```

`plan edit --replace` требует ровно одно вхождение в разделе (`--all` — все); раздел `*` — весь файл (только `--replace`); `--set` без файла или `-` читает stdin. `status`: «тихо» — ни событий, ни коммитов ветки задачи дольше порога (мин).

### Поиск

```
.dpcli/dpcli search <текст|regex> [--module М] [--max N]       # по карточкам, отчётам, событиям, решениям всех модулей
.dpcli/dpcli search --sem "запрос" [--max 10] [--module М|--path ПРЕФИКС] [--all]
.dpcli/dpcli index [--full]                                    # смысловой индекс
```

Перед новой работой полезно `search` по прошлым модулям. Смысловой поиск опционален и по умолчанию выключен (`sem.enabled: false`): без него `search --sem` и `index` сообщают, что поиск выключен, а `merge` в основную ветку индекс не обновляет. Включить: `sem.enabled: true` в конфиге, поставить Ollama и `ollama pull bge-m3`, затем `.dpcli/dpcli index`.
При включении эмбеддинги — через Ollama (`sem.url`, `sem.model`, по умолчанию bge-m3; один раз `ollama pull bge-m3`). Индекс лежит вне git в `sem.cache_dir`, обновляется по хешу текста. `DPCLI_SEM_CPU=1` — считать только на CPU. Корпус — `sem.globs` и журналы dpcli. Нет Ollama или модели — ошибка с подсказкой.

### Документация

```
.dpcli/dpcli docs check [путь …]                              # frontmatter, summary, живые ссылки, размер (код 1 при ошибках); с путями — только эти файлы (каталог — все документы под ним)
.dpcli/dpcli docs index                                       # собрать INDEX.md и реестры (docs.registries)
.dpcli/dpcli docs find [--type T] [--status S] [--module М] [--archive] [--long] [текст]   # строка «путь — summary»
.dpcli/dpcli docs section <путь>[#раздел] [<номер|начало заголовка>] [--depth 3] [--max N]  # оглавление или раздел
.dpcli/dpcli docs show <путь.md>                              # frontmatter + оглавление
.dpcli/dpcli docs findings [--module М] [текст]               # выводы из registry/findings.md
.dpcli/dpcli docs init [--dry] [--refresh-contracts]          # frontmatter файлам без него (summary: "TODO")
```

Документацию читают по кусочку: `INDEX.md` — точка входа (модули по `area`, строка на модуль: summary плана, статус и дата, ссылки на план, контракты, решения, сводку и архив журнала, под ней — прочие документы модуля; остальное — группы по типу, строка на документ `- [путь](путь) — summary [статус]`, архив — одной строкой), `docs find` — строка на документ, `docs section` — оглавление документа (без раздела) или текст раздела с подразделами, без frontmatter. Раздел — номер из оглавления или начало заголовка; если подходит несколько — список кандидатов и код 1 (`plan` разбирает разделы так же).

Frontmatter читается как YAML (списки `related` — блочные `- a` и inline `[a, b]`). Правила `docs check`: `summary` обязательна, одна строка ≤ `docs.summary_max` (140) символов, `TODO` — ошибка (`docs init` ставит `summary: "TODO"`, а не выдумывает из текста); документ больше `docs.max_kb` (40 КБ) — ошибка с подсказкой разбить на разделы-файлы или вынести данные (`docs.max_kb_mode: warn` — только предупреждение; архив и `generated: true` не проверяются). `docs find --status closed|superseded` и `--archive` ищут и в `{docs_dir}/archive/`.

Реестры: `docs.registries` (по умолчанию `[research, contracts]`; `decisions` — только если включён явно, иначе решения ищутся `search`). `registry/findings.md` пишется вручную (`docs index` создаёт заготовку): раздел `## <модуль>`, вывод — пункт `- …` в одну строку с числами и ссылкой `путь#раздел`. Допустимые `type`/`status`, исключения и лимиты — раздел `docs` конфига.

### Долгие запуски и замки

```
.dpcli/dpcli job start <имя> <таймаут_с> <команда…>     # в фоне; rc всегда пишется, 124 — таймаут
.dpcli/dpcli job wait <имя> <таймаут_с>                  # ждёт, печатает код и хвост лога
.dpcli/dpcli job status [имя] [--all]  |  job stop <имя>  |  job attach <имя>
.dpcli/dpcli job --lock cpu|gpu start <имя> <таймаут_с> <команда…>
.dpcli/dpcli lock cpu|gpu <имя> [--timeout СЕК] -- <команда…>
.dpcli/dpcli lock status
```

Логи — `<jobs.dir>/<имя>.{pid,log,rc}`; `rc`: 124 — таймаут, 143 — `job stop`, 129 — окно закрыто пользователем. Замок `cpu` — N слотов (`jobs.cpu_slots` / `DPCLI_CPU_SLOTS`, по умолчанию половина логических ядер), `gpu` — один. Окно tmux по умолчанию (сессия `$DPCLI_TMUX_SESSION`, иначе `jobs.tmux_session`); `--no-tmux` — только фон; нет tmux — предупреждение и обычный фон. Окно закрывается по завершении задачи. Внутри задач tmux отключён (`DPCLI_NO_TMUX=1`).

## Сдача модуля

Журнал — рабочий материал ветки модуля, в итоговую ветку он не идёт. `deliver <модуль>`:

1. отказ, если есть непринятые задачи или вопросы без ответа (`--force` — сдать как есть), если копия модуля или цели грязная;
2. коммитит журнал в копии модуля, делает `git merge --squash <ветка модуля>` в копии итоговой ветки (`--into`, по умолчанию база модуля); конфликт только в `INDEX.md`/реестрах пересобирается сам, иначе — откат, сначала `sync`;
3. из `<plan_dir>/<модуль>/` убирает всё, кроме `deliver.keep` (по умолчанию `decisions.md`, `summary.md`), и пишет эти файлы из журнала:
   - `decisions.md` — вопросы с ответами (ответ под вопросом) и решения по авторам, с «почему»; даты `ГГГГ-ММ-ДД` без времени; у решения пользователя без причины (или с одной ссылкой на источник вроде «ответ пользователя 2026-10-09») — «утверждено разработчиком»;
   - `summary.md` — по задачам: итог (`summary` отчёта), статус и вердикт ревью, «не сделано», «не уверен», вопросы исполнителя;
4. один коммит «<модуль>: <заголовок плана>» со списком задач в теле — через хуки (lint-staged проверяет весь модуль); не прошёл — изменения остаются в индексе;
   во frontmatter обоих — `area` модуля и `archive` (тег с полным журналом, если `deliver.archive_tag` задан);
   план и контракты модуля (`module` во frontmatter) → `status: closed`, `updated`, `area`; `INDEX.md` и реестры пересобираются (`docs index`) — всё в том же коммите;
5. событие `delivered` в журнал модуля и тег `deliver.archive_tag` (`archive/{module}`; `false` — без тега, тогда и `archive` в md не пишется) на ветку модуля — полный журнал остаётся там.

После сдачи ветку модуля не развивать: повторный squash не знает, что уже влито. Доработка — новая задача или модуль от итоговой ветки.

`--in-place` — для журналов, уже влитых в текущую ветку обычным merge: пишет те же md (`archive` — последний коммит с журналом) и удаляет остальное одним коммитом.

`--rerender` — модуль уже сдан, а формат md поменялся: журнал берётся из `--from` (тег или коммит; по умолчанию `deliver.archive_tag`) через `git archive`, md пишутся заново, план и контракты закрываются, индекс пересобирается; коммит — за вами. Старый журнал без `area` — `--area`.

## Хранение журнала

`<plan_dir>/<модуль>/`:

- `module.json` — модуль: код, area, ветка, копия, план, контракты;
- `tasks/<ID>.json` — карточка, `tasks/<ID>.report.json` — отчёт исполнителя, `tasks/<ID>.review.json` — последнее ревью;
- `events.jsonl` — события (только дописывание): `{t, by, task, ev, commits?, note?}`;
- `decisions.jsonl` — решения и вопросы: `{t, by, kind: decision|question, text, why?, id?, answers?}`;
- `.read_<читатель>` — метки чтения inbox (вне git);
- `journal.md` — результат `render`;
- `decisions.md`, `summary.md` — результат `deliver` (после сдачи в итоговой ветке остаются только они).

**Дом журнала** — рабочая копия ветки модуля, если журнал модуля там есть; иначе текущая копия. Поэтому `dpcli` из любой копии (главной, модуля, задачи) читает и пишет один журнал. Коммитит его координатор. `DPCLI_LOCAL=1` — только текущая копия. dpcli сам ничего не коммитит (кроме журнала перед слиянием и `plan edit --commit`).

## Переменные окружения

| Переменная | Назначение |
|---|---|
| `DPCLI_ROLE` | автор событий и читатель inbox по умолчанию (`main`, `coordinator`, `executor`, …) |
| `DPCLI_LOCAL` | `1` — журнал только текущей копии |
| `DPCLI_NO_REEXEC` | `1` — не перезапускаться из главной копии |
| `DPCLI_SESSION` | идентификатор сессии для строки в сообщениях коммитов |
| `DPCLI_TASK` | ID текущей задачи (выставляется в проверках) |
| `DPCLI_COPIES` | каталог рабочих копий вместо `copies_dir` |
| `DPCLI_CPU_SLOTS` | число слотов замка cpu |
| `DPCLI_NO_TMUX` | `1` — не открывать окна tmux |
| `DPCLI_TMUX_SESSION` | сессия tmux для окон |
| `DPCLI_JOB_DIR` | каталог запусков `job` вместо `jobs.dir` |
| `DPCLI_SEM_CPU` | `1` — эмбеддинги только на CPU |

`DPCLI_REEXECED` — служебная (защита от повторного перезапуска).

## Коды выхода

- `0` — успех;
- `1` — ошибка или проверка не прошла (FAIL);
- `2` — неверные аргументы.

Для `job`/`lock` код команды — её собственный код (124 — таймаут).

## Обновление dpcli в проекте

1. Заменить каталог `.dpcli` новой версией (свои файлы в `.dpcli/agents` сохранить или перенести).
2. Выполнить `.dpcli/dpcli init` (или `init --check`, чтобы увидеть, что изменилось; `--force` — перезаписать изменённые вручную файлы).
3. Версия — `VERSION` в `.dpcli/lib/dpcli/__init__.py` (`.dpcli/dpcli --version`).

Устаревшая копия `.dpcli` в рабочей копии задачи перезапускается сама из главной копии (`<главный worktree>/.dpcli/dpcli`), если там `VERSION` новее: в stderr одна строка, аргументы и cwd сохраняются. Отключить — `DPCLI_NO_REEXEC=1`. Поэтому обновлять достаточно главную копию.
