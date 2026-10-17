class_name WorldLink
extends Node
## Связь полётного мира с объектами и рельефом (вызов вниз из Game):
## объекты мира (ветроуказатели, посадки, OSM, препятствия — WorldObjects), просеки для деревьев
## рельефа (WorldClearings) — оба по общим данным места (PlaceData, FL-К2), ветер для травы/деревьев, пилот для примятой травы,
## столкновения с проводами и препятствиями. Сцена объектов — game.json → world_objects_scene.
## Лагерь палаток у старта (WorldObjects.place_camp) — Game зовёт place_camp() после выбора старта
## и до BotPilots.setup_in_world (боты обходят палатки, SC-K1); число ботов — Game.bots_count
## или настройка.

var objects: Node3D  ## WorldObjects или null (сцены нет)

var _prev := Vector3.INF
var _location := "\u0000"
var _terrain: Node


func _ready() -> void:
	var path := String(Config.value("game", "world_objects_scene", ""))
	if path != "" and ResourceLoader.exists(path):
		objects = (load(path) as PackedScene).instantiate() as Node3D
		if objects != null:
			objects.name = "WorldObjects"
			add_child(objects)
	else:
		push_warning("WorldLink: нет сцены объектов мира %s" % path)


## Рельеф загружен (или сменилась погода): всё, что зависит от места и воздуха. Всё в одном кадре
## (расчёт слоя OSM и домов — в рабочих потоках, FL-6); порциями по кадрам — link_async.
func link(terrain: Terrain, air: Node, pilot: Node3D) -> void:
	var place: Variant = _link_begin(terrain, air, pilot)
	if place is bool:
		return
	_link_clearings(terrain, place)
	if objects != null and objects.has_method("setup"):
		objects.call("setup", terrain, air)


## То же порциями (FL-6, FL-10): общие данные места (PlaceData) и маска просек — в рабочих потоках (кадры идут),
## объекты — расчёт в рабочих потоках, узлы не дольше budget_ms за кадр (WorldObjects.setup_async); маска
## считается одновременно с объектами и ставится в рельеф до конца. Ждать: await.
func link_async(terrain: Terrain, air: Node, pilot: Node3D, budget_ms: float = 50.0) -> void:
	if not _link_prep(terrain, air, pilot):
		return
	var place: PlaceData = null
	if terrain.location_id != "":
		var job := PlaceData.start_for_terrain(terrain)
		while not job.done():
			await get_tree().process_frame
		place = job.finish()
		if place == null:
			_location = "\u0000"  # рельеф сменился, пока считались данные места: следующий link — заново
			return
	var mask := {}
	var task := -1
	if place != null and terrain.has_method("set_clearings"):
		var loc: Dictionary = Locations.config(place.location_id)
		var cfg := WorldObjects.load_config()
		task = WorkerThreadPool.add_task(
			func() -> void: mask["c"] = WorldClearings.build_from(place, loc, cfg), false, "WorldClearings"
		)
	await get_tree().process_frame
	if objects != null and objects.has_method(&"setup_async"):
		await objects.setup_async(terrain, air, budget_ms)
	elif objects != null and objects.has_method("setup"):
		objects.call("setup", terrain, air)
	if task >= 0:
		while not WorkerThreadPool.is_task_completed(task):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(task)
		var c: WorldClearings = mask.get("c")
		if c != null and is_instance_valid(terrain) and terrain.location_id == place.location_id:
			terrain.set_clearings(c.image, c.origin, c.cell_m)


## Ветер травы и деревьев, пилот, камни и кусты; общие данные места (FL-К2) — PlaceData или null.
## Та же локация — false (объекты и просеки уже стоят).
func _link_begin(terrain: Terrain, air: Node, pilot: Node3D) -> Variant:
	if not _link_prep(terrain, air, pilot):
		return false
	# общие данные места (FL-К2): OSM и план домов — один раз, для маски просек и объектов
	return PlaceData.for_terrain(terrain) if terrain.location_id != "" else null


## Ветер травы и деревьев, пилот, камни и кусты. Та же локация — false (объекты и просеки уже стоят).
func _link_prep(terrain: Terrain, air: Node, pilot: Node3D) -> bool:
	if terrain.has_method("set_wind_sources"):
		var mean := Callable(air, "mean_wind_at") if air.has_method("mean_wind_at") else Callable()
		var th := Callable(air, "thermals_near") if air.has_method("thermals_near") else Callable()
		var gusts := Callable(air, "air_velocity_at") if air.has_method("air_velocity_at") else Callable()
		# Поле воздуха для травы (AM-10, WF-10): сам air (Atmosphere) — is_air_field_on(),
		# air_field. У CalmAir и т. п. этого метода нет — текстура ветра поля не строится.
		var field_src: Object = air if air.has_method("is_air_field_on") else null
		terrain.set_wind_sources(mean, th, gusts, field_src)
	_terrain = terrain
	if terrain.has_method("set_pilot"):
		terrain.set_pilot(pilot)
	RockScatter.attach(terrain)
	ShrubScatter.attach(terrain)
	var loc := terrain.location_id
	if loc == _location and not terrain.layers.is_empty():
		return false  # та же локация — объекты и просеки уже стоят
	_location = loc
	return true


func _link_clearings(terrain: Terrain, place: PlaceData) -> void:
	if place != null and terrain.has_method("set_clearings"):
		var c := WorldClearings.build_from(place)
		if c != null:
			terrain.set_clearings(c.image, c.origin, c.cell_m)


## Сколько ботов считать в лагере: в сети — Zone.bots_count (настройки создателя, у всех
## клиентов одинаково — палатки входят в препятствия очереди), иначе Game.bots_count
## (--bots=N; < 0 — настройка).
static func camp_bots(game: Object) -> int:
	if game == null:
		return -1
	var net: Variant = game.get(&"net")
	if net is Object and (net as Object).get(&"zone") is Object:
		return int(((net as Object).get(&"zone") as Object).get(&"bots_count"))
	var n: Variant = game.get(&"bots_count")
	return int(n) if n != null else -1


## Палатки у старта Game (get_start): 1 + боты (camp_bots).
func place_camp() -> void:
	var game := get_parent()
	if objects == null or not objects.has_method(&"place_camp") or game == null:
		return
	if not game.has_method(&"get_start") or not is_instance_valid(_terrain):
		return
	var st: Dictionary = game.call(&"get_start")
	objects.call(
		&"place_camp",
		st.position,
		float(st.heading_deg),
		_terrain,
		TentCamp.tent_count(camp_bots(game))
	)
	_apply_trample(st.position)


## Примятая трава вокруг старта (SC-K6): маска по палаткам, вещам и тропе — в GrassField.
func _apply_trample(start: Vector3) -> void:
	var grass: Variant = _terrain.get(&"grass") if is_instance_valid(_terrain) else null
	if grass == null or not objects.has_method(&"trample_mask"):
		return
	var m: Dictionary = objects.call(&"trample_mask", start)
	if m.is_empty():
		grass.set_trample_mask(null, Vector2.ZERO, 1.0)
	else:
		grass.set_trample_mask(m.image, m.origin, m.cell_m)


## Столкновение за шаг (отрезок пути от прошлого положения): {kind, point} или {}.
## kind: building | tree.
func check_hit(pos: Vector3) -> Dictionary:
	var prev := _prev
	_prev = pos
	if objects == null or prev == Vector3.INF or not objects.has_method("obstacle_hit"):
		return {}
	return objects.call("obstacle_hit", prev, pos)


## Новый полёт — не считать телепорт отрезком пути.
func reset_path() -> void:
	_prev = Vector3.INF
