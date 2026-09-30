# Контракты модуля «start-fixes»

Внутренний документ. План — `docs/plan/start_fixes.md`, журнал — `docs/plan/start_fixes_progress.md`. Контрактный тест — `tests/game/test_start_fixes_contracts.gd` (форма стыков; ломается при смене формата без правки контракта). Менять интерфейс — только через координатора: версия +1, что изменилось, уведомить потребителей.

## К1. Карта поверхности и поляны у стартов — v2
Владелец: SF-1 (рельеф, `scripts/terrain/terrain.gd`, `surface_layer.gd`). Потребители: деревья (`TreePlacer`, `TerrainTreeModels`, `ForestImpostors`), кусты (`ShrubScatter`), камни (`RockScatter`), трава (`GrassField`, `grass.gdshader` — SF-2), столкновения (`CollisionCheck` через `Terrain.forest_at`), термики.
Что есть (фиксируем):
- Классы `SurfaceLayer`: `NONE=0, FOREST=1, GRASS=2, CROP=3, SHRUB=4, BARE=5, WATER=6, BUILT=7, SNOW=8`, `CLASS_COUNT=9`. Шейдеры читают класс ближайшего узла карты (как `Terrain.surface_at`).
- `SurfaceLayer.replace_in_circle(cx: float, cz: float, r_in: float, from_class: int, to_class: int)` — мир (x — восток, z — юг), м; для `from_class == FOREST` также обнуляет маску леса 10 м в круге.
- `Terrain.surface_at(x, z) -> int`, `Terrain.forest_at(x, z) -> float` (0..1, лес — от 0,5, `CollisionCheck.FOREST_MIN`).
- Встроенные старты: `Terrain.set_surfaces` вычищает FOREST и SHRUB → GRASS в круге `locations/<id>.json → start_clearing_radius_m` вокруг каждого `get_start_sites()[i].position`.
Новое (SF-1, v2 — 30.09):
- `Terrain.add_start_clearing(x: float, z: float, radius_m: float) -> void` — **синхронный**, вызывается после загрузки (`Game._choose_start` для старта с карты). **Только лес**: `FOREST → GRASS` во всех картах поверхности, маска леса 10 м — ноль (до `radius + 1,42·шаг маски`); `SHRUB`, кусты, камни, трава не трогаются (решение пользователя 30.09: пустырь — с травой, без деревьев). Сразу, в том же вызове: `surface_at`/`forest_at`, текстуры классов и маски у рельефа (`ImageTexture.update` на месте — их же читают трава, `far_layer`, импостеры, процедурные кроны), маска у `TerrainTreeModels`/`ForestImpostors`. Деревья и кусты перестраиваются со следующего кадра (`TerrainTreeModels.invalidate()`, кеш `ShrubScatter` сбрасывается по `surface_revision` — кусты на бывшем лесе растут как на лугу); `rebuild_now`/`build_tile` видят новое сразу.
- `Terrain.surface_revision: int` — растёт при каждой правке карты после сборки.
- `Terrain.get_start_clearings() -> Array[Vector3]` — все пустыри `Vector3(x, z, r)`: встроенные старты и добавленные. `ShrubScatter` не ставит внутри одиночные деревья (кусты — ставит); `RockScatter` не меняется.
- `TerrainRenderer.refresh_surface(li: int, surface: SurfaceLayer)` — обновить текстуры слоя на месте.
- Радиус: `configs/game.json → start_search.clearing_radius_m` (160 м; обоснование — `_doc`), `Terrain.start_clearing_radius_m()` (static) читает его. Встроенные старты: как раньше, `FOREST|SHRUB → GRASS` в `locations/<id>.json → start_clearing_radius_m` (70 м), и дальше до `max(start_clearing_radius_m, clearing_radius_m)` — только `FOREST → GRASS`.
- Инварианты после вызова: для всех точек круга `surface_at != FOREST`, `forest_at == 0`; `SHRUB` — где был; ни одного дерева (модели, импостеры, одиночные деревья `ShrubScatter`) в круге; за кругом карта не меняется. Класс, в который переходит лес, — `GRASS` (трава SF-2 растёт там как на лугу).
- R `≥ 2·L_run` — проверяет `tests/game/test_start_clearing.gd` живым прогоном `GroundRun` по всем крыльям.

## К2. Трава по классам поверхности — v1
Владелец: SF-2 (`grass.gdshader`, `grass_field.gd`, `configs/vegetation.json → grass`). Потребители: нет (визуал).
Что есть: `GrassField.setup(...)` передаёт в материал `shrub_density` (доля пучков на классе SHRUB); пучки на FOREST, BARE, WATER, BUILT, SNOW — не рисуются; высота: луг `blade_height_m`, нива `crop_height_m`.
Новое (SF-2): ключ(и) плотности/высоты травы на классе FOREST в `vegetation.json → grass` → uniform материала; по умолчанию плотность > 0. Имена ключей и uniform владелец вписывает сюда (версия 2). SF-1 от этого не зависит (поляна — класс GRASS).

## К3. Крен на земле и переход в полёт — v1
Владелец: SF-3 (`scripts/flight/ground_run.gd`: `_ground_bank`, `_turn`; стык GROUND→AIR в `flight_model.gd`). Потребители: `FlightTelemetry` (bank_deg, basis), `GliderVisual`, камеры, боты (`bot_pilot.gd` — управляют через `ControlInput`), сеть (`net_flight.gd` передаёт bank), SF-4.
Что есть (фиксируем, не меняется):
- `FlightModel.bank: float` — рад, + вправо, **относительно горизонта** (не склона); `FlightModel.roll_rate: float` — рад/с; `FlightModel.heading` — рад, 0 — север, по часовой; `FlightModel.position` на земле — точка ступней на рельефе.
- `GroundRun.step(m: FlightModel, dt: float, input: ControlInput, air_fn: Callable, ground_fn: Callable) -> Result` (`NONE, TOOK_OFF, FAILED`); `GroundRun.phase ∈ {"standing","walking","running"}`; `GroundRun.failure` — причины `nose_high, nose_low, tailwind, crosswind, weak_run`.
- `ControlInput.roll ∈ [−1, 1]` — на земле A/D (после SF-3 — только курс, не крен), `input.run`, `input.walk`, `input.pitch`.
- Опрокидывание — `failure == "crosswind"` (порог `flight.json → ground_bank.fail_bank_deg`, `takeoff.fail_time_s`).
Новое (SF-3): `configs/flight.json → ground_bank` — новые ключи с физическим смыслом и единицами (момент руки пилота Н·м, инерция кг·м², производная момента по скольжению и т. п.); старые `crosswind_roll_dps_per_ms`, `pilot_roll_rate_dps`, `level_time_s` убираются. Доля веса на ногах `N/W ∈ [0,1]` — публичное поле `GroundRun` (рабочее имя `feet_load`) для тестов и визуала. Имена владелец вписывает сюда (версия 2).

## К4. Поза крыла на земле — v1
Владелец: SF-4 (`glider_visual.gd` `_ground_pose`, `flight_telemetry.gd` basis на земле, тангаж стоя в `ground_run.gd::_aero_force`). Потребители: камеры, `CollisionCheck` (точки крыла над ступнями: `BODY_POINTS_M`, концы консолей по `span_m`, `hang_m`), сеть, SF-3 (крен).
Что есть: `Telemetry.basis = Basis.from_euler(Vector3(theta, −heading, −bank))`, начало координат планера — ступни (`FlightModel.position`); карабин/килевая труба — на `hang_height_m` над ступнями; `GliderVisual` сглаживает позу пилота (`input_smoothing_s`).
Новое (SF-4): если меняется точка поворота базиса на земле или смысл `theta` стоя — вписать сюда (версия 2) и сообщить координатору до коммита: это стык с `CollisionCheck` и камерами.
