class_name VillageLayer
extends Node3D
## Дома посёлков (NO-2): записи VillagePlacer → BuildingPlacer → MultiMesh по тайлам с дальностью
## видимости (configs/world_objects.json → buildings). Коробки домов — в building_obstacles.

## Сколько узлов создано (для тестов и замеров).
var stats: Dictionary = {}
## Препятствия-дома (kind "building").
var building_obstacles: ObstacleIndex


func build(houses: Array, cfg: Dictionary, height_fn: Callable) -> void:
	var steps := assemble(VillageLayer.prepare(houses, cfg, height_fn), cfg)
	for st in steps:
		st.call()


## Расчёт (FL-6, рабочий поток при потокобезопасной height_fn): тайлы экземпляров и коробки домов.
static func prepare(houses: Array, cfg: Dictionary, height_fn: Callable) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var obstacles := ObstacleIndex.new()
	var tiles := BuildingPlacer.place(houses, cfg.buildings, height_fn, obstacles)
	return {"tiles": tiles, "obstacles": obstacles, "place_s": (Time.get_ticks_usec() - t0) / 1.0e6}


## Сборка на главном потоке (FL-6): препятствия и stats — сразу, узлы — шагами (по тайлу).
func assemble(p: Dictionary, cfg: Dictionary) -> Array[Callable]:
	building_obstacles = p.obstacles
	var tiles: Dictionary = p.tiles
	var a := BuildingPlacer.node_steps(tiles, cfg.buildings)
	var root: Node3D = a.root
	root.name = "Buildings"
	var n := 0
	for k in tiles:
		n += (tiles[k].walls as Array).size()
	stats["buildings"] = n
	stats["building_tiles"] = tiles.size()
	stats["place_s"] = p.place_s
	stats["nodes_s"] = 0.0
	var steps: Array[Callable] = [add_child.bind(root)]
	for st: Callable in a.steps:
		steps.append(func() -> void:
			var t := Time.get_ticks_usec()
			st.call()
			stats["nodes_s"] = float(stats["nodes_s"]) + (Time.get_ticks_usec() - t) / 1.0e6)
	return steps
