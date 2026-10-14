---
type: "guide"
status: "active"
module: "game"
area: "game"
updated: "2026-10-15"
summary: "Аргументы командной строки главной сцены (кадры, smoke, старт в воздухе, замеры, отладка сети), запуск тестов и проверок."
related: ["docs/guide/game.md", "docs/guide/architecture.md", "docs/guide/gpu-validation.md", "docs/guide/crash-report.md"]
---
# Командная строка и тесты

Часть описания сборки игры (вход — [game.md](../game.md)). Код: `scripts/game/launch_options.gd` (разбор после `--`), `scenes/main.gd`.

## Командная строка

```
godot --path . res://scenes/main.tscn -- [--autostart] [--autopilot] [--camera=cockpit|chase|free]
      [--screenshot=файл.png] [--time=с] [--pause|--settings|--about|--controls|--setup] [--look=рыскание,тангаж]
      [--location=ongudai] [--site=kayancha_south] [--latlon=51.80,85.80] [--wing=sport] [--mass=80]
      [--temp=26] [--wind=3] [--from=launch|270] [--sky=clear|partly|overcast] [--hour=13]
      [--air-start[=1000[,300]]] [--bots=N] [--seed=N] [--smoke]
```

Аргументы после `--` разбирает `LaunchOptions.parse`; подмены `--wing/--mass/--temp/--sky/--site/--location/--wind/--from/--hour/--latlon` накладываются на выбор меню (`apply_to`). Размер и режим окна задают обычные аргументы Godot (`--resolution`, `--fullscreen`, `--windowed`), они перекрывают сохранённые настройки окна на этот запуск.

| Аргумент | Что делает |
|---|---|
| `--smoke` | проверка сборки (`tools/build.sh`): автостарт с настроек по умолчанию + автопилот, 300 шагов физики (`SMOKE_STEPS`, предел 90 с), проверка данных рельефа и атрибуции, код выхода 0/1 |
| `--prefetch=<lat>,<lon>[;…]`, `--offline` | не лететь: собрать данные места в `user://locations` и выйти (код 0 — все места полные); `--offline` — без сети, только кеш |
| `--autostart` | сразу в полёт, без меню (подсказку управления не показывает) |
| `--autopilot`, `--autopilot-circle=<с>[,<крен>]` | синтетический пилот (разбег, полёт по курсу); через `<с>` после отрыва кружит с креном (15°, + вправо) |
| `--screenshot=<путь>`, `--time=<с>` | снять кадр и выйти; `--time` — время симуляции полёта (в меню — реальное), в сети — время зоны |
| `--camera=`, `--look=`, `--look-at=start\|bots\|bot<N>\|remote`, `--fov=<°>`, `--hold-key=<клавиша>[,<с>]`, `--helmet=none\|open\|visor\|visor_dark`, `--no-overlay` | кадр: камера, поворот головы в кабине, взгляд на старт / ботов / бота N / чужого пилота зоны (через «взгляд на прибор»), угол зрения 2–100° (в профиль не пишется), зажатая клавиша перед кадром, каска, скрыть прибор в углу |
| `--pause`, `--settings`, `--about`, `--controls`, `--setup` | открыть экран перед кадром (`--pause` включает автостарт) |
| `--hour=<ч>` | час старта: ближайший из `world.json → time.start_hours` (9/12/15/20), не произвольное время |
| `--air-start[=<д>[,<h>]]` | старт сразу в воздухе: в `<д>` м от старта по его курсу, `<h>` м над рельефом в этой точке (по умолчанию 1000 и 300), скорость трима, фаза `flying`; разбега нет, полёт сразу «взведён» — касание будет посадкой, не «взлёт сорван». «Ещё раз» (R) — снова в воздухе. Для проверки полёта вдали от старта |
| `--bots=<N>` | другие пилоты: сколько ботов (поверх настройки, 0 — никого) |
| `--seed=<N>` | сид мира (термики, порывы): тот же день при тех же месте, дате, времени и погоде (`world_key`). Без флага «Лететь» из меню — каждый раз новый случайный сид («Ещё раз» — тот же); `--autostart` — сид из `atmosphere.json → seed` |
| `--debug=perf,wind,thermals` | сразу включить отладочные слои F1/F5/F6 |
| `--perf=<с>` | замер старта (`tools/bench/startup_bench.sh`): меню → сам жмёт «Лететь» → `<с>` с полёта, печатает `PERF`-строки (время до меню, «Лететь» → полёт, рывки кадра > 50 мс, сборка шейдеров облаков) и выходит |
| `--air-field=<путь>` | отладка поля воздуха: среднее поле из файла (`<путь>.json` + `.bin`, `WindField.load_file`) вместо расчёта; читает `Atmosphere` (`air_model.enabled` ≠ `off`), `docs/guide/air-model.md` |
| `--net-host[=<порт>]`, `--net-create`, `--net-join=<код>`, `--net-server=<IP:порт>`, `--net-name=`, `--net-seed=`, `--net-code-file=`, `--net-hide-remote` | отладка сети (`network.md`): встроенный сервер и зона / зона на сервере / вход по коду; порт по умолчанию 8080, адрес по умолчанию `127.0.0.1:8080` |
| `--steam`, `--no-steam` | включить Steam в обычной среде разработки / выключить в сборке Steam (`docs/guide/steam.md`) |
| `--crash-report-test` | пробный отчёт о вылете (`docs/guide/crash-report.md`) |

Примеры. Полёт вдали от старта: `godot --path . res://scenes/main.tscn -- --autostart --location=ongudai --site=kayancha_south --temp=31 --wind=5 --wing=training --mass=85 --air-start=1000,300`. Кадр под виртуальным дисплеем: `xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --rendering-method gl_compatibility res://scenes/main.tscn -- --autostart --autopilot --camera=chase --time=12 --screenshot=/tmp/shot.png`. Кадр ботов (бот на разбеге, из кабины, оглянувшись на старт): `godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 -- --autostart --autopilot --autopilot-circle=16,-12 --camera=cockpit --look-at=start --no-overlay --time=33.4 --screenshot=run.png`. Фоны главного меню — `menus-settings.md`.

Скриншотные запуски (не `--headless`) всегда с таймаутом (`timeout 120 godot …`), чтобы зависший процесс не висел.

## Тесты

`godot --headless --path . res://tests/run_tests.tscn -- --filter=game` — тесты `tests/**/test_*.gd` (наследуют `TestCase`, методы `test_*`), `--filter` — подстрока пути; код выхода 1, если есть падения. Тесты, которым нужен настоящий `RenderingDevice` (`TestCase.needs_gpu()`), под `headless` пропускаются; их запускает `tools/gpu_tests.sh [--filter=…]` (окно, флаг `--gpu`). Полная локальная проверка вместо CI — `tools/check.sh [--no-build] [--filter=…]`: импорт, линтер (`tools/lint.sh`), тесты, сборка Linux, smoke-запуск сборки; все запуски идут с временным профилем (`XDG_DATA_HOME`), `project.godot` после запуска возвращается как был. После добавления нового `class_name` — `godot --headless --path . --import`.

Что проверяет набор `tests/game` для главной сцены: сцена грузится; автопилот (W+Shift) стоит → разбег → взлёт → 30 с полёта без ошибок в журнале; анимации stand → run → run_air → climb_in → prone; нет защёлки на отрыве; 5 минут автополёта без ошибок (`ErrorCatcher` — `OS.add_logger`); посадка → экран итога → «Ещё раз»; старт на склоне; статистика и итог; осмотр карты; выбор старта; очередь и боты; сеть; «Подождать час»; пустырь вокруг старта; столкновения. Тесты интерфейса — `tests/ui` (меню, настройки, язык, избранное, популярные места, экран сети, загрузка), сети — `tests/net`, Steam — `tests/steam`. Проверка GPU на загрузке места — `docs/guide/gpu-validation.md`.
