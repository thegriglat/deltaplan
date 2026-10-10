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
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	var wall := BoxMesh.new()
	wall.material = mat
	var roof := PrismMesh.new()
	roof.material = mat
	var tile := float(bc.tile_m)
	var r := WorldTiles.tile_range(float(bc.visibility_m), tile)
	var shadows := bool(bc.cast_shadows)
	var root := Node3D.new()
	root.name = "Buildings"
	add_child(root)
	var n := 0
	for k in tiles:
		var t: Dictionary = tiles[k]
		var o := WorldTiles.center(k, tile)
		root.add_child(WorldTiles.multimesh_node(wall, t.walls, t.wall_colors, o, r, shadows))
		if not t.roofs.is_empty():
			root.add_child(WorldTiles.multimesh_node(roof, t.roofs, t.roof_colors, o, r, shadows))
		n += t.walls.size()
	stats["buildings"] = n
	stats["building_tiles"] = tiles.size()
	stats["place_s"] = (t1 - t0) / 1.0e6
	stats["nodes_s"] = (Time.get_ticks_usec() - t1) / 1.0e6
