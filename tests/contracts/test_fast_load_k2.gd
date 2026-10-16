extends TestCase
## Контракт FL-К2 v1 (docs/contracts/fast-load.md): общие данные места PlaceData — один раз за загрузку;
## план домов один (с домами OSM) для маски просек и объектов; ключ кеша VillagePlacer — из данных.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=fast_load_k2

const ID := "ongudai"

static var _t: Terrain


func _terrain() -> Terrain:
	if _t == null:
		_t = Terrain.new()
		_t.location_id = ""
		_t.load_location(ID)
	return _t


## Один раз на рельеф: повторный for_terrain — тот же объект, без новой сборки; слои — те же, что у Terrain.
func test_place_data_once() -> void:
	var t := _terrain()
	t.remove_meta(PlaceData.META_KEY)
	var n0 := PlaceData.builds
	var pd := PlaceData.for_terrain(t)
	var pd2 := PlaceData.for_terrain(t)
	check(PlaceData.builds == n0 + 1, "собран один раз: %d сборок" % (PlaceData.builds - n0))
	check(pd == pd2 and t.get_meta(PlaceData.META_KEY) == pd, "кеш в мета Terrain \"place_data\"")
	check(pd.layers.size() == t.layers.size() and pd.layers[0] == t.layers[0], "слои — объекты Terrain.layers")
	check(pd.patches == BuiltPatches.for_terrain(t), "пятна — экземпляр из мета Terrain")
	check(pd.osm != null, "OsmData есть (пустой без тайлов)")
	check(pd.house_plan.size() > 300, "план домов: %d" % pd.house_plan.size())
	approx(pd.height_at(100.0, -200.0), t.height_at(100.0, -200.0), 1e-4, "height_at = Terrain.height_at")


## Ключ кеша из данных: другой экземпляр BuiltPatches того же места — попадание (тот же массив).
func test_plan_cache_hit() -> void:
	var t := _terrain()
	var pd := PlaceData.for_terrain(t)
	var vcfg: Dictionary = WorldObjects.load_config().villages
	var fresh := BuiltPatches.for_dir(Locations.data_dir(ID))
	var again := VillagePlacer.plan(fresh, ID, vcfg, pd.height_at, pd.osm.buildings)
	check(is_same(again, pd.house_plan), "повторный план с теми же данными — из кеша")


## Пятно с домом OSM не получает процедурных домов (дом OSM — на месте дома плана в пятне, bbox которого
## не пересекается с другими: принадлежность дома пятну видна по bbox).
func test_osm_patch_has_no_procedural() -> void:
	var t := _terrain()
	var pd := PlaceData.for_terrain(t)
	var vcfg: Dictionary = WorldObjects.load_config().villages
	var list := pd.patches.patches()
	var lone: Array = []
	for p: Dictionary in list:
		var alone := true
		for q: Dictionary in list:
			if q.id != p.id and (q.bbox as Rect2).intersects(p.bbox):
				alone = false
				break
		if alone:
			lone.append(p.bbox)
	var osm_house: Array = []
	var box := Rect2()
	for h: Array in pd.house_plan:
		for bb: Rect2 in lone:
			if bb.has_point(Vector2(float(h[0]), float(h[1]))):
				osm_house = [float(h[0]), float(h[1]), 10.0, 8.0, 0.0, 6.0, 0, 0, 0]
				box = bb
				break
		if not osm_house.is_empty():
			break
	check(not osm_house.is_empty(), "есть отдельное пятно с домами")
	if osm_house.is_empty():
		return
	var before := 0
	for b: Array in pd.house_plan:
		if box.has_point(Vector2(float(b[0]), float(b[1]))):
			before += 1
	var with_osm := VillagePlacer.plan(pd.patches, ID, vcfg, pd.height_at, [osm_house])
	var inside := 0
	for b: Array in with_osm:
		if box.has_point(Vector2(float(b[0]), float(b[1]))):
			inside += 1
	check(before > 0 and inside == 0, "процедурных домов в пятне с домом OSM: %d (без OSM %d)" % [inside, before])
	check(with_osm.size() == pd.house_plan.size() - before, "остальные пятна — как раньше")


## Объекты берут OSM и план из PlaceData (не читают и не считают заново); маска из PlaceData = маске из файлов.
func test_objects_and_mask_share_data() -> void:
	var t := _terrain()
	var pd := PlaceData.for_terrain(t)
	var w := WorldObjects.new()
	w.build(
		ID, t.get_start_sites(), t.get_landing_sites(), t.height_at, Callable(), t.latlon_to_local,
		Vector2(t.center_lat, t.center_lon), pd.patches, pd
	)
	check(is_same(w.houses, pd.house_plan), "дома WorldObjects = план PlaceData")
	check(w.osm == pd.osm, "OSM WorldObjects = OSM PlaceData")
	var live := WorldClearings.build_from(pd)
	var files := WorldClearings.build_for(ID)
	check(live != null and files != null, "маски построены")
	if live != null and files != null:
		check(live.image.get_data() == files.image.get_data(), "маска из PlaceData = маске из файлов")
		check(live.origin == files.origin and live.cell_m == files.cell_m, "привязка маски")
	# каждый дом плана вырублен (деревья не растут в домах), и только план (без домов OSM в фикстуре)
	var miss := 0
	for b: Array in pd.house_plan:
		if not live.is_clear_at(float(b[0]), float(b[1])):
			miss += 1
	check(miss == 0, "домов плана без просеки: %d" % miss)
	w.free()


func test_zz_cleanup() -> void:
	if _t != null:
		_t.free()
		_t = null
