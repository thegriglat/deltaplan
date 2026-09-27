class_name WorldCoverLoader
extends Node
## Рантайм-загрузка карты поверхности (VR-4) для рельефа вокруг произвольной точки (FR-17):
## ESA WorldCover 10 м (COG на AWS), только нужные тайлы 1024×1024 через HTTP range-запросы
## нужного обзорного уровня. Заголовки и тайлы кешируются на диск (surface.runtime.cache_dir).
## Если сеть недоступна или данных нет — возвращает null, Terrain берёт процедурную карту.
## Параметры — configs/world.json → surface.worldcover, surface.runtime.

## Сколько байт начала файла читать как заголовок (COG хранит все IFD в начале).
const HEADER_BYTES := 65536

var _wc: Dictionary = {}
var _rt: Dictionary = {}
var _lut := PackedByteArray()
## Разобранные заголовки: url → CogReader (null — файла нет).
var _cogs: Dictionary = {}
var _result: PackedByteArray


## Построить карту для слоя высот. center — lat/lon центра локации (как в Terrain).
## null — не удалось (нет сети, нет данных).
func build_surface(layer: HeightLayer, center_lat: float, center_lon: float) -> SurfaceLayer:
	_ensure_cfg()
	if not bool(_rt.get("enabled", true)):
		return null
	var step := layer.spacing * maxf(1.0, float(_rt.get("cell_factor", 2)))
	var w := int(floor(layer.size_x() / step)) + 1
	var h := int(floor(layer.size_z() / step)) + 1
	# Углы в градусах → файлы WorldCover (3°×3°) и нужные тайлы.
	var nw := TerrainGeo.local_to_latlon(layer.origin_x, layer.origin_z, center_lat, center_lon)
	var se := TerrainGeo.local_to_latlon(
		layer.origin_x + layer.size_x(), layer.origin_z + layer.size_z(), center_lat, center_lon
	)
	var files: Array[Dictionary] = []
	for la in range(floori(se.x / 3.0) * 3, floori(nw.x / 3.0) * 3 + 1, 3):
		for lo in range(floori(nw.y / 3.0) * 3, floori(se.y / 3.0) * 3 + 1, 3):
			var url := String(_wc.url_template).format({"tile": tile_name(la, lo)})
			var cog: CogReader = await _open(url)
			if cog == null:
				continue
			var level := cog.level_for(step)
			var tiles: Dictionary = await _fetch_tiles(url, cog, level, nw, se)
			if tiles.is_empty():
				return null
			files.append({"cog": cog, "level": level, "tiles": tiles})
	if files.is_empty():
		return null
	var args := [w, h, step, layer.origin_x, layer.origin_z, center_lat, center_lon, files]
	var task := WorkerThreadPool.add_task(_sample.bindv(args))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	var s := SurfaceLayer.from_classes(
		layer.id, w, h, step, layer.origin_x, layer.origin_z, _result
	)
	s.source = "worldcover_runtime"
	return s


## Имя файла WorldCover по юго-западному углу 3°×3°: N51E084, S12W077.
static func tile_name(lat_i: int, lon_i: int) -> String:
	return (
		"%s%02d%s%03d"
		% ["N" if lat_i >= 0 else "S", absi(lat_i), "E" if lon_i >= 0 else "W", absi(lon_i)]
	)


func _ensure_cfg() -> void:
	if not _wc.is_empty():
		return
	var surf: Dictionary = Config.get_config("world").get("surface", {})
	_wc = surf.get("worldcover", {})
	_rt = surf.get("runtime", {})
	_lut.resize(256)
	var classes: Dictionary = _wc.get("classes", {})
	for code in classes:
		_lut[int(code)] = int(classes[code])


func _cache_path(url: String, name: String) -> String:
	return String(_rt.get("cache_dir", "user://terrain_cache/worldcover")).path_join(
		url.get_file().get_basename().path_join(name)
	)


func _open(url: String) -> CogReader:
	if _cogs.has(url):
		return _cogs[url]
	var head: PackedByteArray = await _get_cached(url, "header.bin", 0, HEADER_BYTES)
	var cog: CogReader = null
	if not head.is_empty():
		cog = CogReader.parse(head)
		if not cog.is_valid():
			push_warning("WorldCoverLoader: %s — %s" % [url.get_file(), cog.error])
			cog = null
	_cogs[url] = cog
	return cog


## Скачать тайлы уровня level, покрывающие прямоугольник nw..se (lat, lon).
## Возвращает {Vector2i(tx, ty): PackedByteArray (распакованные коды WorldCover)},
## {} — ошибка.
func _fetch_tiles(url: String, cog: CogReader, level: int, nw: Vector2, se: Vector2) -> Dictionary:
	var lv := cog.levels[level]
	var p0 := cog.pixel_of(level, nw.x, nw.y)
	var p1 := cog.pixel_of(level, se.x, se.y)
	var tw := int(lv.tile_w)
	var th := int(lv.tile_h)
	var queue: Array[Vector2i] = []
	for ty in range(maxi(0, p0.y / th), mini(int(lv.height) - 1, p1.y) / th + 1):
		for tx in range(maxi(0, p0.x / tw), mini(int(lv.width) - 1, p1.x) / tw + 1):
			queue.append(Vector2i(tx, ty))
	var out := {}
	var state := {"left": queue.size(), "failed": false}
	for k in mini(int(_rt.get("max_parallel_requests", 4)), queue.size()):
		_tile_worker(url, cog, level, queue, out, state)
	while int(state.left) > 0 and not bool(state.failed):
		await get_tree().process_frame
	return {} if bool(state.failed) else out


func _tile_worker(
	url: String,
	cog: CogReader,
	level: int,
	queue: Array[Vector2i],
	out: Dictionary,
	state: Dictionary
) -> void:
	while not queue.is_empty() and not bool(state.failed):
		var t: Vector2i = queue.pop_back()
		var idx := cog.tile_index(level, t.x, t.y)
		var off := int(cog.levels[level].offsets[idx])
		var cnt := int(cog.levels[level].counts[idx])
		var raw := PackedByteArray()
		if cnt > 0:
			raw = await _get_cached(url, "L%d_%d_%d.bin" % [level, t.x, t.y], off, cnt)
			if raw.is_empty():
				state.failed = true
				return
		var data := cog.decode_tile(level, raw)
		if data.is_empty():
			state.failed = true
			return
		out[t] = data
		state.left = int(state.left) - 1


## Байты [start, start + size) файла url — из кеша или range-запросом. Пусто — ошибка.
func _get_cached(url: String, name: String, start: int, size: int) -> PackedByteArray:
	var path := _cache_path(url, name)
	if FileAccess.file_exists(path):
		return FileAccess.get_file_as_bytes(path)
	var req := HTTPRequest.new()
	req.timeout = float(_rt.get("timeout_s", 30.0))
	add_child(req)
	var ua := String(Config.value("world", "runtime_terrain").get("user_agent", "deltaplan-sim"))
	var headers := PackedStringArray(
		["User-Agent: " + ua, "Range: bytes=%d-%d" % [start, start + size - 1]]
	)
	if req.request(url, headers) != OK:
		req.queue_free()
		return PackedByteArray()
	var res: Array = await req.request_completed
	req.queue_free()
	var code := int(res[1])
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or (code != 206 and code != 200):
		push_warning("WorldCoverLoader: %s → %s/%s" % [url.get_file(), res[0], code])
		return PackedByteArray()
	var data: PackedByteArray = res[3]
	if code == 200:
		data = data.slice(start, start + size)  # сервер отдал весь файл
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(data)
		f.close()
	return data


## Выборка классов в узлах сетки (рабочий поток). Результат — в _result.
func _sample(
	w: int,
	h: int,
	step: float,
	ox: float,
	oz: float,
	lat0: float,
	lon0: float,
	files: Array[Dictionary]
) -> void:
	var out := PackedByteArray()
	out.resize(w * h)
	for j in h:
		for i in w:
			var ll := TerrainGeo.local_to_latlon(ox + i * step, oz + j * step, lat0, lon0)
			for f in files:
				var cog: CogReader = f.cog
				var level := int(f.level)
				var lv := cog.levels[level]
				var p := cog.pixel_of(level, ll.x, ll.y)
				if p.x < 0 or p.y < 0 or p.x >= int(lv.width) or p.y >= int(lv.height):
					continue
				var tw := int(lv.tile_w)
				var th := int(lv.tile_h)
				var tile: PackedByteArray = f.tiles.get(
					Vector2i(p.x / tw, p.y / th), PackedByteArray()
				)
				if not tile.is_empty():
					out[j * w + i] = _lut[tile[(p.y % th) * tw + (p.x % tw)]]
				break
	_result = out
