extends TestCase
## RasterTileLoader: политика серверов тайлов (SM-К1 v3) — User-Agent, паузы после ошибок и 403/429.
## Без сети: подставной ответ HTTP через http_hook, время — через clock_hook.

var _calls := 0
var _headers := PackedStringArray()
var _t := 1000.0
var _reply: Array = []


func _loader() -> RasterTileLoader:
	var l := RasterTileLoader.new()
	l._ensure_cfg()
	l._cfg = l._cfg.duplicate()
	l._cfg["tile_cache_dir"] = OS.get_temp_dir().path_join("dp_raster_policy_%d" % Time.get_ticks_usec())
	l.clock_hook = func() -> float: return _t
	l.http_hook = _http
	return l


func _http(_url: String, headers: PackedStringArray) -> Array:
	_calls += 1
	_headers = headers
	return _reply


func _png() -> PackedByteArray:
	return Image.create(256, 256, false, Image.FORMAT_RGB8).save_png_to_buffer()


func _osm() -> Dictionary:
	return Config.get_config("world").map_picker.basemaps[0]


func test_user_agent_version_and_site() -> void:
	var l := _loader()
	var ua := l.user_agent()
	var ver := String(ProjectSettings.get_setting("application/config/version"))
	check(ua.contains(ver), "версия игры в UA: " + ua)
	check(not ua.contains("{version}"), "шаблон подставлен")
	check(ua.contains("https://github.com/thegriglat/deltaplan"), "адрес проекта")
	check(not ua.to_lower().contains("non-commercial"), "без non-commercial")
	l.free()


func test_header_sent() -> void:
	var l := _loader()
	_calls = 0
	_reply = [HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), _png()]
	var img: Image = await l.fetch_tile(_osm(), 5, 3, 4)
	check(img != null, "тайл получен")
	check(_headers.size() == 1 and _headers[0] == "User-Agent: " + l.user_agent(), "заголовок UA: %s" % [_headers])
	l.free()


func test_error_tile_waits_retry() -> void:
	var l := _loader()
	_calls = 0
	_t = 1000.0
	_reply = [HTTPRequest.RESULT_SUCCESS, 500, PackedStringArray(), PackedByteArray()]
	check(await l.fetch_tile(_osm(), 6, 1, 1) == null, "500 -> null")
	check(await l.fetch_tile(_osm(), 6, 1, 1) == null, "повтор сразу -> null")
	check(_calls == 1, "повтор не ушёл в сеть: %d" % _calls)
	await l.fetch_tile(_osm(), 6, 2, 2)
	check(_calls == 2, "другой тайл запрашивается: %d" % _calls)
	_t += float(l._cfg.get("retry_after_s", 60.0)) + 1.0
	await l.fetch_tile(_osm(), 6, 1, 1)
	check(_calls == 3, "после паузы повтор уходит: %d" % _calls)
	l.free()


func test_blocked_pauses_layer() -> void:
	for code in [403, 429]:
		var l := _loader()
		_calls = 0
		_t = 1000.0
		_reply = [HTTPRequest.RESULT_SUCCESS, code, PackedStringArray(), PackedByteArray()]
		check(await l.fetch_tile(_osm(), 7, 1, 1) == null, "%d -> null" % code)
		check(await l.fetch_tile(_osm(), 7, 5, 5) == null, "другой тайл слоя -> null")
		check(_calls == 1, "%d: слой на паузе, запросов %d" % [code, _calls])
		_t += float(l._cfg.get("blocked_backoff_s", 600.0)) - 1.0
		await l.fetch_tile(_osm(), 7, 6, 6)
		check(_calls == 1, "пауза ещё идёт")
		_t += 2.0
		await l.fetch_tile(_osm(), 7, 6, 6)
		check(_calls == 2, "после паузы слой снова доступен: %d" % _calls)
		l.free()


func test_blocked_other_layer_unaffected() -> void:
	var l := _loader()
	_calls = 0
	_reply = [HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(), PackedByteArray()]
	await l.fetch_tile(_osm(), 7, 1, 1)
	var topo: Dictionary = Config.get_config("world").map_picker.basemaps[1]
	await l.fetch_tile(topo, 7, 1, 1)
	check(_calls == 2, "другой слой не заблокирован: %d" % _calls)
	l.free()


func test_retry_after_header_longer() -> void:
	var l := _loader()
	_calls = 0
	_t = 1000.0
	_reply = [HTTPRequest.RESULT_SUCCESS, 429, PackedStringArray(["Retry-After: 3000"]), PackedByteArray()]
	await l.fetch_tile(_osm(), 8, 1, 1)
	_t += 2000.0
	await l.fetch_tile(_osm(), 8, 2, 2)
	check(_calls == 1, "Retry-After больше паузы по умолчанию: %d" % _calls)
	_t += 1100.0
	await l.fetch_tile(_osm(), 8, 2, 2)
	check(_calls == 2, "после Retry-After запрос уходит: %d" % _calls)
	l.free()
