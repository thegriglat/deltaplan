class_name OsmLayer
extends Node3D
## Отрисовка данных OSM (VR-6, VR-9): дороги (ленты по рельефу) и здания (MultiMesh).
## Всё — тайлами с дальностью видимости.
## Реки и озёра не рисуются: вода уже в раскраске рельефа (terrain) — см. docs/guide/world-objects.md.
## Здания заносятся в ObstacleIndex.

const DRAPED_SHADER := preload("res://scripts/world_objects/draped.gdshader")

## Сколько узлов создано по видам (для тестов и замеров).
var stats: Dictionary = {}

## Препятствия-здания (отдельный индекс: заполняется в фоновом потоке).
var building_obstacles: ObstacleIndex


## Дороги и здания считаются в пуле потоков параллельно (чистые функции над height_fn),
## ноды создаются здесь же после ожидания — вызов синхронный, но быстрее.
func build(data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex) -> void:
	var t0 := Time.get_ticks_usec()
	var road_tiles := {}
	var bld_tiles := {}
	building_obstacles = ObstacleIndex.new()
	var bidx := building_obstacles
	var tasks: Array[int] = []
	var do_roads := bool(cfg.roads.get("enabled", true))
	var do_bld := bool(cfg.buildings.get("enabled", true))
	var threaded := bool(cfg.get("threaded_build", true))
	var roads_job := func() -> void:
		road_tiles.merge(RoadMesher.build(data.roads, cfg.roads, height_fn))
	var bld_job := func() -> void:
		bld_tiles.merge(BuildingPlacer.place(data.buildings, cfg.buildings, height_fn, bidx))
	for job: Array in [[do_roads, roads_job], [do_bld, bld_job]]:
		if job[0]:
			if threaded:
				tasks.append(WorkerThreadPool.add_task(job[1], true))
			else:
				(job[1] as Callable).call()
	var t1 := Time.get_ticks_usec()
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	var t2 := Time.get_ticks_usec()
	if do_roads:
		_add_roads(road_tiles, cfg.roads)
	if do_bld:
		_add_buildings(bld_tiles, cfg.buildings)
	stats["wait_threads_s"] = (t2 - t1) / 1.0e6
	stats["nodes_s"] = (Time.get_ticks_usec() - t2) / 1.0e6


func _add_roads(tiles: Dictionary, cfg: Dictionary) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = DRAPED_SHADER
	mat.set_shader_parameter(&"depth_pull", float(cfg.depth_pull))
	mat.set_shader_parameter(&"depth_bias_m", float(cfg.lift_m) * 2.0)
	var tile := float(cfg.tile_m)
	var root := Node3D.new()
	root.name = "Roads"
	add_child(root)
	for k in tiles:
		var t: Dictionary = tiles[k]
		var mi := MeshInstance3D.new()
		mi.mesh = t.mesh
		mi.material_override = mat
		mi.position = t.origin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var r := float(cfg.major_visibility_m if t.major else cfg.minor_visibility_m)
		mi.visibility_range_end = WorldTiles.tile_range(r, tile)
		root.add_child(mi)
	stats["road_tiles"] = tiles.size()


func _add_buildings(tiles: Dictionary, cfg: Dictionary) -> void:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	var wall := BoxMesh.new()
	wall.material = mat
	var roof := PrismMesh.new()
	roof.material = mat
	var tile := float(cfg.tile_m)
	var r := WorldTiles.tile_range(float(cfg.visibility_m), tile)
	var shadows := bool(cfg.cast_shadows)
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
