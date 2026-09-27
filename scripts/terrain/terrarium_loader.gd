class_name TerrariumLoader
extends Node
## Рантайм-загрузка рельефа вокруг произвольной точки (FR-17, прототип).
## Источник — открытые тайлы AWS Terrain Tiles (формат Terrarium, PNG 256×256,
## высота = R·256 + G + B/256 − 32768 м). Тайлы кешируются на диск (user://terrain_cache/…),
## повторная загрузка того же района — без сети.
## Слой строится прямо в пикселях web-mercator: на 40–170 км масштаб меняется < 1 %,
## поэтому сетка считается метрической с шагом = размер пикселя на широте центра.
## Параметры — configs/world.json → runtime_terrain.

signal progress(done: int, total: int)

## Экваториальный радиус WGS84 для web-mercator, м (константа проекции).
const MERCATOR_R_M := 6378137.0
const TILE_PX := 256

var _cfg: Dictionary = {}
var _decoded: PackedFloat32Array


## Скачать тайлы и собрать слои. Возвращает {config, layers} или {error}.
func build_location(lat: float, lon: float, size_km: float = -1.0) -> Dictionary:
	_ensure_cfg()
	if _cfg.is_empty():
		return {"error": "нет раздела runtime_terrain в configs/world.json"}
	var layer_cfgs: Array = _cfg.layers
	var built: Array[HeightLayer] = []
	var render := {}
	for k in layer_cfgs.size():
		var lc: Dictionary = layer_cfgs[k]
		var size := float(lc.size_km) * 1000.0
		if k == 0 and size_km > 0.0:
			size = size_km * 1000.0
		var r: Dictionary = await _build_layer(
			String(lc.id), lat, lon, int(lc.zoom), size, int(lc.chunk_cells)
		)
		if r.has("error"):
			return r
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


func _build_layer(
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
	var images: Dictionary = await _fetch_all(z, tiles)
	if images.has("error"):
		return images
	var mosaic := Image.create_empty(
		(tx1 - tx0 + 1) * TILE_PX, (ty1 - ty0 + 1) * TILE_PX, false, Image.FORMAT_RGB8
	)
	for t in tiles:
		var img: Image = images[t]
		mosaic.blit_rect(
			img,
			Rect2i(0, 0, TILE_PX, TILE_PX),
			Vector2i((t.x - tx0) * TILE_PX, (t.y - ty0) * TILE_PX)
		)
	var crop := mosaic.get_region(Rect2i(px0 - tx0 * TILE_PX, py0 - ty0 * TILE_PX, n, n))
	# Декодирование RGB → высоты в отдельном потоке (≈1–2 млн пикселей).
	var bytes := crop.get_data()
	var task := WorkerThreadPool.add_task(_decode.bind(bytes))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	var heights := _decoded
	# Центр пикселя px0 + 0.5 относительно точки gx0.
	var ox := (px0 + 0.5 - gx0) * spacing
	var oz := (py0 + 0.5 - gy0) * spacing
	var layer := HeightLayer.from_heights(id, n, n, spacing, ox, oz, heights)
	return {"layer": layer}


## Декодирование Terrarium RGB → высоты, м. Выполняется в рабочем потоке; результат — в _decoded
## (Packed-массивы передаются по значению, поэтому пишем в поле объекта).
func _decode(bytes: PackedByteArray) -> void:
	var n := bytes.size() / 3
	var out := PackedFloat32Array()
	out.resize(n)
	for p in n:
		var k := p * 3
		out[p] = bytes[k] * 256.0 + bytes[k + 1] + bytes[k + 2] / 256.0 - 32768.0
	_decoded = out


func _fetch_all(z: int, tiles: Array[Vector2i]) -> Dictionary:
	var out := {}
	var queue := tiles.duplicate()
	var state := {"done": 0, "failed": ""}
	var workers := mini(int(_cfg.get("max_parallel_requests", 4)), queue.size())
	for w in workers:
		_worker(z, queue, out, state, tiles.size())
	while int(state.done) < tiles.size() and String(state.failed) == "":
		await get_tree().process_frame
	if String(state.failed) != "":
		return {"error": state.failed}
	return out


func _worker(z: int, queue: Array, out: Dictionary, state: Dictionary, total: int) -> void:
	while not queue.is_empty() and String(state.failed) == "":
		var t: Vector2i = queue.pop_back()
		var img := await _fetch_tile(z, t.x, t.y)
		if img == null:
			state.failed = "не удалось скачать тайл %d/%d/%d" % [z, t.x, t.y]
			return
		out[t] = img
		state.done = int(state.done) + 1
		progress.emit(int(state.done), total)


func _fetch_tile(z: int, x: int, y: int) -> Image:
	var n := 1 << z
	x = posmod(x, n)
	y = clampi(y, 0, n - 1)
	var path := cache_path(z, x, y)
	var data := PackedByteArray()
	if FileAccess.file_exists(path):
		data = FileAccess.get_file_as_bytes(path)
	if data.is_empty():
		var url := String(_cfg.url_template).format({"z": z, "x": x, "y": y})
		var req := HTTPRequest.new()
		req.timeout = float(_cfg.get("timeout_s", 30.0))
		add_child(req)
		var err := req.request(
			url,
			PackedStringArray(["User-Agent: " + String(_cfg.get("user_agent", "deltaplan-sim"))])
		)
		if err != OK:
			req.queue_free()
			return null
		var res: Array = await req.request_completed
		req.queue_free()
		if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
			push_warning("TerrariumLoader: %s → %s/%s" % [url, res[0], res[1]])
			return null
		data = res[3]
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(data)
			f.close()
	var img := Image.new()
	if img.load_png_from_buffer(data) != OK:
		return null
	img.convert(Image.FORMAT_RGB8)
	return img
