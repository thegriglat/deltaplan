class_name TerrariumLoader
extends Node
## Рантайм-загрузка рельефа вокруг произвольной точки (FR-17, прототип).
## Источник — открытые тайлы AWS Terrain Tiles (формат Terrarium, PNG 256×256,
## высота = R·256 + G + B/256 − 32768 м). Тайлы кешируются на диск (user://terrain_cache/…),
## повторная загрузка того же района — без сети.
## Слой строится прямо в пикселях web-mercator: на 40–170 км масштаб меняется < 1 %,
## поэтому сетка считается метрической с шагом = размер пикселя на широте центра.
## Параметры — configs/world.json → runtime_terrain.

## Скачано done тайлов из total (по всем слоям).
signal progress(done: int, total: int)

## Экваториальный радиус WGS84 для web-mercator, м (константа проекции).
const MERCATOR_R_M := 6378137.0
const TILE_PX := 256

var _cfg: Dictionary = {}
var _cancelled := false
var _requests: Array[HTTPRequest] = []
var _done_before := 0
var _total := 0


## Скачать тайлы и собрать слои. Возвращает {config, layers} или {error, kind}:
## kind — "network" (нет связи/таймаут), "nodata" (для места нет тайлов), "cancelled", "config".
## Сборка слоя из тайлов (PNG → высоты) — в рабочем потоке, главный поток не стоит.
func build_location(lat: float, lon: float, size_km: float = -1.0) -> Dictionary:
	_ensure_cfg()
	_cancelled = false
	if _cfg.is_empty():
		return {"error": "нет раздела runtime_terrain в configs/world.json", "kind": "config"}
	if absf(lat) > float(_cfg.get("max_abs_lat", 84.0)):
		return {"error": "широта %.1f° — вне проекции тайлов" % lat, "kind": "nodata"}
	var layer_cfgs: Array = _cfg.layers
	var built: Array[HeightLayer] = []
	var render := {}
	var plans: Array[Dictionary] = []
	_total = 0
	_done_before = 0
	for k in layer_cfgs.size():
		var lc: Dictionary = layer_cfgs[k]
		var size := float(lc.size_km) * 1000.0
		if k == 0 and size_km > 0.0:
			size = size_km * 1000.0
		var z := layer_zoom(lc, lat)
		plans.append(_plan_layer(String(lc.id), lat, lon, z, size, int(lc.chunk_cells)))
		_total += (plans[k].tiles as Array).size()
	for k in layer_cfgs.size():
		var lc: Dictionary = layer_cfgs[k]
		var r: Dictionary = await _build_layer(plans[k])
		if _cancelled:
			return {"error": "отменено", "kind": "cancelled"}
		if r.has("error"):
			return r
		_done_before += (plans[k].tiles as Array).size()
		built.append(r.layer)
		render[String(lc.id)] = {
			"chunk_cells": int(lc.chunk_cells),
			"lod_distances_m": lc.lod_distances_m,
			"skirt_depth_m": float(lc.skirt_depth_m),
		}
	# Стартовая точка — выбранное место, разбег вниз по склону.
	var d := built[0]
	var e := d.spacing
	var gx := d.sample(e, 0.0) - d.sample(-e, 0.0)
	var gz := d.sample(0.0, e) - d.sample(0.0, -e)
	var heading := fposmod(rad_to_deg(atan2(-gx, gz)), 360.0)
	var config := {
		"name": "%.4f, %.4f" % [lat, lon],
		"center_lat": lat,
		"center_lon": lon,
		"render": render,
		"start_sites":
		[
			{
				"id": "picked",
				"name": "Выбранная точка",
				"lat": lat,
				"lon": lon,
				"heading_deg": heading
			}
		],
		"start_position_agl_m": 0.0,
	}
	return {"config": config, "layers": built}


func _ensure_cfg() -> void:
	if _cfg.is_empty():
		_cfg = Config.get_config("world").get("runtime_terrain", {})


## Скачать (или взять из кеша) один тайл Terrarium. null — ошибка.
func fetch_tile(z: int, x: int, y: int) -> Image:
	_ensure_cfg()
	return await _fetch_tile(z, x, y)


## Путь к тайлу в кеше.
func cache_path(z: int, x: int, y: int) -> String:
	return String(_cfg.get("cache_dir", "user://terrain_cache")).path_join(
		"terrarium/%d/%d/%d.png" % [z, x, y]
	)


## Прервать загрузку: запросы закрываются, build_location вернёт {kind: "cancelled"}.
func cancel() -> void:
	_cancelled = true
	for r in _requests:
		if is_instance_valid(r):
			r.cancel_request()
			r.queue_free()
	_requests.clear()


## Уровень тайлов слоя на широте lat: zoom из конфига, но на высоких широтах пиксель
## web-mercator мельчает как cos(широта) — уровень понижается, пока шаг сетки не станет
## не мельче min_spacing_m (иначе на 70° сетка вчетверо больше, чем на 50°).
static func layer_zoom(lc: Dictionary, lat: float) -> int:
	var z := int(lc.zoom)
	var min_step := float(lc.get("min_spacing_m", 0.0))
	while z > 0 and TAU * MERCATOR_R_M * cos(deg_to_rad(lat)) / float(TILE_PX << z) < min_step:
		z -= 1
	return z


## Геометрия слоя: сетка узлов и нужные тайлы.
func _plan_layer(
	id: String, lat: float, lon: float, z: int, size_m: float, chunk_cells: int
) -> Dictionary:
	var world_px := float(TILE_PX << z)
	var gx0 := (lon + 180.0) / 360.0 * world_px
	var lat_r := deg_to_rad(lat)
	var gy0 := (1.0 - log(tan(lat_r) + 1.0 / cos(lat_r)) / PI) / 2.0 * world_px
	var spacing := TAU * MERCATOR_R_M * cos(lat_r) / world_px
	var cells := int(ceil(size_m / spacing / chunk_cells)) * chunk_cells
	var n := cells + 1
	# Узел (0,0) — пиксель px0, py0 (центры пикселей в +0.5).
	var px0 := int(floor(gx0)) - cells / 2
	var py0 := int(floor(gy0)) - cells / 2
	var tx0 := floori(px0 / float(TILE_PX))
	var ty0 := floori(py0 / float(TILE_PX))
	var tx1 := floori((px0 + n - 1) / float(TILE_PX))
	var ty1 := floori((py0 + n - 1) / float(TILE_PX))
	var tiles: Array[Vector2i] = []
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			tiles.append(Vector2i(tx, ty))
	return {
		"id": id,
		"z": z,
		"n": n,
		"spacing": spacing,
		"tiles": tiles,
		"t0": Vector2i(tx0, ty0),
		"t1": Vector2i(tx1, ty1),
		"crop": Vector2i(px0 - tx0 * TILE_PX, py0 - ty0 * TILE_PX),
		# Центр пикселя px0 + 0.5 относительно точки gx0.
		"origin": Vector2((px0 + 0.5 - gx0) * spacing, (py0 + 0.5 - gy0) * spacing),
	}


## Скачать тайлы слоя и собрать HeightLayer (сборка — в рабочем потоке). {layer} или {error, kind}.
func _build_layer(plan: Dictionary) -> Dictionary:
	var raw: Dictionary = await _fetch_all(int(plan.z), plan.tiles)
	if raw.has("error"):
		return raw
	var slot := {}
	var task := WorkerThreadPool.add_task(func() -> void: slot.merge(assemble(plan, raw)))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	return slot


## Мозаика тайлов → обрезка → высоты → HeightLayer (без сцены, годится для рабочего потока).
## raw — {Vector2i тайла: PNG-байты}. {layer} или {error, kind: "nodata"}.
static func assemble(plan: Dictionary, raw: Dictionary) -> Dictionary:
	var t0: Vector2i = plan.t0
	var t1: Vector2i = plan.t1
	var n := int(plan.n)
	var mosaic := Image.create_empty(
		(t1.x - t0.x + 1) * TILE_PX, (t1.y - t0.y + 1) * TILE_PX, false, Image.FORMAT_RGB8
	)
	for t: Vector2i in plan.tiles:
		var img := Image.new()
		if img.load_png_from_buffer(raw[t]) != OK:
			return {"error": "битый тайл %d/%d/%d" % [plan.z, t.x, t.y], "kind": "nodata"}
		img.convert(Image.FORMAT_RGB8)
		mosaic.blit_rect(
			img, Rect2i(0, 0, TILE_PX, TILE_PX), Vector2i((t.x - t0.x) * TILE_PX, (t.y - t0.y) * TILE_PX)
		)
	var crop: Vector2i = plan.crop
	var bytes := mosaic.get_region(Rect2i(crop.x, crop.y, n, n)).get_data()
	var count := bytes.size() / 3
	var heights := PackedFloat32Array()
	heights.resize(count)
	for p in count:
		var k := p * 3
		heights[p] = bytes[k] * 256.0 + bytes[k + 1] + bytes[k + 2] / 256.0 - 32768.0
	var o: Vector2 = plan.origin
	var layer := HeightLayer.from_heights(
		String(plan.id), n, n, float(plan.spacing), o.x, o.y, heights
	)
	return {"layer": layer}


## Все тайлы слоя (PNG-байты, из кеша или сети): {Vector2i: PackedByteArray} или {error, kind}.
func _fetch_all(z: int, tiles: Array[Vector2i]) -> Dictionary:
	var out := {}
	var queue := tiles.duplicate()
	var state := {"done": 0, "failed": "", "kind": ""}
	var workers := mini(int(_cfg.get("max_parallel_requests", 4)), queue.size())
	for w in workers:
		_worker(z, queue, out, state)
	while int(state.done) < tiles.size() and String(state.failed) == "" and not _cancelled:
		await get_tree().process_frame
	if _cancelled:
		return {"error": "отменено", "kind": "cancelled"}
	if String(state.failed) != "":
		return {"error": state.failed, "kind": state.kind}
	return out


func _worker(z: int, queue: Array, out: Dictionary, state: Dictionary) -> void:
	while not queue.is_empty() and String(state.failed) == "" and not _cancelled:
		var t: Vector2i = queue.pop_back()
		var r: Dictionary = await _fetch_tile_bytes(z, t.x, t.y)
		if _cancelled:
			return
		if r.has("error"):
			state.failed = r.error
			state.kind = r.kind
			return
		out[t] = r.data
		state.done = int(state.done) + 1
		progress.emit(_done_before + int(state.done), _total)


## Один тайл Terrarium: {data: PNG-байты} или {error, kind}.
func _fetch_tile_bytes(z: int, x: int, y: int) -> Dictionary:
	var n := 1 << z
	x = posmod(x, n)
	y = clampi(y, 0, n - 1)
	var path := cache_path(z, x, y)
	if FileAccess.file_exists(path):
		var cached := FileAccess.get_file_as_bytes(path)
		if not cached.is_empty():
			return {"data": cached}
	var url := String(_cfg.url_template).format({"z": z, "x": x, "y": y})
	var req := HTTPRequest.new()
	req.timeout = float(_cfg.get("timeout_s", 30.0))
	req.use_threads = true  # TLS и чтение ответа — не в главном потоке
	add_child(req)
	_requests.append(req)
	var err := req.request(
		url, PackedStringArray(["User-Agent: " + String(_cfg.get("user_agent", "deltaplan-sim"))])
	)
	if err != OK:
		_requests.erase(req)
		req.queue_free()
		return {"error": "запрос %s не отправлен (%s)" % [url, error_string(err)], "kind": "network"}
	var res: Array = await req.request_completed
	_requests.erase(req)
	req.queue_free()
	var code := int(res[1])
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("TerrariumLoader: %s → %s/%s" % [url, res[0], code])
		var nodata := int(res[0]) == HTTPRequest.RESULT_SUCCESS and code in [403, 404]
		return {
			"error": "тайл %d/%d/%d: %s/%s" % [z, x, y, res[0], code],
			"kind": "nodata" if nodata else "network"
		}
	var data: PackedByteArray = res[3]
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(data)
		f.close()
	return {"data": data}


func _fetch_tile(z: int, x: int, y: int) -> Image:
	var r: Dictionary = await _fetch_tile_bytes(z, x, y)
	if r.has("error"):
		return null
	var img := Image.new()
	if img.load_png_from_buffer(r.data) != OK:
		return null
	img.convert(Image.FORMAT_RGB8)
	return img
