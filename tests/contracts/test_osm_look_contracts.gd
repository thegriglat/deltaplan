extends TestCase
## Контрактные тесты osm-look (docs/contracts/osm-look.md): версии L1–L6, L1 запись дома (O9 v2),
## L2 BuildingStyle (classify/adjust — форма), L4 провод ветра OsmLayer.update_wind. Модели L5/L6 —
## tests/contracts/test_osm_look_models.gd (создают OL-2/OL-3). Правка контракта (версия +1) — вместе с этим файлом.
## Скрипты нового кода грузятся по пути (load), чтобы файл разбирался и до их появления.

const DOC := "res://docs/contracts/osm-look.md"
const VERSIONS := {"L1": 1, "L2": 1, "L3": 1, "L4": 1, "L5": 1, "L6": 1}
const SAMPLE := "res://tests/contracts/osm_tiles/sample_v1.dpt"
const STYLE_PATH := "res://scripts/world_objects/osm/building_style.gd"


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])
	var o9 := _read("res://docs/contracts/osm-tiles.md")
	check(o9.contains('{"id": "O9", "version": 2}'), "O9 v2 в osm-tiles.md")


## L1: запись дома OsmData — 9 полей, тип O3 0..26, по_правилу 0|1.
func test_l1_record() -> void:
	var o := OsmGrid.origin_d(252, 755)
	var lat := o[0] + 0.5 * OsmGrid.DLAT
	var lon := o[1] + 0.5 * OsmGrid.dlon(252)
	var d := OsmData.from_tiles([OsmTileReader.read(FileAccess.get_file_as_bytes(SAMPLE))], lat, lon, 30000.0)
	check(not d.buildings.is_empty(), "в образце есть дома")
	for b: Array in d.buildings:
		check(b.size() == 9, "L1: 9 полей, а не %d" % b.size())
		if b.size() < 9:
			return
		check(b[7] is int and int(b[7]) >= 0 and int(b[7]) <= 26, "L1: тип O3 0..26: %s" % str(b[7]))
		check(int(b[8]) == 0 or int(b[8]) == 1, "L1: по_правилу 0|1: %s" % str(b[8]))
		check(int(b[6]) == 0 or int(b[6]) == 1, "крыша 0|1")


## L2: BuildingStyle.classify / adjust — форма результата на подставных данных; 7-польные записи = процедурные.
func test_l2_style_shape() -> void:
	check(ResourceLoader.exists(STYLE_PATH), "L2: есть " + STYLE_PATH)
	if not ResourceLoader.exists(STYLE_PATH):
		return
	var bs: GDScript = load(STYLE_PATH)
	var consts := bs.get_script_constant_map()
	check(int(consts.get("CITY", -1)) == 0 and int(consts.get("VILLAGE", -1)) == 1 and int(consts.get("INDUSTRIAL", -1)) == 2,
		"L2: CITY 0, VILLAGE 1, INDUSTRIAL 2")
	var cfg: Dictionary = Config.get_config("world_objects").buildings
	check(cfg.get("style") is Dictionary, "L2: world_objects.json → buildings.style")
	var recs: Array = [
		[0.0, 0.0, 10.0, 8.0, 0.0, 6.0, 0],  # процедурный (7 полей) → VILLAGE
		[50.0, 0.0, 12.0, 9.0, 0.0, 6.0, 0, 1, 1],  # house → VILLAGE
		[100.0, 0.0, 40.0, 20.0, 0.0, 15.0, 1, 2, 1],  # apartments → CITY
		[200.0, 0.0, 120.0, 30.0, 0.0, 8.0, 1, 5, 1],  # industrial → INDUSTRIAL
		[300.0, 0.0, 30.0, 20.0, 0.0, 30.0, 1, 15, 0],  # office с высотой из тегов
	]
	var st: PackedByteArray = bs.classify(recs, cfg)
	check(st.size() == recs.size(), "L2: стиль на каждую запись")
	if st.size() != recs.size():
		return
	check(st[0] == 1 and st[1] == 1 and st[2] == 0 and st[3] == 2, "L2: стили по типам: %s" % str(st))
	var rule: Dictionary = Config.get_config("osm_tiles").height_rule
	check(rule.get("metro") is Dictionary, "L2: osm_tiles.json → height_rule.metro")
	var h_tag := float(recs[4][5])
	var glass: PackedByteArray = bs.adjust(recs, st, rule)
	check(glass.size() == recs.size(), "L2: флаг фасада на каждую запись")
	check(float(recs[4][5]) == h_tag, "L2: высота из тегов не меняется")
	check(float(recs[1][5]) == 6.0 and float(recs[3][5]) == 8.0, "L2: село и промзона без поправки")


## L4: провод ветра — OsmLayer.update_wind(air_fn, cam) зовёт osm_wind у потомков группы osm_wind.
func test_l4_wind_feed() -> void:
	var layer := OsmLayer.new()
	check(layer.has_method("update_wind"), "L4: OsmLayer.update_wind")
	if not layer.has_method("update_wind"):
		layer.free()
		return
	var probe := Node3D.new()
	probe.set_script(_probe_script())
	layer.add_child(probe)
	probe.add_to_group(&"osm_wind")
	layer.call(&"update_wind", func(_p: Vector3) -> Vector3: return Vector3(3, 0, 0), Vector3.ZERO)
	check(int(probe.get(&"calls")) == 1, "L4: osm_wind вызван у потомка группы")
	layer.free()


func _probe_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = (
		"extends Node3D\nvar calls := 0\n"
		+ "func osm_wind(air_fn: Callable, _cam: Vector3) -> void:\n"
		+ "\tif air_fn.call(Vector3.ZERO) == Vector3(3, 0, 0):\n\t\tcalls += 1\n"
	)
	s.reload()
	return s
