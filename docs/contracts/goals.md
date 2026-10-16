---
type: "contract"
status: "active"
module: "goals"
area: "game"
updated: "2026-10-16"
summary: "Стыки модуля целей: FlightSettings (К1), оценка погоды (К2), GoalTracker (К3), прибор и цилиндры (К4), трек и IGC (К5), полоса (К6)."
related: ["docs/plan/goals.md", "docs/guide/tasks.md"]
contracts: [{"id": "GL-К1", "version": 1}, {"id": "GL-К2", "version": 2}, {"id": "GL-К3", "version": 2}, {"id": "GL-К4", "version": 1}, {"id": "GL-К5", "version": 2}, {"id": "GL-К6", "version": 1}]
---
# Контракты модуля goals

План — `docs/plan/goals.md`. Менять — только координатор (версия +1, что изменилось, уведомить потребителей).
Контрактные тесты — по файлу на стык: `tests/contracts/test_goals_k1.gd` … `test_goals_k6.gd` (headless, без сети и GPU). Каждый проверяет заголовок своего раздела с версией — регулярка `(?m)^## (GL-К\d)\. .* \(v(\d+)\)\s*$`; владелец стыка дописывает в свой файл проверку интерфейса (`load(path)` + `get_script_method_list()` / `get_script_signal_list()`, ключи конфига — как `tests/contracts/test_qol_contracts.gd`).

Общее: единицы СИ (м, с, м/с), мир — X восток, Y высота над уровнем моря, −Z север; координаты — WGS84 в градусах. Сетевой игры модуль не касается: при `game.net != null` цели и треки не создаются. Подсказок про опасность нет. Строки интерфейса — `tr()` с ключами в `locale/ui.csv` (ru и en).

## GL-К1. Цели в FlightSettings (v1)
Владелец: GL-2 (`scripts/goals/goal_spec.gd`, класс `GoalSpec`), поля `FlightSettings` — GL-3. Потребители: окно «Полёт…» (GL-3), `Game` (GL-4, GL-7, GL-10), `GoalTracker` (GL-2), `GoalEstimator` (GL-1, только строки `kind`/`level`).

Поля `FlightSettings` (`scripts/game/flight_settings.gd`), с `to_dict()` / `from_dict()` под теми же ключами:
```gdscript
var goals: Array = []                       # [GoalSpec-словарь], пусто — полёт без целей (как сейчас)
var show_last_track: bool = false           # показать след прошлой попытки на этом месте
var track_paths: PackedStringArray = []     # загруженные IGC/GPX (этап C), абсолютные пути
```
GoalSpec-словарь: `{"kind": String, "level": String, "value": float, "task": String}`.
- `level`: `easy` | `medium` | `hard` | `custom` (число правлено руками).
- `kind` и единицы `value`:

| kind | value | смысл |
|---|---|---|
| `height` | м | набор над высотой старта, удержать `tracker.json → height.hold_s` (10 с) |
| `duration` | с | время в воздухе с отрыва |
| `distance` | м | наибольшее горизонтальное расстояние от точки взлёта |
| `return` | м | точка поворота на этом расстоянии от взлёта и назад к взлёту |
| `triangle` | м | периметр равностороннего треугольника от взлёта |
| `route` | 0 (не используется) | `task` — id `configs/tasks/<id>.json` или путь `user://tasks/…` (`Task.list_available()`) |
| `speed` | с | предел времени ведущего маршрута (старт → ESS/гоул) |
| `landing` | м | радиус круга посадки |

`GoalSpec` (RefCounted, статика): `const KINDS := ["height","duration","distance","return","triangle","route","speed","landing"]` (порядок показа), `const LEVELS := ["easy","medium","hard","custom"]`, `static func make(kind: String, level: String, value: float, task := "") -> Dictionary`, `static func validate(goals: Array) -> PackedStringArray` (ошибки; пусто — годно).
Инварианты: каждый `kind` не больше одного раза; `speed` — только вместе с `route`, `triangle` или `return`; `value > 0` у всех, кроме `route`; `route` — непустой `task`. Неизвестный `kind` — ошибка `validate`, `Game` такую цель пропускает.

## GL-К2. Оценка погоды → значения целей (v2)
Владелец: GL-1 (`scripts/goals/goal_estimator.gd`, `configs/goals/estimate.json`). Потребители: окно «Полёт…» (GL-3).
```gdscript
class_name GoalEstimator extends RefCounted
static func weather_for(s: FlightSettings) -> Dictionary
static func suggest(kind: String, level: String, wx: Dictionary, route_m := 0.0) -> float
static func suggest_all(wx: Dictionary, route_m := 0.0) -> Dictionary   # {kind: {easy, medium, hard}} для всех KINDS кроме route
```
- `weather_for` — до старта, без рельефа: `WeatherModel.derive(s.forecast(), ctx, {}, s.start_hour)` с `ctx` места (`Locations.config`, `WeatherModel.reference_context()` для высот), `diurnal_state` для заката. Возвращает `{cloudbase_agl_m, thermal_ms, wind_ms, wind_from_deg, sky, hours_left, start_hour}`; `thermal_ms` — средняя сила термиков, м/с; `hours_left` — часы от `start_hour` до `min(закат, world.json → time.max_hour)`, ≥ 0.
- `suggest` возвращает `value` в единицах К1; `route` → 0; `speed` при `route_m <= 0` → 0; `level == "custom"` → как `medium`. Нет ключа в `wx` — значение по умолчанию из конфига.
- Детерминированно (одни входы — одно число), формулы и коэффициенты — в `estimate.json` с `_doc` у каждого ключа. Округление: высота — 50 м, дальность/возврат/треугольник — 1 км, продолжительность — 5 мин, скорость — 1 мин, посадка — 5 м.
- Порядок уровней: `easy < medium < hard` для всех, кроме `landing` и `speed` (там строже = меньше: `easy > medium > hard`).
- Монотонность: высота, дальность, возврат, треугольник, продолжительность не убывают с `thermal_ms` и `cloudbase_agl_m`; дальность/возврат/треугольник/продолжительность не убывают с `hours_left`.
- Честность (v2, 2026-10-16): уровни не подгоняются под плохую погоду, но в хорошую погоду все достижимы без облака. Высота: запас до базы над стартом `avail = cloudbase_agl_m − estimate.json → height.start_above_mean_m` (высоты старта до загрузки рельефа нет — грубое число с `_doc`); `easy/medium/hard` — доли `avail` (hard ≤ avail), но не меньше нижних порогов уровней (`height.floor_m` по уровням). В слабую/пасмурную погоду пороги больше `avail` → трудное недостижимо; в «ясно, сильные» hard ≤ avail. Так же для маршрутных: нижние пороги уровней в километрах, в плохую погоду больше реально пролетаемого.
v2: честность — через нижние пороги уровней, а не «hard выше базы всегда».

## GL-К3. GoalTracker — цели в полёте (v2)
v2 (2026-10-16, по кадрам GL-6): `reason` — код латиницей, текст — в интерфейсе через `tr("goals_reason_<код>")`.
Владелец: GL-2 (`scripts/goals/goal_tracker.gd`, `configs/goals/tracker.json`). Потребители: `Game` (GL-4), HUD-список, экран итога (GL-4), цилиндры (GL-5).
```gdscript
class_name GoalTracker extends RefCounted
signal goal_done(index: int)
signal goal_failed(index: int)
func setup(goals: Array, ctx: Dictionary) -> void
func reset() -> void                         # новая попытка: те же цели и точки, всё «pending»
func update(t: Telemetry) -> void            # каждый шаг физики, после планера
func on_landed(landing: Dictionary) -> void  # LandingJudge.evaluate(): grade soft|hard|crash; позиция — последняя телеметрия
func items() -> Array                        # по goals, в их порядке
func lead_tracker() -> TaskTracker           # ведущий маршрут или null
func instrument_points() -> Array            # формат FlightInstrument.set_task; [] — маршрута нет
func instrument_active_index() -> int
func instrument_state() -> Dictionary        # формат TaskTracker.get_state(); {} — маршрута нет
func world_points() -> Array                 # [{name, position: Vector3 (y — земля), radius_m, active: bool}] ведущего маршрута
func result() -> Dictionary                  # {goals: items(), done: int, total: int, route: lead_tracker().result() или {}}
```
`ctx`: `{start_pos: Vector3` (точка взлёта, y — земля), `start_heading_deg: float, wind_from_deg: float, wind_ms: float, latlon_fn: Callable(lat, lon) -> Vector2(x, z), height_fn: Callable(x, z) -> float, bounds: Rect2` (детальная зона XZ, `Terrain.detail_bounds()`), `landing_target` (Vector3 центр круга на земле; нет ключа или `null` — посадки нет), `location_id: String}`.

Элемент `items()`: `{kind, value, task_name: String, status: "pending"|"done"|"failed"|"unavailable", current: float, best: float, reason: String}`.
- `reason` — код (`[a-z_]+`), не текст: `landed` (сел, не выполнив), `crash`, `outside_circle`, `too_slow`, `no_room`, `no_target`, `task_error`, `no_goal`, `no_route`, `deadline`, `bad_value`, `unknown_kind`; пусто — нет причины. Перевод — `locale/ui.csv` ключи `goals_reason_<код>` (ru, en).
- `current`/`best` в единицах К1: `height` — набор над стартом сейчас / лучший удержанный; `duration` — с в воздухе; `distance` — м от взлёта сейчас / наибольшее; маршрутные — пройдено пунктов (`best` — оставшаяся дистанция, м); `speed` — с с начала маршрута; `landing` — м от центра (после посадки).
- Засчёт: `height` — набор ≥ value непрерывно `hold_s`; `duration` — время в воздухе ≥ value; `distance` — горизонтальное расстояние от взлёта ≥ value; `route`/`triangle`/`return` — гоул ведущего `TaskTracker`; `speed` — гоул ведущего маршрута за время ≤ value (иначе `failed`); `landing` — посадка в круге и `grade != "crash"`. После посадки все `pending` → `failed`.
- `unavailable` (с `reason`): `return`/`triangle` не помещаются в `bounds` ни при каком повороте (шаг ±15°), `landing` без `landing_target`, `route` с ошибкой загрузки задания. Такие цели не влияют на остальные.
- Построение: первое плечо — откуда дует ветер (`wind_ms >= tracker.json → route.min_wind_ms`), иначе `start_heading_deg`; гоул возврата и треугольника — цилиндр у взлёта (`route.home_radius_m`), пункты — `route.turnpoint_radius_m`.
- Ведущий маршрут — первый не завершённый в порядке `route` → `triangle` → `return`.
- Времена — от `Telemetry.time_s`; новая попытка (`Game` сбросил полёт) — `reset()`.

## GL-К4. Прибор: направление на точку; цилиндры в мире (v1)
Владелец: GL-5 (`scripts/instruments/…`, `scripts/goals/goal_cylinders.gd`, `configs/goals/world.json`). Потребитель: `Game` (GL-4/GL-5), `SettingsPanel`.
- Прибор: `FlightInstrument.set_task(points, active)` и `set_task_state(state)` — без изменений сигнатур; на странице с расстоянием и требуемым качеством до цели — стрелка направления на активную точку относительно путевого курса (`Telemetry.track_deg`); нет цели — стрелки нет.
- `class_name GoalCylinders extends Node3D`: `func set_points(points: Array) -> void` (формат `GoalTracker.world_points()`), видим только при `configs/goals/world.json → cylinders.enabled` (по умолчанию `false`), перечитывается по `Config.reloaded`. Столбы полупрозрачные, от земли вверх (`cylinders.height_m`), активный — заметнее.
- Настройка «Цилиндры целей» — `SettingsPanel`, вкладка game; сохраняется `UserSettings.save_patch("goals/world", {"cylinders": {"enabled": …}})`.

## GL-К5. Трек: FlightTrack, IGC/GPX, след прошлой попытки (v2)
Владелец: GL-7 (`scripts/goals/flight_track.gd`, `track_io.gd`, `last_track_store.gd`, `track_recorder.gd`); подключение к `Game` — GL-7b; GPX — GL-10.
v2 (2026-10-16): добавлен `TrackRecorder`. Потребители: полоса трека (GL-8), окно «Полёт…» (GL-10), `Game`.
```gdscript
class_name FlightTrack extends RefCounted
var lat := PackedFloat64Array()      # градусы
var lon := PackedFloat64Array()
var alt_m := PackedFloat32Array()    # м над уровнем моря
var t_s := PackedFloat32Array()      # с от первой точки, не убывает
var name := ""
var source := ""                     # "last" | путь файла
func size() -> int
func append(lat_deg: float, lon_deg: float, alt: float, t: float) -> void
func vertical_speed_ms(i: int, window_s: float) -> float    # (alt(t+w/2) − alt(t−w/2)) / w по точкам, края — укороченное окно
func inside_fraction(bounds: Rect2, latlon_fn: Callable) -> float   # доля точек в bounds (XZ)

class_name TrackIO extends RefCounted
static func read(path: String) -> FlightTrack           # по расширению .igc/.gpx; ошибка — null
static func last_error() -> String
static func read_igc(path: String) -> FlightTrack
static func write_igc(track: FlightTrack, path: String, meta := {}) -> Error   # временный файл + переименование
static func read_gpx(path: String) -> FlightTrack       # GL-10

class_name LastTrackStore extends RefCounted
static func place_key(s: FlightSettings) -> String      # location_id встроенного места, иначе LocationCache.key_for(pick_lat, pick_lon)
static func path_for(key: String) -> String             # "user://tracks/last/<key>.igc"
static func save(key: String, track: FlightTrack) -> Error   # заменяет прошлую
static func load(key: String) -> FlightTrack            # нет — null

class_name TrackRecorder extends RefCounted
func start(local_to_latlon: Callable) -> void           # Callable(x, z) -> Vector2(lat, lon); новый пустой трек
func update(t: Telemetry) -> void                        # пишет точку не чаще 1 Гц по t.time_s, только в воздухе (не on_ground)
func track() -> FlightTrack                              # записанное; t_s — от первой точки
```
- IGC (подмножество): запись `A`, `HFDTE` (дата полёта из `FlightSettings`), B-записи 1 Гц (`HHMMSS`, `DDMMmmmN`, `DDDMMmmmE`, `A`, давл. высота 5 цифр, GPS-высота 5 цифр = `alt_m` округлённо); чтение — B-записи, GPS-высота, если вся нулевая — давлением; переход через полночь — +86400 с; прочие записи пропускаются.
- GPX: `trkpt` (`lat`, `lon`, `ele`, `time` ISO 8601); без `time` — по 1 с на точку; без `ele` — трек отвергается.
- `Game.goal_tracks: Array` (`[FlightTrack]`) — заполняется в `start()` до первого кадра: след прошлой попытки (`show_last_track`), файлы `track_paths`; пусто — ничего не рисуется. В сети — пусто.
- Запись полёта: 1 Гц от отрыва до конца полёта; сохраняется в `LastTrackStore` при конце полёта, если взлёт был (`stats.summary().took_off`); одна на место.
- «Из этого места»: `inside_fraction(детальная зона места) >= 0.5`; иначе трек не берётся, в окне — сообщение.

## GL-К6. Полоса трека в мире (v1)
Владелец: GL-8 (`scripts/goals/track_ribbon.gd` + шейдер, `configs/goals/track.json`). Потребитель: `Game` (рисует все `goal_tracks`).
```gdscript
class_name TrackRibbon extends MeshInstance3D
func set_track(track: FlightTrack, latlon_fn: Callable) -> void   # меш строится один раз; позиция точки = (x, alt_m, z)
```
- Весь трек сразу; ширина на экране постоянная (`track.json → width_px`) на любом расстоянии; полупрозрачная, не пишет глубину, не мерцает с рельефом.
- Цвет участка — `FlightTrack.vertical_speed_ms(i, vs_window_s)`: ≥ `climb_full_ms` (3,5) — насыщенный `color_climb` (красный), ≤ −`sink_full_ms` (3,5) — `color_sink` (синий), |w| ≤ `dead_band_ms` — почти бесцветный (`alpha_zero`); между — линейно. Все пороги и цвета — в `track.json` с `_doc`.
- Длинный трек прореживается до `max_points` без потери формы (по расстоянию/углу).
