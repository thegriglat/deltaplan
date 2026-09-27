# Архитектура

Godot 4.7.2 (`godot` в PATH), GDScript, рендер Forward+. Цели: Windows + Linux.

## Общие правила
- **Все числа — в `configs/*.json`** (NFR-7). В коде только физические константы (g) и переводы единиц (`Units`).
  В конфигах удобные пилоту единицы, суффикс ключа обязателен: `_kmh`, `_ms`, `_kg`, `_deg`, `_m`, `_s`, `_hz`.
  Ключи на `_` — комментарии (`"_doc": "..."`). Каждый параметр описывается в `_doc` или рядом `"<ключ>_doc"`.
- Чтение: `Config.get_config("wings/sport")`, `Config.value("sim", "physics_hz")`, `Config.list_configs("wings")`.
- Внутри симуляции всё в СИ: м, м/с, кг, с, радианы.
- Физика — только в `_physics_process` (фиксированный шаг, `configs/sim.json → physics_hz`, NFR-3). Рендер интерполирует.
- Интерфейс — на русском, строки через `tr()` там, где это текст для пользователя.
- Никакого HUD и никаких визуальных подсказок (FR-21, FR-22). Весь вывод данных — через приборы.

## Система координат
- X — восток, **−Z — север**, Y — вверх. **Y = высота над уровнем моря**, метры.
- Начало координат X/Z — центр локации (задан в `configs/locations/<id>.json`).
- Курс: 0° — север, по часовой. Крен: + вправо. Тангаж: + нос вверх.

## Модули и владельцы
| Папка | Что | Кто пишет |
|---|---|---|
| `scripts/core/` | Config, Units, ControlInput, Telemetry — общие типы | только интегратор |
| `scripts/flight/`, `configs/wings/`, `configs/pilot.json`, `configs/flight.json`, `tests/flight/` | модель полёта, разбег, посадка | агент flight |
| `scripts/terrain/`, `scripts/world/`, `tools/terrain/`, `data/terrain/`, `configs/locations/`, `configs/world.json`, `tests/terrain/` | рельеф, небо, туман, солнце | агент terrain |
| `scripts/atmosphere/`, `configs/weather/`, `configs/atmosphere.json`, `tests/atmosphere/` | термики, ветер, облака | агент atmosphere |
| `scripts/instruments/`, `scripts/audio/`, `configs/instruments.json`, `configs/audio.json`, `tests/instruments/` | вариометр, прибор, звук | агент instruments |
| `docs/research/` | исследования | агенты-исследователи |
| `scenes/main.*`, `scripts/game/`, `configs/controls.json`, `configs/camera.json` | сборка, камеры, ввод, меню | интегратор |

## Контракты между модулями
Модули не знают друг о друге напрямую — связываются через Callable/ноды, которые передаёт главная сцена.

**Рельеф** (`scripts/terrain/terrain.gd`, нода `Terrain`, группа `"terrain"`):
- `height_at(x: float, z: float) -> float` — высота земли над уровнем моря, м. Быстро, можно звать 1000+ раз за шаг.
- `normal_at(x: float, z: float) -> Vector3`
- `get_start_sites() -> Array[Dictionary]` — `{id, name, position: Vector3, heading_deg}` стартовые площадки.
- `sun_exposure_at(x, z) -> float` 0..1 — освещённость склона солнцем (для источников термиков).

**Атмосфера** (`scripts/atmosphere/atmosphere.gd`, нода `Atmosphere`, группа `"atmosphere"`):
- `set_ground(height_fn: Callable, sun_fn: Callable)` — функции рельефа.
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

## Тесты
- `godot --headless --path . --import` — после добавления новых `class_name` (обновляет кеш классов).
- `godot --headless --path . res://tests/run_tests.tscn -- --filter=flight` — тесты (`tests/**/test_*.gd`, наследуют `TestCase`).
- Скриншоты: `xvfb-run -a godot --path . --rendering-method gl_compatibility <сцена>` + сохранение `get_viewport().get_texture().get_image().save_png(...)`.
