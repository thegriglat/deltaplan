class_name WorldObjects
extends Node3D
## Объекты мира по данным локации (docs/world_objects.md):
##   ветроуказатели на стартах и посадках + ленточки на стартах (VR-7) — анимация по ЛОКАЛЬНОМУ
##   ветру модели (air_velocity_at у вертлюга), посадочные площадки (VR-12), дороги, здания, ЛЭП
##   из OSM (VR-6, VR-9, VR-10). Параметры — configs/world_objects.json.
## Подключение: world_objects.setup(terrain, atmosphere) после загрузки рельефа.
## Столкновения для интегратора: wire_hit(a, b) -> bool, obstacle_hit(a, b) -> {kind, point}.

## Всё построено (после setup / build).
signal built

var cfg: Dictionary = {}
var location_id: String = ""
var obstacles: ObstacleIndex
var osm: OsmData
var osm_layer: OsmLayer
var landing_sites: Array[LandingSite] = []
var indicators: Array[WindIndicator] = []
## Время построения, с (NFR-2).
var build_time_s: float = 0.0

var _air_fn: Callable
var _clearings: WorldClearings
var _active: Array[WindIndicator] = []
var _since_update: float = 0.0
var _since_active: float = INF
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
	_update_dt = 1.0 / maxf(float(cfg.windsock.update_hz), 1.0)
	obstacles = ObstacleIndex.new()
	for s in start_sites:
		_build_start(s, height_fn)
	for site in WorldObjects.landing_specs(cfg.landing, loc_id, landings):
		_build_landing(site, height_fn, latlon_fn)
	var path := String(cfg.osm.data_path).replace("{id}", loc_id)
	if loc_id != "":
		osm = OsmData.load_file(path, center.x, center.y)
	if osm != null:
		osm_layer = OsmLayer.new()
		osm_layer.name = "Osm"
		add_child(osm_layer)
		osm_layer.build(osm, cfg, height_fn, obstacles)
		var centers: Array[Vector3] = []
		for l in landing_sites:
			centers.append(l.center)
		osm_layer.build_fences_near(osm.fences, centers, cfg.landing, height_fn, obstacles)
	_reset_indicators()
	build_time_s = (Time.get_ticks_usec() - t0) / 1.0e6
	print(
		(
			"WorldObjects: '%s' за %.2f с — ветроуказателей %d, посадок %d, OSM %s"
			% [
				loc_id,
				build_time_s,
				indicators.size(),
				landing_sites.size(),
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


## Расчищено ли место в текущей локации (дорога, ЛЭП, застройка, посадка) — деревьев не ставить.
func is_clear_at(x: float, z: float) -> bool:
	if _clearings == null and location_id != "":
		_clearings = WorldClearings.build_for(location_id)
	return _clearings != null and _clearings.is_clear_at(x, z)


## Путь a→b задел провод ЛЭП?
func wire_hit(segment_start: Vector3, segment_end: Vector3) -> bool:
	return obstacles != null and not obstacles.hit(segment_start, segment_end, "wire").is_empty()


## Первое препятствие на пути a→b: {kind: wire|tower|building|tree|fence, point} или {}.
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
