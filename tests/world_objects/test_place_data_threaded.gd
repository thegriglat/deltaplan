extends TestCase
## FL-10: общие данные места (PlaceData.start_for_terrain) и маска просек (WorldClearings.build_from) — в рабочих
## потоках, результат тот же, что на главном; дома OSM в расчёте слоя (OsmBuildings.prepare) не меняют общих
## записей PlaceData.osm.buildings (FL-К2: после сборки — только чтение).
## godot --headless --path . res://tests/run_tests.tscn -- --filter=place_data_threaded

const ID := "ongudai"


## Сборка в потоке = сборка на главном: тот же план домов, OSM, слои и пятна; кладётся в мета Terrain.
func test_threaded_same_as_main() -> void:
	var t := Terrain.new()
	t.location_id = ""
	t.load_location(ID)
	var main_pd := PlaceData.build(t.location_id, t.layers, BuiltPatches.for_terrain(t))
	t.remove_meta(PlaceData.META_KEY)
	var job := PlaceData.start_for_terrain(t)
	check(job.task >= 0, "расчёт — задачей пула")
	var frames := 0
	while not job.done():
		await (Engine.get_main_loop() as SceneTree).process_frame
		frames += 1
	var pd := job.finish()
	check(pd != null, "данные есть")
	if pd == null:
		t.free()
		return
	print("FL-10 PlaceData в потоке: %.2f с, кадров ожидания %d" % [pd.build_time_s, frames])
	check(t.get_meta(PlaceData.META_KEY) == pd and PlaceData.for_terrain(t) == pd, "в мета Terrain, повтор — тот же")
	check(pd.layers.size() == t.layers.size() and pd.layers[0] == t.layers[0], "слои — объекты Terrain.layers")
	check(pd.patches == BuiltPatches.for_terrain(t), "пятна — экземпляр из мета Terrain")
	check(pd.house_plan.size() > 300, "план домов: %d" % pd.house_plan.size())
	check(hash(pd.house_plan) == hash(main_pd.house_plan), "план домов тот же")
	check(pd.osm.buildings.size() == main_pd.osm.buildings.size(), "дома OSM те же")
	check(pd.center_lat == main_pd.center_lat and pd.center_lon == main_pd.center_lon, "центр тот же")
	# готовые данные — job сразу готов, без задачи
	var again := PlaceData.start_for_terrain(t)
	check(again.task < 0 and again.done() and again.finish() == pd, "данные этого места есть — без пересборки")
	# маска просек в потоке = на главном
	var a := WorldClearings.build_from(pd)
	var loc: Dictionary = Locations.config(ID)
	var cfg := WorldObjects.load_config()
	var res := {}
	var task := WorkerThreadPool.add_task(func() -> void: res["c"] = WorldClearings.build_from(pd, loc, cfg))
	WorkerThreadPool.wait_for_task_completion(task)
	var b: WorldClearings = res.get("c")
	check(b != null and a.image.get_data() == b.image.get_data(), "маска в потоке та же")
	check(b != null and a.origin == b.origin and a.cell_m == b.cell_m, "охват маски тот же")
	t.free()


## Рельеф устарел, пока считались данные (рельеф загружен заново) — finish() отдаёт null, мета не трогается.
func test_stale_dropped() -> void:
	var t := Terrain.new()
	t.location_id = ""
	t.load_location(ID)
	t.remove_meta(PlaceData.META_KEY)
	var job := PlaceData.start_for_terrain(t)
	var old_layers := t.layers.duplicate()
	t.layers.clear()  # как новая загрузка: другие слои
	check(job.finish() == null, "устаревшие данные отброшены")
	check(not t.has_meta(PlaceData.META_KEY), "мета не тронута")
	t.layers.assign(old_layers)
	t.free()


## Поправка этажности мегаполиса (BuildingStyle.adjust) — в копии записей: OsmData.buildings после расчёта те же.
## Фикстура — плотный «город» 5 × 5 км (дома 40 × 40 м через 50 м, 10 этажей, тип 2 — многоэтажки, высота по правилу).
func test_buildings_read_only() -> void:
	var d := OsmData.new()
	for j in 100:
		for i in 100:
			d.buildings.append([-2500.0 + 50.0 * i, -2500.0 + 50.0 * j, 40.0, 40.0, 0.0, 30.0, 0, 2, 1])
	var before := hash(d.buildings)
	var cfg := WorldObjects.load_config()
	var rule: Dictionary = Config.get_config("osm_tiles").get("height_rule", {})
	# фикстура в самом деле получает поправку этажности (иначе проверка ниже ничего не ловит)
	var c := d.buildings.duplicate(true)
	BuildingStyle.adjust(c, BuildingStyle.classify(c, cfg.buildings.style), rule)
	BuildingStyle.release()
	check(hash(c) != before, "поправка этажности меняет записи фикстуры")
	var flat := func(_x: float, _z: float) -> float: return 500.0
	var p := OsmBuildings.prepare(d, cfg, flat, rule)
	check(not p.is_empty(), "дома расставлены")
	check(hash(d.buildings) == before, "общие записи домов не изменены")
	# расчёт повторяем — тот же результат (раньше поправка накапливалась в общих записях)
	var p2 := OsmBuildings.prepare(d, cfg, flat, rule)
	check(hash(_walls(p)) == hash(_walls(p2)), "повторный расчёт — те же дома")


static func _walls(p: Dictionary) -> Array:
	var out: Array = []
	var keys: Array = (p.tiles as Dictionary).keys()
	keys.sort()
	for k: Variant in keys:
		out.append(p.tiles[k].walls)
	return out
