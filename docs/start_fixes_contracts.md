# Контракты модуля «start-fixes»

Внутренний документ. План — `docs/plan/start_fixes.md`, журнал — `docs/plan/start_fixes_progress.md`. Контрактный тест — `tests/game/test_start_fixes_contracts.gd` (форма стыков; ломается при смене формата без правки контракта). Менять интерфейс — только через координатора: версия +1, что изменилось, уведомить потребителей.

## К1. Карта поверхности и поляны у стартов — v1
Владелец: SF-1 (рельеф, `scripts/terrain/terrain.gd`, `surface_layer.gd`). Потребители: деревья (`TreePlacer`, `TerrainTreeModels`, `ForestImpostors`), кусты (`ShrubScatter`), камни (`RockScatter`), трава (`GrassField`, `grass.gdshader` — SF-2), столкновения (`CollisionCheck` через `Terrain.forest_at`), термики.
Что есть (фиксируем):
- Классы `SurfaceLayer`: `NONE=0, FOREST=1, GRASS=2, CROP=3, SHRUB=4, BARE=5, WATER=6, BUILT=7, SNOW=8`, `CLASS_COUNT=9`. Шейдеры читают класс ближайшего узла карты (как `Terrain.surface_at`).
- `SurfaceLayer.replace_in_circle(cx: float, cz: float, r_in: float, from_class: int, to_class: int)` — мир (x — восток, z — юг), м; для `from_class == FOREST` также обнуляет маску леса 10 м в круге.
- `Terrain.surface_at(x, z) -> int`, `Terrain.forest_at(x, z) -> float` (0..1, лес — от 0,5, `CollisionCheck.FOREST_MIN`).
- Встроенные старты: `Terrain.set_surfaces` вычищает FOREST и SHRUB → GRASS в круге `locations/<id>.json → start_clearing_radius_m` вокруг каждого `get_start_sites()[i].position`.
Новое (поставляет SF-1):
- Метод рельефа, вычищающий поляну вокруг произвольной точки старта **после** загрузки, с обновлением всего, что читает карту поверхности (деревья, импостеры, кусты, маска леса, текстуры поверхности у рельефа и травы). Рабочее имя: `Terrain.add_start_clearing(x: float, z: float, radius_m: float) -> void` (синхронный или с сигналом/await — владелец выбирает и вписывает сюда, версия 2).
- Инварианты после вызова: для всех точек круга `surface_at ∉ {FOREST, SHRUB}`, `forest_at == 0`; ни одного дерева и куста в круге; за кругом карта не меняется. Класс, в который переходит лес, — `GRASS` (трава SF-2 растёт там как на лугу).
- Радиус R: `≥ 2·L_run` (решение пользователя; L_run — план, SF-1). Где задан — владелец вписывает сюда (версия 2).

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
