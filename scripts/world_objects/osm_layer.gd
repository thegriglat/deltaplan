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
		["Wind", OsmWindTurbines.build(data, cfg, height_fn, obstacles)],
		["Cabins", OsmCableCars.build(data, cfg, height_fn, obstacles)],
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
