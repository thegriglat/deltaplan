extends TestCase
## Объекты мира: godot --headless --path . res://tests/run_tests.tscn -- --filter=world_objects

const LOCATION := "altai"
const OSM_PATH := "res://data/terrain/altai/osm.json"

static var _terrain: Terrain
static var _world: WorldObjects


func _altai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location(LOCATION)
	return _terrain


## Мир Алтая с постоянным ветром с запада 5 м/с (одна сборка на все тесты).
func _built_world() -> WorldObjects:
	if _world == null:
		var t := _altai()
		_world = WorldObjects.new()
		var air := func(_p: Vector3) -> Vector3: return Vector3(5.0, 0.0, 0.0)
		_world.build(
			LOCATION,
			t.get_start_sites(),
			t.get_landing_sites(),
			t.height_at,
			air,
			t.latlon_to_local,
			Vector2(t.center_lat, t.center_lon)
		)
	return _world


static func _cloth_cfg() -> Dictionary:
	return WorldObjects.load_config().windsock


func test_osm_data_loads() -> void:
	var d := OsmData.load_file(OSM_PATH)
	check(d != null, "нет " + OSM_PATH)
	if d == null:
		return
	check(d.attribution.contains("OpenStreetMap"), "атрибуция ODbL")
	check(d.roads.size() > 1000, "дорог %d" % d.roads.size())
	check(d.buildings.size() > 10000, "зданий %d" % d.buildings.size())
	check(d.places.size() > 5, "населённых пунктов %d" % d.places.size())
	var p := OsmData.points(d.roads[0].p)
	check(absf(p[0].x) < 21000.0 and absf(p[0].y) < 21000.0, "координаты в зоне локации")
	check(d.load_time_s < 2.0, "загрузка %.2f с" % d.load_time_s)


func test_all_locations_osm_valid() -> void:
	var n := 0
	for f in Locations.builtin_ids():
		var o := OsmData.load_file(Locations.osm_path(f))
		check(o != null and o.attribution.contains("OpenStreetMap"), f + ": атрибуция")
		check(o != null and o.roads.size() > 100 and o.buildings.size() > 100, f + ": данные")
		n += 1
	check(n >= 3, "локаций с OSM: %d" % n)


func test_reprojection_keeps_latlon() -> void:
	# Тот же файл при сдвинутом центре: точка сдвигается на разницу центров.
	var a := OsmData.load_file(OSM_PATH)
	var b := OsmData.load_file(OSM_PATH, 51.87 + 0.01, 85.87)
	var pa := OsmData.points(a.roads[0].p)[0]
	var pb := OsmData.points(b.roads[0].p)[0]
	approx(pb.y - pa.y, TerrainGeo.meters_per_deg_lat() * 0.01, 1.0, "сдвиг по z")
	approx(pb.x, pa.x, 1.0, "x без изменений")


func test_windsock_turns_to_wind() -> void:
	var m := WindClothModel.new(_cloth_cfg())
	m.reset(Vector3(0.0, 0.0, -5.0))  # дует на север
	approx(_heading(m), 0.0, 1.0, "сразу по ветру")
	for i in 300:
		m.step(1.0 / 30.0, Vector3(5.0, 0.0, 0.0))  # ветер с запада — конус на восток
	approx(_heading(m), 90.0, 5.0, "повернулся на восток")
	for i in 300:
		m.step(1.0 / 30.0, Vector3(0.0, 0.0, 4.0))  # ветер с севера — конус на юг
	approx(_heading(m), 180.0, 5.0, "повернулся на юг")


func test_windsock_droops_in_light_wind() -> void:
	var m := WindClothModel.new(_cloth_cfg())
	approx(m.fill_for_speed(0.5), 0.0, 1.0e-6, "штиль — висит")
	approx(m.fill_for_speed(Units.kmh(28.0)), 1.0, 1.0e-6, "28 км/ч — горизонтально")
	var prev := -1.0
	for v in range(0, 12):
		var f := m.fill_for_speed(float(v))
		check(f >= prev, "наполнение растёт со скоростью")
		prev = f
	m.reset(Vector3(8.0, 0.0, 0.0))
	for i in 150:
		m.step(1.0 / 30.0, Vector3(1.0, 0.0, 0.0))
	check(m.fill < 0.1, "ветер стих — конус обвис (%.2f)" % m.fill)


func test_gusts_make_flutter() -> void:
	var calm := WindClothModel.new(_cloth_cfg())
	var gusty := WindClothModel.new(_cloth_cfg())
	for i in 300:
		var t := i / 30.0
		calm.step(1.0 / 30.0, Vector3(5.0, 0.0, 0.0))
		gusty.step(1.0 / 30.0, Vector3(5.0 + 2.5 * sin(t * 2.3) * sin(t * 0.7), 0.0, sin(t)))
	check(
		gusty.flutter_amp > calm.flutter_amp * 1.5,
		"порывы: болтание %.3f > ровный %.3f" % [gusty.flutter_amp, calm.flutter_amp]
	)
	check(gusty.gust_sigma_ms > 0.5, "СКО порывов %.2f" % gusty.gust_sigma_ms)


func test_updraft_tilts_sock_up() -> void:
	var m := WindClothModel.new(_cloth_cfg())
	for i in 150:
		m.step(1.0 / 30.0, Vector3(6.0, 2.0, 0.0))
	check(m.pitch > 0.1, "в восходящем потоке конус приподнят (%.2f рад)" % m.pitch)


func test_indicator_node_follows_local_wind() -> void:
	var w := _built_world()
	check(w.indicators.size() >= 5, "ветроуказатели на стартах и посадке: %d" % w.indicators.size())
	var ind := w.indicators[0]
	for i in 60:
		ind.update_wind(1.0 / 30.0, Vector3(0.0, 0.0, 6.0))  # ветер с севера
	var fwd := -ind.pivot.basis.z
	check(fwd.z > 0.95, "Pivot смотрит на юг, по ветру: %s" % fwd)


func test_objects_on_ground() -> void:
	var w := _built_world()
	var t := _altai()
	for ind in w.indicators:
		var p := ind.position  # WorldObjects в начале координат
		approx(p.y, t.height_at(p.x, p.z), 0.05, "%s на земле" % ind.name)
	var d := OsmData.load_file(OSM_PATH)
	var bcfg: Dictionary = WorldObjects.load_config().buildings
	var tiles := BuildingPlacer.place(d.buildings.slice(0, 500), bcfg, t.height_at)
	var n := 0
	for k in tiles:
		for xf: Transform3D in tiles[k].walls:
			var g := t.height_at(xf.origin.x, xf.origin.z)
			var bottom := xf.origin.y - xf.basis.get_scale().y * 0.5
			check(bottom <= g + 0.01, "стены от земли (дно %.1f, земля %.1f)" % [bottom, g])
			check(bottom > g - 30.0, "стены не уходят глубоко")
			n += 1
	check(n == 500, "здания размещены: %d" % n)


func test_landing_site() -> void:
	var w := _built_world()
	check(w.landing_sites.size() == 1, "посадка Алтая")
	var info: Dictionary = w.get_landing_sites()[0]
	var t := _altai()
	var ls := w.landing_sites[0]
	var hmin := INF
	var hmax := -INF
	for a in [-0.5, 0.0, 0.5]:
		for b in [-0.5, 0.0, 0.5]:
			var p: Vector3 = info.position + ls.axis * a * ls.length_m + ls.right * b * ls.width_m
			var h := t.height_at(p.x, p.z)
			hmin = minf(hmin, h)
			hmax = maxf(hmax, h)
	check(hmax - hmin < 15.0, "поле ровное: перепад %.1f м" % (hmax - hmin))
	var sock := ls.windsock_position()
	check(sock.distance_to(info.position) < ls.length_m, "ветроуказатель у поля")
	# Лесополоса — препятствие: путь сквозь линию деревьев где-то задевает дерево.
	var hits := 0
	for s in range(-10, 11):
		var base: Vector3 = info.position + ls.axis * s * 15.0
		var a2 := base + Vector3.UP * 8.0
		var b2 := a2 + ls.right * ls.width_m * 1.5
		var c2 := a2 - ls.right * ls.width_m * 1.5 - ls.axis * ls.length_m
		for seg in [[a2, b2], [a2, c2]]:
			var r: Dictionary = w.obstacle_hit(seg[0], seg[1])
			if not r.is_empty() and r.kind == "tree":
				hits += 1
	check(hits > 0, "деревья вокруг поля — препятствия")


func test_landing_specs_merge_terrain_sites() -> void:
	var lcfg: Dictionary = WorldObjects.load_config().landing
	var terrain_sites := [
		{"id": "manzherok_katun", "name": "x", "lat": 1.0, "lon": 2.0},
		{"id": "other", "name": "Другое поле", "lat": 51.9, "lon": 85.9},
	]
	var specs := WorldObjects.landing_specs(lcfg, LOCATION, terrain_sites)
	check(specs.size() == 2, "своя + площадка рельефа: %d" % specs.size())
	check(float(specs[0].lat) > 50.0, "своя запись с lat/lon главнее")
	check(specs[1].id == "other" and specs[1].has("length_m"), "умолчания для площадки рельефа")


func test_obstacle_capsule() -> void:
	var a := Vector3(0.0, 14.0, 0.0)
	var b := Vector3(200.0, 14.0, 0.0)
	var idx := ObstacleIndex.new()
	idx.add_capsule(a, b, 0.4, "capsule")
	check(not idx.hit(Vector3(100, 14.2, -1), Vector3(100, 14.2, 1)).is_empty(), "сквозь капсулу")
	check(idx.hit(Vector3(100, 17.0, -1), Vector3(100, 17.0, 1)).is_empty(), "выше")
	check(idx.hit(Vector3(100, 11.0, -1), Vector3(100, 11.0, 1)).is_empty(), "ниже")


func test_build_time() -> void:
	var w := _built_world()
	check(
		w.build_time_s < 6.0, "сборка объектов %.2f с (NFR-2: вся загрузка ≤ 10 с)" % w.build_time_s
	)
	check(w.osm_layer.stats.get("buildings", 0) > 10000, "здания в MultiMesh")


static func _heading(m: WindClothModel) -> float:
	var p := m.pointing()
	return fposmod(rad_to_deg(atan2(p.x, -p.z)), 360.0)


func test_clearings_mask() -> void:
	var c := WorldClearings.build_for(LOCATION)
	check(c != null and c.image != null, "маска построена")
	if c == null:
		return
	check(c.build_time_s < 3.0, "маска за %.2f с" % c.build_time_s)
	var d := OsmData.load_file(OSM_PATH)
	var road := OsmData.points(d.roads[0].p)
	check(c.is_clear_at(road[0].x, road[0].y), "на дороге деревьев нет")
	var b: Array = d.buildings[0]
	check(c.is_clear_at(float(b[0]), float(b[1])), "на здании деревьев нет")
	var t := _altai()
	var land := t.latlon_to_local(51.83476, 85.81696)
	check(c.is_clear_at(land.x, land.y), "поле посадки")
	check(not c.is_clear_at(30000.0, 0.0), "за краем маски — не расчищено")
	var img := WorldObjects.clearing_mask_for(LOCATION)
	var frac := 0.0
	for k in 2000:
		var x := (k * 7919) % img.get_width()
		var y := (k * 104729) % img.get_height()
		frac += img.get_pixel(x, y).r
	check(frac / 2000.0 < 0.3, "расчищено меньше 30 %% площади (%.2f)" % (frac / 2000.0))


func test_zz_cleanup() -> void:
	if _world != null:
		_world.free()
		_world = null
	if _terrain != null:
		_terrain.free()
		_terrain = null
