---
type: "research"
status: "closed"
module: "perf"
updated: "2026-10-17"
summary: "Замер загрузки места после «карта загружена»: этапы и функции главного потока (тёпло/холодно, Онгудай и точка −27.7176,−48.7799)"
related: []
conclusion: "тёпло 28 с (Онгудай) / 43 с (точка), из них после рельефа 24 / 37–39 с: ветер 14–15 с (решатель, фон), остальное — главный поток одним кадром: объекты 3,7 / 12,4 с (маска просек 1,0 / 6,3–7,7 с), «почти готово» 5,4 / 9,5–11 с (первое обновление термиков 4,2 / 7,2–9,1 с)"
data: "results.json, table_stages.csv, table_lp.csv, logs/"
applied_in: "не применено"
---
# Загрузка места: что идёт после рельефа

Вопрос пользователя: «почему после загрузки карты расстановка дорог и т. п. занимает столько времени — даже если место
уже в кеше». Код игры не менялся: разметка временем ставилась во временной копии и снята.

Вывод — во frontmatter (`conclusion`); таблицы — `table_stages.csv`, `table_lp.csv`; разбор и предложения — в отчёте главной сессии 17.10.

## Как мерили

- Копия `main` (4fc48eb2), Godot 4.7.2, RTX 4070 SUPER, 20 потоков, окно 1280×720, звук Dummy, под `dpcli lock gpu`.
- Зонд `probe.gd` — копия `tools/loading/load_probe.gd`: меню → «Лететь» → ждём полёт, затем ещё 15 с
  кадров полёта (`[lpfly]`). Интервалы кадров > 100 мс — `[gap]` (замороженный экран загрузки).
- Разметка `instrument.py` + `instrument_spec.py`: вокруг вызовов вставляются `LP.t()` / `LP.e(метка)` (`lp.gd`),
  строки лога `[lp] <метка> <мс> @<с>`; счётчики — `[lpn]`; переходы стадий AirRuntime — `[lpair]`.
  `tools/research` под `.gdignore`, поэтому `lp.gd` и зонд копируются в `tools/lp_tmp/` (не коммитить).
- Холодно — пустой профиль `XDG_DATA_HOME` (нет кеша мест, тайлов, шейдеров); тёпло — тот же профиль, новый процесс.
  «Тёпло в том же процессе» (вторая загрузка без перезапуска игры) не мерили.
- Места: `--location=ongudai` (встроенное) и `--latlon=-27.7176,-48.7799` (точка прошлого замера, город у моря).
  Погода по умолчанию автостарта: 12:00, 3 м/с, ясно, 26 °C.

Запуски (логи `logs/`):

| логи | разметка | нагрузка машины (load avg) |
|---|---|---|
| `*_cold`, `*_warm`, `*_warm2` | круг 1 (этапы, вызовы верхнего уровня) | не записана; числа самые низкие — основная таблица |
| `*_deep1/2` | + круг 2 (внутри долгих) | 50–100 (чужие godot-тесты) — абсолютные числа завышены ×1,5–2, только доли |
| `*_final1/2` | + круг 3 | 10–30 — подробности из них |

Машина общая: соседние агенты гоняли тесты godot, разброс между запусками до ±30 %.

## Воспроизведение

```bash
git worktree add --detach ~/deltaplan-loadprof main && cd ~/deltaplan-loadprof
XDG_DATA_HOME=~/.cache/dp-xdg/deltaplan-loadprof godot --headless --path . --import
python3 tools/research/load_profile/instrument.py .          # разметка (все три круга)
XDG_DATA_HOME=~/.cache/dp-xdg/deltaplan-loadprof godot --headless --path . --import   # класс LP
.dpcli/dpcli job --lock gpu start lp-all 5400 tools/research/load_profile/run_all.sh      # холодно+тёпло, оба места
.dpcli/dpcli job --lock gpu start lp-final 3600 tools/research/load_profile/run_final.sh  # ещё тёплые
python3 tools/research/load_profile/summarize.py             # results.json, table_stages.csv, table_lp.csv
git checkout -- scripts && rm -rf tools/lp_tmp                # снять разметку
```

`run_pair.sh <тег> <место>` — холодный и два тёплых запуска в профиле `~/.cache/dp-xdg/loadprof-<тег>`;
`run_warm.sh`, `run_deep.sh`, `run_final.sh` — тёплые повторы.

## Инструмент для модуля fast-load (FL-К3)

Повторяемый замер тёплой загрузки без разметки кода игры (только зонд `probe.gd`; `lp.gd`/`instrument*.py` — для исследования выше).

```bash
# под замком GPU; профиль ~/.cache/dp-xdg/loadprof-<ong|pt>, место уже в кеше
.dpcli/dpcli job --lock gpu start fl-meas 3600 bash -c \
  'tools/research/load_profile/measure.sh <тег> ong 3 --air-cache=off && tools/research/load_profile/measure.sh <тег> pt 3 --air-cache=off'
python3 -I tools/research/load_profile/measure.py --selftest        # проверка разбора на logs/ong_warm.log, pt_warm.log
python3 tools/research/load_profile/compare.py baseline.json <после>.json   # md-таблица медиан
```

- `measure.sh <тег> <ong|pt> <n> [--air-cache=keep|clear|off]` — n запусков подряд, логи `logs/<тег>_<место>_<i>.log`
  (в начале `uptime`, `air_cache`, `commit`; в конце `exit=`, `uptime_end`); в конце вызывает `measure.py <тег>`.
  Зонд копируется в `tools/lp_tmp/` (tools/research под `.gdignore`) и удаляется. `--air-cache`: `clear` — удалить `air_cache`
  профиля перед каждым запуском (miss), `keep` — не трогать (hit, если запись есть), `off` — кеша нет (`none`, до FL-2).
  Профиль был пуст — первый запуск помечен `cold` и не входит в медианы.
- `measure.py <тег>` — логи тега → `<тег>.json` (формат FL-К3 v1, `docs/contracts/fast-load.md`): запуски, этапы, `load_max_gap_ms`
  (наибольший `[gap]` с начала нажатия «Лететь» до полёта), `load_gaps_over_1s`, медианы по `<место>/<air_cache>`.
- `compare.py` — таблица «до/после» (медианы, разница, %).
- `baseline.json` + `logs/baseline_*` — замер «до» на `feature/fast-load` (= main), `--air-cache=off`.
- Ограничения: машина общая (в json — load average начала/конца; разброс ±30 %); окружение — RTX 4070 SUPER, 20 потоков;
  GPU-цена кадра не мерится; «тёпло» = новый процесс при тёплом профиле, не повторная загрузка в одном процессе.

## Файлы

- `results.json` — по каждому логу: этапы (с), метки `[lp]` (мс, сумма за запуск), время до полёта, дома, тайлы OSM.
- `table_stages.csv` — этап × запуск; `table_lp.csv` — метка × запуск (мс).
- `logs/*.log` — сырые логи Godot (≈ 250 КБ всего).

Данные — только замеры времени этой игры; внешних данных нет (тайлы рельефа, покрова и OSM — из обычного
кеша игры, их лицензии — в `ASSETS.md`).

## Замер «до» (FL-1, baseline.json)

`feature/fast-load` (8843db94 = код main), `--air-cache=off`, по 3 тёплых запуска. Медианы: Онгудай — до полёта 29,2 с (ветер 15,1; объекты 3,9; самолёт/«почти готово» 5,7), наибольшее замирание 5,9 с; точка — 40,2 с (ветер 14,9; объекты 11,5; glider 9,8), замирание 11,7 с. Load average машины 82–91 (чужие задачи) — абсолют завышен, разброс по точке 40–50 с.
