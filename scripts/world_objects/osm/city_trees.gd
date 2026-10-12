class_name CityTrees
extends Node3D
## Деревья города и сёл (configs/world_objects.json → city_trees, расстановка — CityTreePlan): MultiMesh по тайлам
## вокруг камеры. Модели и материал те же, что у одиночных деревьев мира (assets/models/trees, tree_model.gdshader,
## LOD0/LOD1/LOD2-импостер), ветер — osm_wind(air_fn, cam). Тайлы строятся и кешируются в рабочем потоке порциями
## (первый раз — ближний радиус first_radius_m), в главный поток уходит только готовый буфер. Тени — LOD с номером
## меньше shadow_lods при cast_shadows. Деревья визуальные (препятствий нет, как у одиночных деревьев мира).
## build(data, cfg, height_fn) — деревья города по данным OSM; build_gardens(houses, cfg, height_fn) — сады домов посёлков.

const SHADER := preload("res://scripts/terrain/tree_model.gdshader")
const LODS := 3

var plan: CityTreePlan
## материалы деревьев (tree_model.gdshader)
var materials: Array[ShaderMaterial] = []
var camera: Camera3D
## Сколько деревьев сейчас в MultiMesh'ах по LOD (для замеров) и время работы потока.
var stats: Dictionary = {}

var _cfg: Dictionary = {}
var _height_fn: Callable
var _mmis: Array[MultiMeshInstance3D] = []
var _tiles: Dictionary = {}
var _task := -1
var _buffers: Array = []
var _counts := PackedInt32Array()
var _last_center := Vector2(INF, INF)
var _pending_center := Vector2.ZERO
var _first_done := false
var _wind := Vector2.ZERO


## Деревья города: улицы, дворы, сады домов OSM. null — выключено или нечего ставить.
static func build(data: OsmData, cfg: Dictionary, height_fn: Callable) -> CityTrees:
	var tc: Dictionary = cfg.get("city_trees", {})
	if data == null or not bool(tc.get("enabled", true)) or data.buildings.is_empty() and data.roads.is_empty():
		return null
	var cell := float((cfg.get("buildings", {}).get("style", {}) as Dictionary).get("cell_m", 200.0))
	return _make(
		tc, data.roads, data.rivers, data.buildings, [], cfg.get("roads", {}), cfg.get("city_ground", {}), cell,
		height_fn
	)


## Сады процедурных домов посёлков (VillagePlacer: [x, z, w, l, угол, высота, крыша]).
static func build_gardens(houses: Array, cfg: Dictionary, height_fn: Callable) -> CityTrees:
	var tc: Dictionary = cfg.get("city_trees", {})
	if houses.is_empty() or not bool(tc.get("enabled", true)):
		return null
	return _make(tc, [], [], [], houses, cfg.get("roads", {}), cfg.get("city_ground", {}), 200.0, height_fn)


static func _make(
	tc: Dictionary, roads: Array, rivers: Array, osm_houses: Array, extra: Array, rc: Dictionary,
	cg: Dictionary, cell: float, height_fn: Callable
) -> CityTrees:
	var n := CityTrees.new()
	n.name = "CityTrees"
	var p := CityTreePlan.new()
	p.setup(tc, roads, rivers, osm_houses, extra, rc, cg, cell, height_fn)
	if not n.setup(p, tc, height_fn):
		n.free()
		return null
	return n


func setup(p: CityTreePlan, cfg: Dictionary, height_fn: Callable) -> bool:
	plan = p
	_cfg = cfg
	_height_fn = height_fn
	var sp: Dictionary = cfg.get("species", {})
	var shadows := bool(cfg.get("cast_shadows", true))
	var shadow_lods := int(cfg.get("shadow_lods", 1))
	for si in plan.species.size():
		var s: Dictionary = sp[plan.species[si]]
		for v in plan.variants:
			var lods := TerrainTreeModels._load_lods(String(s.get("model", "")), v)
			if lods.is_empty():
				push_warning("CityTrees: нет модели %s" % s.get("model", ""))
				return false
			var mh := lods[0].get_aabb().end.y
			plan.model_height[si * plan.variants + v] = mh
			var cache := {}
			for lod in LODS:
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_colors = true
				mm.mesh = _tree_mesh(lods[lod], mh, cache)
				var mmi := MultiMeshInstance3D.new()
				mmi.name = "%s_v%d_LOD%d" % [plan.species[si], v, lod]
				mmi.multimesh = mm
				mmi.cast_shadow = (
					GeometryInstance3D.SHADOW_CASTING_SETTING_ON
					if shadows and lod < shadow_lods
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				)
				add_child(mmi)
				_mmis.append(mmi)
	_counts.resize(_mmis.size())
	add_to_group(&"osm_wind")
	return not _mmis.is_empty()


## Копия меша с материалами tree_model.gdshader (как у TerrainTreeModels: те же текстуры + качание).
func _tree_mesh(src: Mesh, height: float, cache: Dictionary) -> Mesh:
	var mesh := src.duplicate() as Mesh
	for s in mesh.get_surface_count():
		var std := mesh.surface_get_material(s) as BaseMaterial3D
		if std == null:
			continue
		if not cache.has(std.resource_name):
			var m := ShaderMaterial.new()
			m.shader = SHADER
			m.set_shader_parameter("albedo_tex", std.albedo_texture)
			m.set_shader_parameter("albedo_color", std.albedo_color)
			m.set_shader_parameter(
				"alpha_clip", std.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
			)
			m.set_shader_parameter("alpha_threshold", std.alpha_scissor_threshold)
			m.set_shader_parameter("roughness_value", std.roughness)
			m.set_shader_parameter("model_height", height)
			m.set_shader_parameter("sway_top_m", float(_cfg.get("sway_top_m", 0.5)))
			m.set_shader_parameter("sway_hz", float(_cfg.get("sway_hz", 0.25)))
			cache[std.resource_name] = m
			materials.append(m)
		mesh.surface_set_material(s, cache[std.resource_name])
	return mesh


## Ветер слоя OSM: вектор у земли в точке камеры — материалам деревьев.
func osm_wind(air_fn: Callable, cam: Vector3) -> void:
	var a: Vector3 = air_fn.call(Vector3(cam.x, float(_height_fn.call(cam.x, cam.z)) + 10.0, cam.z))
	_wind = Vector2(a.x, a.z)
	for m in materials:
		m.set_shader_parameter("wind_vec", _wind)


func _process(_delta: float) -> void:
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_apply()
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := cam.global_position
	var agl := p.y - float(_height_fn.call(p.x, p.z))
	var show := agl < float(_cfg.get("max_agl_m", 1000.0))
	if visible != show:
		visible = show
	if not show:
		return
	var c := Vector2(p.x, p.z)
	if c.distance_to(_last_center) < float(_cfg.get("rebuild_step_m", 60.0)):
		return
	_pending_center = c
	if not _first_done:
		# сначала ближние тайлы (и общая подготовка), полный радиус — следующим заходом
		_first_done = true
		_task = WorkerThreadPool.add_task(
			_build.bind(c, float(_cfg.get("first_radius_m", 300.0))), false, "city trees"
		)
		return
	_last_center = c
	_task = WorkerThreadPool.add_task(_build.bind(c), false, "city trees")


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Сразу, без потока и камеры (тесты, замеры): подготовить, расставить вокруг c, применить.
func rebuild_now(c: Vector2, limit: float = INF) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_build(c, limit)
	_pending_center = c
	_apply()
	_last_center = c


## Рабочий поток: подготовка (один раз), достроить тайлы в радиусе, собрать буферы.
func _build(c: Vector2, limit: float = INF) -> void:
	plan.prepare()
	var radius := minf(float(_cfg.get("radius_m", 1100.0)), limit)
	var tile := float(_cfg.get("tile_m", 192.0))
	var keys := ShrubScatter._tile_keys(c, radius, tile, _tiles)
	for k in keys:
		if not _tiles.has(k):
			_tiles[k] = plan.build_tile(k.x, k.y)
	var bufs: Array = []
	bufs.resize(_mmis.size())
	for i in bufs.size():
		bufs[i] = PackedFloat32Array()
	var lod_m: Array = _cfg.get("lod_m", [70.0, 220.0])
	var l0 := float(lod_m[0])
	var l1 := float(lod_m[1])
	var budget := int(_cfg.get("max_instances", 40000))
	for k in keys:
		var t: Dictionary = _tiles[k]
		var xf: PackedFloat32Array = t.xf
		var col: PackedFloat32Array = t.col
		var vv: PackedInt32Array = t["var"]
		for i in vv.size():
			var d := Vector2(xf[i * 12 + 3], xf[i * 12 + 11]).distance_to(c)
			if d > radius:
				continue
			var b := vv[i] * LODS + (0 if d < l0 else (1 if d < l1 else 2))
			var buf: PackedFloat32Array = bufs[b]
			buf.append_array(xf.slice(i * 12, i * 12 + 12))
			buf.append_array(col.slice(i * 4, i * 4 + 4))
			bufs[b] = buf
			budget -= 1
			if budget <= 0:
				break
		if budget <= 0:
			break
	_buffers = bufs


func _apply() -> void:
	if _buffers.is_empty():
		return
	var r := float(_cfg.get("radius_m", 1100.0))
	var aabb := AABB(
		Vector3(_pending_center.x - r, -500.0, _pending_center.y - r), Vector3(2.0 * r, 6000.0, 2.0 * r)
	)
	for b in _mmis.size():
		var buf: PackedFloat32Array = _buffers[b]
		var mm := _mmis[b].multimesh
		mm.instance_count = buf.size() / 16
		if buf.size() > 0:
			mm.buffer = buf
		_mmis[b].custom_aabb = aabb
		_counts[b] = mm.instance_count
	_buffers = []
	var by_lod := [0, 0, 0]
	for b in _counts.size():
		by_lod[b % LODS] += _counts[b]
	stats["lod"] = by_lod
	stats["total"] = by_lod[0] + by_lod[1] + by_lod[2]


## Деревьев в MultiMesh'ах сейчас.
func instance_count() -> int:
	var n := 0
	for c in _counts:
		n += c
	return n
