class_name OsmLayer
extends Node3D
## Каркас слоя OSM места (O9): вызывает OsmRoads / OsmPilot / OsmBuildings (scripts/world_objects/osm/) над
## данными OsmData и вешает возвращённые узлы потомками. Дороги, вершины, ЛЭП и дома наполняют
## OT-9 / OT-10 / OT-11; здесь только каркас и общий индекс препятствий домов.

## Сколько узлов создано по слоям и время, с (для тестов и замеров).
var stats: Dictionary = {}

## Препятствия-дома (заполняет OsmBuildings); collision_check берёт его у WorldObjects.osm_layer.
var building_obstacles: ObstacleIndex


## obstacles — общий индекс WorldObjects (опоры, провода и т. п. для OsmRoads/OsmPilot).
func build(data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex) -> void:
	var t0 := Time.get_ticks_usec()
	building_obstacles = ObstacleIndex.new()
	var parts: Array = [
		["Roads", OsmRoads.build(data, cfg, height_fn, obstacles)],
		["Pilot", OsmPilot.build(data, cfg, height_fn, obstacles)],
		["Buildings", OsmBuildings.build(data, cfg, height_fn, building_obstacles)],
	]
	var made := 0
	for p: Array in parts:
		var node: Node3D = p[1]
		if node != null:
			node.name = p[0]
			add_child(node)
			made += 1
	stats["layers"] = made
	stats["build_s"] = (Time.get_ticks_usec() - t0) / 1.0e6


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
