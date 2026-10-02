# Архитектура

Godot 4.7.2 (`godot` в PATH), GDScript, рендер Forward+. Цели: Windows + Linux.

## Общие правила
- **Все числа — в `configs/*.json`** (NFR-7). В коде только физические константы (g) и переводы единиц (`Units`).
  В конфигах удобные пилоту единицы, суффикс ключа обязателен: `_kmh`, `_ms`, `_kg`, `_deg`, `_m`, `_s`, `_hz`.
  Ключи на `_` — комментарии (`"_doc": "..."`). Каждый параметр описывается в `_doc` или рядом `"<ключ>_doc"`.
- Чтение: `Config.get_config("wings/sport")`, `Config.value("sim", "physics_hz")`, `Config.list_configs("wings")`.
- Внутри симуляции всё в СИ: м, м/с, кг, с, радианы.
- Физика — только в `_physics_process` (фиксированный шаг, `configs/sim.json → physics_hz`, NFR-3). Рендер интерполирует.
- Интерфейс — русский и английский (NFR-4): весь текст для пилота — через `tr("ключ")`, ключи snake_case с префиксом области (`menu_fly`, `result_crash`, `tab_vario`) в `locale/ui.csv` (колонки ru, en; формат `%s` — в значениях). Русский текст ключом в `tr()` не пишем (проверяет `tests/ui/test_language.gd`). Названия из конфигов (крылья, места, старты, пресеты, подсказки управления) — тоже ключи. Язык — `Language` (`scripts/ui/language.gd`), `game.json → language` (пусто — по системе); при смене экраны пересоздаются (`main.gd → _rebuild_ui`).
- Никакого HUD и никаких визуальных подсказок (FR-21, FR-22). Весь вывод данных — через приборы.

## Система координат
- X — восток, **−Z — север**, Y — вверх. **Y = высота над уровнем моря**, метры.
- Начало координат X/Z — центр локации (задан в `configs/locations/<id>.json`).
- Курс: 0° — север, по часовой. Крен: + вправо. Тангаж: + нос вверх.

## Модули и владельцы
| Папка | Что | Кто пишет |
|---|---|---|
| `scripts/core/` | Config, Units, ControlInput, Telemetry — общие типы | только интегратор |
| `scripts/flight/`, `configs/wings/`, `configs/wing_groups.json`, `configs/pilot.json`, `configs/flight.json`, `tests/flight/` | модель полёта, разбег, посадка | агент flight |
| `scripts/terrain/`, `scripts/world/`, `tools/terrain/`, `data/terrain/`, `configs/locations/`, `configs/world.json`, `tests/terrain/` | рельеф, небо, туман, солнце | агент terrain |
| `scripts/atmosphere/`, `configs/weather/`, `configs/atmosphere.json`, `tests/atmosphere/` | термики, ветер, облака | агент atmosphere |
| `scripts/instruments/`, `scripts/audio/`, `configs/instruments.json`, `configs/audio.json`, `tests/instruments/` | вариометр, прибор, звук | агент instruments |
| `scripts/world_objects/`, `scenes/world_objects/`, `configs/world_objects.json`, `data/osm/`, `tools/osm/`, `tests/world_objects/` | объекты мира: ветроуказатели, посадочные площадки, дороги/здания/ЛЭП из OSM, столкновения | агент world_objects |
| `scripts/vegetation/` (плановая папка) — пока трава/деревья остаются в `scripts/terrain/` (`grass_field.gd`, `grass.gdshader`, `tree_placer.gd`, `terrain_tree_models.gd`, `forest_impostors.*`), `configs/vegetation.json` | растительность | агент vegetation (перенос файлов из terrain — после согласования) |
| `scripts/tasks/`, `scenes/tasks/`, `configs/tasks/`, `tests/tasks/` | задания, тренировки, рекорды (FR-35…37); логика готова, в `Game.tick()` не подключена | агент tasks |
| `scripts/ui/`, `scenes/ui/`, `locale/`, `configs/ui.json` | меню, пауза, настройки, «Об игре», экраны | агент ui |
| `docs/research/` | исследования | агенты-исследователи |
| `scenes/main.*`, `scripts/game/`, `configs/controls.json`, `configs/camera.json` | сборка, камеры, ввод, меню | интегратор |

## Контракты между модулями
Модули не знают друг о друге напрямую — связываются через Callable/ноды, которые передаёт главная сцена.

**Рельеф** (`scripts/terrain/terrain.gd`, нода `Terrain`, группа `"terrain"`):
- `height_at(x: float, z: float) -> float` — высота земли над уровнем моря, м. Быстро, можно звать 1000+ раз за шаг.
- `normal_at(x: float, z: float) -> Vector3`
- `get_start_sites() -> Array[Dictionary]` — `{id, name, position: Vector3, heading_deg}` стартовые площадки.
- `sun_exposure_at(x, z) -> float` 0..1 — освещённость склона солнцем (для источников термиков).
- `surface_at(x, z) -> int` — класс поверхности (WorldCover: лес, луг, пашня, скалы, вода, застройка, снег).
- `thermal_source_strength_at(x, z) -> float` 0..1 — сила источника термиков (класс × освещённость × усиление у границ поле–лес). Передаётся в `Atmosphere.set_ground` как `sun_fn`.
- `get_landing_sites() -> Array[Dictionary]` — посадочные площадки.

**Атмосфера** (`scripts/atmosphere/atmosphere.gd`, нода `Atmosphere`, группа `"atmosphere"`):
- `set_ground(height_fn: Callable, sun_fn: Callable)` — функции рельефа.
- `set_weather(w: String | Dictionary, blend_s := -1.0)` — погода: имя эталона (`configs/weather/*`, тесты) или
  словарь `WeatherModel.derive` (игра, FR-16); `blend_s ≥ 0` — мягкий переход без пересоздания термиков (ход дня).
- `set_wind(км/ч, откуда_°, ref_msl := NAN)` — ветер прогноза на высоте `ref_msl` (старт); выше — сильнее.
- `air_velocity_at(pos: Vector3) -> Vector3` — скорость воздуха (ветер + вертикальные потоки), м/с. Дёшево: зовётся несколько раз за шаг (центр и концы крыла).
- `step(dt: float)` — продвинуть время атмосферы (жизнь термиков). Вызывается из `_physics_process` самой ноды.
- Рисует облака сама (дочерние ноды).

**Полёт** (`scripts/flight/`):
- `FlightModel` (RefCounted, без нод, тестируется headless): `setup(wing: Dictionary, pilot: Dictionary)`,
  `step(dt, input: ControlInput, air_fn: Callable, ground_fn: Callable)`, `telemetry: Telemetry`, `reset_on_ground(pos, heading_deg)`.
- `Glider` (Node3D, `scenes/glider/glider.tscn`): держит FlightModel, в `_physics_process` читает ввод, двигает себя, сигнал `telemetry_updated(t: Telemetry)`, сигнал `landed(result: Dictionary)`.

**Приборы и звук** (`scripts/instruments/`, `scripts/audio/`):
- `Vario` (RefCounted): фильтр, среднее за N с — из `Telemetry`.
- `FlightInstrument` (сцена): экран прибора в SubViewport → текстура для модели на трапеции и для угла экрана. Метод `update(t: Telemetry)`.
- `VarioAudio` (Node): процедурный звук вариометра через AudioStreamGenerator. `set_vario(ms: float)`.

**Объекты мира** (`scripts/world_objects/world_objects.gd`, нода `WorldObjects`):
- `setup(terrain, air)` — принимает рельеф и атмосферу для позиционирования и обдува ветроуказателей.
- `wire_hit(a: Vector3, b: Vector3) -> bool`, `obstacle_hit(a: Vector3, b: Vector3) -> Dictionary {kind, point}` — проверка отрезка движения на столкновение с проводом ЛЭП/деревом/забором/зданием (см. `scripts/game/collision_check.gd`, интеграция — карточка G05).
- `get_landing_sites() -> Array[Dictionary]`, `clearing_mask_for(id)`, `is_clear_at`, `WorldClearings.build_for(id)`, сигнал `built`.

**Задания** (`scripts/tasks/`, без нод, тестируется headless):
- `Task.load_config / list_available`, `TaskTracker` (`setup`, `update(t)`, `get_state`, `result`, сигналы `turnpoint_reached`, `start_taken`, `goal_reached`, `task_failed`), `TrainingMode`, `FlightRecords.add_flight`. Логика готова (FR-35…37), в `Game.tick()` пока не подключена.

## Тесты
- **Скриншотные запуски** (не `--headless`, через xvfb или DISPLAY=:0) — всегда с таймаутом (`timeout 120 godot ...`), чтобы зависший процесс не висел. Звук в динамики пользователю не мешает (слышно, что игра работает); `--audio-driver Dummy` — по желанию.
- `godot --headless --path . --import` — после добавления новых `class_name` (обновляет кеш классов).
- `godot --headless --path . res://tests/run_tests.tscn -- --filter=flight` — тесты (`tests/**/test_*.gd`, наследуют `TestCase`).
- Скриншоты: `xvfb-run -a godot --path . --rendering-method gl_compatibility <сцена>` + сохранение `get_viewport().get_texture().get_image().save_png(...)`.

## Заменяемые модели и текстуры
Модели и текстуры будут заменяться на более качественные, поэтому код не зависит от конкретного ассета.
- **Путь к ассету берётся из конфига** (например `configs/visuals.json` или конфиг модуля), а не зашит в код.
  Замена ассета = новый файл + правка пути, код не меняется.
- **Визуал — отдельная сцена-обёртка** (`scenes/<модуль>/<что>_visual.tscn`) со стандартными именованными точками крепления (`Marker3D`):
  например у крыла `HangPoint`, `PilotHead`, `BaseBar`, `InstrumentMount`, `WingTipL`, `WingTipR`.
  Логика ищет эти маркеры по имени и не знает про меши внутри. Новая модель должна содержать те же маркеры.
- **Масштаб и оси:** 1 единица = 1 м, вперёд −Z, вверх +Y. Модели из Blender экспортируются в glTF (`.glb`) с «+Y up».
- **Анимируемые части** (сдвиг пилота по крену, трапеция, парус) — отдельные ноды с понятными именами;
  код двигает ноды или передаёт параметры в материал (`shader parameter`), а не правит вершины.
- **Материалы:** параметры (цвета, шероховатость, пути к текстурам) — в `.tres`-материалах или в конфиге, не в коде.
  Шейдеры принимают текстуры через `uniform`, чтобы процедурную заглушку можно было заменить картинкой.
- **Запасной вариант:** если ассет не найден, модуль строит простую процедурную заглушку и пишет предупреждение в лог. Игра не падает.
- **Исходники моделей:** `.blend` и скрипты генерации лежат в `assets/source/` и `tools/blender/`, готовые `.glb` — в `assets/models/`. Каждый ассет вносится в [ASSETS.md](../../ASSETS.md).
- **Blender 4.3** установлен (`blender`). Модели можно генерировать скриптом: `blender --background --python tools/blender/<скрипт>.py`.

## Модульность и поддерживаемость (NFR-8)
Код пишем так, как принято в Godot ([best practices](https://docs.godotengine.org/en/stable/tutorials/best_practices/index.html)):
- **Сцена = самостоятельный компонент.** Сцену модуля можно открыть и запустить отдельно (есть `*_preview.tscn`); она не лезет в чужие части дерева.
- **«Вызов вниз, сигнал вверх».** Родитель вызывает методы детей; дети сообщают наверх только сигналами.
  Никаких `get_node("../../Something")` и `get_parent().get_parent()`.
- **Зависимости передаются явно:** через `@export`-поля, методы `set_*` или `Callable`, которые выставляет главная сцена. Группы (`"terrain"`, `"atmosphere"`) — только для редких глобальных запросов (камера, отладка).
- **Autoload — только для глобальных сервисов без состояния игры** (сейчас это `Config`). Игровое состояние в autoload не держим.
- **Композиция вместо наследования:** поведение собирается из дочерних нод и компонентов, глубокие иерархии классов не строим.
- **Логика отдельно от нод.** Расчёты — в `RefCounted`-классах (например `FlightModel`, `Vario`), которые тестируются headless. Ноды — тонкая обёртка: время, ввод, визуал.
- **Данные — в конфигах и ресурсах** (`JSON`, `.tres`), не в коде.
- **Статическая типизация везде:** типы у переменных, параметров и возвращаемых значений, `class_name` у переиспользуемых классов.
- **Стиль — официальный [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html):** `snake_case` для функций и переменных, `PascalCase` для классов и нод, `CONSTANT_CASE` для констант, порядок членов класса как в гайде, строки ≤ 100 символов, отступ — табы.
- **Проверка:** `tools/lint.sh` (gdlint) без ошибок, тесты проходят. Новый модуль приходит с тестами и `docs/<модуль>.md`.
- **Маленькие файлы и функции:** скрипт отвечает за одну вещь. Если он разрастается больше ~400 строк, его пора делить.
