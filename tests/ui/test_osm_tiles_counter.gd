extends Node
## Счётчик «OSM: N/9» на экране загрузки (решение пользователя, механизм NO-7): N растёт до M, кеш засчитан
## сразу, пропуск (таймаут/ошибка) виден — «OSM: пропущено». Тексты ru/en. Без сети.

const SAMPLE := "res://tests/contracts/osm_tiles/sample_v1.dpt"
var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _run_stage(hook: Callable, over: Dictionary, p: LoadProgress) -> int:
	OsmTilesStage.cache_root_override = "user://test_osm_counter/v1"
	var ctx := LocationBuildContext.new()
	ctx.center_lat = 45.45
	ctx.center_lon = 14.55
	ctx.host = self
	ctx.dir = "user://test_osm_counter"
	DirAccess.make_dir_recursive_absolute(ctx.dir)
	ctx.counter.connect(func(s: String, d: int, t: int) -> void: p.counter(s, d, t))
	var st := OsmTilesStage.new()
	st.http_hook = hook
	var cfg := {"base_url": "https://tiles.example.org", "timeout_s": 0.3}
	cfg.merge(over, true)
	st.cfg_override = cfg
	var err: int = await st.run(ctx)
	OsmTilesStage.cache_root_override = ""
	return err


func test_counter_grows_to_9_then_cache_immediately() -> void:
	LocationCache.remove_dir("user://test_osm_counter")
	TranslationServer.set_locale("ru")
	var body := FileAccess.get_file_as_bytes(SAMPLE)
	var hook := func(_u: String, _h: PackedStringArray) -> Array:
		await get_tree().process_frame
		return [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), body]
	var p := LoadProgress.new({"dem": 1.0, "osm": 1.0})
	p.begin()
	p.stage("osm", "x")
	var seen: Array = []
	p.changed.connect(func(_t: String, _f: float) -> void: seen.append(p.counter_text("osm_tiles")))
	var err := await _run_stage(hook, {}, p)
	check(err == OK, "стадия OK")
	check(p.counters["osm_tiles"] == [9, 9], "N дошло до M=9: %s" % str(p.counters))
	check(p.counter_text("osm_tiles") == "OSM: 9/9", "текст: " + p.counter_text("osm_tiles"))
	check(seen.has("OSM: 0/9") and seen.has("OSM: 4/9"), "промежуточные значения видны: %s" % str(seen))
	# второй раз: все из кеша, ни одного запроса, 9/9 сразу
	var hook2 := func(_u: String, _h: PackedStringArray) -> Array:
		failures.append("запрос при полном кеше")
		return []
	var p2 := LoadProgress.new({"osm": 1.0})
	p2.begin()
	p2.stage("osm", "x")
	await _run_stage(hook2, {}, p2)
	check(p2.counters["osm_tiles"] == [9, 9], "из кеша засчитано сразу: %s" % str(p2.counters))
	LocationCache.remove_dir("user://test_osm_counter")


func test_skipped_on_timeout() -> void:
	LocationCache.remove_dir("user://test_osm_counter")
	TranslationServer.set_locale("ru")
	var hook := func(_u: String, _h: PackedStringArray) -> Array:
		await get_tree().create_timer(10.0).timeout
		return []
	var p := LoadProgress.new({"osm": 1.0})
	p.begin()
	p.stage("osm", "x")
	var err := await _run_stage(hook, {"timeout_s": 0.2}, p)
	check(err == ERR_UNAVAILABLE, "таймаут → ERR_UNAVAILABLE")
	check(p.counter_text("osm_tiles") == "OSM: пропущено", "пропуск виден: " + p.counter_text("osm_tiles"))
	TranslationServer.set_locale("en")
	check(p.counter_text("osm_tiles") == "OSM: skipped", "en: " + p.counter_text("osm_tiles"))
	TranslationServer.set_locale("ru")
	check(p.total_text() == "", "пропущенная стадия в «Всего» не входит")
	LocationCache.remove_dir("user://test_osm_counter")


func test_screen_line_and_total() -> void:
	TranslationServer.set_locale("ru")
	var l: LoadingScreen = (load("res://scenes/ui/loading_screen.tscn") as PackedScene).instantiate()
	add_child(l)
	var p := LoadProgress.new({"dem": 1.0, "osm": 1.0})
	p.begin()
	l.open(p, "")
	p.stage("dem", "x")
	p.counter("dem", 63, 63)
	p.stage("osm", "y")
	p.counter("osm_tiles", 4, 9)
	check(l.counter_line() == "Рельеф: 63/63   OSM: 4/9   Всего: 67/72", "строка: " + l.counter_line())
	p.counter("osm_tiles", -1, 9)
	check(l.counter_line() == "Рельеф: 63/63   OSM: пропущено", "пропуск на экране: " + l.counter_line())
	l.queue_free()
