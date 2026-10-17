class_name WorldObjects
extends Node3D
## Объекты мира по данным локации (docs/guide/world-objects.md):
##   ветроуказатели на стартах и посадках + ленточки на стартах (VR-7) — анимация по ЛОКАЛЬНОМУ
##   ветру модели (air_velocity_at у вертлюга), посадочные площадки (VR-12), тропы к стартам,
##   лагерь. Параметры — configs/world_objects.json.
## Подключение: world_objects.setup(terrain, atmosphere) после загрузки рельефа.
## Столкновения для интегратора: obstacle_hit(a, b) -> {kind, point}.

const DRAPED_SHADER := preload("res://scripts/world_objects/draped.gdshader")

## Всё построено (после setup / build).
signal built

var cfg: Dictionary = {}
var location_id: String = ""
var obstacles: ObstacleIndex
## Данные OSM места (тайлы osm-tiles, O9) и каркас слоя; osm не null после build() (пустой — нет тайлов).
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
## Дома посёлков (VillagePlacer, N3): [x, z, w, l, угол_град, высота_стен_м, крыша].
var houses: Array = []
var village_layer: VillageLayer
## Снаряжение у стартов (StartGear.plan): по старту локации (порядок start_sites) свой список вещей.
var start_gear: Array = []
## Время плана снаряжения на один старт, мс (последняя сборка; отчёт SC-2).
var start_gear_plan_ms: Array[float] = []
## Суда на море (ShipPlacer, S3): записи последней расстановки; слой — после счёта в рабочем потоке.
var ships: Array[Dictionary] = []
var ship_layer: ShipLayer
## Суда готовы (слой построен или моря нет).
signal ships_ready


var _air_fn: Callable
var _gear_terrain: Node = null
var _height_fn: Callable
## Высота для рабочих потоков (PlaceData.height_at) или height_fn, если расчёт на главном потоке.
var _work_fn: Callable
var _threaded := false
var _building := false
## Номер сборки: clear/новый build обрывает build_async прежнего.
var _gen := 0
var _t0 := 0
var _osm_done := false
var _village_task := -1
var _village_res: Dictionary = {}
var _village_steps: Array[Callable] = []
var _vi := 0
var _clearings: WorldClearings
## Общие данные места (FL-К2): OSM и план домов берутся отсюда, не читаются заново; null — читать самим.
var _place: PlaceData
var _active: Array[WindIndicator] = []
var _since_update: float = 0.0
var _since_active: float = INF
var _since_fire: float = INF
var _since_osm_wind: float = INF
var _update_dt: float = 1.0 / 30.0
## Счёт маски моря и судов в WorkerThreadPool: id задачи (-1 — нет), поколение сборки (старый итог — в мусор).
var _ship_task: int = -1
var _ship_gen: int = 0


## Главный вход: зависимости передаются явно. atmosphere может быть null (ветроуказатели — штиль).
func setup(terrain: Node, atmosphere: Node) -> void:
	var a := _setup_args(terrain, atmosphere)
	_gear_terrain = terrain
	build(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8])
	_gear_terrain = null


## То же порциями (FL-6): расчёт OSM и домов — в рабочих потоках, узлы — не дольше budget_ms за кадр
## (await process_frame между порциями). Узел должен быть в дереве.
func setup_async(terrain: Node, atmosphere: Node, budget_ms: float = 50.0) -> void:
	var a := _setup_args(terrain, atmosphere)
	_gear_terrain = terrain
	if await build_async(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], budget_ms):
		_gear_terrain = null


func _setup_args(terrain: Node, atmosphere: Node) -> Array:
	var air := Callable()
	if atmosphere != null:
		air = Callable(atmosphere, &"air_velocity_at")
	var landings: Array = []
	if terrain.has_method(&"get_landing_sites"):
		landings = terrain.call(&"get_landing_sites")
	var patches: BuiltPatches = null
	var place: PlaceData = null
	if terrain is Terrain:
		place = PlaceData.for_terrain(terrain)
		patches = place.patches
	return [
		String(terrain.get(&"location_id")),
		terrain.call(&"get_start_sites"),
		landings,
		Callable(terrain, &"height_at"),
		air,
		Callable(terrain, &"latlon_to_local"),
		Vector2(float(terrain.get(&"center_lat")), float(terrain.get(&"center_lon"))),
		patches,
		place,
	]


## То же без нод (тесты, другие источники рельефа).
## start_sites — как Terrain.get_start_sites(); landings — как Terrain.get_landing_sites()
## ({id, name, lat, lon}; подробности поля — configs/world_objects.json → landing.sites по id);
## latlon_fn(lat, lon) -> Vector2(x, z); center — (lat, lon).
## patches — пятна застройки места (BuiltPatches) для домов; null — берутся из данных локации по id.
## place — общие данные места (PlaceData, FL-К2): OSM и план домов из него; null — OSM и план считаются здесь.
## С place расчёт слоя OSM и домов посёлков идёт в рабочих потоках по place.height_at (FL-6), без него — на
## главном потоке по height_fn (её объект может быть узлом сцены).
func build(
	loc_id: String,
	start_sites: Array,
	landings: Array,
	height_fn: Callable,
	air_fn: Callable,
	latlon_fn: Callable,
	center: Vector2,
	patches: BuiltPatches = null,
	place: PlaceData = null
) -> void:
	_begin(loc_id, start_sites, landings, height_fn, air_fn, latlon_fn, center, patches, place)
	_wait_jobs()
	_advance(1 << 62)
	_end(start_sites)


## build порциями (FL-6): между порциями сборки узлов (не дольше budget_ms) — await process_frame, пока
## рабочие потоки считают — тоже. Новый build/clear во время сборки обрывает эту (тогда false).
func build_async(
	loc_id: String,
	start_sites: Array,
	landings: Array,
	height_fn: Callable,
	air_fn: Callable,
	latlon_fn: Callable,
	center: Vector2,
	patches: BuiltPatches = null,
	place: PlaceData = null,
	budget_ms: float = 50.0
) -> bool:
	_begin(loc_id, start_sites, landings, height_fn, air_fn, latlon_fn, center, patches, place)
	var gen := _gen
	var tree := get_tree()
	while not _advance(int(budget_ms * 1000.0)):
		await tree.process_frame
		if gen != _gen:
			return false  # место сменилось — эту сборку бросили
	_end(start_sites)
	return true


## Сборка идёт (build_async не закончил).
func is_building() -> bool:
	return _building


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_wait_villages()  # поток держит план и конфиг
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		_wait_ships()


## Начало: всё лёгкое — на главном потоке; OSM и дома посёлков — запуск расчёта в рабочих потоках.
func _begin(
	loc_id: String,
	start_sites: Array,
	landings: Array,
	height_fn: Callable,
	air_fn: Callable,
	latlon_fn: Callable,
	center: Vector2,
	patches: BuiltPatches,
	place: PlaceData
) -> void:
	_t0 = Time.get_ticks_usec()
	clear()
	_building = true
	_clearings = null
	_place = place if place != null and place.location_id == loc_id else null
	location_id = loc_id
	cfg = WorldObjects.load_config()
	_air_fn = air_fn
	_height_fn = height_fn
	_threaded = _place != null
	# в рабочих потоках — только потокобезопасная высота из общих данных места (FL-К2)
	_work_fn = _place.height_at if _threaded else height_fn
	_update_dt = 1.0 / maxf(float(cfg.windsock.update_hz), 1.0)
	obstacles = ObstacleIndex.new()
	for s in start_sites:
		_build_start(s, height_fn)
	for site in WorldObjects.landing_specs(cfg.landing, loc_id, landings):
		_build_landing(site, height_fn, latlon_fn)
	_start_osm(loc_id, center)
	_start_villages(patches, height_fn)
	_start_ships(loc_id, center, height_fn)
	if bool(cfg.start_tracks.get("enabled", true)):
		start_tracks = StartTracks.plan(start_sites, cfg.start_tracks, height_fn)
		_build_start_tracks(height_fn)


## Дождаться рабочих потоков (сборка без кадров).
func _wait_jobs() -> void:
	if osm_layer != null:
		osm_layer.finish()
	_wait_villages()


## Порция сборки узлов на главном потоке; true — OSM и посёлки собраны.
func _advance(budget_us: int) -> bool:
	var t := Time.get_ticks_usec()
	if osm_layer != null and not _osm_done:
		if not osm_layer.step(budget_us):
			return false
		_osm_done = true
		_finish_osm()
	if not _village_steps.is_empty() or _village_task >= 0 or not _village_res.is_empty():
		if _village_task >= 0:
			if not WorkerThreadPool.is_task_completed(_village_task):
				return false
			_wait_villages()
		if not _village_res.is_empty():
			_assemble_villages()
		while _vi < _village_steps.size():
			if Time.get_ticks_usec() - t >= budget_us:
				return false
			(_village_steps[_vi] as Callable).call()
			_vi += 1
		_village_steps = []
		_vi = 0
	return true


## Конец: снаряжение у стартов, ветроуказатели, итог.
func _end(start_sites: Array) -> void:
	_build_start_gear(start_sites)
	_reset_indicators()
	_building = false
	build_time_s = (Time.get_ticks_usec() - _t0) / 1.0e6
	print(
		(
			"WorldObjects: '%s' за %.2f с — ветроуказателей %d, посадок %d, троп к стартам %d, домов %d, OSM %s"
			% [
				location_id,
				build_time_s,
				indicators.size(),
				landing_sites.size(),
				start_tracks.size(),
				houses.size(),
				"тайлов %d/%d" % [osm.tiles_ok, osm.tiles_ok + osm.tiles_missing] if osm != null else "нет"
			]
		)
	)
	built.emit()


func clear() -> void:
	_gen += 1
	_building = false
	_wait_villages()
	_village_res = {}
	_village_steps = []
	_vi = 0
	_osm_done = false
	for c in get_children():
		c.queue_free()
	indicators.clear()
	landing_sites.clear()
	start_tracks.clear()
	houses = []
	start_gear = []
	start_gear_plan_ms.clear()
	village_layer = null
	osm_layer = null
	osm = null
	camp.clear()
	campfire = null
	_active.clear()
	ships = []
	ship_layer = null
	_ship_gen += 1


## Суда (S3): маска моря места (SeaMask.load_for — файл или счёт 1–3 с) и расстановка — в рабочем потоке,
## узлы — в главном (_ships_done). Нет моря — ни одного узла.
func _start_ships(loc_id: String, center: Vector2, height_fn: Callable) -> void:
	if loc_id == "":
		return
	var lc: Dictionary = Locations.config(loc_id)
	var clat := float(lc.get("center_lat", center.x))
	var clon := float(lc.get("center_lon", center.y))
	var dir := Locations.data_dir(loc_id)
	var params := ShipPlacer.params_from_config()
	var gen := _ship_gen
	_wait_ships()
	_ship_task = WorkerThreadPool.add_task(func() -> void:
		var res := ShipPlacer.ships_for(SeaMask.load_for(dir), clat, clon, params, height_fn)
		call_deferred(&"_ships_done", res, gen)
	, false, "sea ships")


func _ships_done(res: Array[Dictionary], gen: int) -> void:
	_wait_ships()
	if gen != _ship_gen:
		return
	ships = res
	if not ships.is_empty():
		ship_layer = ShipLayer.new()
		ship_layer.name = "Ships"
		add_child(ship_layer)
		ship_layer.build(ships)
		print("WorldObjects: судов %d (без модели %d)" % [ship_layer.ship_count, ship_layer.skipped])
	ships_ready.emit()


func _wait_ships() -> void:
	if _ship_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_ship_task)
		_ship_task = -1


## Данные OSM места (osm_tiles.json в папке места + кеш тайлов) → OsmData и каркас OsmLayer (расчёт запущен,
## сборка — _advance). Нет тайлов — пустой OsmData, слой не создаётся.
func _start_osm(loc_id: String, center: Vector2) -> void:
	var ocfg: Dictionary = Config.get_config("osm_tiles")
	osm = OsmData.new()
	if _place != null:
		osm = _place.osm  # прочитан один раз за загрузку (FL-К2)
	elif loc_id == "" or not bool(ocfg.get("enabled", true)):
		return
	else:
		_load_osm(loc_id, center, ocfg)
	if osm.is_empty():
		return
	osm_layer = OsmLayer.new()
	osm_layer.name = "Osm"
	add_child(osm_layer)
	var forest_fn := Callable()
	if _gear_terrain != null and _gear_terrain.has_method(&"forest_at"):
		forest_fn = Callable(_gear_terrain, &"forest_at")
	osm_layer.start(osm, cfg, _work_fn, obstacles, forest_fn, _threaded)


## Слой OSM собран: город — деревья-модели на местах крон, рельеф кроны на земле там не рисует.
func _finish_osm() -> void:
	var ct := osm_layer.get_node_or_null("CityTrees") as CityTrees
	if _gear_terrain != null and _gear_terrain.has_method(&"set_city_canopy_on"):
		_gear_terrain.call(&"set_city_canopy_on", false)   # прежнее место могло оставить маску
	if ct != null and _gear_terrain != null and _gear_terrain.has_method(&"set_city_canopy"):
		ct.city_mask_ready.connect(Callable(_gear_terrain, &"set_city_canopy"))
		ct.shown_changed.connect(Callable(_gear_terrain, &"set_city_canopy_on"))


## OSM места без PlaceData (build без общих данных): центр — в double из конфига локации
## (Vector2 — float32, сдвиг объектов до ~0,5 м).
func _load_osm(loc_id: String, center: Vector2, ocfg: Dictionary) -> void:
	var lc: Dictionary = Locations.config(loc_id)
	var clat := float(lc.get("center_lat", center.x))
	var clon := float(lc.get("center_lon", center.y))
	osm = OsmData.load_for(
		Locations.data_dir(loc_id), clat, clon, float(ocfg.get("half_m", 20000.0)), Locations.osm_root(loc_id)
	)


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
## null) — лес, вода, застройка, камни и кусты; без него — только уклон и тропы.
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


## Снаряжение у каждого старта локации (StartGear, configs/world_objects.json → start_gear): набор
## постоянный (не от погоды и игрока), узел StartGear_<i>, препятствия «gear» (крылья, аппарат,
## чехлы — коробки). Окружение запретов — как у палаток (_camp_env); после троп и посёлков.
func _build_start_gear(start_sites: Array) -> void:
	var gc: Dictionary = cfg.get("start_gear", {})
	if gc.is_empty() or not bool(gc.get("enabled", true)):
		return
	var t0 := Time.get_ticks_usec()
	var total := 0
	for i in start_sites.size():
		var site: Dictionary = start_sites[i]
		var sp: Vector3 = site.position
		var env := _camp_env(sp, cfg.get("tents", {}), _gear_terrain)
		var t1 := Time.get_ticks_usec()
		var items := StartGear.plan(sp, float(site.heading_deg), gc, env)
		start_gear_plan_ms.append((Time.get_ticks_usec() - t1) / 1000.0)
		start_gear.append(items)
		if items.is_empty():
			continue
		total += items.size()
		var node := StartGear.build_node(items, gc)
		node.name = "StartGear_%d" % i
		add_child(node)
		for it: Dictionary in items:
			var box: Vector3 = it.box
			if box == Vector3.ZERO:
				continue
			var c: Vector3 = it.center
			obstacles.add_box(
				c.x, c.z, box.x, box.y, -float(it.yaw), c.y - 0.5, c.y + box.z, "gear"
			)
	print(
		(
			"WorldObjects: снаряжение у %d стартов — %d вещей за %.0f мс"
			% [start_sites.size(), total, (Time.get_ticks_usec() - t0) / 1000.0]
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


## Дома посёлков по пятнам застройки (VillageLayer) — отрисовка, препятствия: план и запуск расчёта
## (BuildingPlacer.place — в рабочем потоке при общих данных места), узлы — _advance.
func _start_villages(patches: BuiltPatches, height_fn: Callable) -> void:
	var bc: Dictionary = cfg.buildings
	if not bool(bc.get("enabled", true)):
		return
	if _place != null:
		houses = _place.house_plan  # тот же план, по которому вырублена маска просек (FL-К2)
	else:
		if patches == null:
			patches = WorldClearings.patches_for_location(location_id)
		houses = VillagePlacer.plan(
			patches, location_id, cfg.villages, height_fn, osm.buildings if osm != null else []
		)
	if houses.is_empty():
		return
	var res := {}
	_village_res = res
	var h := houses
	var c := cfg
	var fn := _work_fn
	var job := func() -> void: res.merge(VillageLayer.prepare(h, c, fn))
	if _threaded:
		_village_task = WorkerThreadPool.add_task(job, false, "village houses")
	else:
		job.call()


func _wait_villages() -> void:
	if _village_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_village_task)
		_village_task = -1


## Расчёт домов готов: слой, препятствия, шаги узлов (по тайлу) и сады.
func _assemble_villages() -> void:
	var res := _village_res
	_village_res = {}
	village_layer = VillageLayer.new()
	village_layer.name = "Villages"
	add_child(village_layer)
	_village_steps = village_layer.assemble(res, cfg)
	_vi = 0
	var vl := village_layer
	var h := houses
	var c := cfg
	var fn := _height_fn
	_village_steps.append(func() -> void:
		var gardens := CityTrees.build_gardens(h, c, fn)
		if gardens != null:
			gardens.name = "Gardens"
			vl.add_child(gardens))


## Окружение для TentCamp.plan: рельеф, запреты (лес/вода/застройка), линии (тропы), точки (камни, кусты).
func _camp_env(start: Vector3, tc: Dictionary, terrain: Node) -> Dictionary:
	var env := {"lines": [], "points": []}
	var tw := float(tc.get("track_margin_m", 4.0))
	for pts: PackedVector2Array in start_tracks:
		env.lines.append([pts, tw + float(cfg.start_tracks.get("width_m", 2.0)) * 0.5])
	if osm != null:
		# дороги, реки, ж/д OSM (OT-9): только отрезки рядом со стартом — они бывают на десятки километров
		var c := Vector2(start.x, start.z)
		var reach := float(tc.distance_m[1]) + 60.0
		var rm := float(tc.get("road_margin_m", 8.0))
		for arr: Array in [osm.roads, osm.rivers, osm.rail]:
			for item: Dictionary in arr:
				if bool(item.get("tunnel", false)):
					continue
				var pts: PackedVector2Array = item.p
				for i in pts.size() - 1:
					var seg := PackedVector2Array([pts[i], pts[i + 1]])
					if TentCamp.dist_to_polyline(c, seg) < reach:
						env.lines.append([seg, rm])
	var bm := float(tc.get("building_margin_m", 15.0))
	var reach := float(tc.distance_m[1]) + 60.0
	for b: Array in houses:
		if Vector2(float(b[0]) - start.x, float(b[1]) - start.z).length() < reach:
			env.points.append(Vector3(float(b[0]), float(b[1]), bm))
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


## Расчищено ли место в текущей локации (застройка, посадка) — деревьев не ставить.
func is_clear_at(x: float, z: float) -> bool:
	if _clearings == null and location_id != "":
		_clearings = (
			WorldClearings.build_from(_place) if _place != null else WorldClearings.build_for(location_id)
		)
	return _clearings != null and _clearings.is_clear_at(x, z)


## Первое препятствие на пути a→b: {kind: building|tree, point} или {}.
func obstacle_hit(segment_start: Vector3, segment_end: Vector3) -> Dictionary:
	var best := {} if obstacles == null else obstacles.hit(segment_start, segment_end)
	if osm_layer != null and osm_layer.building_obstacles != null:
		var ob := osm_layer.building_obstacles.hit(segment_start, segment_end)
		if (
			not ob.is_empty()
			and (
				best.is_empty()
				or segment_start.distance_to(ob.point) < segment_start.distance_to(best.point)
			)
		):
			best = ob
	if village_layer != null and village_layer.building_obstacles != null:
		var b := village_layer.building_obstacles.hit(segment_start, segment_end)
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
	_update_osm_wind(delta)
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


## L4: ветер слоя OSM (и дым процедурных посёлков) раз в osm_wind.update_s: OsmLayer.update_wind(air_fn, cam).
func _update_osm_wind(delta: float) -> void:
	if osm_layer == null and village_layer == null:
		return
	_since_osm_wind += delta
	if _since_osm_wind < float(cfg.get("osm_wind", {}).get("update_s", 0.5)):
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	_since_osm_wind = 0.0
	var air := Callable(self, &"_air_at")
	if osm_layer != null:
		osm_layer.update_wind(air, cam.global_position)
	if village_layer != null:
		OsmLayer.feed_wind(village_layer, air, cam.global_position)


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


## Меши троп к стартам (StartTracks): "Tracks" — узкая естественная грунтовая
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
	mat.shader = DRAPED_SHADER
	mat.set_shader_parameter(&"depth_pull", float(tc.depth_pull))
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


## Маска примятой травы вокруг старта (SC-K6, TrampleMask): {image: Image R8, origin: Vector2, cell_m},
## пустой словарь — выключена в конфиге. Палатки (camp), пятна вещей SC-K2 (start_gear этого старта,
## если есть) и тропа StartTracks. Вызывать после place_camp; передаётся GrassField.set_trample_mask.
func trample_mask(start: Vector3, size_m: float = 256.0, cell_m: float = 0.5) -> Dictionary:
	var tc: Dictionary = cfg.get("trample", {})
	if not bool(tc.get("enabled", true)):
		return {}
	tc = tc.duplicate()
	tc["size_m"] = size_m
	tc["cell_m"] = cell_m
	var gear: Array = []
	var all_gear = get("start_gear")
	if all_gear is Array:
		for g in all_gear:
			if g is Array and not g.is_empty():
				var p: Vector3 = g[0].position
				if Vector2(p.x, p.z).distance_to(Vector2(start.x, start.z)) < 60.0:
					gear.append_array(g)
	return TrampleMask.build(start, camp, gear, start_tracks, cfg.get("tents", {}), tc)
