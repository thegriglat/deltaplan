class_name OsmBuildings
extends RefCounted
## Дома OSM (OT-11, контракт O9, docs/contracts/osm-tiles.md): записи OsmData.buildings
## ([x, z, w, l, угол, высота стен, крыша]; высота и крыша уже по height_rule в OsmData) → BuildingPlacer →
## MultiMesh по тайлам с дальностью видимости (configs/world_objects.json → buildings), как процедурные дома
## VillageLayer. Коробки домов — в obstacles (OsmLayer.building_obstacles). Нет домов — null.
## Процедурные дома в пятнах с домами OSM не ставятся (VillagePlacer.plan(..., osm_houses)).

## Статистика последней постройки (для тестов и замеров): buildings, building_tiles, style_s (стиль + поправка), place_s, nodes_s.
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
	# L2: стиль и поправка этажности мегаполиса (меняет высоты в data.buildings на месте) — до расстановки
	var style := BuildingStyle.classify(data.buildings, bc.style)
	var tc := Time.get_ticks_usec()
	var glass := BuildingStyle.adjust(data.buildings, style, Config.get_config("osm_tiles").height_rule)
	BuildingStyle.release()
	var t1 := Time.get_ticks_usec()
	var tiles := BuildingPlacer.place(data.buildings, bc, height_fn, obstacles, style, glass)
	var t2 := Time.get_ticks_usec()
	var root := BuildingPlacer.make_nodes(tiles, bc)
	var n := 0
	for k in tiles:
		n += (tiles[k].walls as Array).size()
	last_stats = {
		"buildings": n,
		"building_tiles": tiles.size(),
		"style_s": (t1 - t0) / 1.0e6,
		"classify_s": (tc - t0) / 1.0e6,
		"place_s": (t2 - t1) / 1.0e6,
		"nodes_s": (Time.get_ticks_usec() - t2) / 1.0e6,
	}
	return root
