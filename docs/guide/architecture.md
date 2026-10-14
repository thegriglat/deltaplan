---
type: "guide"
status: "active"
module: ""
area: "process"
updated: "2026-10-15"
summary: "Архитектура: правила кода и конфигов, координаты, папки модулей, контракты между модулями, заменяемые ассеты."
related: ["docs/guide/game.md", "docs/guide/models.md", "docs/guide/net-protocol.md", "docs/guide/tasks.md"]
---
# Архитектура

Godot 4.7.2 (`godot` в PATH), GDScript, рендер Forward+ (`project.godot`). Цели: Windows, Linux, macOS.

## Общие правила
- **Все числа — в `configs/*.json`** (NFR-7). В коде только физические константы (g) и переводы единиц (`Units`).
  В конфигах удобные пилоту единицы, суффикс ключа обязателен: `_kmh`, `_ms`, `_kg`, `_deg`, `_m`, `_s`, `_hz`.
  Ключи на `_` — комментарии (`"_doc": "..."`). Каждый параметр описывается в `_doc` или рядом `"<ключ>_doc"`.
- Чтение: `Config.get_config("wings/sport")`, `Config.value("sim", "physics_hz")`, `Config.list_configs("wings")`. Конфиг складывается слоями (глубокое слияние, каждый следующий поверх): `res://configs` → `configs/` рядом с исполняемым файлом (только сборка) → `user://configs` (правки пилота, в Steam Cloud) → `user://local/configs` (машинные настройки: графика и т. п., в облако не идут).
- Внутри симуляции всё в СИ: м, м/с, кг, с, радианы.
- Физика — только в `_physics_process` (фиксированный шаг, `configs/sim.json → physics_hz`, NFR-3). Рендер интерполирует.
- Интерфейс — русский и английский (NFR-4): весь текст для пилота — через `tr("ключ")`, ключи snake_case с префиксом области (`menu_fly`, `result_crash`, `tab_vario`) в `locale/ui.csv` (колонки ru, en; формат `%s` — в значениях). Русский текст ключом в `tr()` не пишем (проверяет `tests/ui/test_language.gd`). Названия из конфигов (крылья, места, старты, пресеты, подсказки управления) — тоже ключи. Язык — `Language` (`scripts/ui/language.gd`), `game.json → language` (пусто — английский, от локали ОС не зависит); при смене экраны пересоздаются (`main.gd → _rebuild_ui`).
- В полёте нет HUD с данными и подсказками: цифры — только через приборы (FR-21, FR-22). Исключения, которые пилот видит или отключает настройками: прибор в углу во внешних камерах, индикатор смещения пилота, часы текстом во внешних камерах, подсказка управления на старте полёта, отладочные слои F1–F6 (`docs/guide/game/cameras-input.md`).

## Система координат
- X — восток, **−Z — север**, Y — вверх. **Y = высота над уровнем моря**, метры.
- Начало координат X/Z — центр локации (задан в `configs/locations/<id>.json`).
- Курс: 0° — север, по часовой. Крен: + вправо. Тангаж: + нос вверх.

## Модули и папки
Распределение по папкам; кто и как работает над модулем — `.claude/workflow.md`. Подробное устройство — в гайдах `docs/guide/` (ссылки в таблице).

| Папка | Что | Описание |
|---|---|---|
| `scripts/core/` | `Config` (автозагрузка), `Units`, `ControlInput`, `Telemetry`, `LoadProgress`, `Activity`, отчёты о вылетах — общие типы и сервисы | `crash-report.md` |
| `scripts/flight/`, `configs/wings/`, `configs/wing_groups.json`, `wing_classes.json`, `pilot.json`, `flight.json`, `pendulum.json`, `tests/flight/` | модель полёта, разбег, посадка, маятник | `flight.md` |
| `scripts/terrain/`, `scripts/world/`, `configs/locations/`, `configs/world.json`, `tools/terrain/`, `tests/terrain/` | рельеф, трава и деревья (`grass_field.gd`, `grass.gdshader`, `tree_placer.gd`, `terrain_tree_models.gd`, `forest_impostors.*`, `configs/vegetation.json`), небо, туман, солнце (`SunClock`) | `terrain.md`, `vegetation.md`, `osm-tiles.md`, `location-data.md` |
| `scripts/atmosphere/`, `configs/weather/`, `atmosphere.json`, `weather_model.json`, `tests/atmosphere/` | термики, ветер, облака, погода из прогноза, поле воздуха | `atmosphere.md`, `air-model.md`, `air-model-gpu.md` |
| `scripts/instruments/`, `scripts/audio/`, `configs/instruments.json`, `audio.json`, `tests/instruments/` | вариометр, планшет, звук | `instruments.md`, `telltale.md` |
| `scripts/world_objects/`, `scenes/world_objects/`, `configs/world_objects.json` | объекты мира: ветроуказатели, посадочные площадки, здания из OSM, лагерь у старта, препятствия | `world-objects.md` |
| `scripts/tasks/`, `scenes/tasks/`, `configs/tasks/`, `tests/tasks/` | задания, тренировки, рекорды (FR-35…37); логика готова, в `Game.tick()` не подключена | `tasks.md` |
| `scripts/net/`, `server/`, `configs/net.json`, `tests/net/` | клиент сетевой игры, встроенный сервер, Go-сервер | `net-protocol.md`, `game/network.md` |
| `scripts/steam/`, `steam/`, `configs/steam.json`, `achievements.json`, `tests/steam/` | Steam: сервис, ачивки, присутствие, лобби | `steam.md` |
| `scripts/motion_rig/`, `configs/motion_rig.json` | вывод в симулятор движения | `motion-rig.md` |
| `scripts/ui/`, `scenes/ui/`, `locale/`, `configs/ui.json` | меню, пауза, настройки, «Об игре», итог, сеть | `game/menus-settings.md` |
| `scenes/main.*`, `scripts/game/`, `scenes/game/`, `configs/game.json`, `controls.json`, `camera.json`, `bots.json` | сборка, камеры, ввод, боты, сетевой полёт | `game.md` |
| `docs/research/`, `tools/research/` | исследования и эксперименты | `docs/INDEX.md` |

## Контракты между модулями
Модули не знают друг о друге напрямую — связываются через `Callable`/ноды, которые передаёт главная сцена (`Game`). Контракты стыков живых модулей — `docs/contracts/`; ниже — сам стык в `main`.

**Рельеф** (`scripts/terrain/terrain.gd`, нода `Terrain`, группа `"terrain"`):
- `height_at(x: float, z: float) -> float` — высота земли над уровнем моря, м. Быстро, можно звать 1000+ раз за шаг.
- `normal_at(x: float, z: float) -> Vector3`
- `get_start_sites() -> Array[Dictionary]` — `{id, name, position: Vector3, heading_deg, lat, lon}` стартовые площадки.
- `sun_exposure_at(x, z) -> float` 0..1 — освещённость склона солнцем.
- `surface_at(x, z) -> int` — класс поверхности (WorldCover: лес, луг, пашня, скалы, вода, застройка, снег); `forest_at(x, z)` — доля леса 0..1.
- `thermal_source_strength_at(x, z) -> float` 0..1 — сила источника термиков (из потока тепла `SurfaceHeat` по классу, склону и влажности + усиление у границ поле–лес; `atmosphere.md` → «Сила источника аналитических термиков»). Передаётся в `Atmosphere.set_ground` как `sun_fn`.
- `get_landing_sites() -> Array[Dictionary]` — посадочные площадки.

**Атмосфера** (`scripts/atmosphere/atmosphere.gd`, нода `Atmosphere`, группа `"atmosphere"`):
- `set_ground(height_fn: Callable, sun_fn: Callable, surface_fn := Callable())` — функции рельефа.
- `set_weather(w: String | Dictionary, blend_s := -1.0)` — погода: имя эталона (`configs/weather/*`, тесты) или словарь `WeatherModel.derive` (игра, FR-16); `blend_s ≥ 0` — мягкий переход без пересоздания термиков.
- `set_wind(км/ч, откуда_°, ref_msl := NAN)` — ветер прогноза на высоте `ref_msl` (старт); выше — сильнее.
- `air_velocity_at(pos: Vector3) -> Vector3` — скорость воздуха (ветер + вертикальные потоки), м/с. Дёшево: зовётся несколько раз за шаг (центр и концы крыла).
- `step(dt: float)` — продвинуть время атмосферы (жизнь термиков). Шагает `Game.tick` (собственный `_physics_process` ноды выключен — порядок явный).
- Рисует облака сама (дочерние ноды). Остальной интерфейс воздуха и запасной `CalmAir` — `game/world-air-time.md`.

**Полёт** (`scripts/flight/`):
- `FlightModel` (RefCounted, без нод, тестируется headless): `setup(wing_cfg: Dictionary, pilot_cfg: Dictionary, flight_override := {})`, `step(dt, input: ControlInput, air_fn: Callable, ground_fn: Callable)`, `telemetry: Telemetry`, `reset_on_ground(pos, heading_deg)`.
- `Glider` (Node3D, `scenes/glider/glider.tscn`): держит `FlightModel` и визуал, `setup(wing_id, pilot_mass_kg, apparatus)`, `set_input`, `step(dt)` (шагает `Game`, не собственный `_physics_process`); сигналы `telemetry_updated(t: Telemetry)`, `landed(result: Dictionary)`, `takeoff_failed(reason)`, `took_off`.

**Приборы и звук** (`scripts/instruments/`, `scripts/audio/`):
- `Vario` (RefCounted): фильтр, среднее за N с — из `Telemetry`.
- `FlightInstrument` (сцена): экран прибора в SubViewport → текстура для модели на трапеции и для угла экрана. Метод `update(t: Telemetry, dt := -1.0)`; `set_task`, `set_task_state` для заданий.
- `VarioAudio` (Node): процедурный звук вариометра через AudioStreamGenerator. `set_vario(ms: float)`.

**Объекты мира** (`scripts/world_objects/world_objects.gd`, нода `WorldObjects`):
- `setup(terrain, air)` — принимает рельеф и атмосферу для позиционирования и обдува ветроуказателей.
- `obstacle_hit(a: Vector3, b: Vector3) -> Dictionary {kind: building|tree, point}` — проверка отрезка движения на столкновение со зданием или деревом посадки (интеграция — `scripts/game/collision_check.gd`).
- `get_landing_sites() -> Array[Dictionary]`, `is_clear_at(x, z)`, статический `clearing_mask_for(location_id) -> Image`, `WorldClearings.build_for(id)` (`world_clearings.gd`), сигнал `built`.

**Задания** (`scripts/tasks/`, без нод, тестируется headless): `Task.load_config / list_available`, `TaskTracker`, `TrainingMode`, `FlightRecords.add_flight` — `tasks.md`; в `Game.tick()` не подключены.

**Сеть и Steam:** `NetClient` / `NetZone` / `NetPilots` (автозагрузки), `NetFlight` (связка с `Game`) — `game/network.md`, протокол — `net-protocol.md`; `SteamService` — единственная точка доступа к GodotSteam — `steam.md`.

## Тесты
Подробно — `docs/guide/game/cli-tests.md`.
- `godot --headless --path . --import` — после добавления новых `class_name` (обновляет кеш классов).
- `godot --headless --path . res://tests/run_tests.tscn -- --filter=flight` — тесты (`tests/**/test_*.gd`, наследуют `TestCase`); тесты, которым нужен настоящий GPU, — `tools/gpu_tests.sh`; всё вместе (импорт, линтер, тесты, сборка, smoke) — `tools/check.sh`.
- **Скриншотные запуски** (не `--headless`, через xvfb или `DISPLAY=:0`) — всегда с таймаутом (`timeout 120 godot ...`), чтобы зависший процесс не висел; `--audio-driver Dummy` — по желанию.
- Скриншоты: `xvfb-run -a godot --path . --rendering-method gl_compatibility <сцена>` + сохранение `get_viewport().get_texture().get_image().save_png(...)`, либо `--screenshot=` главной сцены.

## Заменяемые модели и текстуры
Модели и текстуры будут заменяться на более качественные, поэтому код не зависит от конкретного ассета.
- **Путь к ассету берётся из конфига** (например `configs/wings/<id>.json → visual_model`, `configs/instruments.json → model_path`, `configs/pilot.json → visual.visual_model`), а не зашит в код.
  Замена ассета = новый файл + правка пути, код не меняется.
- **Визуал — отдельная сцена-обёртка** (`scenes/<модуль>/<что>_visual.tscn`) со стандартными именованными точками крепления (`Marker3D`):
  например у крыла `HangPoint`, `WingCG`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL`, `WingTipR` (список и назначение — `docs/guide/models.md`); `PilotHead` — в модели пилота.
  Логика ищет эти маркеры по имени и не знает про меши внутри. Новая модель должна содержать те же маркеры.
- **Масштаб и оси:** 1 единица = 1 м, вперёд −Z, вверх +Y. Модели из Blender экспортируются в glTF (`.glb`) с «+Y up».
- **Анимируемые части** (сдвиг пилота по крену, трапеция, парус) — отдельные ноды с понятными именами;
  код двигает ноды или передаёт параметры в материал (`shader parameter`), а не правит вершины.
- **Материалы:** параметры (цвета, шероховатость, пути к текстурам) — в `.tres`-материалах или в конфиге, не в коде.
  Шейдеры принимают текстуры через `uniform`, чтобы процедурную заглушку можно было заменить картинкой.
- **Запасной вариант:** если ассет не найден, модуль строит простую процедурную заглушку и пишет предупреждение в лог. Игра не падает.
- **Исходники моделей:** `.blend` и скрипты генерации лежат в `assets/source/` и `tools/blender/`, готовые `.glb` — в `assets/models/`. Каждый ассет вносится в [ASSETS.md](../../ASSETS.md).
- **Blender 4.3** (`blender`). Модели можно генерировать скриптом: `blender --background --python tools/blender/<скрипт>.py`.

## Модульность и поддерживаемость (NFR-8)
Код пишем так, как принято в Godot ([best practices](https://docs.godotengine.org/en/stable/tutorials/best_practices/index.html)):
- **Сцена = самостоятельный компонент.** Сцену модуля можно открыть и запустить отдельно (есть `*_preview.tscn`); она не лезет в чужие части дерева.
- **«Вызов вниз, сигнал вверх».** Родитель вызывает методы детей; дети сообщают наверх только сигналами.
  Никаких `get_node("../../Something")` и `get_parent().get_parent()`.
- **Зависимости передаются явно:** через `@export`-поля, методы `set_*` или `Callable`, которые выставляет главная сцена. Группы (`"terrain"`, `"atmosphere"`) — только для редких глобальных запросов (камера, отладка).
- **Autoload — для глобальных сервисов** (`project.godot → [autoload]`: `Config`, `CrashReporter`, `MotionRig`, `SteamService`, `Achievements`, `Activity`, `SteamPresence`, `NetClient`, `NetZone`, `NetPilots`, `LanDiscovery`, `SteamLobby`). Сетевые и Steam-сервисы держат состояние соединения и зоны, потому что живут дольше одного полёта; состояние самого полёта (планер, воздух, рельеф) в autoload не держим — оно в `Game`.
- **Композиция вместо наследования:** поведение собирается из дочерних нод и компонентов, глубокие иерархии классов не строим.
- **Логика отдельно от нод.** Расчёты — в `RefCounted`-классах (например `FlightModel`, `Vario`), которые тестируются headless. Ноды — тонкая обёртка: время, ввод, визуал.
- **Данные — в конфигах и ресурсах** (`JSON`, `.tres`), не в коде.
- **Статическая типизация везде:** типы у переменных, параметров и возвращаемых значений, `class_name` у переиспользуемых классов.
- **Стиль — официальный [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html):** `snake_case` для функций и переменных, `PascalCase` для классов и нод, `CONSTANT_CASE` для констант, порядок членов класса как в гайде, строки ≤ 100 символов, отступ — табы.
- **Проверка:** `tools/lint.sh` (gdtoolkit через `uvx`; входит в `tools/check.sh`) и тесты. Новый модуль приходит с тестами и описанием в `docs/guide/`.
- **Маленькие файлы и функции:** скрипт отвечает за одну вещь; ориентир — до ~400 строк. На деле крупнейшие файлы больше (`scripts/game/game.gd` ~1600 строк, `scenes/main.gd` ~1300): там сосредоточена сборка игры, часть логики вынесена в `RefCounted`-классы рядом.
