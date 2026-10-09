class_name CogReader
extends RefCounted
## Разбор заголовка Cloud Optimized GeoTIFF (без сети): уровни (основной + обзорные),
## тайлы, геопривязка. Хватает для ESA WorldCover: классический TIFF little-endian, 8 бит,
## 1 канал, тайлы, сжатие Deflate или без сжатия. То же на Python — tools/terrain/cog.py.
## Для Copernicus DEM GLO-30 — float32, Deflate, предиктор 3 (floating point), тайлы 1024×1024:
## decode_tile_f32. Скачивание тайлов — WorldCoverLoader и DemStage (HTTP range или локальный файл).

const _TAG_WIDTH := 256
const _TAG_BITS := 258
const _TAG_SAMPLE_FORMAT := 339
const _TAG_HEIGHT := 257
const _TAG_COMPRESSION := 259
const _TAG_PREDICTOR := 317
const _TAG_TILE_W := 322
const _TAG_TILE_H := 323
const _TAG_TILE_OFFSETS := 324
const _TAG_TILE_COUNTS := 325
const _TAG_PIXEL_SCALE := 33550
const _TAG_TIEPOINT := 33922
const _TYPE_SIZE := {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 12: 8, 16: 8}

## Уровни: {width, height, tile_w, tile_h, offsets: PackedInt64Array, counts, compression}.
var levels: Array[Dictionary] = []
## Размер пикселя уровня 0 в градусах (по долготе, по широте).
var pixel_deg: Vector2 = Vector2.ZERO
## Долгота/широта верхнего левого угла пикселя (0, 0).
var origin_lon: float = 0.0
var origin_lat: float = 0.0
## Ошибка разбора ("" — всё хорошо). Если заголовок не поместился в данные — "need_more".
var error: String = ""


## Разобрать заголовок. head — первые байты файла (COG кладёт все IFD в начало).
static func parse(head: PackedByteArray) -> CogReader:
	var r := CogReader.new()
	r._parse(head)
	return r


func is_valid() -> bool:
	return error == "" and not levels.is_empty()


## Уровень, у которого пиксель по широте не крупнее max_pixel_m (метры), самый грубый из таких.
func level_for(max_pixel_m: float) -> int:
	var best := 0
	for k in levels.size():
		var px_m: float = pixel_deg.y * float(levels[0].width) / float(levels[k].width) * 111195.0
		if px_m <= max_pixel_m:
			best = k
	return best


## Пиксель уровня level для точки (lat, lon): Vector2i (столбец, строка), может быть вне файла.
func pixel_of(level: int, lat: float, lon: float) -> Vector2i:
	var k: float = float(levels[0].width) / float(levels[level].width)
	return Vector2i(
		floori((lon - origin_lon) / (pixel_deg.x * k)),
		floori((origin_lat - lat) / (pixel_deg.y * k))
	)


## Номер тайла в массивах offsets/counts.
func tile_index(level: int, tx: int, ty: int) -> int:
	var lv: Dictionary = levels[level]
	var cols: int = (int(lv.width) + int(lv.tile_w) - 1) / int(lv.tile_w)
	return ty * cols + tx


## Распаковать тайл (raw — байты из файла). Пустой массив — ошибка.
func decode_tile(level: int, raw: PackedByteArray) -> PackedByteArray:
	var lv: Dictionary = levels[level]
	var n: int = int(lv.tile_w) * int(lv.tile_h)
	if raw.is_empty():
		var z := PackedByteArray()
		z.resize(n)
		return z
	var comp: int = int(lv.compression)
	if comp == 8 or comp == 32946:
		return raw.decompress(n, FileAccess.COMPRESSION_DEFLATE)
	if comp == 1:
		return raw.slice(0, n)
	return PackedByteArray()


## Распаковать тайл float32 (raw — байты из файла): Deflate или без сжатия, предиктор 3 (байты float
## разложены по плоскостям и разностно закодированы по строке). Результат tile_w·tile_h значений,
## строки сверху вниз. Пустой массив — ошибка. Потокобезопасно (без общего состояния).
func decode_tile_f32(level: int, raw: PackedByteArray) -> PackedFloat32Array:
	var lv: Dictionary = levels[level]
	var tw: int = int(lv.tile_w)
	var th: int = int(lv.tile_h)
	var n: int = tw * th * 4
	if not bool(lv.float32):
		return PackedFloat32Array()
	if raw.is_empty():
		var z := PackedFloat32Array()
		z.resize(tw * th)
		return z
	var comp: int = int(lv.compression)
	var d: PackedByteArray
	if comp == 8 or comp == 32946:
		d = raw.decompress(n, FileAccess.COMPRESSION_DEFLATE)
	elif comp == 1:
		d = raw.slice(0, n)
	if d.size() != n:
		return PackedFloat32Array()
	if int(lv.predictor) == 3:
		var out := PackedByteArray()
		out.resize(n)
		var row_bytes: int = tw * 4
		for r in th:
			var base: int = r * row_bytes
			var acc := 0
			# Плоскость b = 0 — старшие байты; результат little-endian.
			for b in 4:
				var src: int = base + b * tw
				var dst: int = base + 3 - b
				for k in tw:
					acc = (acc + d[src + k]) & 255
					out[dst + k * 4] = acc
		d = out
	return d.to_float32_array()


func _parse(h: PackedByteArray) -> void:
	if h.size() < 8 or h[0] != 0x49 or h[1] != 0x49 or h.decode_u16(2) != 42:
		error = "не little-endian TIFF"
		return
	var off := int(h.decode_u32(4))
	while off != 0:
		if off + 2 > h.size():
			error = "need_more"
			return
		var n: int = h.decode_u16(off)
		if off + 2 + n * 12 + 4 > h.size():
			error = "need_more"
			return
		var tags := {}
		for i in n:
			var e := off + 2 + i * 12
			var tag: int = h.decode_u16(e)
			var vals: Variant = _values(h, h.decode_u16(e + 2), int(h.decode_u32(e + 4)), e + 8)
			if vals == null:
				return
			tags[tag] = vals
		if not (tags.has(_TAG_TILE_OFFSETS) and tags.has(_TAG_TILE_W)):
			error = "TIFF без тайлов"
			return
		var bits: int = int(tags.get(_TAG_BITS, [8])[0])
		var is_float: bool = int(tags.get(_TAG_SAMPLE_FORMAT, [1])[0]) == 3 and bits == 32
		var predictor: int = int(tags.get(_TAG_PREDICTOR, [1])[0])
		if predictor != 1 and not (predictor == 3 and is_float):
			error = "предиктор TIFF не поддержан"
			return
		(
			levels
			. append(
				{
					"width": int(tags[_TAG_WIDTH][0]),
					"height": int(tags[_TAG_HEIGHT][0]),
					"tile_w": int(tags[_TAG_TILE_W][0]),
					"tile_h": int(tags[_TAG_TILE_H][0]),
					"offsets": tags[_TAG_TILE_OFFSETS],
					"counts": tags[_TAG_TILE_COUNTS],
					"compression": int(tags.get(_TAG_COMPRESSION, [1])[0]),
					"predictor": predictor,
					"float32": is_float,
				}
			)
		)
		if tags.has(_TAG_PIXEL_SCALE):
			pixel_deg = Vector2(tags[_TAG_PIXEL_SCALE][0], tags[_TAG_PIXEL_SCALE][1])
			origin_lon = float(tags[_TAG_TIEPOINT][3])
			origin_lat = float(tags[_TAG_TIEPOINT][4])
		off = int(h.decode_u32(off + 2 + n * 12))
	if pixel_deg == Vector2.ZERO:
		error = "нет геопривязки"


## Значения тега (массив чисел). null — не хватает байтов (error = "need_more").
func _values(h: PackedByteArray, typ: int, cnt: int, at: int) -> Variant:
	var size: int = int(_TYPE_SIZE.get(typ, 1)) * cnt
	var p := at if size <= 4 else int(h.decode_u32(at))
	if p + size > h.size():
		error = "need_more"
		return null
	var out := []
	if typ == 2:
		return out
	for k in cnt:
		match typ:
			1:
				out.append(h[p + k])
			3:
				out.append(h.decode_u16(p + k * 2))
			4:
				out.append(int(h.decode_u32(p + k * 4)))
			12:
				out.append(h.decode_double(p + k * 8))
			16:
				out.append(h.decode_u64(p + k * 8))
			_:
				out.append(0)
	return out
