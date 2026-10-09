class_name TerrariumLoader
extends Node
## Тайлы Terrarium для карты выбора точки: высота точки (elevation_at). Сборка рельефа места — DemStage.
## Источник — открытые тайлы AWS Terrain Tiles (формат Terrarium, PNG 256×256,
## высота = R·256 + G + B/256 − 32768 м). Тайлы кешируются на диск (user://terrain_cache/…),
## повторная загрузка того же района — без сети.
## Слой строится прямо в пикселях web-mercator: на 40–170 км масштаб меняется < 1 %,
## поэтому сетка считается метрической с шагом = размер пикселя на широте центра.
## Параметры — configs/world.json → runtime_terrain.

## Экваториальный радиус WGS84 для web-mercator, м (константа проекции).
const MERCATOR_R_M := 6378137.0
const TILE_PX := 256

var _cfg: Dictionary = {}
var _cancelled := false
var _requests: Array[HTTPRequest] = []


func _ensure_cfg() -> void:
	if _cfg.is_empty():
		_cfg = Config.get_config("world").get("runtime_terrain", {})


## Скачать (или взять из кеша) один тайл Terrarium. null — ошибка.
func fetch_tile(z: int, x: int, y: int) -> Image:
	_ensure_cfg()
	return await _fetch_tile(z, x, y)


## Высота, м над уровнем моря, из цвета пикселя Terrarium (каналы 0..1 в Color).
static func decode_height(c: Color) -> float:
	return roundf(c.r * 255.0) * 256.0 + roundf(c.g * 255.0) + roundf(c.b * 255.0) / 256.0 - 32768.0


## Высота билинейно по 4 соседним пикселям; px — в пикселях тайла (центр пикселя i — i + 0,5).
static func height_in_image(img: Image, px: Vector2) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var fx := px.x - 0.5
	var fy := px.y - 0.5
	var x0 := floori(fx)
	var y0 := floori(fy)
	var tx := fx - x0
	var ty := fy - y0
	var xa := clampi(x0, 0, w - 1)
	var xb := clampi(x0 + 1, 0, w - 1)
	var ya := clampi(y0, 0, h - 1)
	var yb := clampi(y0 + 1, 0, h - 1)
	var top := lerpf(decode_height(img.get_pixel(xa, ya)), decode_height(img.get_pixel(xb, ya)), tx)
	var bot := lerpf(decode_height(img.get_pixel(xa, yb)), decode_height(img.get_pixel(xb, yb)), tx)
	return lerpf(top, bot, ty)


## Высота точки, м над уровнем моря (тайл z — по умолчанию map_picker.elevation_zoom, общий кеш).
## NAN — нет данных.
func elevation_at(lat: float, lon: float, z: int = -1) -> float:
	_ensure_cfg()
	if z < 0:
		z = int(Config.get_config("world").get("map_picker", {}).get("elevation_zoom", 12))
	if absf(lat) > 85.0:
		return NAN
	var wp := MapPicker.latlon_to_world_px(lat, lon, z)
	var n := 1 << z
	var tx := clampi(floori(wp.x / TILE_PX), 0, n - 1)
	var ty := clampi(floori(wp.y / TILE_PX), 0, n - 1)
	var img: Image = await _fetch_tile(z, tx, ty)
	if img == null:
		return NAN
	return height_in_image(img, wp - Vector2(tx, ty) * TILE_PX)


## Путь к тайлу в кеше.
func cache_path(z: int, x: int, y: int) -> String:
	return String(_cfg.get("cache_dir", "user://terrain_cache")).path_join(
		"terrarium/%d/%d/%d.png" % [z, x, y]
	)


## Прервать загрузку: запросы закрываются.
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
	var res: Array = await HttpLog.fetch(
		self, url,
		PackedStringArray(["User-Agent: " + RasterTileLoader.expand_user_agent(String(_cfg.get("user_agent", "deltaplan/{version}")))]),
		"terrarium %d/%d/%d" % [z, x, y], HTTPClient.METHOD_GET, "", float(_cfg.get("timeout_s", 30.0)), _requests)
	if int(res[0]) == HTTPRequest.RESULT_CANT_CONNECT and int(res[1]) == 0 and (res[3] as PackedByteArray).is_empty():
		return {"error": "запрос %s не отправлен" % url, "kind": "network"}
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
