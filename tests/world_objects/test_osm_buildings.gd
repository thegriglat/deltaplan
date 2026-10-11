extends TestCase
## Дома OSM (OT-11, O9): OsmBuildings → BuildingPlacer/MultiMesh, препятствия; пятна с домами OSM без
## процедурных (VillagePlacer.plan с osm_houses); замер на фикстуре и на Алматы 3x3 (если тайлы есть).

const FIX := "res://tests/fixtures/osm_tiles"
const ALMATY := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a"


static func _flat(_x: float, _z: float) -> float:
	return 100.0


func _data(houses: Array) -> OsmData:
	var d := OsmData.new()
	d.buildings = houses
	return d


func _mm_count(root: Node) -> int:
	var n := 0
	for c in root.get_children():
		var mmi := c as MultiMeshInstance3D
		if mmi == null:
			continue
		var mm := mmi.multimesh
		if mm.mesh is BoxMesh and mm.mesh.material is ShaderMaterial:
			n += mm.instance_count
	return n


func test_empty_is_null() -> void:
	var cfg := WorldObjects.load_config()
	check(OsmBuildings.build(OsmData.new(), cfg, _flat, ObstacleIndex.new()) == null, "нет домов — null")


func test_build_and_obstacles() -> void:
	var cfg := WorldObjects.load_config()
	var houses := [[10.0, 10.0, 12.0, 8.0, 30.0, 6.0, 0], [2500.0, -40.0, 30.0, 20.0, 90.0, 27.0, 1]]
	var obs := ObstacleIndex.new()
	var root := OsmBuildings.build(_data(houses), cfg, _flat, obs)
	check(root != null, "узел домов")
	check(_mm_count(root) == 2, "две коробки стен: %d" % _mm_count(root))
	check(int(OsmBuildings.last_stats.building_tiles) == 2, "два тайла MultiMesh")
	var hit := obs.hit(Vector3(10.0, 100.0 + 3.0, -30.0), Vector3(10.0, 100.0 + 3.0, 40.0))
	check(not hit.is_empty() and hit.kind == "building", "дом OSM в индексе препятствий")
	root.free()


## Поддельные пятна: BuiltPatches без файлов — два пятна 100x100 м, доля застройки 1 в обоих.
func _fake_patches() -> BuiltPatches:
	var bp := BuiltPatches.new()
	bp.source = "test"
	bp._img_tried = true
	bp._x0 = 0.0
	bp._z0 = 0.0
	bp._cell = 10.0
	bp._w = 100
	bp._h = 20
	var data := PackedByteArray()
	data.resize(100 * 20)
	data.fill(0)
	for j in 10:
		for i in 10:
			data[j * 100 + i] = 255  # пятно 0: x 0..100, z 0..100
			data[j * 100 + 50 + i] = 255  # пятно 1: x 500..600, z 0..100
	bp._data = data
	bp._patches = [
		{"id": 0, "x": 50.0, "z": 50.0, "area_m2": 10000.0, "share": 1.0, "bbox": Rect2(0, 0, 100, 100)},
		{"id": 1, "x": 550.0, "z": 50.0, "area_m2": 10000.0, "share": 1.0, "bbox": Rect2(500, 0, 100, 100)},
	]
	return bp


func test_patches_with_osm_have_no_procedural() -> void:
	var bp := _fake_patches()
	var vcfg: Dictionary = WorldObjects.load_config().villages
	VillagePlacer._cache.clear()
	var base := VillagePlacer.plan(bp, "t11", vcfg, _flat)
	var in0 := 0
	var in1 := 0
	for b: Array in base:
		if float(b[0]) < 300.0:
			in0 += 1
		else:
			in1 += 1
	check(in0 > 0 and in1 > 0, "без OSM дома в обоих пятнах: %d/%d" % [in0, in1])
	var osm := [[50.0, 50.0, 10.0, 8.0, 0.0, 6.0, 0], [900.0, 50.0, 10.0, 8.0, 0.0, 6.0, 0]]  # второй — вне пятен
	VillagePlacer._cache.clear()
	var with_osm := VillagePlacer.plan(bp, "t11", vcfg, _flat, osm)
	var n0 := 0
	var n1 := 0
	for b: Array in with_osm:
		if float(b[0]) < 300.0:
			n0 += 1
		else:
			n1 += 1
	check(n0 == 0, "в пятне с домом OSM процедурных 0: %d" % n0)
	check(n1 == in1, "другое пятно — как раньше: %d == %d" % [n1, in1])
	VillagePlacer._cache.clear()


## Тайлы 3x3 вокруг точки из каталога с v1/ → OsmData (без стадии и сети).
func _load(root: String, lat: float, lon: float, half_m: float) -> OsmData:
	var paths: Array = []
	for t in OsmGrid.neighbors(lat, lon):
		var p := root.path_join("v1/%d/%d.dpt" % [t.x, t.y])
		if FileAccess.file_exists(p):
			paths.append(p)
	var tiles: Array = []
	for r: Variant in OsmData.decode_files(paths):
		if r is Dictionary and not (r as Dictionary).is_empty():
			tiles.append(r)
	return OsmData.from_tiles_parallel(tiles, lat, lon, half_m)


func _measure(label: String, d: OsmData) -> Dictionary:
	var cfg := WorldObjects.load_config()
	var mem0 := OS.get_static_memory_usage()
	var obs := ObstacleIndex.new()
	var t0 := Time.get_ticks_usec()
	var root := OsmBuildings.build(d, cfg, _flat, obs)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var mem := (OS.get_static_memory_usage() - mem0) / 1048576.0
	var st := OsmBuildings.last_stats
	print("OT-11 замер %s: домов OSM %d, тайлов MultiMesh %d, постройка %.0f мс (стиль %.0f из них классификация %.0f, расстановка %.0f, узлы %.0f), память +%.0f МБ" % [
		label, d.buildings.size(), int(st.get("building_tiles", 0)), ms,
		float(st.get("style_s", 0.0)) * 1000.0, float(st.get("classify_s", 0.0)) * 1000.0, float(st.get("place_s", 0.0)) * 1000.0, float(st.get("nodes_s", 0.0)) * 1000.0, mem])
	if root != null:
		check(_mm_count(root) == d.buildings.size(), "%s: все дома в MultiMesh" % label)
		root.free()
	return {"n": d.buildings.size(), "ms": ms, "mb": mem}


func test_fixture_bohinj() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "/fixture.json"))
	var d := _load(ProjectSettings.globalize_path(FIX), float(fx.center_lat), float(fx.center_lon), 20000.0)
	check(d.buildings.size() > 10, "дома в фикстуре: %d" % d.buildings.size())
	_measure("Бохинь 3x3", d)


func test_almaty() -> void:
	if not DirAccess.dir_exists_absolute(ALMATY):
		print("OT-11: нет тайлов Алматы (%s)" % ALMATY)
		return
	var d := _load(ALMATY, 43.238, 76.945, 20000.0)
	var m := _measure("Алматы 3x3", d)
	check(int(m.n) > 100000, "Алматы: много домов OSM (%d)" % int(m.n))
