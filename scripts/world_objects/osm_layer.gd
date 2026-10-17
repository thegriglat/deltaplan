class_name OsmLayer
extends Node3D
## Каркас слоя OSM места (O9): вызывает OsmRoads / OsmPilot / OsmBuildings (scripts/world_objects/osm/) над
## данными OsmData и вешает возвращённые узлы потомками. Дороги, вершины, ЛЭП и дома наполняют
## OT-9 / OT-10 / OT-11; здесь только каркас и общий индекс препятствий домов.
## FL-6: тяжёлый расчёт (земля города, дороги, слой «для пилота», дома) — в рабочих потоках (start), на главном —
## только узлы и меши из готовых массивов порциями (step) в прежнем порядке: мир тот же. Малые построители
## (дым труб, ветряки, канатки, машины, деревья города) — по шагу целиком на главном потоке.
##   layer.build(...)                                                    # всё сразу
##   layer.start(...); while not layer.step(50_000): await process_frame  # порциями по кадрам

## Сколько узлов создано по слоям и время, с (для тестов и замеров): layers, compute_s (расчёт), build_s (всего),
## max_step_ms / max_step — самый долгий шаг сборки на главном потоке.
var stats: Dictionary = {}

## Препятствия-дома (заполняет OsmBuildings); collision_check берёт его у WorldObjects.osm_layer.
var building_obstacles: ObstacleIndex

var _data: OsmData
var _cfg: Dictionary
var _height_fn: Callable
var _forest_fn: Callable
var _obstacles: ObstacleIndex
## Результаты расчёта по построителям: имя → словарь-итог своей задачи (читаются после ожидания).
var _res: Dictionary = {}
var _roads: Dictionary = {}
var _task := -1
## Построители по порядку (каждый вызов — {root, steps}) и шаги текущего.
var _parts: Array[Array] = []
var _pi := 0
var _steps: Array = []
var _si := 0
var _part_name := ""
var _computed := false
var _done := false
var _made := 0
var _t0 := 0


## obstacles — общий индекс WorldObjects (опоры, провода и т. п. для OsmRoads/OsmPilot).
## forest_fn(x, z) -> доля леса (Terrain.forest_at) — деревья города на местах крон; пусто — без них.
## threaded — расчёт в рабочих потоках (height_fn потокобезопасна: PlaceData.height_at, чистая функция);
## false — тот же расчёт на главном потоке (height_fn узла сцены, например Callable(terrain, "height_at")).
func build(
	data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex,
	forest_fn: Callable = Callable(), threaded: bool = true
) -> void:
	start(data, cfg, height_fn, obstacles, forest_fn, threaded)
	finish()


## Запуск расчёта. Без потоков — расчёт здесь же. Дальше — step() / finish() на главном потоке.
func start(
	data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex,
	forest_fn: Callable = Callable(), threaded: bool = true
) -> void:
	_t0 = Time.get_ticks_usec()
	_data = data
	_cfg = cfg
	_height_fn = height_fn
	_forest_fn = forest_fn
	_obstacles = obstacles
	_res = {}
	_parts.clear()
	_pi = 0
	_steps = []
	_si = 0
	_computed = false
	_done = false
	_made = 0
	building_obstacles = ObstacleIndex.new()
	_roads = OsmRoads.prepare(data, cfg, height_fn)
	var rule: Dictionary = Config.get_config("osm_tiles").get("height_rule", {})
	# у каждой задачи свой словарь-итог (общий словарь потоки не трогают)
	var pilot := {}
	var houses := {}
	var ground := {}
	_res = {"Pilot": pilot, "Buildings": houses, "CityGround": ground}
	# длинные — первыми: ЛЭП и провода, дома, куски дорог, земля города
	var jobs: Array[Callable] = [
		func() -> void: pilot.merge(OsmPilot.prepare(data, cfg, height_fn)),
		func() -> void: houses.merge(OsmBuildings.prepare(data, cfg, height_fn, rule)),
	]
	if not _roads.is_empty():
		jobs.append_array(_roads.jobs)
	jobs.append(func() -> void: ground.merge(OsmCityGround.prepare(data, cfg, height_fn)))
	if threaded and bool(cfg.get("threaded_build", true)):
		_task = WorkerThreadPool.add_group_task(
			func(i: int) -> void: jobs[i].call(), jobs.size(), -1, false, "osm layer"
		)
	else:
		for j in jobs:
			j.call()
		_on_computed()


## Расчёт готов (сборка не будет ждать потоков).
func is_computed() -> bool:
	return _task < 0 or WorkerThreadPool.is_group_task_completed(_task)


## Сборка порцией на главном потоке: шаги, пока не истёк budget_us (хотя бы один). true — слой готов.
## Пока расчёт идёт — false без работы.
func step(budget_us: int) -> bool:
	if _done:
		return true
	if not is_computed():
		return false
	var t := Time.get_ticks_usec()
	if _task >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_task)
		_task = -1
		_on_computed()
	while true:
		var ts := Time.get_ticks_usec()
		var what := ""
		if _si < _steps.size():
			(_steps[_si] as Callable).call()
			_si += 1
			what = _part_name
		elif _pi < _parts.size():
			_part_name = _parts[_pi][0]
			_begin_part(_parts[_pi])
			_pi += 1
			what = _part_name + " (начало)"
		else:
			_finish_stats()
			return true
		var ms := (Time.get_ticks_usec() - ts) / 1000.0
		if ms > float(stats.get("max_step_ms", 0.0)):
			stats["max_step_ms"] = ms
			stats["max_step"] = what
		if Time.get_ticks_usec() - t >= budget_us:
			return false
	return false


## Дождаться расчёта и собрать всё сразу.
func finish() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_task)
		_task = -1
		_on_computed()
	step(1 << 62)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _task >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_task)  # задачи держат данные слоя
		_task = -1


func _on_computed() -> void:
	_computed = true
	stats["compute_s"] = (Time.get_ticks_usec() - _t0) / 1.0e6
	var d := _data
	var cfg := _cfg
	var hf := _height_fn
	var obs := _obstacles
	var res := _res
	var roads := _roads
	# прежний порядок слоёв; препятствия — в общий индекс в прежнем порядке (ЛЭП, ветряки, канатки)
	_parts = [
		["CityGround", func() -> Dictionary: return OsmCityGround.assemble(res.get("CityGround", {}), cfg)],
		["Roads", func() -> Dictionary: return OsmRoads.assemble(roads)],
		["Pilot", func() -> Dictionary:
			var p: Dictionary = res.get("Pilot", {})
			if obs != null and p.has("obstacles"):
				obs.merge(p.obstacles)
			return OsmPilot.assemble(p)],
		["ChimneyPlumes", func() -> Dictionary: return _whole(OsmChimneyPlumes.build(d, cfg, hf))],
		["Wind", func() -> Dictionary: return _whole(OsmWindTurbines.build(d, cfg, hf, obs))],
		["Cabins", func() -> Dictionary: return _whole(OsmCableCars.build(d, cfg, hf, obs))],
		["Traffic", func() -> Dictionary: return _whole(OsmTraffic.build(d, cfg, hf, obs))],
		["Buildings", func() -> Dictionary:
			var p: Dictionary = res.get("Buildings", {})
			if p.has("obstacles"):
				building_obstacles = p.obstacles
			return OsmBuildings.assemble(p, cfg)],
		["CityTrees", func() -> Dictionary: return _whole(CityTrees.build(d, cfg, hf, _forest_fn))],
	]


## Построитель: корень — потомком с именем слоя, его шаги — следующими.
func _begin_part(p: Array) -> void:
	var a: Dictionary = (p[1] as Callable).call()
	_steps = a.steps
	_si = 0
	var root: Node3D = a.root
	if root == null:
		return
	root.name = p[0]
	add_child(root)
	_made += 1


func _finish_stats() -> void:
	_done = true
	stats["layers"] = _made
	stats["build_s"] = (Time.get_ticks_usec() - _t0) / 1.0e6
	_data = null
	_res = {}
	_roads = {}
	_parts.clear()
	_steps = []


## Узел целиком (малые построители).
static func _whole(node: Node3D) -> Dictionary:
	return {"root": node, "steps": []}


## Выполнить все шаги сборки {root, steps} сразу; root (null — строить нечего).
static func run_all(a: Dictionary) -> Node3D:
	for s: Callable in a.steps:
		s.call()
	return a.root


## L4: ветер слоя OSM. air_fn(p: Vector3) -> Vector3 — скорость воздуха модели в точке, м/с; cam — позиция камеры
## (мир). Зовёт osm_wind(air_fn, cam) у каждого потомка в группе osm_wind (дым, ветряки, кабинки).
func update_wind(air_fn: Callable, cam: Vector3) -> void:
	feed_wind(self, air_fn, cam)


## Обход потомков узла: osm_wind(air_fn, cam) у каждого в группе osm_wind (работает и вне SceneTree).
static func feed_wind(root: Node, air_fn: Callable, cam: Vector3) -> void:
	for c in root.get_children():
		if c.is_in_group(&"osm_wind") and c.has_method(&"osm_wind"):
			c.call(&"osm_wind", air_fn, cam)
		feed_wind(c, air_fn, cam)
