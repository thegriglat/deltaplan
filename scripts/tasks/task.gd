class_name Task
extends RefCounted
## Маршрутное задание (FR-35): пункты-цилиндры, старт, ESS, гоул, стартовые окна.
## Источник — configs/tasks/<id>.json (свой формат, см. docs/tasks.md) или .xctsk (XCTrack).
## Координаты lat/lon переводятся в мир через latlon_fn(lat, lon) -> Vector2(x, z)
## (Terrain.latlon_to_local), высота земли у пункта — height_fn(x, z) -> float (Terrain.height_at).

const TYPE_RACE := "race"
const TYPE_ELAPSED := "elapsed"
const TYPE_OPEN := "open_distance"

var id: String = ""
var name: String = ""
## "race" — гонка к гоулу (время от стартового окна), "elapsed" — время от своего старта,
## "open_distance" — дальность (пункты необязательны, гоула нет).
var type: String = TYPE_RACE
## Локация и стартовая площадка, для которых задание составлено (подсказка интегратору).
var location: String = ""
var start_site: String = ""
## Курс разбега на пункте взлёта, если start_site не задан (NAN — неизвестен).
var takeoff_heading_deg: float = NAN
var points: Array[TaskPoint] = []
## Время открытия стартовых окон, с от начала полёта (Telemetry.time_s). Пусто — старт открыт.
var start_gates_s: PackedFloat64Array = []
## Крайний срок задания, с от начала полёта (INF — нет).
var deadline_s: float = INF
var cylinder_tolerance: float = 0.005
## Минимальная полоса допуска, м (CIVL S7F: большее из доли радиуса и 5 м).
var min_tolerance_m: float = 5.0
## Время суток UTC (с от полуночи), соответствующее time_s = 0 (NAN — неизвестно; из .xctsk).
var clock_origin_s: float = NAN
var takeoff_index: int = -1
var sss_index: int = -1
var ess_index: int = -1
var goal_index: int = -1
## Ошибки разбора (пусто — задание корректно).
var errors: PackedStringArray = []


## Собрать задание из словаря своего формата. settings — configs/tasks/settings.json.
static func from_dict(
	d: Dictionary,
	latlon_fn: Callable = Callable(),
	height_fn: Callable = Callable(),
	settings: Dictionary = {}
) -> Task:
	if settings.is_empty():
		settings = Config.get_config("tasks/settings")
	var t := Task.new()
	t.id = String(d.get("id", ""))
	t.name = String(d.get("name", t.id))
	t.type = String(d.get("type", TYPE_RACE))
	if t.type not in [TYPE_RACE, TYPE_ELAPSED, TYPE_OPEN]:
		t.errors.append("неизвестный тип задания '%s'" % t.type)
		t.type = TYPE_RACE
	t.location = String(d.get("location", ""))
	t.start_site = String(d.get("start_site", ""))
	t.takeoff_heading_deg = float(d.get("takeoff_heading_deg", NAN))
	t.cylinder_tolerance = float(
		d.get("cylinder_tolerance", settings.get("cylinder_tolerance", 0.005))
	)
	t.min_tolerance_m = float(
		d.get("min_tolerance_m", settings.get("min_tolerance_m", t.min_tolerance_m))
	)
	t.deadline_s = float(d.get("deadline_s", INF))
	t.clock_origin_s = float(d.get("clock_origin_s", NAN))
	for g: Variant in d.get("start_gates_s", []):
		t.start_gates_s.append(float(g))
	t.start_gates_s.sort()
	for p: Variant in d.get("turnpoints", []):
		if p is Dictionary:
			t.points.append(_parse_point(p, latlon_fn, height_fn, settings, t.errors))
	t._index_points()
	return t


## Задание из configs/tasks/<id>.json (с правками пилота из user://configs).
static func load_config(
	task_id: String, latlon_fn: Callable = Callable(), height_fn: Callable = Callable()
) -> Task:
	var d: Dictionary = Config.get_config("tasks/" + task_id).duplicate(true)
	if not d.has("id"):
		d["id"] = task_id
	return from_dict(d, latlon_fn, height_fn)


## Задание из файла: .xctsk (XCTrack) или .json (свой формат). null — файл не прочитан.
static func load_file(
	path: String, latlon_fn: Callable = Callable(), height_fn: Callable = Callable()
) -> Task:
	if not FileAccess.file_exists(path):
		push_error("Task: нет файла %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var settings: Dictionary = Config.get_config("tasks/settings")
	var d: Dictionary
	if path.get_extension().to_lower() == "xctsk":
		d = XctskImporter.parse(text, settings)
	else:
		var data: Variant = JSON.parse_string(text)
		d = data if data is Dictionary else {}
	if d.is_empty():
		push_error("Task: не удалось разобрать %s" % path)
		return null
	if not d.has("id"):
		d["id"] = path.get_file().get_basename()
	return from_dict(d, latlon_fn, height_fn, settings)


## Доступные задания: [{id, name, source: "config"|"file", path}].
## Конфиги configs/tasks/*.json (кроме settings и training_*) и файлы user://tasks/*.xctsk|*.json.
static func list_available(user_dir: String = "user://tasks") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cfg_name in Config.list_configs("tasks"):
		var short := cfg_name.get_file()
		if short == "settings" or short.begins_with("training_"):
			continue
		var d: Dictionary = Config.get_config(cfg_name)
		out.append(
			{"id": short, "name": String(d.get("name", short)), "source": "config", "path": ""}
		)
	var dir := DirAccess.open(user_dir)
	if dir != null:
		for f in dir.get_files():
			if f.get_extension().to_lower() in ["xctsk", "json"]:
				out.append(
					{
						"id": f.get_basename(),
						"name": f.get_basename(),
						"source": "file",
						"path": user_dir.path_join(f)
					}
				)
	return out


static func _parse_point(
	p: Dictionary,
	latlon_fn: Callable,
	height_fn: Callable,
	settings: Dictionary,
	errors: PackedStringArray
) -> TaskPoint:
	var tp := TaskPoint.new()
	tp.name = String(p.get("name", ""))
	tp.kind = TaskPoint.kind_from_string(String(p.get("type", "turnpoint")))
	tp.radius_m = float(p.get("radius_m", settings.get("default_radius_m", 400.0)))
	tp.exit = String(p.get("direction", "enter")).to_lower() == "exit"
	tp.is_line = String(p.get("goal_type", "cylinder")).to_lower() == "line"
	tp.line_length_m = float(p.get("line_length_m", settings.get("goal_line_length_m", 400.0)))
	var xz := Vector2.ZERO
	if p.has("lat") and p.has("lon"):
		tp.lat = float(p.lat)
		tp.lon = float(p.lon)
		if latlon_fn.is_valid():
			xz = latlon_fn.call(tp.lat, tp.lon)
		else:
			errors.append("пункт '%s': нет перевода lat/lon в мир" % tp.name)
	else:
		xz = Vector2(float(p.get("x_m", 0.0)), float(p.get("z_m", 0.0)))
	var y := float(p.get("alt_m", 0.0))
	if height_fn.is_valid():
		y = float(height_fn.call(xz.x, xz.y))
	tp.position = Vector3(xz.x, y, xz.y)
	return tp


func _index_points() -> void:
	for i in points.size():
		match points[i].kind:
			TaskPoint.Kind.TAKEOFF:
				takeoff_index = i if takeoff_index < 0 else takeoff_index
			TaskPoint.Kind.SSS:
				sss_index = i if sss_index < 0 else sss_index
			TaskPoint.Kind.ESS:
				ess_index = i
			TaskPoint.Kind.GOAL:
				goal_index = i
	if type == TYPE_OPEN:
		return
	var last := points.size() - 1
	if goal_index < 0 and last > maxi(takeoff_index, sss_index):
		goal_index = last  # последний пункт — гоул (как в XCTrack)
		points[last].kind = TaskPoint.Kind.GOAL
	if goal_index < 0:
		errors.append("в задании нет гоула")
	if ess_index < 0:
		ess_index = goal_index


## Полоса допуска цилиндра, м: вход засчитывается до r + допуск, выход — от r − допуск.
func tolerance_m(p: TaskPoint) -> float:
	return maxf(p.radius_m * cylinder_tolerance, min_tolerance_m)


func is_open_distance() -> bool:
	return type == TYPE_OPEN


func has_goal() -> bool:
	return goal_index >= 0


## Первый пункт, который нужно взять после взлёта (старт или первый поворотный).
func first_index() -> int:
	return takeoff_index + 1 if takeoff_index >= 0 else 0


func first_gate_s() -> float:
	return start_gates_s[0] if not start_gates_s.is_empty() else 0.0


## Последнее открытое к моменту time_s стартовое окно; NAN — старт ещё закрыт.
func gate_for(time_s: float) -> float:
	if start_gates_s.is_empty():
		return 0.0
	var g := NAN
	for s in start_gates_s:
		if s <= time_s:
			g = s
	return g


## Направление прилёта к пункту i (единичный XZ): от центра предыдущего пункта.
func leg_direction(i: int) -> Vector2:
	if i <= 0 or i >= points.size():
		return Vector2(0, -1)
	var d := points[i].center_2d() - points[i - 1].center_2d()
	return d.normalized() if d.length() > 0.001 else Vector2(0, -1)


## Цели для оптимизатора: пункты from_i..гоул (для открытой дальности — до последнего).
func route_targets(from_i: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var last := goal_index if goal_index >= 0 else points.size() - 1
	for i in range(maxi(from_i, 0), last + 1):
		var p := points[i]
		if p.kind == TaskPoint.Kind.TAKEOFF:
			continue
		if p.kind == TaskPoint.Kind.GOAL and p.is_line:
			var e := p.line_ends(leg_direction(i))
			out.append(RouteOptimizer.line(e[0], e[1]))
		else:
			out.append(RouteOptimizer.circle(p.center_2d(), p.radius_m))
	return out


## Оптимизированная дистанция задания: от взлёта (или центра старта) через все пункты, м.
func task_distance_m(optimizer: RouteOptimizer = null) -> float:
	if points.is_empty():
		return 0.0
	if optimizer == null:
		optimizer = RouteOptimizer.from_settings()
	var from_i := takeoff_index if takeoff_index >= 0 else 0
	var origin := points[from_i].center_2d()
	return float(optimizer.solve(origin, route_targets(from_i + 1)).distance_m)


## Пункты для FlightInstrument.set_task: [{name, position, radius_m}] без взлёта.
func instrument_points() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in points:
		if p.kind != TaskPoint.Kind.TAKEOFF:
			out.append({"name": p.name, "position": p.position, "radius_m": p.radius_m})
	return out


## Индекс пункта задания → индекс в instrument_points().
func instrument_index(i: int) -> int:
	return i - 1 if takeoff_index >= 0 and i > takeoff_index else i
