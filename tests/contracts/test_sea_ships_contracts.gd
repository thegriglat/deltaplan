extends TestCase
## Контрактные тесты модуля sea-ships (docs/contracts/sea-ships.md): S2 — маска моря и стадия, S3/S4 — конфиг
## configs/sea_ships.json (расстановка и виды судов), S3 v3 — ShipPlacer.ships_for (сигнатура с height_fn, поля элемента с y).
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=sea_ships_contracts


func _cfg() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://configs/sea_ships.json"))


func test_config_keys_and_docs() -> void:
	var c := _cfg()
	for k in ["mask", "placement", "types", "render"]:
		check(c.has(k), "ключ %s" % k)
		check(c.get(k) is Dictionary and (c[k] as Dictionary).has("_doc"), "%s: _doc" % k)
	check(c.has("_doc"), "корень: _doc")
	var r: Dictionary = c.render
	for k in ["lod_m", "cast_shadow_lod0", "roughness"]:
		check(r.has(k) and r.has(k + "_doc"), "render.%s и пояснение" % k)


func test_s2_mask_params() -> void:
	var m: Dictionary = _cfg().mask
	check(int(m.min_cells) == 100 and is_equal_approx(float(m.median_max_m), 0.25) and is_equal_approx(float(m.q99_min_m), -1.0),
		"mask: 100 / 0,25 / −1,0")
	for k in ["min_cells", "median_max_m", "q99_min_m"]:
		check(m.has(k + "_doc"), "%s: пояснение" % k)
	var p := SeaMask.params_from_config()
	check(int(p.min_cells) == 100 and float(p.median_max_m) == 0.25 and float(p.q99_min_m) == -1.0, "params_from_config")


func test_s2_compute_shape_and_values() -> void:
	var n := 40
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	var cls := PackedByteArray()
	cls.resize(n * n)
	cls.fill(6)
	for y in n:
		hs[y * n] = 10.0
		cls[y * n] = 1  # суша — западный столбец
	var m := SeaMask.compute(hs, cls, n, n, 100.0, SeaMask.params_from_config())
	check(m.size() == n * n, "размер w·h")
	check(m[0] == 0 and m[1] == 2 and m[11] == 12 and m[n - 1] == 40, "значение = 1 + floor(d / 100 м): %d %d %d" % [m[1], m[11], m[n - 1]])
	var m0 := SeaMask.compute(hs, PackedByteArray(), n, n, 100.0, {})
	check(m0.size() == n * n, "неверный вход — массив нужного размера")


func test_s2_stage_registered() -> void:
	var names: Array = []
	for st in LocationBuilder.default_stages():
		names.append(st.name)
	var i := names.find("sea")
	check(i > names.find("smooth") and i < names.find("osm_tiles"), "sea после smooth, до osm_tiles: %s" % str(names))
	check(ResourceLoader.exists("res://scripts/terrain/build/sea_stage.gd"), "sea_stage.gd")
	check(SeaMask.FILE == "far_sea.webp", "имя файла")


func test_s3_placement_params() -> void:
	var p: Dictionary = _cfg().placement
	check(is_equal_approx(float(p.cell_deg), 0.02) and int(p.shore_min_m) == 3000 and int(p.shore_max_m) == 15000 and int(p.center_max_m) == 30000, "cell_deg 0,02, полоса 3000…15000, центр ≤ 30000")
	check(int(p.n_min) == 2 and int(p.n_max) == 6 and int(p.min_sep_m) == 1500, "n 2…6, min_sep_m 1500")
	check(not p.has("p_cell") and not p.has("min_shore_m"), "старые ключи p_cell, min_shore_m убраны")
	var wt: Dictionary = p.types
	check(wt.size() == 3 and wt.has_all(["tanker", "bulk", "container"]), "виды tanker, bulk, container")
	for k: String in wt:
		check(is_equal_approx(float(wt[k]), 1.0), "вес вида %s = 1 (слой пропускает вид без .glb)" % k)
	for k in ["cell_deg", "shore_min_m", "shore_max_m", "center_max_m", "n_min", "n_max", "min_sep_m", "types"]:
		check(p.has(k + "_doc"), "%s: пояснение" % k)


func test_s4_types() -> void:
	var t: Dictionary = _cfg().types
	var want := {"tanker": [250, 44, 15], "bulk": [225, 32, 12], "container": [300, 48, 13]}
	for k: String in want:
		var d: Dictionary = t.get(k, {})
		check(d.size() == 3 and [int(d.get("length_m", 0)), int(d.get("beam_m", 0)), int(d.get("draft_m", 0))] == want[k], "%s: размеры" % k)
	var placement_types: Dictionary = _cfg().placement.types
	for k: String in placement_types:
		check(t.has(k), "вид %s из placement описан в types" % k)


func test_s3_ships_for() -> void:
	var m: Dictionary = {}
	for d in (load("res://scripts/world_objects/ship_placer.gd") as Script).get_script_method_list():
		if d.name == "ships_for":
			m = d
	check(not m.is_empty(), "ShipPlacer.ships_for есть")
	var args: Array = m.get("args", [])
	var names: Array = []
	var types: Array = []
	for a in args:
		names.append(a.name)
		types.append(a.type)
	check(names == ["mask", "center_lat", "center_lon", "params", "height_fn"], "аргументы ships_for: %s" % str(names))
	check(types == [TYPE_DICTIONARY, TYPE_FLOAT, TYPE_FLOAT, TYPE_DICTIONARY, TYPE_CALLABLE], "типы аргументов")
	check(int(m.get("flags", 0)) & METHOD_FLAG_STATIC != 0, "static")
	check(ShipPlacer.ships_for({}, 0.0, 0.0, ShipPlacer.params_from_config(), Callable()).is_empty(), "нет маски — []")
	var n := 401
	var data := PackedByteArray()
	data.resize(n * n)
	data.fill(255)
	var half := (n - 1) * 50.0
	var mask := {"image": Image.create_from_data(n, n, false, Image.FORMAT_L8, data), "origin": Vector2(-half, -half), "cell_m": 100.0}
	var p := ShipPlacer.params_from_config()
	var data2 := data.duplicate()
	data2.fill(100)
	mask["image"] = Image.create_from_data(n, n, false, Image.FORMAT_L8, data2)
	var ships := ShipPlacer.ships_for(mask, -27.12, -109.35, p, func(_x: float, _z: float) -> float: return 0.0)
	check(ships.size() >= 2 and ships.size() <= 6, "число судов: %d" % ships.size())
	check(not ships.is_empty(), "полоса у берега — суда есть, N ∈ [2, 6]")
	for s in ships:
		check(s.type is String and s.x is float and s.y is float and s.z is float and s.heading_rad is float and s.cell is Vector2i, "типы полей элемента")
		check(absf(float(s.x)) <= half and absf(float(s.z)) <= half, "точка внутри far")
		var ll := TerrainGeo.local_to_latlon(float(s.x), float(s.z), -27.12, -109.35)
		check(Vector2i(floori(ll.y / 0.02), floori(ll.x / 0.02)) == s.cell, "cell = (floor(lon / cell_deg), floor(lat / cell_deg))")


func test_s2_v2_level_and_compute_info() -> void:
	var n := 40
	var hs := PackedFloat32Array()
	hs.resize(n * n)
	var cls := PackedByteArray()
	cls.resize(n * n)
	cls.fill(6)
	for y in n:
		hs[y * n] = 10.0
		cls[y * n] = 1
		for x in range(1, n):
			hs[y * n + x] = -28.0 - x * 3.0 if x > 5 else -28.0
	var r := SeaMask.compute_info(hs, cls, n, n, 100.0, {"min_cells": 100, "median_max_m": 0.25, "q99_min_m": -1.0})
	check(r.has("levels") and r.has("heights") and r.has("flattened"), "compute_info: levels/heights/flattened")
	check(r.sea_cells == 0, "−28 м с батиметрией по медиане — не море по порогу 0,25 (уровень применим только к морю)")
	var hs2 := hs.duplicate()
	for i in hs2.size():
		if cls[i] == 6:
			hs2[i] = 0.0 if (i % n) < 30 else -300.0
	var r2 := SeaMask.compute_info(hs2, cls, n, n, 100.0, {"min_cells": 100, "median_max_m": 0.25, "q99_min_m": -1.0})
	check(r2.components == 1 and r2.levels.size() == 1 and absf(float(r2.levels[0])) < 0.001, "уровень = мода 0 м")
	var a: PackedFloat32Array = r2.heights
	check(a[1] == 0.0 and a[n - 1] == 0.0 and a[0] == 10.0 and r2.flattened == 10 * n, "батиметрия выровнена, суша прежняя: %d" % r2.flattened)
	check(hs2[n - 1] == -300.0, "вход не изменён")


func test_s2_v2_sea_json_fields_doc() -> void:
	var doc := FileAccess.get_file_as_string("res://docs/contracts/sea-ships.md")
	for k in ["levels_m", "flattened_cells"]:
		check(doc.contains(k), "контракт описывает %s" % k)
