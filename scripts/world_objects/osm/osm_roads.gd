class_name OsmRoads
extends RefCounted
## Дороги, реки и каналы, железные дороги из тайлов OSM (O9, OT-9): ленты по рельефу (RoadMesher), тайлами с
## дальностью видимости. Реки и каналы — материал воды (в маску воды рельефа не пишутся), ж/д — тёмная лента.
## Тоннели не рисуются; мосты — обычной лентой. Сигнатура — контракт O9: данные места (OsmData), конфиг
## WorldObjects, высота рельефа height_fn(x, z) -> float и индекс препятствий (дороги препятствий не дают).
## Возвращает Node3D "Roads" (в meta "stats" — счётчики) или null, если строить нечего.

const DRAPED_SHADER := preload("res://scripts/world_objects/draped.gdshader")
const ROAD_SHADER := preload("res://scripts/world_objects/osm/road.gdshader")


## Кусков на группу (не больше; по числу лент /400): куски одного тайла дают отдельные меши (ключ с номером куска).
## Постоянное число, а не число ядер — мир одинаков на любой машине.
const CHUNKS := 8


static func build(data: OsmData, cfg: Dictionary, height_fn: Callable, _obstacles: ObstacleIndex) -> Node3D:
	var prep := prepare(data, cfg, height_fn)
	if prep.is_empty():
		return null
	var jobs: Array = prep.jobs
	if bool(cfg.get("threaded_build", true)):
		PoolFor.run(func(i: int) -> void: (jobs[i] as Callable).call(), jobs.size(), "osm roads")
	else:
		for j: Callable in jobs:
			j.call()
	return OsmLayer.run_all(assemble(prep))


## Подготовка (FL-6, главный поток, дёшево): группы и куски; jobs — расчёт кусков (RoadMesher.build), каждый —
## в своём рабочем потоке при потокобезопасной height_fn. Строить нечего — {}.
static func prepare(data: OsmData, cfg: Dictionary, height_fn: Callable) -> Dictionary:
	if data == null:
		return {}
	var groups := _groups(data, cfg)
	if groups.is_empty():
		return {}
	var jobs: Array[Callable] = []
	for g: Dictionary in groups:
		var items: Array = g.items
		var n := clampi(items.size() / 400, 1, CHUNKS)
		g.parts = []
		for k in n:
			var part := {"items": items.slice(k * items.size() / n, (k + 1) * items.size() / n), "tiles": {}, "counts": {}}
			(g.parts as Array).append(part)
			jobs.append(_run_part.bind(part, g.cfg, height_fn))
	return {"groups": groups, "jobs": jobs}


static func _run_part(part: Dictionary, gcfg: Dictionary, height_fn: Callable) -> void:
	part.tiles = RoadMesher.build(part.items, gcfg, height_fn, part.counts)


## Сборка на главном потоке (FL-6) после всех jobs: {root, steps}; root в meta "stats". Нечего — root null.
static func assemble(prep: Dictionary) -> Dictionary:
	if prep.is_empty():
		return {"root": null, "steps": []}
	var groups: Array = prep.groups
	var stats := {"roads": {}, "rivers": {}, "rail": {}, "tiles": 0, "skipped_tunnels": 0}
	var steps: Array[Callable] = []
	var root := Node3D.new()
	for g: Dictionary in groups:
		var parts: Array = g.parts
		for k in parts.size():
			for c in parts[k].counts:
				g.counts[c] = int(g.counts.get(c, 0)) + int(parts[k].counts[c])
			for key in parts[k].tiles:
				g.tiles["%s#%d" % [key, k]] = parts[k].tiles[key]
		stats[g.kind] = g.counts
		stats.skipped_tunnels += int(g.tunnels)
		stats.tiles += (g.tiles as Dictionary).size()
		_group_steps(root, g, steps)
	root.set_meta(&"stats", stats)
	if steps.is_empty():
		root.free()
		return {"root": null, "steps": []}
	return {"root": root, "steps": steps}


## Группы построения: роады, реки/каналы, ж/д — {kind, name, items, cfg, counts, tunnels, water}.
static func _groups(data: OsmData, cfg: Dictionary) -> Array:
	var out: Array = []
	var rc: Dictionary = cfg.get("roads", {})
	if bool(rc.get("enabled", true)) and not data.roads.is_empty() and rc.has("classes"):
		var f := _without_tunnels(data.roads)
		out.append(_group("roads", "Roads", f.items, rc, f.tunnels, false))
	var vc: Dictionary = cfg.get("rivers", {})
	if bool(vc.get("enabled", true)) and not data.rivers.is_empty() and vc.has("classes"):
		var items: Array = []
		for r: Dictionary in data.rivers:
			var t := String(r.t)
			if t == "river" and bool(r.get("named", false)):
				t = "river_named"
			items.append({"t": t, "p": r.p})
		out.append(_group("rivers", "Rivers", items, _inherit(vc, rc), 0, true))
	var lc: Dictionary = cfg.get("rail", {})
	if bool(lc.get("enabled", true)) and not data.rail.is_empty() and lc.has("classes"):
		var f2 := _without_tunnels(data.rail)
		out.append(_group("rail", "Rail", f2.items, _inherit(lc, rc), f2.tunnels, false))
	return out


static func _group(kind: String, node_name: String, items: Array, gcfg: Dictionary, tunnels: int, water: bool) -> Dictionary:
	return {
		"kind": kind, "name": node_name, "items": items, "cfg": gcfg, "counts": {}, "tunnels": tunnels,
		"water": water, "tiles": {},
	}


## Общие ключи (шаг, подъём, тайл, шейдер) берутся из roads, если у группы своих нет.
static func _inherit(own: Dictionary, base: Dictionary) -> Dictionary:
	var c := own.duplicate()
	for k in ["step_m", "minor_step_m", "lift_m", "depth_pull", "tile_m"]:
		if not c.has(k):
			c[k] = base.get(k, own.get("step_m", 12.0))
	if not own.has("minor_step_m"):
		c.minor_step_m = own.get("step_m", c.minor_step_m)
	return c


static func _without_tunnels(arr: Array) -> Dictionary:
	var items: Array = []
	var tunnels := 0
	for r: Dictionary in arr:
		if bool(r.get("tunnel", false)):
			tunnels += 1
		else:
			items.append(r)
	return {"items": items, "tunnels": tunnels}


static func _group_steps(parent: Node3D, g: Dictionary, steps: Array[Callable]) -> void:
	var tiles: Dictionary = g.tiles
	if tiles.is_empty():
		return
	var gcfg: Dictionary = g.cfg
	var mat := ShaderMaterial.new()
	mat.shader = DRAPED_SHADER if g.water or g.kind != "roads" else ROAD_SHADER
	mat.set_shader_parameter(&"depth_pull", float(gcfg.depth_pull))
	mat.set_shader_parameter(&"depth_bias_m", float(gcfg.lift_m) * 2.0)
	if mat.shader == ROAD_SHADER:
		_look_params(mat, gcfg.get("look", {}))
	if g.water:
		mat.set_shader_parameter(&"roughness", float(gcfg.get("roughness", 0.12)))
		mat.set_shader_parameter(&"edge_darken", 0.0)
	var tile := float(gcfg.tile_m)
	var root := Node3D.new()
	root.name = g.name
	steps.append(parent.add_child.bind(root))
	for k in tiles:
		var t: Dictionary = tiles[k]
		steps.append(func() -> void:
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, t.arrays)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = mat
			mi.position = t.origin
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var r := float(gcfg.get("major_visibility_m", 12000.0) if t.major else gcfg.get("minor_visibility_m", 3000.0))
			mi.visibility_range_end = WorldTiles.tile_range(r, tile)
			root.add_child(mi))


## roads.look (L7) → uniform'ы шейдера дорог: числа и цвета (массив [r, g, b] sRGB — для uniform с source_color).
static func _look_params(mat: ShaderMaterial, look: Dictionary) -> void:
	for k: String in look:
		if k.ends_with("_doc") or k == "styles" or k.begins_with("_"):
			continue
		var v: Variant = look[k]
		if v is Array:
			var a: Array = v
			mat.set_shader_parameter(StringName(k), Color(float(a[0]), float(a[1]), float(a[2])))  # source_color: sRGB
		elif v is float or v is int:
			mat.set_shader_parameter(StringName(k), float(v))
