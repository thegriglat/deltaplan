class_name WorldObjects
extends Node3D
## Объекты мира по данным локации (docs/guide/world-objects.md):
##   ветроуказатели на стартах и посадках + ленточки на стартах (VR-7) — анимация по ЛОКАЛЬНОМУ
##   ветру модели (air_velocity_at у вертлюга), посадочные площадки (VR-12), дороги и здания
##   из OSM (VR-6, VR-9). Параметры — configs/world_objects.json.
## Подключение: world_objects.setup(terrain, atmosphere) после загрузки рельефа.
## Столкновения для интегратора: obstacle_hit(a, b) -> {kind, point}.

## Всё построено (после setup / build).
signal built

var cfg: Dictionary = {}
var location_id: String = ""
var obstacles: ObstacleIndex
var osm: OsmData
var osm_layer: OsmLayer
var landing_sites: Array[LandingSite] = []
var indicators: Array[WindIndicator] = []
## Тропы к стартам (StartTracks.plan) — по одной ломаной (мир x, z) на start_sites[i].
var start_tracks: Array = []
## Время построения, с (NFR-2).
var build_time_s: float = 0.0
## Лагерь пилотов у старта (place_camp, TentCamp.plan):
## [{type, position, basis, yaw, color, radius}].
var camp: Array[Dictionary] = []
## Костёр лагеря (Campfire) или null.
var campfire: Campfire = null

var _air_fn: Callable
var _height_fn: Callable
var _clearings: WorldClearings
var _active: Array[WindIndicator] = []
var _since_update: float = 0.0
var _since_active: float = INF
var _since_fire: float = INF
var _update_dt: float = 1.0 / 30.0


## Главный вход: зависимости передаются явно. atmosphere может быть null (ветроуказатели — штиль).
func setup(terrain: Node, atmosphere: Node) -> void:
	var air := Callable()
	if atmosphere != null:
		air = Callable(atmosphere, &"air_velocity_at")
	var landings: Array = []
	if terrain.has_method(&"get_landing_sites"):
		landings = terrain.call(&"get_landing_sites")
	build(
		String(terrain.get(&"location_id")),
		terrain.call(&"get_start_sites"),
		landings,
		Callable(terrain, &"height_at"),
		air,
		Callable(terrain, &"latlon_to_local"),
		Vector2(float(terrain.get(&"center_lat")), float(terrain.get(&"center_lon")))
	)


## То же без нод (тесты, другие источники рельефа).
## start_sites — как Terrain.get_start_sites(); landings — как Terrain.get_landing_sites()
## ({id, name, lat, lon}; подробности поля — configs/world_objects.json → landing.sites по id);
## latlon_fn(lat, lon) -> Vector2(x, z); center — (lat, lon).
func build(
	loc_id: String,
	start_sites: Array,
	landings: Array,
	height_fn: Callable,
	air_fn: Callable,
	latlon_fn: Callable,
	center: Vector2
) -> void:
	var t0 := Time.get_ticks_usec()
	clear()
	_clearings = null
	location_id = loc_id
	cfg = WorldObjects.load_config()
	_air_fn = air_fn
	_height_fn = height_fn
	_update_dt = 1.0 / maxf(float(cfg.windsock.update_hz), 1.0)
	obstacles = ObstacleIndex.new()
	for s in start_sites:
		_build_start(s, height_fn)
	for site in WorldObjects.landing_specs(cfg.landing, loc_id, landings):
		_build_landing(site, height_fn, latlon_fn)
	if loc_id != "":
		osm = OsmData.load_file(Locations.osm_path(loc_id), center.x, center.y)
	if osm != null:
		osm_layer = OsmLayer.new()
		osm_layer.name = "Osm"
		add_child(osm_layer)
		osm_layer.build(osm, cfg, height_fn, obstacles)
	if bool(cfg.start_tracks.get("enabled", true)):
		start_tracks = StartTracks.plan(start_sites, osm, cfg.start_tracks, height_fn)
		_build_start_tracks(height_fn)
	_reset_indicators()
	build_time_s = (Time.get_ticks_usec() - t0) / 1.0e6
	print(
		(
			"WorldObjects: '%s' за %.2f с — ветроуказателей %d, посадок %d, троп к стартам %d, OSM %s"
			% [
				loc_id,
				build_time_s,
				indicators.size(),
				landing_sites.size(),
				start_tracks.size(),
				osm_layer.stats if osm_layer != null else "нет"
			]
		)
	)
	built.emit()


func clear() -> void:
	for c in get_children():
		c.queue_free()
	indicators.clear()
	landing_sites.clear()
	start_tracks.clear()
	camp.clear()
	campfire = null
	_active.clear()
	osm_layer = null
	osm = null


## Конфиг с учётом пресета качества (configs/world_objects.json → quality).
static func load_config() -> Dictionary:
	var c: Dictionary = Config.get_config("world_objects").duplicate(true)
	var preset: Dictionary = c.get("quality_presets", {}).get(String(c.get("quality", "high")), {})
	for section in preset:
		if c.has(section) and c[section] is Dictionary:
			(c[section] as Dictionary).merge(preset[section], true)
	return c


## Площадки посадки: записи конфига локации + площадки рельефа, которых нет в конфиге
## (для них — landing.defaults). Запись конфига без lat/lon берёт их у площадки рельефа с тем же id.
static func landing_specs(landing_cfg: Dictionary, loc_id: String, landings: Array) -> Array:
	var by_id := {}
	for l in landings:
		by_id[String(l.id)] = l
	var out: Array = []
	var seen := {}
	for site in landing_cfg.get("sites", {}).get(loc_id, []):
		var s: Dictionary = (landing_cfg.get("defaults", {}) as Dictionary).duplicate(true)
		s.merge(site, true)
		var src: Dictionary = by_id.get(String(s.id), {})
		if not s.has("lat") and not src.is_empty():
			s.lat = src.lat
			s.lon = src.lon
		if not s.has("name") and not src.is_empty():
			s.name = src.name
		if s.has("lat"):
			out.append(s)
			seen[String(s.id)] = true
	for l in landings:
		if not seen.has(String(l.id)):
			var s: Dictionary = (landing_cfg.get("defaults", {}) as Dictionary).duplicate(true)
			s.merge({"id": l.id, "name": l.name, "lat": l.lat, "lon": l.lon}, true)
			out.append(s)
	return out


## Маска просек локации для расстановки деревьев (L8, 255 — расчищено; пиксель — clearings.cell_m,
## угол (0, 0) — мир (−half, −half)). Подробности и привязка — WorldClearings.build_for().
static func clearing_mask_for(loc_id: String) -> Image:
	var c := WorldClearings.build_for(loc_id)
	return c.image if c != null else null


## Палатки лагеря пилотов у старта игрока (TentCamp, configs/world_objects.json → tents): вызывать
## после build/setup, когда старт выбран. count < 0 — 1 + боты из настроек. terrain (Terrain или
## null) — лес, вода, застройка, камни и кусты; без него — только уклон, тропы и OSM.
## Прошлый лагерь (другой старт той же локации) убирается вместе с препятствиями «tent».
func place_camp(start: Vector3, heading_deg: float, terrain: Node = null, count: int = -1) -> void:
	for old_name in ["Camp", "Campfire"]:
		var old := get_node_or_null(old_name)
		if old != null:
			remove_child(old)
			old.queue_free()
	camp.clear()
	campfire = null
	if obstacles != null:
		obstacles.remove_kind("tent")
	var tc: Dictionary = cfg.get("tents", {})
	if tc.is_empty() or not bool(tc.get("enabled", true)):
		return
	if count < 0:
		count = TentCamp.tent_count()
	var t0 := Time.get_ticks_usec()
	var env := _camp_env(start, tc, terrain)
	camp = TentCamp.plan(start, heading_deg, count, tc, env)
	if camp.is_empty():
		print("WorldObjects: у старта нет ровного места для палаток")
		return
	add_child(TentCamp.build_node(camp, tc))
	_place_campfire(start, heading_deg, tc, env)
	for t in camp:
		var ty: Dictionary = tc.types[t.type]
		var p: Vector3 = t.position
		var half: Array = ty.half_size_m
		obstacles.add_box(
			p.x,
			p.z,
			float(half[0]),
			float(half[1]),
			-float(t.yaw),
			p.y - 0.5,
			p.y + float(ty.height_m),
			"tent"
		)
	print(
		(
			"WorldObjects: палаток у старта %d из %d за %.0f мс"
			% [camp.size(), count, (Time.get_ticks_usec() - t0) / 1000.0]
		)
	)


## Костёр у лагеря (Campfire, configs/world_objects.json → campfire).
func _place_campfire(start: Vector3, heading_deg: float, tc: Dictionary, env: Dictionary) -> void:
	var fc: Dictionary = cfg.get("campfire", {})
	if fc.is_empty() or not bool(fc.get("enabled", true)):
		return
	var pos := Campfire.plan(camp, start, heading_deg, fc, tc, env)
	if not pos.is_finite():
		print("WorldObjects: у лагеря нет места для костра")
		return
	campfire = Campfire.new()
	add_child(campfire)
	campfire.position = pos
	campfire.setup(fc)
	_update_campfire()


func _update_campfire() -> void:
	var pts := campfire.sample_points()
	campfire.update_wind(_air_at(pts[0]), _air_at(pts[1]))
	_since_fire = 0.0


## Окружение для TentCamp.plan: рельеф, запреты (лес/вода/застройка), линии (тропы, дороги,
## реки), точки (камни, кусты, здания).
func _camp_env(start: Vector3, tc: Dictionary, terrain: Node) -> Dictionary:
	var c := Vector2(start.x, start.z)
	var reach := float(tc.distance_m[1]) + 60.0
	var env := {"lines": [], "points": [], "zone": TentCamp.launch_zone(tc)}
	var tw := float(tc.get("track_margin_m", 4.0))
	for pts: PackedVector2Array in start_tracks:
		env.lines.append([pts, tw + float(cfg.start_tracks.get("width_m", 2.0)) * 0.5])
	if osm != null:
		for arr: Array in [osm.roads, osm.rivers]:
			for item: Dictionary in arr:
				# только отрезки рядом со стартом — дороги бывают на десятки километров
				var pts := OsmData.points(item.p)
				for i in pts.size() - 1:
					var seg := PackedVector2Array([pts[i], pts[i + 1]])
					if TentCamp.dist_to_polyline(c, seg) < reach:
						env.lines.append([seg, float(tc.get("road_margin_m", 8.0))])
		for b: Array in osm.buildings:
			var bp := Vector2(float(b[0]), float(b[1]))
			if bp.distance_to(c) < reach:
				env.points.append(Vector3(bp.x, bp.y, float(tc.get("building_margin_m", 15.0))))
	if terrain != null:
		env.height_fn = Callable(terrain, &"height_at")
		if terrain.has_method(&"surface_at") and terrain.has_method(&"forest_at"):
			env.blocked_fn = TentCamp.blocked_by_surface.bind(terrain)
		var min_size := float(tc.get("scatter_min_size_m", 0.6))
		var tiles := {}
		env.points_fn = func(pc: Vector2, pr: float) -> Array: return TentCamp.scatter_near(
			terrain, pc, pr, min_size, tiles
		)
	else:
		env.height_fn = _height_fn
	return env


## Расчищено ли место в текущей локации (дорога, застройка, посадка) — деревьев не ставить.
func is_clear_at(x: float, z: float) -> bool:
	if _clearings == null and location_id != "":
		_clearings = WorldClearings.build_for(location_id)
	return _clearings != null and _clearings.is_clear_at(x, z)


## Первое препятствие на пути a→b: {kind: building|tree, point} или {}.
func obstacle_hit(segment_start: Vector3, segment_end: Vector3) -> Dictionary:
	var best := {} if obstacles == null else obstacles.hit(segment_start, segment_end)
	if osm_layer != null and osm_layer.building_obstacles != null:
		var b := osm_layer.building_obstacles.hit(segment_start, segment_end)
		if (
			not b.is_empty()
			and (
				best.is_empty()
				or segment_start.distance_to(b.point) < segment_start.distance_to(best.point)
			)
		):
			best = b
	return best


## Посадочные площадки: [{id, name, position, axis_deg, length_m, width_m}].
func get_landing_sites() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for l in landing_sites:
		out.append(l.info())
	return out


func _physics_process(delta: float) -> void:
	if campfire != null:
		_since_fire += delta
		if _since_fire >= float(cfg.campfire.get("update_s", 0.3)):
			_update_campfire()
	if indicators.is_empty():
		return
	_since_active += delta
	if _since_active >= float(cfg.update_interval_s):
		_since_active = 0.0
		_pick_active()
	_since_update += delta
	if _since_update < _update_dt:
		return
	var dt := _since_update
	_since_update = 0.0
	for ind in _active:
		ind.update_wind(dt, _air_at(ind.pivot_position()))


## Анимировать только ветроуказатели ближе active_radius_m к камере (без камеры — все).
func _pick_active() -> void:
	_active.clear()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var r := float(cfg.windsock.active_radius_m)
	for ind in indicators:
		if cam == null or cam.global_position.distance_to(ind.global_position) <= r:
			_active.append(ind)


func _air_at(p: Vector3) -> Vector3:
	return _air_fn.call(p) if _air_fn.is_valid() else Vector3.ZERO


func _reset_indicators() -> void:
	for ind in indicators:
		ind.reset_wind(_air_at(ind.pivot_position()))
	_since_active = INF


func _add_indicator(kind: String, section: Dictionary, pos: Vector3, scale_k: float) -> void:
	var ind := WindIndicator.new()
	ind.name = "%s_%d" % [kind, indicators.size()]
	add_child(ind)
	ind.position = pos
	ind.setup(kind, section, scale_k)
	indicators.append(ind)


func _build_start(site: Dictionary, height_fn: Callable) -> void:
	var p: Vector3 = site.position
	var fwd := TerrainGeo.heading_vector(float(site.heading_deg))
	var right := fwd.cross(Vector3.UP)
	var ws: Dictionary = cfg.windsock
	var off: Array = ws.launch_offset
	_add_indicator(
		"windsock",
		ws,
		_on_ground(p + right * float(off[0]) + fwd * float(off[1]), height_fn),
		float(ws.mast_scale)
	)
	var st: Dictionary = cfg.streamers
	for o in st.offsets:
		_add_indicator(
			"streamer", st, _on_ground(p + right * float(o[0]) + fwd * float(o[1]), height_fn), 1.0
		)


func _build_landing(site: Dictionary, height_fn: Callable, latlon_fn: Callable) -> void:
	var ls := LandingSite.new()
	ls.name = "Landing_" + String(site.id)
	add_child(ls)
	var xz: Vector2 = latlon_fn.call(float(site.lat), float(site.lon))
	ls.setup(site, cfg.landing, xz, height_fn, obstacles)
	landing_sites.append(ls)
	var ws: Dictionary = cfg.windsock
	_add_indicator("windsock", ws, ls.windsock_position(), float(ws.landing_scale))


static func _on_ground(p: Vector3, height_fn: Callable) -> Vector3:
	return Vector3(p.x, float(height_fn.call(p.x, p.z)), p.z)


## Меши троп к стартам (StartTracks): "Tracks" — как "Roads", но узкая естественная грунтовая
## лента (вытоптанная трава, гуляющая ширина, мягкий рваный край) и короткой видимостью (near..far),
## мягко угасающей к дальней границе. Добавляется в дерево после планирования (start_tracks).
func _build_start_tracks(height_fn: Callable) -> void:
	var tc: Dictionary = cfg.start_tracks
	var tiles := StartTracks.build_meshes(start_tracks, tc, height_fn)
	if tiles.is_empty():
		return
	var root := Node3D.new()
	root.name = "Tracks"
	add_child(root)
	var mat := ShaderMaterial.new()
	mat.shader = OsmLayer.DRAPED_SHADER
	mat.set_shader_parameter(&"depth_pull", float(cfg.roads.depth_pull))
	mat.set_shader_parameter(&"depth_bias_m", float(tc.lift_m) * 2.0)
	mat.set_shader_parameter(&"edge_alpha_start", 0.25)
	mat.set_shader_parameter(&"edge_noise_m", float(tc.edge_noise_m))
	var far := float(tc.visibility_far_m)
	mat.set_shader_parameter(&"fade_start_m", maxf(far - float(tc.fade_far_m), 0.0))
	mat.set_shader_parameter(&"fade_end_m", far)
	for k in tiles:
		var t: Dictionary = tiles[k]
		var mi := MeshInstance3D.new()
		mi.mesh = t.mesh
		mi.material_override = mat
		mi.position = t.origin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_begin = float(tc.visibility_near_m)
		mi.visibility_range_end = WorldTiles.tile_range(float(tc.visibility_far_m), float(tc.tile_m))
		root.add_child(mi)
