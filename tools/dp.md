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

Агенту остаются только задачи, которые детерминированным скриптом не решить, — подумать: спроектировать, решить, разобрать причину, написать текст/код. Всё, что можно сделать скриптом (поиск, сводки, проверки, перенос, слияние, отчёты по числам), — делает `tools/dp` или скрипт задачи; повторяющуюся ручную операцию — оформить командой dp (через обратную связь).
Детерминированное — командами dp: поиск и работа с планами, журналами, документами, ветками — только через `tools/dp` (`dp search`, `dp search --sem`, `dp plan`, `dp docs …`, `dp log`, `dp status`, `dp task …`, `dp sync/merge`); свои grep/python-скрипты для этого не писать (исключение — код игры и исследовательский код задачи). Не хватило команды — обойти один раз и сразу записать обратную связь (`dp event <модуль> note --note "dp: …"` или поле dp_feedback).

## Версия, перезапуск, ID
`DP_VERSION` в начале `tools/dp`: если в главной копии (`/home/greg/deltaplan/tools/dp`) версия новее, устаревший dp в копии задачи перезапускается из неё (`os.execv`, те же аргументы и cwd), в stderr — одна строка; `DP_NO_REEXEC=1` — отключить. Поднимать `DP_VERSION` при каждом изменении dp.
ID задачи — `<КОД>-[этап]<n>[буква]` (`^[A-Z]{2,4}-[A-Z]?\d+[a-z]?$`: NN-7, NN-7a, этапные NN-P8); КОД — `code` в `module.json` (2–4 заглавные латинские, уникален по модулям, `T` зарезервирован под TODO.md; `dp init <модуль> --code NN`, `dp module new … --code NN`). `dp task new <модуль>` без ID — следующий номер (максимум + 1; `--stage P` — следующий `<КОД>-P<n>`); ID уникален по всем модулям. Контракты (C1, П1…) — не задачи. Старые ID в журналах не переименовываются.

## Команды
```
dp task new <модуль> <ID> --type dp-engineer --title "…" --goal "…" [--plan-ref "UC-3"] \
    [--contract У2@1] [--scope путь] [--dont-touch путь] [--test ui_controls] \
    [--check ИМЯ "команда" EXPECT] [--from card.json|-] [--force]
dp task show <ID> [--json] [--full] [--diff]   # карточка для исполнителя; --full — полное задание (пункты по строке, правила, заметки); --diff — как менялась (события edited)
dp task sync <ID> [--message М] [--trailer Т]  # влить ветку модуля (base) в ветку задачи в её копии
dp task set <ID> поле=знач поле+=элем поле-=элем [--check ИМЯ CMD EXPECT] [--test Ф] [--drop-check ИМЯ]
                                  # правка карточки без переписывания JSON (значение — JSON или строка); событие edited
                                  # строка в списочное поле (scope, report_extra…) — список через запятую: report_extra=epoch_s,hours
dp event <ID> started|reported|accepted|merged|blocked|cancelled|note [--commit h] [--note "…"]
dp event <модуль> note --note "…" # событие модуля (не задачи)
dp decide <модуль> "<решение>" --by user|coordinator|main [--why "…"] [--task ID] [--answers Q1]
dp decide <модуль> "<вопрос>" --ask      # шлюз: вопрос пользователю → Q1, висит в status до --answers Q1
dp accept <ID> [--only ИМЯ] [--here|--cwd DIR] [-j 4] [--commit h] [--dry] [--no-accept] [--no-review] [--bg --timeout СЕК]
                                  # --dry — пробный прогон исполнителем до отчёта (без события); --only → в конце сводка по всем проверкам карточки
                                  # (последние результаты для текущего HEAD, build/dp/<ID>/results.json); частичные прогоны складываются в accepted
                                  # --bg — через dp job (долгие GPU-проверки): dp job wait dp-accept-<ID> <сек>
dp report <ID> [файл|-]  |  dp report <ID> --show [--full]  |  dp report --template
dp review <ID> --verdict accept|rework --from r.json|- [--note …]  |  --note "итог"  |  dp review <ID> --show [--full]  |  dp review --template
dp status [<модуль>] [--full] [--stale 40]   # «⚠тихо» = ни событий, ни коммитов ветки задачи > 40 мин; accepted+merged — одним статусом
dp log <модуль|ID> [-n 10] [--full] [--no-decisions]   # события и решения; [src] и [unparsed] у записей из миграции
dp search <текст|regex> [--module М] [--max 30]   # по карточкам, отчётам, событиям, решениям всех модулей; строка на находку
dp plan <модуль|файл.md> [<номер|начало заголовка>] [--contracts] [--depth 3] [--max 150]
dp render <модуль> [--out путь|-] [--force]
# главная сессия
dp plan edit <модуль|файл.md> <раздел> --append "текст" | --replace СТАРОЕ НОВОЕ | --set [ФАЙЛ|-] [--contracts] [--commit]
dp decide <модуль> "решение" --by user --why "…" [--plan [раздел]]
dp inbox <модуль> [--by coordinator] [--peek]  |  dp questions  |  dp answer <Qn|модуль/Qn> "ответ"
dp module new <модуль> [--from main] [--code NN]  |  dp sync <модуль|ветка> [-m М] [--trailer Т]  |  dp merge <ветка> [--into main] [--push] [-m М] [--trailer Т]  |  dp gc [ВЕТКА|МОДУЛЬ…] [--remove]
dp status --since 30m|2h|today [<модуль>]  |  dp digest --since today|<дата>
```

dp index [--full]                                    # смысловой индекс (bge-m3, только CPU); обновляет только изменённое
dp search --sem "запрос" [--max 10] [--module М|--path ПРЕФИКС]   # оценка путь:строка — заголовок — фрагмент

**Смысловой поиск.** Эмбеддинги — bge-m3 через Ollama (`localhost:11434`, GPU по умолчанию, `keep_alive` 2m; `DP_SEM_CPU=1` — только CPU, `num_gpu: 0`). Один раз: `ollama pull bge-m3`.
Только stdlib, окружения нет. Корпус (главная копия): `docs/**/*.md`, README/summary/reference в `tools/research`, дневник, CHANGELOG,
журналы dp (событие/решение/карточка/отчёт = запись). Markdown режется по заголовкам, кусок ≤ ~1500 симв. с перекрытием.
Индекс общий, вне git: `~/.cache/deltaplan_sem/main/` (`emb.f16` + `meta.jsonl`), работает из любой копии; обновление по хешу текста куска;
flock на `.lock` (вторая индексация ждёт), файлы заменяются атомарно. `dp search --sem` сам тихо обновляет изменённое.
Ollama не отвечает/нет модели — ошибка «Ollama не запущен / нет модели: ollama pull bge-m3».

**Перед новой работой — `dp search` по прошлым модулям** (старые журналы `docs/plan/*_progress.md` переведены в dp скриптом `tools/dp_migrate.py`; исходник — поле `legacy_journal` в `module.json`, у записей поле `src` — строка исходника).

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

## Команды главной сессии
Раздел — как в `dp plan`: номер из оглавления или начало заголовка. Вывод — одна строка.
```
# план и контракты по разделам (событие plan в журнале модуля; --commit — только этот файл, строка Claude-Session из $DP_SESSION)
dp plan edit air-nn "Решения" --append "- Q оставить на камере (2026-10-02)" --commit
dp plan edit air-nn 4 --replace "шаг 0.1" "шаг 0.05"        # ровно одно вхождение в разделе, иначе ошибка (--all — все)
dp plan edit air-nn '*' --replace NN-P8 NN-16 --all           # раздел «*» — весь файл (только --replace)
dp plan edit air-nn --contracts У2 --set new_body.md         # --set без файла или «-» — stdin; тело раздела заменяется целиком

# решения и вопросы
dp decide air-nn "Берём Picard" --by user --why "быстрее" --plan   # + строка в «Решения пользователя» плана (--plan "Раздел" — в другой; создаётся, если дефолтного нет)
dp inbox air-nn                 # новое с прошлого чтения этим читателем (--by, иначе $DP_ROLE, иначе coordinator); «нового нет»
dp questions                    # открытые вопросы (decide --ask) по всем модулям: «Q1 [модуль] (возраст): текст»
dp questions --all | --module air-nn   # и отвеченные (✓) с текстом ответа
dp answer Q1 "Прибор" [--module air-nn]   # = decide --by user --answers Q1; попадает в inbox модуля
```
Метка чтения inbox — `docs/plan/<модуль>/.read_<читатель>` (в .gitignore: у каждой копии/читателя своя, в git не нужна).

```
# ветки и копии (детерминированно; $DP_COPIES — каталог копий вместо ~, для проверок)
dp module new air-nn [--from main]   # feature/air-nn + git worktree ~/deltaplan-air-nn + module.json/events.jsonl, коммит в ветке
dp sync air-nn                       # git merge main в копии ветки; конфликт → merge --abort и список файлов; грязная копия → отказ
dp merge feature/air-nn [--into main] [--push]   # --no-ff в копии, где выписана цель: «main 22d55f2: слияние feature/air-nn, файлов 6; индекс обновляется в фоне» (при слиянии в main запускается `dp index` отвязанно, лог `~/.cache/deltaplan_sem/main/index.log`; `--no-index` — не запускать; нет Ollama — предупреждение, слияние не падает)
dp gc                                # список копий/веток, уже влитых в main (ветки, совпадающие с main, не считаются)
                                     # пропуск: у модуля незакрытые задачи или живые ветки <модуль>/*, задача ветки не закрыта,
                                     # на копию смотрят симлинки других копий (.venv); игнорируемые каталоги, которые снимутся, — в выводе
dp gc --remove                       # git worktree remove (без --force; грязные пропускаются) + git branch -d

# наблюдение и дневник
dp status --since 30m                # по модулям: события, коммиты веток (не в main), новые вопросы (✓ — отвечен, ? — открыт); ≤ 5 событий; + main
dp digest --since today              # решения пользователя, принятые задачи, правки плана, коммиты main (first-parent)
```

Слияния (`sync`, `merge`, `task sync`): незакоммиченный журнал `docs/plan/<модуль>/` в целевой копии перед слиянием коммитится сам своими путями («<модуль>: журнал dp»), остальная «грязь» — отказ. Строка `Claude-Session` в сообщение — из `$DP_SESSION`; `-m/--message` — своё сообщение, `--trailer` — доп. строки.
`dp init <модуль> --legacy путь` — ссылка на старый журнал (`legacy_journal`); `report` принимает `extra` — свободный объект своих чисел (в `--show` коротко).

## Обратная связь по dp
Чего не хватило, что неудобно — в конце работы: исполнитель — поле `dp_feedback` отчёта, координатор —
`dp event <модуль> note --note "dp: …"`. Собрать: `grep -h 'dp_feedback\|"dp: ' docs/plan/*/events.jsonl`.

## Документация: `dp docs` (tools/dp_docs.py)

```
dp docs find [--type T] [--status S] [--module M] [текст]   # строка на документ: путь — тип — статус — summary
dp docs show docs/guide/terrain.md                           # frontmatter + оглавление, без тела
dp docs findings [текст] [--module M]                        # выдержки из реестра выводов
dp docs check                                                # frontmatter, живые ссылки, размер > 40 КБ
dp docs index                                                # собрать docs/INDEX.md и docs/registry/{research,contracts,decisions}.md
dp docs init [--dry]                                         # frontmatter новым файлам (эвристики)
```

## Долгие запуски и замки: `dp job`, `dp lock`

```
dp job start <имя> <таймаут_с> <команда…>     # в фоне (setsid, rc всегда пишется, 124 — таймаут); логи ~/.cache/deltaplan-jobs/<имя>.{pid,log,rc}
dp job wait <имя> <таймаут_с>                  # ждёт PID (tail --pid), печатает код и хвост лога; таймаут обязателен
dp job status [имя] [--all] | dp job stop <имя>   # без имени — идущие + последние 10 (--all — все); stop — по PID, только свой процесс
dp job --lock cpu|gpu start <имя> <таймаут_с> <команда…>   # фоновая задача под замком (опцию — перед start)
dp lock gpu|cpu <имя> [--timeout СЕК] -- <команда…>        # под замком, ожидание блокирующее, таймаут → 124
dp lock status                                 # кто держит: имя, PID, команда, с какого времени, копия
```
Замок `gpu` — файл `/tmp/heat_ca_gpu.lock`, тот же, что у `GpuLock` пилота (air_nn_pilot): пилот и `dp lock gpu` видят друг друга. `cpu` — N слотов (`DP_CPU_SLOTS`, по умолчанию max(1, nproc // 8)).
