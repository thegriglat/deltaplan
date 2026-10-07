---
type: "guide"
status: "active"
module: "game"
updated: "2026-10-03"
summary: "Сборка игры (scenes/main, scenes/game, scenes/ui) — Главная сцена собирает модули в играбельный полёт: меню → полёт ⇄ пауза → итог."
related: []
---
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
| `scripts/game/flight_settings.gd` (`FlightSettings`) | выбор пилота: крыло, масса, прогноз (температура днём, ветер на старте, откуда, облачность), старт |
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

## Камеры (FR-26, FR-21)
C переключает `camera.json → modes`: кабина → сзади → свободная. Прибор в углу (`InstrumentOverlay`) — только во
внешних камерах, в кабине его нет (прибор виден на трапеции). **Сзади** (`chase`) — за планером по курсу, не ниже
`chase.min_agl_m` над рельефом. **Свободная** (`free`) появляется сзади-сбоку и смотрит на пилота, дальше летает сама:
WASD — по взгляду, E/Q — вверх/вниз, Shift — ×`fast_factor`, мышь (захват или правая кнопка) — поворот, колесо —
скорость, V — навести на планер; не ниже `free.min_agl_m`. В ней клавиши двигают камеру, а не крыло:
`InputController.hands_off` — трапеция в триме, на земле пилот стоит (автопилот тестов этим не отключается).
Последняя выбранная клавишей C камера (кабина или сзади; свободная не запоминается) пишется в
`user://pilot_state.json` (`UserSettings.start_camera`) — следующий полёт начинается с неё; без выбора — `default_mode`.
**Старт каждого полёта:** полупрозрачная подсказка (`ControlsScreen.start_hint_keys_text` слева — клавиши, `start_hint_mouse_text` справа — мышь; центр свободен); уходит на первое W или отрыв; `--autostart` её не показывает.
**F12** (`controls.json → keys.screenshot`) — снимок экрана в «Изображения»/Deltaplan/`deltaplan_ГГГГММДД_ЧЧММСС.png` (`UserSettings.screenshot_dir`, нет папки —
`user://screenshots`); на экране ~2 с строка «Снимок: <путь>», путь и в журнале. Клавиши свободной камеры (E/Q, WASD, Shift) и F12 — на экране «Управление».
Клавиши 1–5 / Tab листают планшет в любой камере. Звук вариометра берётся с прибора
`game.json → vario_sound_from[пресет]` (classic_90s — вариометр 90-х на стойке), стрелка и писк совпадают.

## Кабина (FR-26, FR-31)
Глаза — маркер `PilotHead` (пустышка `Head` пилота) + `camera.json → cockpit.offset_m` (голова чуть приподнята).
Голова держит горизонт: курс — вдоль крыла, тангаж — `look_down_deg` от горизонта, крен — доля
`head_roll_follow` крена крыла. FOV 60° по вертикали. В кадре — простор: горизонт, земля, облака; трапеция,
руки и планшет — ниже кадра, парус — выше (как говорят пилоты: «в полёте крыло не видишь»).
Мышь всегда ведёт крыло (трапеция, контракт У1 v3, `docs/contracts/ui-controls.md`); осмотреться — правая кнопка зажата
(трапеция держит положение), V или средняя кнопка — взгляд вперёд. W/S/A/D крыло не двигают никогда: в полёте они
поворачивают голову в кабине (контракт У2 v2): A/D — влево/вправо, W/S — вверх/вниз, `cockpit.head.key_rate_deg_s` °/с,
отпустил — взгляд остаётся, V — вперёд. На земле эти клавиши — шаг и поворот пилота, голова от них не движется.
В камере «сзади» эти клавиши ничего не делают. **Q (держать)** — плавный взгляд на планшет (`cockpit.glance`), отпустил — назад.
Шлем (`cockpit.hidden_nodes`) из кабины не рисуется (слой `hidden_layer`), тело пилота видно при взгляде вниз.
Внутри облака — белая мгла (`game.json → cloud_whiteout`, плотность — `Atmosphere.cloud_density_at`).

## Разбег (FR-9, FR-30)
Контракты С1 v2 / С2 v2 / К3 v3 (`docs/contracts/control-fix.md`), решение пользователя «вариант В».
**Стоя и шагом:** W/S — шаг (`walk_forward`/`walk_back`), A/D — поворот на месте (`turn_left`/`turn_right` →
`ControlInput.turn`, крыло не кренится); нос и крен крыла — как в полёте, действиями трапеции
(`pitch_pull_in`/`pitch_push_out`, `roll_left`/`roll_right` — только стрелки), плюс мышь (при захвате, M) и стик.
**Разбег — держать Shift** (W не нужен, пилот бежит сам): W/S/A/D на разбеге ничего не делают; нос и крен
крыла — мышь, стрелки, стик, как в полёте; курс на бегу идёт дугой за креном крыла (docs/guide/flight.md → «Крен на земле»).
На земле `pitch` — нос крыла (0 — угол разбега крыла `launch.alpha_neutral_deg`), `roll` — заданный крен «руки
пилота» (±`flight.json → ground_bank.command_max_deg`). Клавиши, мышь и стик ведут трапецию одинаково на
земле и в полёте — на отрыве `pitch`/`roll` непрерывны, защёлки нет. Знак клавиш задаёт только карта
`controls.json → keys` (ui-controls, контракт У1 v3: ↑ — от себя, ↓ — на себя). Автопилот тестов жмёт те же действия: Shift и трапецию по углу атаки киля.
**Пустырь вокруг старта.** Старт с карты (`StartPlacement.find_launch`) может попасть в лес — после выбора точки
`Game._choose_start` вызывает `terrain.add_start_clearing` (docs/guide/terrain.md): лес в круге R → луг — деревьев нет,
трава, кусты и камни остаются. R = `game.json → start_search.clearing_radius_m` = 160 м; у встроенных стартов — не меньше. Правило (решение
пользователя): **R ≥ 2 · L_run**, иначе сразу за разбегом деревья и набрать высоту до них нельзя. L_run — разбег с места
до отрыва в штиль на самом пологом пригодном склоне (`min_slope_deg` = 12°) при эталонной массе, по всем крыльям линейки;
не взлетел — дистанция за 10 с (предел самого теста; в игре срыва по времени нет). Замер (`tests/game/test_start_clearing.gd`, живой `GroundRun`,
30.09.2026): sport 71,9 м и combat 69,9 м — в штиль на 12° не отрываются за 10 с; остальные 13–18 м (atlas — срыв
nose_high на 1,2 с). 2 · 71,9 = 144 м, запас ≈ 10 % → 160 м. Тест пересчитывает L_run каждый раз.

## Анимации пилота
`PilotAnimator` (конфиг `game.json → pilot_animation`, контракт — docs/guide/models.md → «Пилот»): фазы земли →
stand/walk/run; отрыв → run_air → climb_in → prone (очередь по длине анимаций во времени симуляции);
у земли при снижении (ниже `climb_out_agl_m`, не раньше `min_air_time_s`) или при выравнивании → climb_out →
flare; посадка → stand. Нет AnimationPlayer — ничего не делает.

## Объекты мира и столкновения
`WorldLink` при загрузке локации: `WorldObjects.setup(terrain, air)` (ветроуказатели, посадки, OSM), просеки
`WorldClearings.build_for(id)` → `terrain.set_clearings`, `terrain.set_wind_sources(mean_wind_at, thermals_near)`,
`terrain.set_pilot(glider)`.

**Столкновения** (`scripts/game/collision_check.gd`, `CollisionCheck`, G05; VR-10, VR-12) — каждый шаг в `Game.tick`,
только ниже 60 м над землёй и не стоя/пешком на земле. Точки крыла: пилот (0,5 м над ступнями), середина
трапеции (1,25 м), килевая труба и концы консолей (высота подвески `flight.json → visual.hang_height_m`,
± половина размаха) — отрезок движения каждой от прошлого шага против препятствий `WorldObjects`
(провода, опоры, деревья и заборы посадок — `obstacles`, здания — `osm_layer.building_obstacles`; те же фигуры,
что у `obstacle_hit`, но через свой кэш мелких клеток 8 м с AABB: в долинах с ЛЭП у клетки индекса 64 м сотни
кандидатов, `obstacle_hit` там ~0,8 мс, кэш — ~15 мкс на шаг). Лес: `terrain.forest_at(пилот) ≥ 0,5` и высота над
рельефом ниже крон — касание кроны; высота крон = самая низкая порода `world.json → trees.species.height_m` ×
(1 − `trees.sink_fraction`) (рельеф — DSM, кроны в нём утоплены), сейчас 7,2 м. Скачок > 20 м за шаг — телепорт,
не путь. Попадание — авария: `flight_ended("landed", {grade: "crash", collision, finish_reason, text})`,
`finish_reason` — `crash_wire` (провод) / `crash_obstacle` (опора, здание, забор) / `crash_trees` (дерево,
кроны); текст — `game.json → collision_texts` по `collision`; звук — `FlightAudio.play_landing` с оценкой crash;
планер стоит до «Ещё раз». Тест — `tests/game/test_collisions.gd` (реальная ЛЭП Онгудая, 20 м выше неё, лес,
поле посадки, время проверки).
Атмосфере источники термиков — `terrain.thermal_source_strength_at`; дымке — `sky.set_inversion_height_msl(
air.get_cloudbase_msl())`.

## Графика
`game.json → graphics` (по умолчанию medium) и `graphics_presets`: каждый пресет — правки конфигов (облака,
деревья, тени, эффекты) и окна (MSAA, доля разрешения 3D); выбор в настройках пишется в user://configs.
Автовыбор по видеокарте (`graphics_autodetect`) есть, но выключен.

### Замеры (NFR-1/NFR-2, `tools/bench/`, RTX 4070 SUPER, пресет medium, 1920×1080, `--disable-vsync`)

FPS — три отметки сим.времени полёта (старт у склона, высота над лесом, вид на облака), камеры кабина/сзади
(`tools/bench/frame_bench.sh`):

| Локация | Ракурс@отметка | средний FPS | 1%-low FPS |
| --- | --- | --- | --- |
| altai | cockpit@2с / chase@2с | 177.7 / 178.1 | 104.2 / 110.0 |
| altai | cockpit@30с / chase@30с | 160.8 / 169.0 | 99.6 / 114.9 |
| altai | cockpit@60с / chase@60с | 176.9 / 184.0 | 80.5 / 97.9 |
| askarovo | cockpit@2с / chase@2с | 188.2 / 181.6 | 92.8 / 79.8 |
| askarovo | cockpit@30с / chase@30с | 175.5 / 183.3 | 79.3 / 132.7 |
| askarovo | cockpit@60с / chase@60с | 176.1 / 183.9 | 114.1 / 118.8 |
| aushkul | cockpit@2с / chase@2с | 80.5 / 110.3 | 43.1 / 55.5 |
| aushkul | cockpit@30с / chase@30с | 98.7 / 179.5 | 39.9 / 117.0 |
| aushkul | cockpit@60с / chase@60с | 188.9 / 193.6 | 102.8 / 119.4 |
| ongudai | cockpit@2с / chase@2с | 79.0 / 69.2 | 39.3 / 31.5 |
| ongudai | cockpit@30с / chase@30с | 82.4 / 176.8 | 43.0 / 110.2 |
| ongudai | cockpit@60с / chase@60с | 84.9 / 88.4 | 39.8 / 43.4 |

Все средние ≥ 60 FPS (NFR-1 формально выполнен), но ongudai заметно медленнее остальных у земли/на разбеге
(средний 69–88, 1%-low 31–43) — узкое место не деревья/здания (у altai построек 27362 против 5482 у ongudai,
и там FPS выше): у ongudai сеть ЛЭП и заборов OSM тяжелее (`wires: 11012, supports: 3767, wire_tiles: 775,
osm_fence_spans: 2230` против 0 заборов и на порядок меньше проводов у остальных локаций) — похоже, провода/опоры/
заборы рисуются отдельными мешами без MultiMesh-батчинга, много draw call'ов у земли. Оптимизация — карточке-
владельцу world-объектов/OSM, не этой.

Время загрузки локации (тёплый кеш `.godot/`, от старта скрипта пробы до первого кадра полёта —
`tools/bench/load_bench.sh`): altai 3.69 с, askarovo 3.18 с, aushkul 3.96 с, ongudai 3.26 с — все ≤ 10 с (NFR-2).

## Состояния главной сцены
`MENU` (мир за меню живёт, ввод выключен, камера `menu_camera_mode`) → «Лететь» → `LOADING` (рельеф, для точки с карты —
из сети) → `FLYING` ⇄ `PAUSED` (Esc: дерево на паузе — физика и `Telemetry.time_s` стоят, `Game.set_paused` глушит
звук и ввод; «Заново» — `Game.restart()` на тот же старт). Конец полёта → через `result_delay_s` → `RESULT` (пауза,
экран итога: главная «В главное меню» → меню, «Ещё раз» / R → тот же старт; «Продолжить» — `Game.continue_on_foot()`:
ходьба по земле, новый разбег — новый полёт; кнопку показывает/прячет ResultScreen).
Прошлый выбор меню хранится в `user://last_flight.json`.

Вход в полёт — один: «Лететь» главного меню (под ней — строка текущего выбора, `StartMenu.summary_text`).
«Полёт…» — только выбор: «Готово» сохраняет его в `user://last_flight.json` и возвращает в меню, «Назад» — без
изменений; на карте — «Выбрать эту точку».
«Популярные места…» (рядом с «Выбрать на карте») — окно `PopularPlacesWindow` (`scripts/ui/popular_places_window.gd`, данные — `PopularPlaces`): страны → места страны с высотой и ветром старта, поиск по названию; выбор места = точка старта по координатам, как с карты; название идёт в «Недавние места». Каталог — `configs/ui.json` → `popular_places_path` (контракт PP-К1, docs/contracts/popular-places.md); файла нет — кнопка скрыта.
«В избранное» (внизу «Полёт…», QL-12) — текущие условия (`FlightSettings.to_dict()`) в `user://favorites.json` (`Favorites`, `scripts/game/favorites.gd`): не больше 8, девятое вытесняет самое старое, одинаковые не дублируются. В главном меню слева — список «Избранное» с автоназванием («Онгудай, 13:00, 3 м/с СЗ, Sport»): щелчок — сразу `fly_requested` с этими условиями, × — удалить. Тест — `tests/ui/test_favorites.gd`.

### Загрузка
На время `LOADING` поверх фона — `LoadingScreen` (`scenes/ui/loading_screen.tscn`): куда летим, этап, полоса,
секунды; «Лететь» и «Полёт…» недоступны. Ход — `terrain.progress` (`LoadProgress`): этапы рельефа (docs/guide/terrain.md →
«Рантайм-загрузка с карты»), затем в `Game.start` — «Погода и термики…», «Камни, кусты и дороги…», «Почти готово…»,
каждый в своём кадре. Шаг физики на время `start()` выключен (воздух и планер ещё не настроены; иначе каждый
долгий кадр догонял бы пропущенные шаги). Ошибка (море, нет сети, нет данных) — текст в меню, состояние `MENU`.
Замер пауз главного потока: `tools/loading/load_probe.tscn` (docs/guide/terrain.md).

## Итог свободного полёта (FR-27b, для группы 11 — ui)
Когда полёт закончен, решает `FlightStats` (не касание само по себе): `Game.tick()` после шага планера спрашивает
`stats.is_finished()` / `stats.finish_reason()` — посадка засчитана, если пилот простоял на земле
`LANDING_CONFIRM_S` (1,5 с); подскоки и чирки короче полёт не завершают. Касание до «взведения» полёта
(`ARM_*`: ≥ 10 с в воздухе и ≥ 10 м над землёй или ≥ 50 м от отрыва) — `takeoff_failed`. Старт в воздухе
(`reset_in_air`, фаза сразу `flying`) взводит полёт сразу. Столкновение с объектом и срыв разбега (`GroundRun`)
завершают полёт сразу. Сигнал один раз: `Game.flight_ended(kind, info)`.

`kind`: `"landed"` — посадка или авария; `"takeoff_failed"` — срыв разбега или касание до взведения.
`info` — сводка `FlightStats.summary()` всегда (перекрывает одноимённые поля касания: `flight_time_s` модели
обнуляется при `reset_in_air`) плюс:

| Ключ | Когда | Что |
|---|---|---|
| `flight_time_s` | всегда | время в воздухе, с |
| `distance_m` | всегда | от точки отрыва по прямой (по горизонтали), м |
| `track_length_m` | всегда | путь по следу, м |
| `height_gain_m` | всегда | макс. высота над точкой отрыва, м |
| `total_climb_m` | всегда | суммарный набор (все участки подъёма), м |
| `max_altitude_msl_m` | всегда | макс. высота над морем, м |
| `avg_speed_ms`, `max_climb_ms`, `max_sink_ms`, `best_thermal_climb_ms`, `circling_time_s`, `circling_fraction`, `avg_glide_ratio`, `took_off` | всегда | см. `FlightStats.summary()` |
| `grade` | посадка | `"soft"` / `"hard"` / `"crash"` (LandingJudge; столкновение — `"crash"`) |
| `vertical_speed_ms`, `horizontal_speed_ms`, `bank_deg` | посадка | скорость касания и крен |
| `position` | посадка | точка касания (Vector3) |
| `finish_reason` | всегда | `landed` / `takeoff_failed` / `crash_wire` / `crash_obstacle` / `crash_trees` |
| `collision`, `text` | столкновение | вид объекта (`game.json → collision_texts`) и текст |
| `reason`, `text` | `takeoff_failed` | `wingtip` (консоль коснулась земли на старте) или `short_flight` (касание до взведения); текст для экрана |

Рекордов и заданий нет (отложено). Тест — `tests/game/test_gameplay.gd`.

## Воздух (заменяемый)
`configs/game.json → air.script` — основная модель (`scripts/atmosphere/atmosphere.gd`), `fallback_script` —
`CalmAir`, если основная не загрузилась. Интерфейс: `set_weather(имя)`, `set_wind(км/ч, откуда°)`,
`set_ground(height_fn, sun_fn)`, `air_velocity_at(pos)`, `step(dt)`, `focus_node`; необязательные —
`set_sun_direction`, `load_static_thermals` (из `thermals` конфига локации), `place_thermals_near`, `mean_wind_at`.
**Погода из прогноза (FR-16).** Пилот задаёт на экране «Полёт…» то, что знает из прогноза: температуру днём
(0…+40 °C), ветер на старте (м/с), откуда ветер (встречный или румб) и облачность (ясно / переменная /
облачно). `Game.start` после загрузки рельефа собирает место (`WeatherModel.ground_context`: долина и средняя
высота вокруг, дата, широта, пояс) и зовёт `air.set_weather(WeatherModel.derive(прогноз, место, час старта))`;
ветер — `air.set_wind(км/ч, курс старта | румб, высота старта)`: выше старта ветер сильнее. Ход дня: раз в
`weather_model.json → diurnal.update_s` игрового времени `Game` мягко ведёт атмосферу к погоде нового часа
(`set_weather(w, blend_s)`), дымку — `sky.set_haze_density`. Модель — docs/guide/atmosphere.md → «Погода из прогноза».

## Время суток (VR-5)
Единый источник солнца — `SunClock` (`scripts/world/sun_clock.gd`), узел `sky.clock` у `SkyEnvironment`.
`Game.start` зовёт `sky.clock.start_flight(terrain.center_lat, center_lon, settings.month, settings.day,
settings.start_hour, utc_offset_h локации)`, `Game.tick` — `sky.clock.advance(dt)` (время идёт только в полёте, пауза его держит),
«Ещё раз» — `reset()` к времени старта. Скорость — `world.json → time.speed` (настройки: ×1, ×10, ×60, стоп),
диапазон 6:00–21:00, часы — поясное время места (`utc_offset_h` в конфиге локации: Алтай UTC+7, Башкирия и Аушкуль UTC+5; нет — `round(lon/15)`); `world.json → time.utc_offset_h`: число — один пояс для всех, `"solar"` — местное солнечное.
Положение: склонение и часовой угол (NOAA), `SunClock.solar_position(lat, lon, день_года, часы)`.
Свет по высоте солнца (`time.light`): цвет и яркость солнца, неба, окружения и дымки — в `SkyEnvironment._apply_sun`.

Как подписаться (рельеф, свои шейдеры): взять `sky.clock.to_sun()` при старте и слушать
`sky.clock.sun_changed(to_sun: Vector3)` — единичный вектор НА солнце (север −Z, восток +X), высота не ниже
`time.min_light_elevation_deg`; сигнал — при сдвиге ≥ 0,05°. Облака и перистые берут направление с
`DirectionalLight3D` сами. Воздух (`set_sun_direction` — тени облаков на источниках) и источники термиков
идут за солнцем по часам: `Game._on_sun_changed` — тени облаков для воздуха и солнце по классам поверхности с
запаздыванием прогрева (`SurfaceHeating` → `Terrain.set_class_sun`: камни и деревни греют и вечером). Сила и
высота термиков по времени дня — `WeatherModel.derive(…, час)` (фаза 2 плана погоды, пилот: «утром мягкие,
днём жёсткие, вечером мягкий воздух, термиков мало»).
Кадры: `tools/shots/tod_shot.tscn -- --out=<папка> [--hours=7,13,19]`. Тест — `tests/world/test_sun_clock.gd`.

## Приборы на трапеции
`game.json → mounted_instruments`: сцена + имя маркера в модели крыла. Сцена с `use_instrument(FlightInstrument)`
показывает общий экран (планшет); другой сцене (вариометр 90-х) зовётся `update(t, dt)`. `face_pilot` доворачивает
экран к глазам пилота в позе полёта. `optional` — тихо пропустить, если нет сцены или маркера.
Клавиши: Tab — следующая страница, 1…5 — страница напрямую (сколько действий `instrument_page_N` в controls.json).

## Управление
| Клавиша | В полёте | На земле | В разбеге |
|---|---|---|---|
| ↑ | трапеция от себя (нос вверх, торможение) | нос крыла вверх | нос крыла вверх |
| ↓ | трапеция на себя (нос вниз, разгон) | нос крыла вниз | нос крыла вниз |
| ← / → | крен: смещение веса влево / вправо | крен крыла | крен крыла, курс — дугой |
| W / S | осмотреться: голова вверх / вниз (кабина) | шаг вперёд / назад | ничего |
| A / D | осмотреться: голова влево / вправо (кабина) | поворот на месте | ничего |
| Shift (держать) | — | разбег | разбег |
| Q (держать) | взгляд на прибор | | |
| Мышь (при захвате, M) | трапеция: от себя — нос вверх, на себя — нос вниз, вбок — крен; без захвата крыло не двигает | нос и крен крыла | нос и крен крыла |
| Правая кнопка (держать) | осмотреться мышью (кабина), трапеция держит положение | | |
| V / средняя кнопка | взгляд вперёд | | |
| C | камера: кабина → сзади → свободная | | |
| W/A/S/D | камера «сзади»: в полёте ничего не делают | | |
| W/A/S/D, E/Q, Shift | свободная камера: движение, вверх/вниз, быстрее (крыло без рук) | | |
| Tab, 1…5 | страницы прибора | | |
| M | захват мыши вкл/выкл | | |
| R | заново с того же старта | | |
| Esc | пауза / назад | | |

Раскладка тангажа — дельтапланерная, не самолётная: от себя (↑, мышь от себя, стик вперёд) — нос вверх и торможение, на себя (↓, мышь на себя) — нос вниз и разгон; на земле так же ведётся нос крыла. Настройка «Инверсия тангажа» (по умолчанию выключена) переворачивает всё разом для стрелок, мыши и стика: «как в самолёте». Режима мыши «Обзор» нет: мышь всегда крыло, W/S/A/D — никогда не крыло.

Геймпад: левый стик — трапеция и крен (на земле — нос и крен крыла), стик вперёд — от себя; кнопка A — разбег. Всё — `configs/controls.json`.

## Настройки пилота
Экран «Настройки» (из меню и паузы): громкость и звук вариометра, чувствительность мыши, инверсия тангажа.
Пишутся патчем в `user://configs/audio.json` и `user://configs/controls.json` — `Config` накладывает их
поверх `res://configs` (третий слой), в файле только изменённые ключи.

**Окно и кадры (QL-13).** В настройках графики: VSync (по умолчанию вкл), предел кадров 30/60/120/144/без предела (по умолчанию 144),
режим окна (оконный/полноэкранный), разрешение окна (список — что помещается в монитор; «Как есть» — не менять),
«Масштаб рендера» (FSR) — рядом. Хранится в `game.json → display` как машинная настройка
(`user://local/configs`, ключ `game.display` в `LOCAL_KEYS` и `auto_cloud.json`). Применяет `GraphicsPresets.apply_display`:
`Engine.max_fps`, `DisplayServer.window_set_vsync_mode`, режим и размер окна; при запуске (из `apply_viewport`) и сразу при
сохранении настроек. Аргументы Godot `--resolution`/`--fullscreen`/`--windowed` перекрывают режим и размер на этот запуск
(VSync и предел кадров применяются всегда). Без VSync и без предела GPU грузится на 100 % — предел кадров для этого и нужен.

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
      [--wing=sport] [--mass=80] [--temp=26] [--wind=3] [--from=launch|270] [--site=sinyukha_west]
      [--latlon=51.80,85.80] [--air-start[=1000[,300]]] [--smoke]
```
`--air-start=<д>[,<h>]` — старт сразу в воздухе: в `<д>` м от старта по его курсу, `<h>` м над рельефом в этой
точке (по умолчанию 1000 и 300), скорость трима, фаза `flying`; разбега нет, полёт сразу «взведён» — касание будет
посадкой, не «взлёт сорван». «Ещё раз» (R) — снова в воздухе. `Game.air_start_m`/`air_start_agl_m`, для проверки
полёта вдали от старта: `godot --path . res://scenes/main.tscn -- --autostart --location=ongudai
--site=kayancha_south --temp=31 --wind=5 --wing=training --mass=85 --air-start=1000,300`.
Скриншоты: `xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --rendering-method gl_compatibility
res://scenes/main.tscn -- --autostart --autopilot --camera=chase --time=12 --screenshot=/tmp/shot.png`.
Фон главного меню (`assets/ui/menu_background.jpg`, кадр из игры): `tools/shots/menu_background.sh
[--size=3840x2160|2560x1440] [--out=файл.jpg]`. Все параметры кадра — `tools/shots/menu_background.json`: флаги игры
(место, старт, крыло, ветер, погода, `--hour`, сид, `--air-start`, автопилот с креном), `clock_hour` (часы неба
на момент кадра — 20:15; старт в 13:00 нужен ради кучевых: в 20:15 модель погоды облаков уже не строит),
`sim_time_s` (кадр в момент симуляции, потом сим замирает), камера от планера в осях его курса (назад/вправо/вверх,
рыскание/тангаж, FOV), пресет графики `high` и масштаб рендера 100 % (без FSR), прогрев кадрами. Окно — виртуальный
дисплей xvfb нужного размера (Vulkan на видеокарте), профиль временный; ~1 мин. После замены jpg перезапустить импорт
(`godot --headless --import`). Два запуска подряд отличаются мелочами (облака, трава).
`--smoke` (проверка сборки, `tools/build.sh`): автостарт с настроек по умолчанию + автопилот, 300 шагов физики,
проверка данных рельефа и атрибуции, код выхода 0/1.

`--bots=<N>` — сколько «других пилотов в небе» (поверх настройки, 0 — никого).
`--look-at=start|bots|bot<N>` — в кабине смотреть на старт / на ботов / на бота N (через «взгляд на прибор»,
для кадров). `--autopilot-circle=<с>[,<крен>]` — автопилот через `<с>` после отрыва кружит с креном (15°).
Кадры ботов: `godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 -- --autostart
--autopilot --autopilot-circle=16,-12 --camera=cockpit --look-at=start --no-overlay --time=33.4
--screenshot=run.png` (бот на разбеге, из кабины, оглянувшись на старт).

## Другие пилоты
`scripts/game/bot_pilots.gd` (узел `Game/Bots`), параметры — `configs/bots.json`, число — настройка
«Другие пилоты в небе» 0–20 (user-конфиг `bots.count`, со следующего полёта). Боты стоят с крылом на ровных местах
позади старта (не в коридоре разбега, не у камней/кустов/деревьев); пока игрок на земле — ждут; после его отрыва —
по одному через `launch.interval_s` (30 с): подход к старту (очередь в стороне), разбег как у игрока
(`BotAgent`: ControlInput walk/turn/run, нос — `bots.json → launch.run_nose` + LaunchNose, крыло ровно). В воздухе — `WanderPilot`
(= `BotPilot`, бывший XcPilot маршрутника, без маршрута): термики по вариометру, «восьмёрка» у склона в сильный
ветер, перелёты к случайным точкам у старта (под облаками). Та же FlightModel и `Atmosphere.air_velocity_at`, шаг —
30/10/4 Гц по удалению от игрока. Расхождение: прогноз сближения, ≥ 50 м / 15 м друг от друга, от игрока — 90 м /
30 м заранее; столкновений с игроком нет. В одном термике одна сторона виража — задаёт первый (игрок тоже).
Посадки нет: коснулся земли — стоит минуту, затем снова встаёт в очередь на старт. Вид — `BotGlider`: та же
модель (GliderVisual, PilotAnimator, руки), парус перекрашен (`sail.gdshader` → hue_shift_rad/sat_scale/value_scale,
палитра `visual.sail_schemes`), шаги — объёмный звук; дальше 500 м — треугольник цвета паруса, дальше 7 км не видно.
Над ботом — имя (`NameTag`, Label3D-билборд, `bots.json → names`): постоянный размер на экране (`font_px` при
высоте 1080, с учётом FOV), пропадает к `fade_end_m` (на земле — к `ground_fade_end_m`); непрозрачный (ALPHA_CUT_DISCARD —
пишет глубину, иначе дымка `haze.gdshader` рисуется поверх), с проверкой глубины — за
горой не видно; во всех камерах. Имена — `configs/bot_names.json`, пул на язык интерфейса (ru, en): без повторов
в полёте, порядок — от сида полёта; смена языка (NOTIFICATION_TRANSLATION_CHANGED) — имена из нового пула.
Настройка «Имена пилотов» (`bots.names.show`) применяется сразу, и из паузы (`Config.reloaded`).

## Тесты
`godot --headless --path . res://tests/run_tests.tscn -- --filter=game`:
главная сцена грузится, автопилот (W+Shift) стоит → разбег → взлёт → 30 с полёта без ошибок в логе,
анимации stand → run → run_air → climb_in → prone; защёлка (W+Shift держат 3 с после отрыва — крыло не
пикирует); 5 минут автополёта без ошибок (`ErrorCatcher` —
`OS.add_logger`); посадка → экран итога → «Ещё раз»; старт на склоне; статистика; опции; настройки; атрибуция; UI.


**Уточнение замеров (W01):** повторный замер Онгудая (medium, 1920×1080) — среднее 175–187 FPS, 1%-low 74–122; прежние 69–88 / 31–43 были сняты при параллельной нагрузке других прогонов на ту же видеокарту. OSM-объекты дают ~50 из 225 draw calls и на FPS не влияют. Заборы теперь MultiMesh по тайлам 500 м.
