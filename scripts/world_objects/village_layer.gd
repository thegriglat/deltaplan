class_name VillageLayer
extends Node3D
## Дома посёлков (NO-2): записи VillagePlacer → BuildingPlacer → MultiMesh по тайлам с дальностью
## видимости (configs/world_objects.json → buildings). Коробки домов — в building_obstacles.

## Сколько узлов создано (для тестов и замеров).
var stats: Dictionary = {}
## Препятствия-дома (kind "building").
var building_obstacles: ObstacleIndex


func build(houses: Array, cfg: Dictionary, height_fn: Callable) -> void:
	var t0 := Time.get_ticks_usec()
	building_obstacles = ObstacleIndex.new()
	var bc: Dictionary = cfg.buildings
	var tiles := BuildingPlacer.place(houses, bc, height_fn, building_obstacles)
	var t1 := Time.get_ticks_usec()
	var root := BuildingPlacer.make_nodes(tiles, bc)
	root.name = "Buildings"
	add_child(root)
	var n := 0
	for k in tiles:
		n += (tiles[k].walls as Array).size()
	stats["buildings"] = n
	stats["building_tiles"] = tiles.size()
	stats["place_s"] = (t1 - t0) / 1.0e6
	stats["nodes_s"] = (Time.get_ticks_usec() - t1) / 1.0e6
