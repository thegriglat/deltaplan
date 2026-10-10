extends Node
## OsmTilesStage (O9, OA-К3): 200 / 404 / таймаут 5 с / офлайн / битый файл через http_hook, кеш без сети,
## локальный каталог, base_url пуст → missing без сети, интеграция в LocationBuilder (missing и догрузка).
## Все файлы — во временном профиле (XDG_DATA_HOME) и в user://test_osm_tiles.

const SAMPLE := "res://tests/contracts/osm_tiles/sample_v1.dpt"
const ROOT := "user://test_osm_tiles/v1"
const LAT := 45.45
const LON := 14.55

var failures: PackedStringArray = []
var calls: Array = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _clean() -> void:
	LocationCache.remove_dir("user://test_osm_tiles")
	LocationCache.remove_dir("user://test_osm_place")
	OsmTilesStage.cache_root_override = ROOT
	calls.clear()


func _ctx() -> LocationBuildContext:
	var ctx := LocationBuildContext.new()
	ctx.center_lat = LAT
	ctx.center_lon = LON
	ctx.host = self
	ctx.dir = "user://test_osm_place"
	DirAccess.make_dir_recursive_absolute(ctx.dir)
	return ctx


func _stage(hook: Callable, over: Dictionary = {}) -> OsmTilesStage:
	var st := OsmTilesStage.new()
	st.http_hook = hook
	var cfg := {"base_url": "https://tiles.example.org/osm", "timeout_s": 5.0}
	cfg.merge(over, true)
	st.cfg_override = cfg
	return st


func _listing(ctx: LocationBuildContext) -> Array:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(ctx.dir.path_join("osm_tiles.json")))
	return d.tiles if d is Dictionary else []


func _states(ctx: LocationBuildContext) -> Array:
	var out: Array = []
	for e: Array in _listing(ctx):
		out.append(e[2])
	return out


## Хук: всегда 200 с образцом тайла.
func _ok_hook() -> Callable:
	var body := FileAccess.get_file_as_bytes(SAMPLE)
	return func(url: String, _h: PackedStringArray) -> Array:
		calls.append(url)
		return [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), body]


func test_200_all_tiles_cached() -> void:
	_clean()
	var ctx := _ctx()
	var log: Array = []
	ctx.counter.connect(func(s: String, d: int, t: int) -> void: log.append([s, d, t]))
	var err: int = await _stage(_ok_hook()).run(ctx)
	check(err == OK, "стадия OK: %d" % err)
	check(calls.size() == 9 and ctx.net_requests == 9, "9 запросов: %d / %d" % [calls.size(), ctx.net_requests])
	check(_states(ctx) == ["ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok"], "все ok: %s" % str(_states(ctx)))
	for e: Array in _listing(ctx):
		check(FileAccess.file_exists(OsmTilesStage.tile_path(int(e[0]), int(e[1]))), "файл в кеше %s" % str(e))
	check(not (calls[0] as String).contains("?") and (calls[0] as String).begins_with("https://tiles.example.org/osm/v1/"),
		"URL: " + str(calls[0]))
	check(log.size() > 0 and log[0] == ["osm_tiles", 0, 9], "счётчик начат с 0/9: %s" % str(log.slice(0, 2)))
	check(log[-1] == ["osm_tiles", 9, 9], "счётчик дошёл до 9/9: %s" % str(log[-1]))
	var prev := -1
	var mono := true
	for e: Array in log:
		mono = mono and int(e[1]) >= prev
		prev = int(e[1])
	check(mono, "N только растёт")


func test_cache_counts_immediately_without_network() -> void:
	_clean()
	await _stage(_ok_hook()).run(_ctx())
	calls.clear()
	var ctx := _ctx()
	var log: Array = []
	ctx.counter.connect(func(s: String, d: int, t: int) -> void: log.append([s, d, t]))
	var fut: Array = [false]
	# синхронно, без единого кадра: из кеша — сразу 9/9
	var st := _stage(_ok_hook())
	var err: int = await st.run(ctx)
	fut[0] = true
	check(err == OK and calls.is_empty() and ctx.net_requests == 0, "из кеша — без запросов: %d" % calls.size())
	check(log.size() == 10 and log[-1] == ["osm_tiles", 9, 9], "9 тиков из кеша: %s" % str(log.size()))


func test_404_is_empty_tile() -> void:
	_clean()
	var hook := func(url: String, _h: PackedStringArray) -> Array:
		calls.append(url)
		return [HTTPRequest.RESULT_SUCCESS, 404, PackedStringArray(), PackedByteArray()]
	var ctx := _ctx()
	var err: int = await _stage(hook).run(ctx)
	check(err == OK, "404 = пустой тайл, стадия OK: %d" % err)
	check(_states(ctx).count("none") == 9, "9 none: %s" % str(_states(ctx)))
	var t := OsmGrid.neighbors(LAT, LON)[0]
	check(FileAccess.file_exists(OsmTilesStage.none_path(t.x, t.y)), "метка .none")
	check(not FileAccess.file_exists(OsmTilesStage.tile_path(t.x, t.y)), "файла тайла нет")
	calls.clear()
	var err2: int = await _stage(hook).run(_ctx())
	check(err2 == OK and calls.is_empty(), "повтор: .none из кеша, без запросов")


func test_5xx_and_network_error_are_missing() -> void:
	_clean()
	var n := [0]
	var hook := func(url: String, _h: PackedStringArray) -> Array:
		calls.append(url)
		n[0] += 1
		if n[0] % 3 == 0:
			return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
		if n[0] % 3 == 1:
			return [HTTPRequest.RESULT_SUCCESS, 503, PackedStringArray(), PackedByteArray()]
		return [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), FileAccess.get_file_as_bytes(SAMPLE)]
	var ctx := _ctx()
	var log: Array = []
	ctx.counter.connect(func(s: String, d: int, t: int) -> void: log.append([s, d, t]))
	var err: int = await _stage(hook).run(ctx)
	check(err == ERR_UNAVAILABLE, "есть missing → ERR_UNAVAILABLE: %d" % err)
	var st := _states(ctx)
	check(st.count("ok") == 3 and st.count("missing") == 6, "3 ok, 6 missing: %s" % str(st))
	check(log[-1] == ["osm_tiles", -1, 9], "пропуск виден в счётчике: %s" % str(log[-1]))
	check(ctx.log_lines.size() > 0, "причина в журнале")


func test_timeout_5s_semantics() -> void:
	_clean()
	var hook := func(url: String, _h: PackedStringArray) -> Array:
		calls.append(url)
		await get_tree().create_timer(30.0).timeout
		return [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), FileAccess.get_file_as_bytes(SAMPLE)]
	var ctx := _ctx()
	var t0 := Time.get_ticks_msec()
	var err: int = await _stage(hook, {"timeout_s": 0.4}).run(ctx)
	var dt := (Time.get_ticks_msec() - t0) / 1000.0
	check(err == ERR_UNAVAILABLE, "таймаут → ERR_UNAVAILABLE: %d" % err)
	check(dt >= 0.35 and dt < 2.0, "ждали общий таймаут, не по запросу: %.2f с" % dt)
	check(_states(ctx).count("missing") == 9, "9 missing: %s" % str(_states(ctx)))
	check(calls.size() == 9, "запросы ушли параллельно: %d" % calls.size())


func test_default_timeout_is_5s() -> void:
	check(float(Config.get_config("osm_tiles").timeout_s) == 5.0, "timeout_s по умолчанию 5 с")


func test_late_answer_after_timeout_is_ignored() -> void:
	_clean()
	var hook := func(_url: String, _h: PackedStringArray) -> Array:
		await get_tree().create_timer(0.6).timeout
		return [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), FileAccess.get_file_as_bytes(SAMPLE)]
	var ctx := _ctx()
	var err: int = await _stage(hook, {"timeout_s": 0.2}).run(ctx)
	check(err == ERR_UNAVAILABLE, "таймаут")
	await get_tree().create_timer(0.8).timeout
	var t := OsmGrid.neighbors(LAT, LON)[0]
	check(not FileAccess.file_exists(OsmTilesStage.tile_path(t.x, t.y)), "опоздавший ответ в кеш не пишется")


func test_offline_uses_cache_only() -> void:
	_clean()
	var ctx := _ctx()
	ctx.offline = true
	var err: int = await _stage(_ok_hook()).run(ctx)
	check(err == ERR_UNAVAILABLE and calls.is_empty() and ctx.net_requests == 0, "офлайн без кеша: missing, сети нет")
	# часть тайлов в кеше
	var tiles := OsmGrid.neighbors(LAT, LON)
	for k in 4:
		DirAccess.make_dir_recursive_absolute(OsmTilesStage.tile_path(tiles[k].x, tiles[k].y).get_base_dir())
		DirAccess.copy_absolute(SAMPLE, OsmTilesStage.tile_path(tiles[k].x, tiles[k].y))
	var ctx2 := _ctx()
	ctx2.offline = true
	var err2: int = await _stage(_ok_hook()).run(ctx2)
	check(err2 == ERR_UNAVAILABLE and _states(ctx2).count("ok") == 4 and calls.is_empty(),
		"офлайн: 4 из кеша, остальные missing: %s" % str(_states(ctx2)))


func test_broken_file_is_missing() -> void:
	_clean()
	var hook := func(url: String, _h: PackedStringArray) -> Array:
		calls.append(url)
		var bad := FileAccess.get_file_as_bytes(SAMPLE)
		if calls.size() % 2 == 0:
			bad = bad.slice(0, 100)  # обрезан кадр
		else:
			bad = "<html>502 Bad Gateway</html> ".to_utf8_buffer() + bad
		return [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), bad]
	var ctx := _ctx()
	var err: int = await _stage(hook).run(ctx)
	check(err == ERR_UNAVAILABLE and _states(ctx).count("missing") == 9, "все битые → missing: %s" % str(_states(ctx)))
	for t in OsmGrid.neighbors(LAT, LON):
		check(not FileAccess.file_exists(OsmTilesStage.tile_path(t.x, t.y)), "битый файл в кеш не попал")


func test_empty_base_url_is_missing_without_network() -> void:
	_clean()
	var ctx := _ctx()
	var log: Array = []
	ctx.counter.connect(func(s: String, d: int, t: int) -> void: log.append([s, d, t]))
	var err: int = await _stage(_ok_hook(), {"base_url": ""}).run(ctx)
	check(err == ERR_UNAVAILABLE and calls.is_empty() and ctx.net_requests == 0, "пустой base_url: missing, сети нет")
	check(log.is_empty(), "счётчика нет — слой отключён настройкой, не ошибкой")


func test_disabled_is_ok_and_empty() -> void:
	_clean()
	var ctx := _ctx()
	var err: int = await _stage(_ok_hook(), {"enabled": false}).run(ctx)
	check(err == OK and calls.is_empty() and _listing(ctx).is_empty(), "enabled=false — стадия пуста")


func test_env_overrides_base_url() -> void:
	_clean()
	OS.set_environment(OsmTilesStage.ENV_URL, "http://env.example.org/t")
	var err: int = await _stage(_ok_hook(), {"base_url": ""}).run(_ctx())
	OS.unset_environment(OsmTilesStage.ENV_URL)
	check(err == OK and (calls[0] as String).begins_with("http://env.example.org/t/v1/"), "DELTAPLAN_OSM_TILES_URL: " + str(calls))


func test_local_directory() -> void:
	_clean()
	var src := ProjectSettings.globalize_path("user://test_osm_tiles/served")
	var tiles := OsmGrid.neighbors(LAT, LON)
	for k in 5:  # пять тайлов есть, четыре — нет файла (404, пустые)
		var p := src.path_join("v1/%d/%d.dpt" % [tiles[k].x, tiles[k].y])
		DirAccess.make_dir_recursive_absolute(p.get_base_dir())
		DirAccess.copy_absolute(SAMPLE, p)
	for base in [src, "file://" + src]:
		LocationCache.remove_dir("user://test_osm_tiles/v1")
		var ctx := _ctx()
		var err: int = await _stage(_ok_hook(), {"base_url": base}).run(ctx)
		var st := _states(ctx)
		check(err == OK and st.count("ok") == 5 and st.count("none") == 4, "%s: %s" % [base, str(st)])
		check(calls.is_empty() and ctx.net_requests == 0, "локальный каталог — без HTTP")
		for t in tiles:
			check(not FileAccess.file_exists(OsmTilesStage.none_path(t.x, t.y)), "каталог не пишет .none в кеш: %s" % str(t))


# ---------- интеграция в LocationBuilder ----------

class FakeDem:
	extends RefCounted

	func run(ctx: LocationBuildContext) -> Error:
		var h := PackedFloat32Array()
		h.resize(25)
		h.fill(100.0)
		HeightLayer.encode_rgb24(h, 5, 5, 100.0, 0.125).save_webp(ctx.dir.path_join("detail.webp"), false)
		var info := {"id": "detail", "file": "detail.webp", "width": 5, "height": 5, "spacing_m": 25.0,
			"origin_x_m": -50.0, "origin_z_m": -50.0, "source": "fake", "water_file": "detail_water.webp",
			"height_min_m": 100.0, "height_step_m": 0.03125}
		ctx.heights = {"detail": h}
		ctx.layers = {"detail": info}
		var f := FileAccess.open(ctx.dir.path_join("meta.json"), FileAccess.WRITE)
		f.store_string(JSON.stringify({"location": ctx.key, "center_lat": ctx.center_lat,
			"center_lon": ctx.center_lon, "layers": [info], "attribution": []}))
		f.close()
		return OK


func test_builder_missing_then_only_osm_reruns() -> void:
	_clean()
	var point := Vector2(-33.07, 151.93)
	var key := LocationCache.key_for(point.x, point.y)
	LocationCache.remove_dir(LocationCache.dir_for(key))
	var dem := FakeDem.new()
	var make := func(base: String) -> LocationBuilder:
		var b := LocationBuilder.new()
		b.stages = [{"name": "dem", "obj": dem}, {"name": "osm_tiles", "obj": _stage(_ok_hook(), {"base_url": base})}]
		return b
	var r1: Dictionary = await make.call("").build(self, point.x, point.y)
	check(bool(r1.ok) and r1.missing == ["osm_tiles"], "без сети место открывается с missing: %s" % str(r1))
	check(not LocationCache.is_complete(key), "неполное")
	var r2: Dictionary = await make.call("https://tiles.example.org").build(self, point.x, point.y)
	check(bool(r2.ok) and r2.missing == [] and LocationCache.is_complete(key), "догружена: %s" % str(r2))
	check(calls.size() == 9, "догрузили только OSM: 9 запросов, %d" % calls.size())
	check(FileAccess.file_exists(LocationCache.dir_for(key).path_join("osm_tiles.json")), "osm_tiles.json в папке места")
	calls.clear()
	var r3: Dictionary = await make.call("https://tiles.example.org").build(self, point.x, point.y)
	check(bool(r3.ok) and calls.is_empty(), "полное место — без сети")
	LocationCache.remove_dir(LocationCache.dir_for(key))
	OsmTilesStage.cache_root_override = ""
