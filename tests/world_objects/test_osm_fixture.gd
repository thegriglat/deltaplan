extends Node
## Реальные тайлы-фикстура (tests/fixtures/osm_tiles, Бохинь — Блед, 3x3 из OT-2): стадия из локального
## каталога → osm_tiles.json → OsmData.load_for; время разбора на рабочих потоках (печатается в журнал).
## Центральный тайл Алматы — из /home/greg/deltaplan_data/osm_tiles/OT-2/acc_kz (если каталог есть).

const FIX := "res://tests/fixtures/osm_tiles"
const KZ := "/home/greg/deltaplan_data/osm_tiles/OT-2/acc_kz/tiles"
var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _stage_to(base: String, lat: float, lon: float, dir: String) -> int:
	OsmTilesStage.cache_root_override = "user://test_osm_fixture/v1"
	var ctx := LocationBuildContext.new()
	ctx.center_lat = lat
	ctx.center_lon = lon
	ctx.host = self
	ctx.dir = dir
	DirAccess.make_dir_recursive_absolute(dir)
	var st := OsmTilesStage.new()
	st.cfg_override = {"base_url": base}
	var err: int = await st.run(ctx)
	return err


func _measure(base: String, lat: float, lon: float, label: String) -> OsmData:
	LocationCache.remove_dir("user://test_osm_fixture")
	var dir := "user://test_osm_fixture/place"
	var err := await _stage_to(base, lat, lon, dir)
	check(err == OK, "%s: стадия OK (%d)" % [label, err])
	var best := 1e9
	var d: OsmData
	for k in 3:
		var t0 := Time.get_ticks_usec()
		var paths: Array = []
		for t in OsmGrid.neighbors(lat, lon):
			var p := OsmTilesStage.tile_path(t.x, t.y)
			if FileAccess.file_exists(p):
				paths.append(p)
		var res := OsmData.decode_files(paths)
		best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
		for r: Dictionary in res:
			check(not r.is_empty(), "%s: тайл разобран" % label)
	d = OsmData.load_for(dir, lat, lon, 20000.0)
	print("OT-8 замер %s: разбор 3x3 на потоках %.1f мс (лучший из 3); load_for целиком %.1f мс; дорог %d, домов %d, вершин %d, ЛЭП %d" % [
		label, best, d.load_time_s * 1000.0, d.roads.size(), d.buildings.size(), d.peaks.size(), d.power.size()])
	OsmTilesStage.cache_root_override = ""
	return d


func test_fixture_bohinj() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX + "/fixture.json"))
	var base := ProjectSettings.globalize_path(FIX)
	var d := await _measure(base, float(fx.center_lat), float(fx.center_lon), "Бохинь 3x3")
	check(d.tiles_ok == 9 and d.tiles_missing == 0, "9 тайлов: %d/%d" % [d.tiles_ok, d.tiles_missing])
	check(d.roads.size() > 10 and d.buildings.size() > 10, "дороги и дома есть")
	check(d.attribution != "", "атрибуция")
	for b: Array in d.buildings:
		check(absf(b[0]) <= 20200.5 and float(b[2]) >= float(b[3]) and float(b[5]) > 0.0, "дом в окне, w ≥ l, высота > 0")
		break
	LocationCache.remove_dir("user://test_osm_fixture")


func test_almaty_center() -> void:
	if not DirAccess.dir_exists_absolute(KZ):
		print("OT-8: Алматы — нет данных (%s)" % KZ)
		return
	var d := await _measure(KZ.get_base_dir() + "/tiles", 43.25, 76.95, "Алматы")
	check(d.tiles_ok >= 1, "тайлы Алматы")
	LocationCache.remove_dir("user://test_osm_fixture")
