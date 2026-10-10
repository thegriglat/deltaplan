class_name OsmBuildings
extends RefCounted
## Дома OSM (OT-11, контракт O9, docs/contracts/osm-tiles.md): записи OsmData.buildings
## ([x, z, w, l, угол, высота стен, крыша]; высота и крыша уже по height_rule в OsmData) → BuildingPlacer →
## MultiMesh по тайлам с дальностью видимости (configs/world_objects.json → buildings), как процедурные дома
## VillageLayer. Коробки домов — в obstacles (OsmLayer.building_obstacles). Нет домов — null.
## Процедурные дома в пятнах с домами OSM не ставятся (VillagePlacer.plan(..., osm_houses)).

## Статистика последней постройки (для тестов и замеров): buildings, building_tiles, place_s, nodes_s.
static var last_stats: Dictionary = {}


static func build(
	data: OsmData, cfg: Dictionary, height_fn: Callable, obstacles: ObstacleIndex
) -> Node3D:
	last_stats = {}
	if data == null or data.buildings.is_empty():
		return null
	var bc: Dictionary = cfg.buildings
	if not bool(bc.get("enabled", true)):
		return null
	var t0 := Time.get_ticks_usec()
	var tiles := BuildingPlacer.place(data.buildings, bc, height_fn, obstacles)
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
	var n := 0
	for k in tiles:
		var t: Dictionary = tiles[k]
		var o := WorldTiles.center(k, tile)
		root.add_child(WorldTiles.multimesh_node(wall, t.walls, t.wall_colors, o, r, shadows))
		if not t.roofs.is_empty():
			root.add_child(WorldTiles.multimesh_node(roof, t.roofs, t.roof_colors, o, r, shadows))
		n += t.walls.size()
	last_stats = {
		"buildings": n,
		"building_tiles": tiles.size(),
		"place_s": (t1 - t0) / 1.0e6,
		"nodes_s": (Time.get_ticks_usec() - t1) / 1.0e6,
	}
	return root
