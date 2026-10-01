class_name WorldLink
extends Node
## Связь полётного мира с объектами и рельефом (вызов вниз из Game):
## объекты мира (ветроуказатели, посадки, OSM, препятствия — WorldObjects), просеки для деревьев
## рельефа (WorldClearings), ветер для травы/деревьев, пилот для примятой травы,
## столкновения с проводами и препятствиями. Сцена объектов — game.json → world_objects_scene.
## Лагерь палаток у старта (WorldObjects.place_camp) — когда Game закончил загрузку полёта
## (status_changed("")): старт выбран, число ботов известно (Game.bots_count или настройка).

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
	var game := get_parent()
	if game != null and game.has_signal(&"status_changed"):
		game.connect(&"status_changed", _on_game_status)


## Рельеф загружен (или сменилась погода): всё, что зависит от места и воздуха.
func link(terrain: Terrain, air: Node, pilot: Node3D) -> void:
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
		return  # та же локация — объекты и просеки уже стоят
	_location = loc
	if loc != "" and terrain.has_method("set_clearings"):
		var c := WorldClearings.build_for(loc)
		if c != null:
			terrain.set_clearings(c.image, c.origin, c.cell_m)
	if objects != null and objects.has_method("setup"):
		objects.call("setup", terrain, air)


## Палатки у старта Game (get_start): 1 + боты (Game.bots_count ≥ 0 — --bots=N, иначе настройка).
func place_camp() -> void:
	var game := get_parent()
	if objects == null or not objects.has_method(&"place_camp") or game == null:
		return
	if not game.has_method(&"get_start") or not is_instance_valid(_terrain):
		return
	var st: Dictionary = game.call(&"get_start")
	var bots := int(game.get(&"bots_count")) if &"bots_count" in game else -1
	objects.call(
		&"place_camp", st.position, float(st.heading_deg), _terrain, TentCamp.tent_count(bots)
	)


## Загрузка полёта закончена (Game.start → status_changed("")) — старт выбран.
func _on_game_status(text: String) -> void:
	if text == "":
		place_camp()


## Столкновение за шаг (отрезок пути от прошлого положения): {kind, point} или {}.
## kind: wire | tower | building | tree | fence.
func check_hit(pos: Vector3) -> Dictionary:
	var prev := _prev
	_prev = pos
	if objects == null or prev == Vector3.INF or not objects.has_method("obstacle_hit"):
		return {}
	return objects.call("obstacle_hit", prev, pos)


## Новый полёт — не считать телепорт отрезком пути.
func reset_path() -> void:
	_prev = Vector3.INF
