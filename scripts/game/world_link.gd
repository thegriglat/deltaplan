class_name WorldLink
extends Node
## Связь полётного мира с объектами и рельефом (вызов вниз из Game):
## объекты мира (ветроуказатели, посадки, OSM, препятствия — WorldObjects), просеки для деревьев
## рельефа (WorldClearings), ветер для травы/деревьев, пилот для примятой травы,
## столкновения с проводами и препятствиями. Сцена объектов — game.json → world_objects_scene.

var objects: Node3D  ## WorldObjects или null (сцены нет)

var _prev := Vector3.INF
var _location := "\u0000"


func _ready() -> void:
	var path := String(Config.value("game", "world_objects_scene", ""))
	if path != "" and ResourceLoader.exists(path):
		objects = (load(path) as PackedScene).instantiate() as Node3D
		if objects != null:
			objects.name = "WorldObjects"
			add_child(objects)
	else:
		push_warning("WorldLink: нет сцены объектов мира %s" % path)


## Рельеф загружен (или сменилась погода): всё, что зависит от места и воздуха.
func link(terrain: Terrain, air: Node, pilot: Node3D) -> void:
	if terrain.has_method("set_wind_sources"):
		var mean := Callable(air, "mean_wind_at") if air.has_method("mean_wind_at") else Callable()
		var th := Callable(air, "thermals_near") if air.has_method("thermals_near") else Callable()
		var gusts := Callable(air, "air_velocity_at") if air.has_method("air_velocity_at") else Callable()
		terrain.set_wind_sources(mean, th, gusts)
	if terrain.has_method("set_pilot"):
		terrain.set_pilot(pilot)
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
