# Сборка игры (scenes/main, scenes/game, scenes/ui)

Главная сцена собирает модули в играбельный полёт: меню → полёт ⇄ пауза → итог.
Модули не знают друг о друге — связи (Callable, сигналы) ставит `Game`.

## Что где
| Файл | Что |
|---|---|
| `scenes/main.tscn` + `scenes/main.gd` | корень: `Game` + слой `UI` с экранами; переходы между состояниями, аргументы командной строки |
| `scenes/game/game.tscn` + `scripts/game/game.gd` (`Game`) | полётный мир: небо, рельеф, воздух, планер, ввод, камера, приборы, звук; `start()`, `restart()`, `tick()` |
| `scripts/game/input_controller.gd` (`InputController`) | клавиатура / мышь / геймпад → `ControlInput` (FR-30…33) |
| `scripts/game/camera_rig.gd` (`CameraRig`) | камеры cockpit / chase / free (FR-26), поворот головы мышью (FR-31) |
| `scripts/game/flight_settings.gd` (`FlightSettings`) | выбор пилота: крыло, масса, погода, ветер, старт |
| `scripts/game/start_placement.gd` (`StartPlacement`) | старт в точке с карты: ближайший склон, курс вниз по склону |
| `scripts/game/flight_stats.gd` (`FlightStats`) | итоги полёта для экрана после посадки |
| `scripts/game/calm_air.gd` (`CalmAir`) | запасная модель воздуха (ветер + статичные термики) |
| `scripts/game/cloud_whiteout.gd` (`CloudWhiteout`) | «белая мгла» в облаке: туман окружения по плотности облака у камеры |
| `scripts/game/pilot_animator.gd` (`PilotAnimator`) | анимации пилота по фазе: stand/walk/run → run_air → climb_in → prone → climb_out → flare |
| `scripts/game/world_link.gd` (`WorldLink`) | объекты мира (WorldObjects), просеки для деревьев, ветер для травы, столкновения |
| `scripts/game/graphics_presets.gd` (`GraphicsPresets`) | пресеты графики low/medium/high = правки конфигов в user://configs |
| `scripts/game/autopilot.gd` (`Autopilot`) | синтетический пилот для тестов, smoke и скриншотов |
| `scripts/game/user_settings.gd` (`UserSettings`) | запись настроек в `user://configs/*.json`, последний выбор меню |
| `scripts/game/launch_options.gd` (`LaunchOptions`) | аргументы командной строки |
| `scripts/ui/*.gd`, `scenes/ui/*.tscn` | меню, пауза, настройки, «Об игре», итог; `UiKit` — вёрстка; `AssetsCredits` — атрибуция из ASSETS.md |
| `scenes/ui/theme.tres` | тема: тёмная полупрозрачная панель, акцент — янтарный |
| `locale/ui.csv` | переводы (ключ — русский текст; ru, en) |
| `configs/game.json`, `configs/ui.json`, `configs/controls.json`, `configs/camera.json` | параметры |

## Дерево сцены
```
Main (Node, process ALWAYS)            scenes/main.gd
├── Game (Node3D, PAUSABLE)            scripts/game/game.gd
│   ├── Environment                    SkyEnvironment (небо, солнце, дымка)
│   ├── Terrain                        рельеф; грузится в Game.start()
│   ├── Glider                         планер; его _physics_process выключен — шагает Game
│   │   └── Visual/…/InstrumentMount   ← Instrument3D (game.json → mounted_instruments)
│   ├── InputController
│   ├── CameraRig (Camera3D)           кабина — от маркера PilotHead
│   ├── FlightInstrument               ОДИН экран прибора: и на трапеции, и в углу экрана
│   ├── InstrumentOverlay              прибор в углу — только во внешних камерах (FR-21)
│   ├── VarioAudio, FlightAudio
│   └── Air (создаётся в коде)         Atmosphere или CalmAir (game.json → air)
└── UI (CanvasLayer)
    └── StartMenu, PauseMenu, SettingsPanel, AboutScreen, ResultScreen
```

## Порядок обновления
`Game._physics_process(dt)` → `Game.tick(dt)`:
1. `air.step(dt)` — время атмосферы;
2. (тесты/скриншоты) `autopilot.drive()` — жмёт действия InputMap;
3. ввод: `input_controller.on_ground = фаза != "flying"`, `glider.set_input(input_controller.update(dt))`;
4. планер: `glider.step(dt)` → сигнал `telemetry_updated`;
5. по сигналу: `FlightInstrument.update(t)` → `VarioAudio.set_vario(Vario.vario_ms)` → `FlightAudio.update(t, extra)` → `FlightStats.update(t)`.

Собственные `_physics_process` планера и атмосферы выключены, чтобы порядок был явным и одинаковым в игре и в
тестах (тест зовёт `game.tick()` сам — 30 с полёта считаются за ~2 с). Рендер: планер интерполирует положение в
`_process`, камера (`process_priority = 10`) ставится после него.

## Кабина (FR-26, FR-31)
Глаза — маркер `PilotHead` (пустышка `Head` пилота) + `camera.json → cockpit.offset_m` (голова чуть приподнята).
Голова держит горизонт: курс — вдоль крыла, тангаж — `look_down_deg` от горизонта, крен — доля
`head_roll_follow` крена крыла. FOV 60° по вертикали. В кадре — простор: горизонт, земля, облака; трапеция,
руки и планшет — ниже кадра, парус — выше (как говорят пилоты: «в полёте крыло не видишь»).
Мышь — поворот головы; **Q (держать)** — плавный взгляд на планшет (`cockpit.glance`), отпустил — назад.
Шлем (`cockpit.hidden_nodes`) из кабины не рисуется (слой `hidden_layer`), тело пилота видно при взгляде вниз.
Внутри облака — белая мгла (`game.json → cloud_whiteout`, плотность — `Atmosphere.cloud_density_at`).

## Разбег (FR-9, FR-30)
На земле: W — идти, **W+Shift — разбег**, S — назад, A/D — поворот. Нос крыла на разбеге держится сам
(`controls.json → ground.run_nose_neutral` = 0,3 — отрыв у всех крыльев и масс в штиль и при встречном до
6 м/с на склоне 17°), ↑/↓ — подстройка (`nose_trim_range`). **Защёлка при отрыве:** клавиши тангажа/крена,
зажатые в момент отрыва, не действуют, пока их не отпустят; трапеция за `takeoff_latch.trim_time_s` уходит в
трим — зажатая W не бросает крыло в пике. Автопилот тестов жмёт те же действия (W = walk_forward + pitch_pull_in).

## Анимации пилота
`PilotAnimator` (конфиг `game.json → pilot_animation`, контракт — docs/models.md → «Пилот»): фазы земли →
stand/walk/run; отрыв → run_air → climb_in → prone (очередь по длине анимаций во времени симуляции);
у земли при снижении (ниже `climb_out_agl_m`, не раньше `min_air_time_s`) или при выравнивании → climb_out →
flare; посадка → stand. Нет AnimationPlayer — ничего не делает.

## Объекты мира и столкновения
`WorldLink` при загрузке локации: `WorldObjects.setup(terrain, air)` (ветроуказатели, посадки, OSM), просеки
`WorldClearings.build_for(id)` → `terrain.set_clearings`, `terrain.set_wind_sources(mean_wind_at, thermals_near)`,
`terrain.set_pilot(glider)`. Каждый шаг — `obstacle_hit(прошлое, текущее положение)`; попадание — авария
(`flight_ended("landed", {grade: "crash", collision, text})`, тексты — `game.json → collision_texts`).
Атмосфере источники термиков — `terrain.thermal_source_strength_at`; дымке — `sky.set_inversion_height_msl(
air.get_cloudbase_msl())`.

## Графика
`game.json → graphics` (по умолчанию medium) и `graphics_presets`: каждый пресет — правки конфигов (облака,
деревья, тени, эффекты) и окна (MSAA, доля разрешения 3D); выбор в настройках пишется в user://configs.
Автовыбор по видеокарте (`graphics_autodetect`) есть, но выключен.

## Состояния главной сцены
`MENU` (мир за меню живёт, ввод выключен, камера `menu_camera_mode`) → «Лететь» → `LOADING` (рельеф, для точки с карты —
из сети) → `FLYING` ⇄ `PAUSED` (Esc, дерево на паузе). Посадка или срыв взлёта → через `result_delay_s` →
`RESULT` (пауза, экран итога: «Ещё раз» / «Продолжить» после мягкой и жёсткой посадки / «В меню»).
Прошлый выбор меню хранится в `user://last_flight.json`.

## Воздух (заменяемый)
`configs/game.json → air.script` — основная модель (`scripts/atmosphere/atmosphere.gd`), `fallback_script` —
`CalmAir`, если основная не загрузилась. Интерфейс: `set_weather(имя)`, `set_wind(км/ч, откуда°)`,
`set_ground(height_fn, sun_fn)`, `air_velocity_at(pos)`, `step(dt)`, `focus_node`; необязательные —
`set_sun_direction`, `load_static_thermals` (из `thermals` конфига локации), `place_thermals_near`, `mean_wind_at`.
Ветер «в лоб старту» (`wind_mode = into_site`) — сила из пресета погоды, направление — курс старта.

## Приборы на трапеции
`game.json → mounted_instruments`: сцена + имя маркера в модели крыла. Сцена с `use_instrument(FlightInstrument)`
показывает общий экран (планшет); другой сцене (вариометр 90-х) зовётся `update(t, dt)`. `face_pilot` доворачивает
экран к глазам пилота в позе полёта. `optional` — тихо пропустить, если нет сцены или маркера.
Клавиши: Tab — следующая страница, 1…5 — страница напрямую (сколько действий `instrument_page_N` в controls.json).

## Управление
| Клавиша | В полёте | На земле | В разбеге |
|---|---|---|---|
| W / ↑ | трапеция на себя (разгон) | W — шаг вперёд | ↑ — нос чуть выше |
| S / ↓ | трапеция от себя (торможение) | S — шаг назад | ↓ — нос чуть ниже |
| A / ← , D / → | смещение веса влево / вправо | поворот на месте | выравнивание крыла |
| W + Shift (держать) | — | разбег | разбег (нос держится сам) |
| Q (держать) | взгляд на прибор | | |
| Мышь | поворот головы (или трапеция — в настройках) | | |
| V / средняя кнопка | взгляд вперёд | | |
| C | камера: кабина → сзади → свободная | | |
| Tab, 1…5 | страницы прибора | | |
| M | захват мыши вкл/выкл | | |
| R | заново с того же старта | | |
| Esc | пауза / назад | | |

Геймпад: левый стик — трапеция и крен (на земле — ходьба), кнопка A — разбег. Всё — `configs/controls.json`.

## Настройки пилота
Экран «Настройки» (из меню и паузы): громкость и звук вариометра, чувствительность мыши, инверсия тангажа,
режим мыши. Пишутся патчем в `user://configs/audio.json` и `user://configs/controls.json` — `Config` накладывает их
поверх `res://configs` (третий слой), в файле только изменённые ключи.

### Как добавить настройку
1. Параметр уже есть в каком-то `configs/<имя>.json` (NFR-7).
2. В `scripts/ui/settings_panel.gd`: элемент в `_ready()` (`UiKit.slider_row` / `UiKit.row`), чтение в
   `load_values()`, запись в `save()` через `UserSettings.save_patch("<имя>", {…}, config_dir)`.
3. Если значение закешировано в ноде — применить в `Game.apply_user_settings()`.
4. Строку подписи — в `locale/ui.csv`.

### Как добавить экран
1. `scripts/ui/<экран>.gd` (`extends Control`, `class_name`), вёрстка в `_ready()` через `UiKit`, наружу — только
   сигналы (`closed`, `…_requested`).
2. `scenes/ui/<экран>.tscn` — корень Control на весь экран, `theme = theme.tres`, скрипт.
3. Инстанс в `scenes/main.tscn` под `UI`, подключение сигналов в `main.gd → _connect_ui()`, показ через
   `_open_overlay(экран, откуда)` (Esc вернёт назад).
4. Тексты — через `tr()`, ключи и переводы — `locale/ui.csv`.

## «Об игре» (FR-27a)
Текст собирается при открытии: таблицы из `ASSETS.md` (`AssetsCredits.parse_tables`: заголовки `##` и таблицы
`| … |`, колонки «Что», «Источник», «Лицензия») + тексты лицензий (`configs/ui.json → license_files`).
Эти файлы кладутся в сборку: `export_presets.cfg → include_filter`.

## Командная строка
```
godot --path . res://scenes/main.tscn -- [--autostart] [--autopilot] [--camera=cockpit|chase|free]
      [--screenshot=файл.png] [--time=с] [--pause|--settings|--about] [--look=рыскание,тангаж]
      [--wing=sport] [--mass=80] [--weather=medium] [--site=sinyukha_west] [--wind=into_site|preset]
      [--latlon=51.80,85.80] [--smoke]
```
Скриншоты: `xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --rendering-method gl_compatibility
res://scenes/main.tscn -- --autostart --autopilot --camera=chase --time=12 --screenshot=/tmp/shot.png`.
`--smoke` (проверка сборки, `tools/build.sh`): автостарт с настроек по умолчанию + автопилот, 300 шагов физики,
проверка данных рельефа и атрибуции, код выхода 0/1.

## Тесты
`godot --headless --path . res://tests/run_tests.tscn -- --filter=game`:
главная сцена грузится, автопилот (W+Shift) стоит → разбег → взлёт → 30 с полёта без ошибок в логе,
анимации stand → run → run_air → climb_in → prone; защёлка (W+Shift держат 3 с после отрыва — крыло не
пикирует); 5 минут автополёта без ошибок (`ErrorCatcher` —
`OS.add_logger`); посадка → экран итога → «Ещё раз»; старт на склоне; статистика; опции; настройки; атрибуция; UI.
