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
	var prep := prepare(data, cfg, height_fn, Config.get_config("osm_tiles").height_rule)
	if obstacles != null and prep.has("obstacles"):
		obstacles.merge(prep.obstacles)
	return OsmLayer.run_all(assemble(prep, cfg))


## Расчёт (FL-6, рабочий поток при потокобезопасной height_fn): стиль, поправка этажности (меняет высоты в
## data.buildings на месте), тайлы экземпляров и коробки домов (свой ObstacleIndex). rule — osm_tiles.json →
## height_rule (читается на главном потоке). Нет домов — {}.
static func prepare(data: OsmData, cfg: Dictionary, height_fn: Callable, rule: Dictionary) -> Dictionary:
	if data == null or data.buildings.is_empty():
		return {}
	var bc: Dictionary = cfg.buildings
	if not bool(bc.get("enabled", true)):
		return {}
	var t0 := Time.get_ticks_usec()
	# L2: стиль и поправка этажности мегаполиса (меняет высоты в data.buildings на месте) — до расстановки
	var style := BuildingStyle.classify(data.buildings, bc.style)
	var tc := Time.get_ticks_usec()
	var glass := BuildingStyle.adjust(data.buildings, style, rule)
	BuildingStyle.release()
	var t1 := Time.get_ticks_usec()
	var obstacles := ObstacleIndex.new()
	var tiles := BuildingPlacer.place(data.buildings, bc, height_fn, obstacles, style, glass)
	var t2 := Time.get_ticks_usec()
	var n := 0
	for k in tiles:
		n += (tiles[k].walls as Array).size()
	return {
		"tiles": tiles,
		"obstacles": obstacles,
		"stats": {
			"buildings": n,
			"building_tiles": tiles.size(),
			"style_s": (t1 - t0) / 1.0e6,
			"classify_s": (tc - t0) / 1.0e6,
			"place_s": (t2 - t1) / 1.0e6,
		},
	}


## Сборка на главном потоке (FL-6): {root, steps} (BuildingPlacer.node_steps); last_stats.nodes_s — после всех шагов.
static func assemble(p: Dictionary, cfg: Dictionary) -> Dictionary:
	last_stats = {}
	if p.is_empty():
		return {"root": null, "steps": []}
	last_stats = (p.stats as Dictionary).duplicate()
	last_stats["nodes_s"] = 0.0
	var a := BuildingPlacer.node_steps(p.tiles, cfg.buildings)
	var steps: Array[Callable] = []
	for st: Callable in a.steps:
		steps.append(func() -> void:
			var t := Time.get_ticks_usec()
			st.call()
			last_stats["nodes_s"] = float(last_stats["nodes_s"]) + (Time.get_ticks_usec() - t) / 1.0e6)
	return {"root": a.root, "steps": steps}
