---
type: "guide"
status: "active"
module: "game"
area: "game"
updated: "2026-10-15"
summary: "Сборка игры: главная сцена, Game и порядок шага физики; оглавление частей — камеры и ввод, старт, полёт и итог, мир, меню, боты, сеть."
related: ["docs/guide/game/cameras-input.md", "docs/guide/game/launch.md", "docs/guide/game/flight-flow.md", "docs/guide/game/world-air-time.md", "docs/guide/game/menus-settings.md", "docs/guide/game/bots.md", "docs/guide/game/network.md", "docs/guide/game/cli-tests.md", "docs/guide/architecture.md"]
---
# Сборка игры (scenes/main, scenes/game, scenes/ui)

Главная сцена собирает модули в играбельный полёт: меню → загрузка → полёт ⇄ пауза → итог. Модули не знают друг о друге: связи (`Callable`, сигналы) ставит `Game`. Общие правила кода и контракты модулей — `docs/guide/architecture.md`.

Документ описывает код в `main`. Он разбит на части (лимит 40 КБ на файл); этот файл — вход: что где лежит, дерево сцены, порядок шага физики и оглавление.

## Оглавление частей

| Часть | Разделы |
|---|---|
| [cameras-input.md](game/cameras-input.md) | Камеры; Кабина; Управление (клавиши, мышь, геймпад); Приборы на трапеции; Отладочные слои |
| [launch.md](game/launch.md) | Разбег; Выбор старта и пустырь вокруг него; Осмотр карты; Анимации пилота |
| [flight-flow.md](game/flight-flow.md) | Состояния главной сцены; Загрузка; Итог свободного полёта; Столкновения; «Подождать час» |
| [world-air-time.md](game/world-air-time.md) | Объекты мира; Воздух (заменяемый) и погода из прогноза; Время суток; Графика и замеры |
| [menus-settings.md](game/menus-settings.md) | Главное меню; Настройки пилота; Как добавить настройку и экран; «Об игре» |
| [bots.md](game/bots.md) | Другие пилоты |
| [network.md](game/network.md) | Сетевой полёт в игре (зона, очередь на старт, «Догнать») |
| [cli-tests.md](game/cli-tests.md) | Командная строка; Тесты |

Ссылки вида «docs/guide/game.md → «Другие пилоты»» в коде и конфигах ведут в соответствующую часть из этой таблицы.

## Что где

| Файл | Что |
|---|---|
| `scenes/main.tscn` + `scenes/main.gd` | корень: `Game` + слой `UI` с экранами; состояния `MENU`/`LOADING`/`FLYING`/`PAUSED`/`RESULT`, аргументы командной строки, F12 |
| `scenes/game/game.tscn` + `scripts/game/game.gd` (`Game`) | полётный мир: небо, рельеф, воздух, планер, ввод, камера, приборы, звук; `start()`, `restart()`, `tick()` |
| `scripts/game/input_controller.gd` (`InputController`) | клавиатура / мышь / геймпад → `ControlInput` |
| `scripts/game/camera_rig.gd` (`CameraRig`) | камеры cockpit / chase / free, поворот головы |
| `scripts/game/flight_settings.gd` (`FlightSettings`) | выбор пилота: крыло, масса, место, прогноз, время старта; `world_key()` для сети |
| `scripts/game/world_key.gd` (`WorldKey`) | ключ мира зоны (строка + хэш), версия генератора `VERSION` |
| `scripts/game/start_placement.gd`, `start_spot.gd` | старт в точке с карты: курс вниз по уклону; допустимость выбранной точки |
| `scripts/game/flight_stats.gd` (`FlightStats`) | итоги полёта, «взведение», подтверждение посадки |
| `scripts/game/collision_check.gd` (`CollisionCheck`) | столкновения крыла со зданиями, деревьями у посадок и кронами леса |
| `scripts/game/calm_air.gd` (`CalmAir`) | запасная модель воздуха (ветер + статичные термики) |
| `scripts/game/cloud_whiteout.gd` (`CloudWhiteout`) | «белая мгла» в облаке |
| `scripts/game/pilot_animator.gd` (`PilotAnimator`) | анимации пилота по фазе |
| `scripts/game/world_link.gd` (`WorldLink`) | объекты мира, просеки, ветер для травы/деревьев, лагерь у старта |
| `scripts/game/graphics_presets.gd` (`GraphicsPresets`) | пресеты графики low/medium/high, автовыбор по видеокарте, окно и кадры |
| `scripts/game/autopilot.gd` (`Autopilot`) | синтетический пилот для тестов, smoke и кадров |
| `scripts/game/user_settings.gd` (`UserSettings`) | запись настроек в `user://configs/*.json`, последний выбор, имя пилота, папка снимков |
| `scripts/game/launch_options.gd` (`LaunchOptions`) | аргументы командной строки |
| `scripts/game/favorites.gd`, `recent_places.gd`, `wing_catalog.gd` | избранное, недавние места, каталог крыльев меню |
| `scripts/game/achievement_feed.gd` (`AchievementFeed`) | поток событий полёта для ачивок (`docs/guide/steam.md`) |
| `scripts/game/bot_*.gd`, `wander_pilot.gd` | другие пилоты в небе (часть bots.md) |
| `scripts/game/net_flight.gd`, `net_queue.gd`, `net_bots.gd`, `remote_pilots.gd`, `catch_up_tow.gd` | сетевой полёт (часть network.md) |
| `scripts/game/debug_overlays.gd`, `fkey_hint.gd` | отладочные слои F1/F5/F6 и подсказка клавиш |
| `scripts/ui/*.gd`, `scenes/ui/*.tscn` | меню, пауза, настройки, «Об игре», итог, сеть, загрузка; `UiKit` — вёрстка; `AssetsCredits` — атрибуция из `ASSETS.md` |
| `scenes/ui/theme.tres` | тема: тёмная полупрозрачная панель, акцент — янтарный |
| `locale/ui.csv` | переводы (ключи snake_case, колонки ru, en) |
| `configs/game.json`, `ui.json`, `controls.json`, `camera.json`, `bots.json`, `bot_names.json`, `net.json` | параметры |

## Дерево сцены

```
Main (Node, process ALWAYS)            scenes/main.gd
├── Game (Node3D, PAUSABLE)            scripts/game/game.gd
│   ├── Environment                    SkyEnvironment (небо, солнце, дымка, часы sky.clock)
│   ├── Terrain                        рельеф; грузится в Game.start()
│   ├── Glider                         планер; его _physics_process выключен — шагает Game
│   │   └── Visual/…/InstrumentMount   ← Instrument3D (game.json → mounted_instruments)
│   ├── InputController
│   ├── CameraRig (Camera3D)           кабина — от маркера PilotHead
│   ├── FlightInstrument               ОДИН экран прибора: и на трапеции, и в углу экрана
│   ├── InstrumentOverlay              прибор в углу — только во внешних камерах (FR-21)
│   ├── VarioAudio, FlightAudio
│   ├── WindFieldDebug                 слой F3 «ветер над местностью»
│   └── (создаются в _ready)           WorldLink, Bots, Air (Atmosphere или CalmAir), AirRuntime,
│                                      DebugOverlays, FKeyHint, PilotShiftIndicator, ClockLabel
└── UI (CanvasLayer)
    └── StartMenu, PauseMenu, SettingsPanel, AboutScreen, ResultScreen, ControlsScreen,
        FlightSetupScreen, LoadingScreen   (NetScreen и CatchUpMenu — создаются по требованию)
```

Автозагрузки (`project.godot`): `Config`, `CrashReporter`, `MotionRig`, `SteamService`, `Achievements`, `Activity`, `SteamPresence`, `NetClient`, `NetZone`, `NetPilots`, `LanDiscovery`, `SteamLobby`.

## Порядок обновления

`Game._physics_process(dt)` → `Game.tick(dt)`:

1. время мира: в одиночной игре `sky.clock.advance(dt)` и `air.step(dt)` (при «Подождать час» — `dt·wait_speed`); в сети — шаг до часов зоны (`_net_world_step`); затем `_update_day_weather()`;
2. ждёт час (`_wait_left_s > 0`) или осмотр карты (`inspect_mode`) — дальше крыло не шагает;
3. (тесты/кадры) `autopilot.drive()` — жмёт действия `InputMap`;
4. ввод: `input_controller.on_ground = фаза != "flying"`, `hands_off` (свободная камера, меню «Догнать»), `glider.set_input(input_controller.update(dt))`; в сети — ходьба в очереди на старт;
5. `bots.tick(dt, телеметрия игрока)`;
6. буксир «Догнать» (`tow`) заменяет физику; после столкновения (`_crashed`) крыло стоит;
7. `glider.step(dt)` → сигнал `telemetry_updated` → `FlightInstrument.update` → `VarioAudio.set_vario` → `FlightAudio.update` → `FlightStats.update`; затем `MotionRig.step` (поток движения платформы), `_feed_step` (поток ачивок);
8. `collisions.check(телеметрия)` → `_on_collision`; `_check_finished()` → `flight_ended`.

Собственные `_physics_process` планера и воздуха выключены, чтобы порядок был явным и одинаковым в игре и в тестах (тест зовёт `game.tick()` сам — 30 с полёта считаются за ~2 с). Рендер: планер интерполирует положение в `_process`, камера (`process_priority = 10`) ставится после него.
