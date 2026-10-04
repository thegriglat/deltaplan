class_name RasterTileLoader
extends Node
## Растровые тайлы подложки карты выбора старта (SM-К1): OpenTopoMap / OSM standard.
## Кеш на диске <tile_cache_dir>/<id>/<z>/<x>/<y>.png, не больше max_parallel_requests запросов
## одновременно (политика OSM: честный User-Agent, только видимые тайлы, без предзагрузки).
## Параметры — configs/world.json → map_picker.

var _cfg: Dictionary = {}
var _active := 0
var _next_sub := 0


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
	var max_par := int(_cfg.get("max_parallel_requests", 4))
	while _active >= max_par:
		await get_tree().process_frame
		if not is_inside_tree():
			return null
	_active += 1
	var data := await _download(basemap, z, x, y)
	_active -= 1
	if data.is_empty():
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


func _download(basemap: Dictionary, z: int, x: int, y: int) -> PackedByteArray:
	var req := HTTPRequest.new()
	req.timeout = float(_cfg.get("timeout_s", 20.0))
	req.use_threads = true
	add_child(req)
	var err := req.request(
		tile_url(basemap, z, x, y),
		PackedStringArray(["User-Agent: " + String(_cfg.get("user_agent", "deltaplan-sim"))])
	)
	if err != OK:
		req.queue_free()
		return PackedByteArray()
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return PackedByteArray()
	return res[3]
