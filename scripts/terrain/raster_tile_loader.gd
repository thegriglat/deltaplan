class_name RasterTileLoader
extends Node
## Растровые тайлы подложки карты выбора старта (SM-К1): OpenTopoMap / OSM standard.
## Кеш на диске <tile_cache_dir>/<id>/<z>/<x>/<y>.png, не больше max_parallel_requests запросов
## одновременно (политика OSM: честный User-Agent, только видимые тайлы, без предзагрузки).
## Параметры — configs/world.json → map_picker.

var _cfg: Dictionary = {}
var _active := {}  ## id слоя → число запросов в полёте
var _next_sub := 0
var _failed_until := {}  ## "id/z/x/y" → момент (с), раньше которого тайл не запрашивается снова
var _blocked_until := {}  ## id слоя → момент (с), раньше которого слой не запрашивается (403/429)

## Шов для тестов (без сети): Callable(url: String, headers: PackedStringArray) -> Array в формате
## request_completed [result, код, заголовки, тело]; допускается await внутри. Пусто — реальный HTTP.
var http_hook: Callable = Callable()
## Шов для тестов: Callable() -> float, секунды. Пусто — Time.get_ticks_msec().
var clock_hook: Callable = Callable()


func _ensure_cfg() -> void:
	if _cfg.is_empty():
		_cfg = Config.get_config("world").get("map_picker", {})


## Тайл слоя basemap (элемент map_picker.basemaps). null — нет сети/ошибка.
## z выше max_zoom слоя — растягивается тайл max_zoom (результат всё равно 256×256).
func fetch_tile(basemap: Dictionary, z: int, x: int, y: int) -> Image:
	_ensure_cfg()
	var max_z := int(basemap.get("max_zoom", 17))
	if z > max_z:
		var d := z - max_z
		var base: Image = await fetch_tile(basemap, max_z, x >> d, y >> d)
		if base == null:
			return null
		var cell := 256 >> d
		if cell < 1:
			return null
		var part := base.get_region(Rect2i((x & ((1 << d) - 1)) * cell, (y & ((1 << d) - 1)) * cell, cell, cell))
		part.resize(256, 256, Image.INTERPOLATE_BILINEAR)
		return part
	var n := 1 << z
	x = posmod(x, n)
	if y < 0 or y >= n:
		return null
	var path := cache_path(basemap, z, x, y)
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) == OK:
			img.convert(Image.FORMAT_RGB8)
			return img
	var id := String(basemap.id)
	var fail_key := "%s/%d/%d/%d" % [id, z, x, y]
	var now := _now()
	if now < float(_blocked_until.get(id, 0.0)) or now < float(_failed_until.get(fail_key, 0.0)):
		return null
	var max_par := mini(int(_cfg.get("max_parallel_requests", 4)), int(basemap.get("max_parallel", 1 << 30)))
	max_par = maxi(max_par, 1)
	while int(_active.get(id, 0)) >= max_par:
		await get_tree().process_frame
		if not is_inside_tree():
			return null
		if _now() < float(_blocked_until.get(id, 0.0)):
			return null
	_active[id] = int(_active.get(id, 0)) + 1
	var data := await _download(basemap, z, x, y)
	_active[id] = int(_active[id]) - 1
	if data.is_empty():
		_failed_until[fail_key] = _now() + float(_cfg.get("retry_after_s", 60.0))
		return null
	var im := Image.new()
	if im.load_png_from_buffer(data) != OK:
		return null
	im.convert(Image.FORMAT_RGB8)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(data)
		f.close()
	return im


func cache_path(basemap: Dictionary, z: int, x: int, y: int) -> String:
	return String(_cfg.get("tile_cache_dir", "user://map_cache")).path_join(
		"%s/%d/%d/%d.png" % [basemap.id, z, x, y]
	)


func tile_url(basemap: Dictionary, z: int, x: int, y: int) -> String:
	var subs: Array = basemap.get("subdomains", [])
	var s := ""
	if not subs.is_empty():
		s = String(subs[_next_sub % subs.size()])
		_next_sub += 1
	return String(basemap.url_template).format({"z": z, "x": x, "y": y, "s": s})


func _now() -> float:
	if clock_hook.is_valid():
		return float(clock_hook.call())
	return Time.get_ticks_msec() / 1000.0


## Заголовок User-Agent: шаблон map_picker.user_agent, {version} — application/config/version.
func user_agent() -> String:
	_ensure_cfg()
	return expand_user_agent(String(_cfg.get("user_agent", "deltaplan/{version}")))


## Подставляет {version} (application/config/version) в шаблон User-Agent; общая для всех загрузчиков.
static func expand_user_agent(template: String) -> String:
	var ver := String(ProjectSettings.get_setting("application/config/version", "0"))
	return template.replace("{version}", ver)


func _download(basemap: Dictionary, z: int, x: int, y: int) -> PackedByteArray:
	var url := tile_url(basemap, z, x, y)
	var headers := PackedStringArray(["User-Agent: " + user_agent()])
	var res: Array
	if http_hook.is_valid():
		res = await http_hook.call(url, headers)
	else:
		var req := HTTPRequest.new()
		req.timeout = float(_cfg.get("timeout_s", 20.0))
		req.use_threads = true
		add_child(req)
		if req.request(url, headers) != OK:
			req.queue_free()
			return PackedByteArray()
		res = await req.request_completed
		req.queue_free()
	var code := int(res[1])
	if int(res[0]) == HTTPRequest.RESULT_SUCCESS and (code == 403 or code == 429):
		var pause := float(_cfg.get("blocked_backoff_s", 600.0))
		pause = maxf(pause, _retry_after(res[2]))
		_blocked_until[String(basemap.id)] = _now() + pause
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or code != 200:
		return PackedByteArray()
	return res[3]


## Retry-After (секунды, целое) из заголовков ответа; 0 — нет или не число.
func _retry_after(headers: PackedStringArray) -> float:
	for h in headers:
		if h.to_lower().begins_with("retry-after:"):
			var v := h.substr(12).strip_edges()
			return float(v) if v.is_valid_int() else 0.0
	return 0.0
