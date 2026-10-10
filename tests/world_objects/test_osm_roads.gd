extends TestCase
## OsmRoads (O9, OT-9): ленты дорог, рек/каналов, ж/д из реальных тайлов (фикстура Бохинь — Блед, Алматы);
## число лент по классам = числу объектов OsmData (без тоннелей), вода — свой материал, просеки вдоль дорог.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=osm_roads

const FIX := "res://tests/fixtures/osm_tiles/v1"
const ALMATY := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a/v1"


func _data(base: String, lat: float, lon: float) -> OsmData:
	var paths: Array = []
	for t in OsmGrid.neighbors(lat, lon):
		var p := "%s/%d/%d.dpt" % [base, t.x, t.y]
		if FileAccess.file_exists(p):
			paths.append(p)
	var res := OsmData.decode_files(paths)
	return OsmData.from_tiles_parallel(res, lat, lon, 20000.0)


static func _flat(_x: float, _z: float) -> float:
	return 500.0


## Ожидаемое число лент по ключу класса (как их делит OsmRoads).
static func _expect(arr: Array, classes: Dictionary, rivers: bool = false) -> Dictionary:
	var e := {}
	for r: Dictionary in arr:
		if bool(r.get("tunnel", false)):
			continue
		var t := String(r.t)
		if rivers and t == "river" and bool(r.get("named", false)):
			t = "river_named"
		if classes.has(t):
			e[t] = int(e.get(t, 0)) + 1
	return e


func test_fixture_counts_match_objects() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/osm_tiles/fixture.json"))
	var d := _data(FIX, float(fx.center_lat), float(fx.center_lon))
	var cfg := WorldObjects.load_config()
	var t0 := Time.get_ticks_usec()
	var node := OsmRoads.build(d, cfg, _flat, ObstacleIndex.new())
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(node != null, "узел дорог построен")
	if node == null:
		return
	var st: Dictionary = node.get_meta(&"stats")
	check(st.roads == _expect(d.roads, cfg.roads.classes), "ленты дорог по классам: %s против %s" % [st.roads, _expect(d.roads, cfg.roads.classes)])
	check(st.rivers == _expect(d.rivers, cfg.rivers.classes, true), "реки/каналы по классам: %s" % st.rivers)
	check(st.rail == _expect(d.rail, cfg.rail.classes), "ж/д по классам: %s" % st.rail)
	var total := 0
	for k in ["roads", "rivers", "rail"]:
		for c in st[k]:
			total += int(st[k][c])
	check(total > 100, "лент достаточно: %d" % total)
	var tunnels := 0
	for arr: Array in [d.roads, d.rail]:
		for r: Dictionary in arr:
			tunnels += int(bool(r.tunnel))
	check(int(st.skipped_tunnels) == tunnels, "тоннели пропущены: %d из %d" % [st.skipped_tunnels, tunnels])
	print("OT-9 фикстура Бохинь: лент %d, меш-тайлов %d, тоннелей пропущено %d, дороги %s, реки %s, ж/д %s, %.0f мс" % [
		total, st.tiles, st.skipped_tunnels, st.roads, st.rivers, st.rail, ms])
	if d.rivers.size() > 0:
		var rv := node.get_node_or_null("Rivers")
		check(rv != null and rv.get_child_count() > 0, "узел рек есть")
		if rv != null and rv.get_child_count() > 0:
			var m := (rv.get_child(0) as MeshInstance3D).material_override as ShaderMaterial
			var rm := (node.get_node("Roads").get_child(0) as MeshInstance3D).material_override as ShaderMaterial
			check(m != rm and m.get_shader_parameter(&"roughness") != null and rm.get_shader_parameter(&"roughness") == null, "у воды свой материал (шероховатость)")
	node.free()


func test_empty_returns_null() -> void:
	check(OsmRoads.build(OsmData.new(), WorldObjects.load_config(), _flat, ObstacleIndex.new()) == null, "пусто — null")


func test_tunnel_not_drawn() -> void:
	var d := OsmData.new()
	d.roads = [
		{"t": "primary", "p": PackedVector2Array([Vector2(0, 0), Vector2(100, 0)]), "w": 0.0, "lanes": 0, "tunnel": true, "bridge": false, "grade": 0},
		{"t": "primary", "p": PackedVector2Array([Vector2(0, 50), Vector2(100, 50)]), "w": 0.0, "lanes": 0, "tunnel": false, "bridge": true, "grade": 0},
	]
	var node := OsmRoads.build(d, WorldObjects.load_config(), _flat, ObstacleIndex.new())
	check(node != null, "мост рисуется")
	if node != null:
		var st: Dictionary = node.get_meta(&"stats")
		check(st.roads == {"primary": 1} and st.skipped_tunnels == 1, "одна лента, тоннель пропущен: %s" % st)
		node.free()


func test_clearings_along_roads() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/osm_tiles/fixture.json"))
	var d := _data(FIX, float(fx.center_lat), float(fx.center_lon))
	var cfg := WorldObjects.load_config()
	var c := WorldClearings.new()
	c.build([], cfg, 20000.0, [], [], d)
	var n := 0
	var clear := 0
	for r: Dictionary in d.roads:
		if bool(r.tunnel) or not cfg.roads.classes.has(r.t):
			continue
		var pts: PackedVector2Array = r.p
		for q in pts:
			if absf(q.x) < 19000.0 and absf(q.y) < 19000.0:
				n += 1
				clear += int(c.is_clear_at(q.x, q.y))
	check(n > 100 and clear == n, "точки дорог расчищены: %d из %d" % [clear, n])
	var nb := 0
	var cb := 0
	for b: Array in d.buildings:
		if absf(b[0]) < 19000.0 and absf(b[1]) < 19000.0:
			nb += 1
			cb += int(c.is_clear_at(b[0], b[1]))
	check(nb > 10 and cb == nb, "дома OSM расчищены: %d из %d" % [cb, nb])
	var c0 := WorldClearings.new()
	c0.build([], cfg, 20000.0)
	check(not c0.is_clear_at(d.roads[0].p[0].x, d.roads[0].p[0].y), "без OSM просек нет")


func test_almaty_build_time() -> void:
	if not DirAccess.dir_exists_absolute(ALMATY):
		print("OT-9: Алматы — нет данных (%s)" % ALMATY)
		return
	var d := _data(ALMATY, 43.25, 76.95)
	var cfg := WorldObjects.load_config()
	var t0 := Time.get_ticks_usec()
	var node := OsmRoads.build(d, cfg, _flat, ObstacleIndex.new())
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(node != null, "Алматы: дороги построены")
	if node != null:
		var st: Dictionary = node.get_meta(&"stats")
		check(st.roads == _expect(d.roads, cfg.roads.classes), "Алматы: ленты = объекты")
		check(st.rivers == _expect(d.rivers, cfg.rivers.classes, true) and st.rail == _expect(d.rail, cfg.rail.classes), "Алматы: реки и ж/д = объекты")
		print("OT-9 Алматы 3x3: объектов дорог %d, рек %d, ж/д %d; ленты дорог %s, рек %s, ж/д %s; меш-тайлов %d; постройка %.0f мс" % [
			d.roads.size(), d.rivers.size(), d.rail.size(), st.roads, st.rivers, st.rail, st.tiles, ms])
		node.free()
