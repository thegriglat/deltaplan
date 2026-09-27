extends TestCase
## Тропы к стартам (StartTracks):
## godot --headless --path . res://tests/run_tests.tscn -- --filter=world_objects

const LOCATION := "altai"

static var _terrain: Terrain
static var _osm: OsmData


func _altai() -> Terrain:
	if _terrain == null:
		_terrain = Terrain.new()
		_terrain.location_id = ""
		_terrain.load_location(LOCATION)
	return _terrain


func _cfg() -> Dictionary:
	return WorldObjects.load_config().start_tracks


func _osm_data() -> OsmData:
	if _osm == null:
		var t := _altai()
		_osm = OsmData.load_file("res://data/osm/altai.json", t.center_lat, t.center_lon)
	return _osm


func test_every_start_has_a_track() -> void:
	var t := _altai()
	var sites := t.get_start_sites()
	check(sites.size() > 0, "нет стартов")
	var tracks := StartTracks.plan(sites, _osm_data(), _cfg(), t.height_at)
	check(tracks.size() == sites.size(), "тропа на каждый старт")
	for i in tracks.size():
		var pts: PackedVector2Array = tracks[i]
		check(pts.size() >= 2, "тропа старта '%s' пуста" % sites[i].id)
		var p0: Vector3 = sites[i].position
		check(
			Vector2(p0.x, p0.z).distance_to(pts[0]) < 1.0,
			"тропа старта '%s' начинается не у площадки" % sites[i].id
		)


func test_slope_within_limit() -> void:
	var t := _altai()
	var cfg := _cfg()
	var limit := float(cfg.max_slope_deg)
	var tracks := StartTracks.plan(t.get_start_sites(), _osm_data(), cfg, t.height_at)
	for i in tracks.size():
		var pts: PackedVector2Array = tracks[i]
		if pts.size() < 2:
			continue
		var worst := StartTracks.max_slope_deg(pts, t.height_at)
		check(
			worst <= limit + 0.5,
			"уклон тропы старта %d — %.1f° (лимит %.1f°)" % [i, worst, limit]
		)


func test_track_not_in_water() -> void:
	var t := _altai()
	var osm := _osm_data()
	var cfg := _cfg()
	var tracks := StartTracks.plan(t.get_start_sites(), osm, cfg, t.height_at)
	var buf := float(cfg.water_buffer_m)
	for pts: PackedVector2Array in tracks:
		for p in pts:
			check(not StartTracks._in_water(p, osm, buf), "точка тропы в воде: %s" % p)


func test_osm_track_is_used_when_close() -> void:
	# Синтетический OSM-трек, конец которого рядом со стартом: должен использоваться как есть,
	# не генерироваться заново (быстрая проверка через фиктивный старт над треком).
	var osm := OsmData.new()
	osm.roads = [{"t": "track", "p": [0.0, 0.0, 0.0, 100.0, 0.0, 200.0]}]
	var height_fn := func(_x: float, _z: float) -> float: return 0.0
	var start := [{"position": Vector3(2.0, 0.0, 198.0)}]
	var cfg := _cfg()
	var tracks := StartTracks.plan(start, osm, cfg, height_fn)
	check(tracks.size() == 1, "одна тропа")
	var pts: PackedVector2Array = tracks[0]
	check(pts.size() >= 2, "тропа не пуста")
	check(pts[0].distance_to(Vector2(2.0, 198.0)) < 0.01, "тропа начинается точно у старта")
	# Дальний конец должен уводить к 0,0 (сторона с большей длиной трека), не назад в никуда.
	check(pts[pts.size() - 1].y < 198.0, "тропа идёт от старта вдоль трека к дороге")


func test_generated_without_osm_track() -> void:
	# Нет подходящего OSM (осм пуст) — процедурная тропа: спуск фиксированной длины.
	var height_fn := func(x: float, z: float) -> float: return -0.05 * z  # мягкий уклон на юг
	var start := [{"position": Vector3(0.0, 20.0, 0.0)}]
	var cfg := _cfg()
	var tracks := StartTracks.plan(start, null, cfg, height_fn)
	check(tracks.size() == 1, "одна тропа")
	var pts: PackedVector2Array = tracks[0]
	check(pts.size() >= 2, "процедурная тропа не пуста")
	var length := 0.0
	for i in pts.size() - 1:
		length += pts[i].distance_to(pts[i + 1])
	approx(length, float(cfg.no_destination_length_m), 5.0, "длина тропы без OSM")


func test_build_meshes_produces_geometry() -> void:
	var t := _altai()
	var cfg := _cfg()
	var tracks := StartTracks.plan(t.get_start_sites(), _osm_data(), cfg, t.height_at)
	var tiles := StartTracks.build_meshes(tracks, cfg, t.height_at)
	check(not tiles.is_empty(), "нет мешей троп")
	for k in tiles:
		var mesh: ArrayMesh = tiles[k].mesh
		check(mesh.get_surface_count() == 1, "меш тайла %s" % k)
