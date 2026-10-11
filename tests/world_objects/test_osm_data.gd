extends TestCase
## OsmData (O9): тайл → мир места (проекция O1 → TerrainGeo), окно ±half_m, клип линий, угол и высота дома,
## имена вершин, load_for по osm_tiles.json и кешу, время разбора. Без сети.

const SAMPLE := "res://tests/contracts/osm_tiles/sample_v1.dpt"


func _tile() -> Dictionary:
	return OsmTileReader.read(FileAccess.get_file_as_bytes(SAMPLE))


## Центр места — середина тайла sample (j=252, i=755).
func _center() -> Vector2:
	var o := OsmGrid.origin_d(252, 755)
	return Vector2(o[0] + 0.5 * OsmGrid.DLAT, o[1] + 0.5 * OsmGrid.dlon(252))


func test_projection_matches_terrain_geo() -> void:
	var c := _center()
	var d := OsmData.from_tiles([_tile()], c.x, c.y, 30000.0)
	var o := OsmGrid.origin_d(252, 755)
	# первая башня: тайл (5000, 15200)
	var want_ll := Vector2(o[0] + 15200.0 / OsmGrid.m_per_deg(), o[1] + 5000.0 / OsmGrid.kx(252))
	var want := TerrainGeo.latlon_to_local(want_ll.x, want_ll.y, c.x, c.y)
	var found := false
	for q in d.towers:
		if q.distance_to(want) < 0.6:  # Vector2 — float32
			found = true
	check(found, "башня на месте по TerrainGeo: %s" % str(d.towers))
	check(d.attribution == "© OpenStreetMap contributors", "атрибуция при наличии объектов")


func test_window_and_clip() -> void:
	var c := _center()
	var big := OsmData.from_tiles([_tile()], c.x, c.y, 30000.0)
	var small := OsmData.from_tiles([_tile()], c.x, c.y, 2000.0)
	check(big.roads.size() >= 3, "дороги в большом окне: %d" % big.roads.size())
	check(small.roads.size() < big.roads.size() or small.roads.is_empty(), "малое окно режет")
	for r: Dictionary in small.roads:
		for q: Vector2 in r.p:
			check(absf(q.x) <= 2200.5 and absf(q.y) <= 2200.5, "точка дороги в окне: %s" % str(q))
	for b: Array in small.buildings:
		check(absf(b[0]) <= 2200.5 and absf(b[1]) <= 2200.5, "дом в окне")
	var none := OsmData.from_tiles([_tile()], c.x + 5.0, c.y, 1000.0)
	check(none.is_empty() and none.attribution == "", "пустое окно — пустой OsmData, без атрибуции")


func test_clip_function() -> void:
	var pts := PackedVector2Array([Vector2(-500, 0), Vector2(0, 0), Vector2(500, 0), Vector2(500, 500)])
	var parts := OsmData._clip(pts, 100.0)
	check(parts.size() == 1 and parts[0].size() == 3, "один кусок из трёх точек: %s" % str(parts))
	check(parts[0][0] == Vector2(-100, 0) and parts[0][2] == Vector2(100, 0), "концы на границе")
	var out := OsmData._clip(PackedVector2Array([Vector2(-500, 300), Vector2(500, 300)]), 100.0)
	check(out.is_empty(), "линия мимо окна")
	var two := OsmData._clip(PackedVector2Array([Vector2(-50, 0), Vector2(300, 0), Vector2(300, 50), Vector2(50, 50)]), 100.0)
	check(two.size() == 2, "вышла и вернулась — два куска: %d" % two.size())


func test_building_format_angle_height() -> void:
	var c := _center()
	var d := OsmData.from_tiles([_tile()], c.x, c.y, 30000.0)
	check(d.buildings.size() == 3, "три дома: %d" % d.buildings.size())
	# дом 0: w2=16, l2=24, angle 0, hq 0, type house(1) → 2 этажа, крыша двускатная (0)
	var b0: Array = []
	var b1: Array = []
	for b: Array in d.buildings:
		if absf(float(b[2]) - 12.0) < 0.01:
			b0 = b
		if absf(float(b[2]) - 30.5) < 0.01:
			b1 = b
	check(b0.size() == 9, "формат L1 [x, z, w, l, угол, высота, крыша, тип, по_правилу]")
	check(int(b0[7]) == 1 and int(b0[8]) == 1, "house (1), высота из правила: %s" % str(b0))
	check(absf(float(b0[3]) - 8.0) < 0.01 and absf(float(b0[4])) < 0.01, "w — длинная сторона, l — короткая, угол 0")
	check(absf(float(b0[5]) - 6.0) < 0.01 and int(b0[6]) == 0, "house: 2 этажа = 6 м, крыша 0: %s" % str(b0))
	# дом 1: angle 37 (против часовой от востока) → в мире (z на юг) угол −37 ≡ 143
	check(absf(float(b1[4]) - 143.0) < 0.01, "угол 37° → 143° в соглашении BuildingPlacer: %s" % str(b1))
	check(absf(float(b1[5]) - 7.0) < 0.01 and int(b1[8]) == 0, "своя высота hq=14 → 7 м, по_правилу 0")
	# направление: длинная сторона вдоль (cos a, sin a) в (x, z) должна быть вдоль (cos 37, −sin 37)
	var a := deg_to_rad(float(b1[4]))
	var dot := cos(a) * cos(deg_to_rad(37.0)) - sin(a) * sin(deg_to_rad(37.0))
	check(absf(absf(dot) - 1.0) < 1e-4, "ось вдоль (cos 37°, −sin 37°) с точностью до знака: север вверх → z вниз")


func test_height_rule() -> void:
	var table := OsmData._type_rule_table(Config.get_config("osm_tiles").height_rule)
	var r := OsmData._house_rule(table, 9, 30.0)  # shed
	check(r.levels == 1 and r.roof == 0, "shed 1 этаж")
	r = OsmData._house_rule(table, 5, 900.0)  # industrial
	check(r.height_m == 8.0 and r.roof == 1, "industrial 8 м плоская")
	r = OsmData._house_rule(table, 2, 100.0)
	check(r.levels == 3 and r.roof == 1, "apartments A<300 → 3")
	r = OsmData._house_rule(table, 3, 1500.0)
	check(r.levels == 9, "residential 800..2000 → 9")
	r = OsmData._house_rule(table, 3, 5000.0)
	check(r.levels == 12, "residential ≥ 2000 → 12")
	r = OsmData._house_rule(table, 4, 700.0)
	check(r.levels == 3, "commercial ≥ 600 → 3")
	r = OsmData._house_rule(table, 26, 100.0)
	check(r.levels == 2, "прочее A<600 → 2")
	r = OsmData._house_rule(table, 0, 100.0)
	check(r.levels == 2 and r.roof == 0, "yes <200 → 2, крыша 0")
	r = OsmData._house_rule(table, 0, 400.0)
	check(r.levels == 4 and r.roof == 1, "yes <600 → 4")
	r = OsmData._house_rule(table, 0, 5000.0)
	check(r.levels == 3 and r.roof == 1, "yes большой → 3")


func test_peaks_names_and_kinds() -> void:
	var c := _center()
	var d := OsmData.from_tiles([_tile()], c.x, c.y, 30000.0)
	check(d.peaks.size() == 3 and d.passes.size() == 2, "вершины %d, перевалы %d" % [d.peaks.size(), d.passes.size()])
	var named: Array = []
	for p: Dictionary in d.peaks:
		named.append(p.name)
	check(named.has("Триглав") and named.has("Vršič") and named.has(""), "имена вершин: %s" % str(named))
	for p: Dictionary in d.peaks:
		if p.name == "Триглав":
			check(p.ele == 2864.0, "высота вершины")
	var pn: Array = []
	for p: Dictionary in d.passes:
		pn.append(p.name)
	check(pn.has("Перевал Мојстрана") and pn.has(""), "имена перевалов (после вершин): %s" % str(pn))
	check(d.rivers.size() >= 2 and d.rail.size() >= 1 and d.power.size() >= 1 and d.aerialways.size() >= 1, "прочие потоки")
	check(d.verticals.size() == 3 and d.verticals[0].t == "mast" and d.verticals[0].comm, "vertical")
	var kinds := {}
	for a: Dictionary in d.aeroways:
		kinds[a.kind] = true
	check(kinds.has("point") and kinds.has("line") and kinds.has("area"), "aeroway виды: %s" % str(kinds.keys()))
	var tr_ := false
	for r: Dictionary in d.roads:
		tr_ = tr_ or (r.t == "track" and r.grade == 2)
	check(tr_, "track с grade")
	var br := false
	for r: Dictionary in d.roads:
		br = br or (r.t == "secondary" and r.bridge and absf(r.w - 6.5) < 1e-4 and r.lanes == 2)
	check(br, "дорога: класс, мост, ширина 6,5 м, полосы")


func test_load_for_with_cache_and_timing() -> void:
	var root := "user://test_osm_data/v1"
	LocationCache.remove_dir("user://test_osm_data")
	var place := "user://test_osm_data/place"
	DirAccess.make_dir_recursive_absolute(place)
	DirAccess.make_dir_recursive_absolute(root + "/252")
	DirAccess.copy_absolute(SAMPLE, root + "/252/755.dpt")
	var f := FileAccess.open(place + "/osm_tiles.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"tiles": [[252, 755, "ok"], [252, 756, "none"], [252, 754, "missing"]]}))
	f.close()
	var c := _center()
	var d := OsmData.load_for(place, c.x, c.y, 30000.0, root)
	check(d.tiles_ok == 2 and d.tiles_missing == 1, "ok(+none) 2, missing 1: %d/%d" % [d.tiles_ok, d.tiles_missing])
	check(d.buildings.size() == 3, "данные из кеша")
	check(d.load_time_s > 0.0, "время загрузки записано")
	var g := FileAccess.open(place + "/osm_tiles.json", FileAccess.WRITE)
	g.store_string(JSON.stringify({"tiles": [[252, 755, "ok"]]}))
	g.close()
	DirAccess.remove_absolute(root + "/252/755.dpt")
	var e := OsmData.load_for(place, c.x, c.y, 30000.0, root)
	check(e.is_empty() and e.tiles_missing == 1, "файл тайла исчез — missing, не падение")
	LocationCache.remove_dir("user://test_osm_data")


## Замер: разбор 9 файлов на рабочих потоках + перевод в мир (мс). Образец мал; на реальной фикстуре 3x3
## (tests/fixtures/osm_tiles/) число другое — см. отчёт OT-8.
func test_decode_timing_3x3() -> void:
	var paths: Array = []
	for k in 9:
		paths.append(SAMPLE)
	OsmData.decode_files(paths)
	var t0 := Time.get_ticks_usec()
	var res := OsmData.decode_files(paths)
	var t1 := Time.get_ticks_usec()
	var d := OsmData.from_tiles(res, _center().x, _center().y, 20000.0)
	var t2 := Time.get_ticks_usec()
	print("OsmData: образец x9 — разбор %.2f мс, перевод в мир %.2f мс" % [(t1 - t0) / 1000.0, (t2 - t1) / 1000.0])
	check(res.size() == 9 and not (res[8] as Dictionary).is_empty() and d.buildings.size() == 27, "9 тайлов разобраны")
