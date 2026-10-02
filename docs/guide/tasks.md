---
type: "guide"
status: "active"
module: "game"
updated: "2026-10-03"
summary: "Задания, тренировки, рекорды — FR-35 (маршрутный полёт), FR-36 (тренировки), FR-37 (рекорды), NFR-6, NFR-7."
related: []
---
# Задания, тренировки, рекорды

FR-35 (маршрутный полёт), FR-36 (тренировки), FR-37 (рекорды), NFR-6, NFR-7. Правила соревнований и
формат `.xctsk` — [research/competition_rules.md](../research/competition_rules.md).
Вся логика — `RefCounted` без нод (NFR-8), тесты `tests/tasks/`.

## Что где
| Файл | Что |
|---|---|
| `scripts/tasks/task.gd` (`Task`) | задание: пункты, тип, стартовые окна, крайний срок; загрузка из конфига / `.xctsk` / `.json`, список доступных |
| `scripts/tasks/task_point.gd` (`TaskPoint`) | пункт: цилиндр или линия гоула в координатах мира |
| `scripts/tasks/xctsk_importer.gd` (`XctskImporter`) | `.xctsk` (XCTrack, JSON v1) → словарь своего формата |
| `scripts/tasks/route_optimizer.gd` (`RouteOptimizer`) | оптимизированная дистанция по касательным к цилиндрам |
| `scripts/tasks/task_tracker.gd` (`TaskTracker`) | прохождение задания по телеметрии, сигналы, состояние для прибора, итог |
| `scripts/tasks/flight_records.gd` (`FlightRecords`) | локальные рекорды `user://records.json` |
| `scripts/tasks/training_mode.gd` (`TrainingMode`) + `training_*.gd` | тренировки: центровка, склон, точность посадки |
| `scripts/tasks/task_preview.gd`, `scenes/tasks/task_preview.tscn` | превью задания в плане (цилиндры + маршрут) |
| `configs/tasks/settings.json` | допуски, радиусы по умолчанию, оптимизатор, импорт `.xctsk`, рекорды |
| `configs/tasks/<id>.json` | задания: `ongudai_demo` (основная локация), `altai_demo` (Манжерок) |
| `configs/tasks/training_*.json` | параметры тренировок |

## Формат задания (`configs/tasks/<id>.json`)
```jsonc
{
  "name": "…", "type": "race",          // race | elapsed | open_distance
  "location": "ongudai",                 // локация (configs/locations/<id>.json)
  "start_site": "",                      // id старта локации; пусто — пилот ставится на пункт takeoff
  "takeoff_heading_deg": 180,            // курс разбега, если start_site пуст
  "start_gates_s": [900, 1500, 2100],    // открытие стартовых окон, с от начала полёта (Telemetry.time_s)
  "deadline_s": 12600,                   // крайний срок, с от начала полёта (нет — без срока)
  "cylinder_tolerance": 0.005,           // доля радиуса; полоса = max(r·доля, min_tolerance_m)
  "turnpoints": [
    {"name": "…", "type": "takeoff", "lat": 50.78, "lon": 86.23, "radius_m": 400},
    {"name": "Старт", "type": "sss", "direction": "exit", "lat": …, "lon": …, "radius_m": 3000},
    {"name": "…", "lat": …, "lon": …, "radius_m": 1000},              // type по умолчанию turnpoint
    {"name": "…", "type": "ess", …},
    {"name": "…", "type": "goal", "goal_type": "line", "line_length_m": 400, …}
  ]
}
```
Вместо `lat/lon` можно `x_m/z_m` (метры мира) и `alt_m` (высота земли, если нет `height_fn`).
Нет `goal` — гоулом становится последний пункт; нет `ess` — ESS = гоул; нет `sss` — старт при взлёте.
Время в игре — секунды от начала полёта; у `.xctsk` время UTC переводится так, что полёт начинается за
`xctsk.start_lead_s` (20 мин) до первого окна (`Task.clock_origin_s` — часы UTC в момент time_s = 0).

**Демо-задания.**
- `ongudai_demo`: взлёт — южный склон горы Каянча у «Онгудайского ретранслятора» → старт на выход 3 км →
  Шашикман → Улита (ESS) → гоул у Онгудая (пойма Урсула); 27,8 км. ⚠ **Сверить**: координаты взлёта
  (50.7862N 86.2355E, ~1780 м) взяты по описанию на форуме deltaplanerizm.ru («Онгудай — Горный Алтай»:
  старт — лужайка в кедраче у вышки ретранслятора, на юг) и рельефу Terrarium; когда появится
  `configs/locations/ongudai.json`, поставить `start_site` и выровнять пункт `takeoff` по нему (тест
  `test_ongudai_demo_inside_detail_area` сам возьмёт центр и размер детальной зоны из конфига локации;
  пока его нет — центр 50.75N 86.14E, зона 40×40 км). Посадка — тоже сверить.
- `altai_demo`: Синюха-запад → старт 2 км → Соузга → Черемшанка → Манжерок (ESS) → Озёрное; 14,8 км, все
  пункты в детальной зоне 40×40 км (тест). Сёла — координаты OSM.

Превью: `godot --path . res://scenes/tasks/task_preview.tscn -- --task=ongudai_demo [--shot=file.png]`
или `--file=user://tasks/x.xctsk`.

## API
```gdscript
# Задание
var task := Task.load_config("ongudai_demo", terrain.latlon_to_local, terrain.height_at)
var task2 := Task.load_file("user://tasks/comp_day1.xctsk", terrain.latlon_to_local, terrain.height_at)
Task.list_available() -> [{id, name, source: "config"|"file", path}]   # для меню
task.errors            # PackedStringArray, пусто — задание корректно
task.location, task.start_site, task.takeoff_heading_deg, task.points[i].position
task.task_distance_m() # оптимизированная дистанция задания, м
task.instrument_points() -> [{name, position, radius_m}]   # формат FlightInstrument.set_task

# Прохождение
var tracker := TaskTracker.new()
tracker.setup(task)                    # reset() — новая попытка
tracker.update(t: Telemetry)           # каждый шаг физики, после планера
signal start_taken(time_s)             # засчитанное время старта (race — окно, elapsed — своё)
signal turnpoint_reached(index, point_name, time_s)
signal ess_reached(time_s)
signal goal_reached(result)
signal task_failed(result)             # приземлился (status "landed") или вышел срок ("deadline")
tracker.get_state() -> {phase, next_index, next_name, instrument_active, start_open, time_to_start_s,
	start_time_s, early_start, distance_to_next_m, remaining_distance_m, task_distance_m,
	required_glide, elapsed_s}
tracker.result() -> {task_id, task_name, status, made_goal, reached_ess, start_time_s, ess_time_s,
	goal_time_s, speed_section_time_s, task_distance_m, distance_m, turnpoints_reached}
tracker.instrument_points(), tracker.instrument_active_index()

# Рекорды
var records := FlightRecords.new()     # user://records.json
records.add_flight(result) -> {"<категория>": {value, previous}}   # новые рекорды, пусто — нет
# result: FlightStats.summary() + {location, wing, [task: tracker.result()]}; категории задания — "task_*"
records.free_records(location, wing), records.task_records(task_id, wing)

# Тренировки
var mode: TrainingMode = TrainingSpotLanding.new()   # / TrainingThermalCentering / TrainingRidgeSoaring
mode.latlon_fn = terrain.latlon_to_local             # для мишени из lat/lon
var cfg := Config.get_config("tasks/training_spot_landing").duplicate(true)
cfg.location = current_location_id
mode.setup(cfg)
mode.update(t)                   # каждый шаг; тренировка идёт с момента взлёта
mode.on_landed(landing_result)   # из Glider.landed (оценка посадки для точности)
mode.is_finished(), mode.result() -> {mode, title, success, score 0..100, reason, elapsed_s, …}
signal finished(result)
```
Критерии тренировок (всё в `configs/tasks/training_*.json`):
- **центровка** — набрать `target_gain_m` за `time_limit_s`, пробыв в подъёме (усреднённый вариометр ≥
  `lift_threshold_ms`) не меньше `required_lift_time_s`; оценка = набор (вес 0,7) + доля времени в подъёме (0,3);
- **склон** — `duration_s` в полосе высоты `min_agl_m…max_agl_m` над землёй и не дальше `max_distance_m` от
  взлёта; оценка = время в полосе / max(время попытки, duration_s);
- **точность посадки** — очки по кольцам мишени × коэффициент оценки посадки (мягкая 1, жёсткая 0,5, авария 0).

## Подключение (для интегратора)
```gdscript
# меню «Режим»: свободный полёт / задание (Task.list_available()) / тренировка (training_*)
var task := Task.load_config(id, terrain.latlon_to_local, terrain.height_at)
if task.start_site != "": site = <старт локации с этим id>
else: glider.reset_on_ground(task.points[task.takeoff_index].position, task.takeoff_heading_deg)
tracker.setup(task)
instrument.set_task(tracker.instrument_points(), tracker.instrument_active_index())   # стр. 2 и 4
tracker.turnpoint_reached.connect(func(_i, _n, _s):
	instrument.set_task(tracker.instrument_points(), tracker.instrument_active_index()))
tracker.start_taken.connect(...)       # звук/мигание на приборе — у агента instruments
tracker.goal_reached.connect(_show_result)   # экран итога: result() + records.add_flight(...)
tracker.task_failed.connect(_show_result)

# в Game.tick() после шага планера:
tracker.update(glider.telemetry)
training.update(glider.telemetry)
glider.landed.connect(training.on_landed)

# итог полёта → рекорды (FR-37)
var r := stats.summary(end_pos)        # FlightStats: flight_time_s, distance_m, max_altitude_msl_m
r.merge({"location": loc_id, "wing": wing_id})
if tracker: r["task"] = tracker.result()   # рекорды задания: время скоростного участка, дистанция
var new_records := records.add_flight(r)   # показать «Новый рекорд!» на экране итога
```
**Прибор.** Страницы 2 (карта) и 4 (задание) уже рисуют пункты из `FlightInstrument.set_task(points, active)`.
Для страницы 3/4 полезно добавить показ из `tracker.get_state()`: время до открытия старта / «старт взят»,
оставшаяся оптимизированная дистанция, требуемое качество **до гоула** (`required_glide`; сейчас
`InstrumentTask` считает до активного пункта напрямую) — это задача агента instruments (метод вроде
`set_task_state(state: Dictionary)`).
