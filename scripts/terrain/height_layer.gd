class_name HeightLayer
extends RefCounted
## Регулярная сетка высот (один слой рельефа).
## Узел (i, j): x = origin_x + i·spacing, z = origin_z + j·spacing.
## Строки идут с севера на юг (j растёт к +Z), столбцы с запада на восток.

var id: String = ""
var width: int = 0
var height: int = 0
var spacing: float = 1.0
var origin_x: float = 0.0
var origin_z: float = 0.0
var min_h: float = 0.0
var max_h: float = 0.0
var heights: PackedFloat32Array = PackedFloat32Array()
## Маска рек (0..1) на той же сетке или null.
var water_texture: Texture2D

var _inv_spacing: float = 1.0


## Создать слой из готового массива высот (width·height значений).
static func from_heights(
	layer_id: String, w: int, h: int, step: float, ox: float, oz: float, data: PackedFloat32Array
) -> HeightLayer:
	var l := HeightLayer.new()
	l.id = layer_id
	l.width = w
	l.height = h
	l.spacing = step
	l.origin_x = ox
	l.origin_z = oz
	l.heights = data
	l._inv_spacing = 1.0 / step
	l.update_min_max()
	return l


## Загрузить слой из файла <id>.webp (N5: WebP lossless, RGB8, код v = R·65536 + G·256 + B,
## h = height_min_m + v·height_step_m) по описанию из meta.json.
static func load_from_file(path: String, info: Dictionary) -> HeightLayer:
	var w := int(info.width)
	var h := int(info.height)
	var img := _read_webp(path)
	if img == null:
		push_error("HeightLayer: не прочитан %s" % path)
		return null
	if img.get_width() != w or img.get_height() != h:
		push_error("HeightLayer: неверный размер данных %s: %dx%d" % [path, img.get_width(), img.get_height()])
		return null
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	var l := HeightLayer.new()
	l.id = String(info.id)
	l.width = w
	l.height = h
	l.spacing = float(info.spacing_m)
	l.origin_x = float(info.origin_x_m)
	l.origin_z = float(info.origin_z_m)
	l._inv_spacing = 1.0 / l.spacing
	l.heights = decode_rgb24(img.get_data(), w * h, float(info.height_min_m), float(info.height_step_m))
	l.min_h = float(info.get("min_height_m", 0.0))
	l.max_h = float(info.get("max_height_m", 0.0))
	if l.max_h <= l.min_h:
		l.update_min_max()
	return l


## Все слои сразу (файлы читаются параллельно): [HeightLayer или null] в порядке infos.
static func load_files(dir: String, infos: Array) -> Array:
	var out := []
	out.resize(infos.size())
	var job := func(i: int) -> void:
		out[i] = load_from_file(dir.path_join(String(infos[i].file)), infos[i])
	var gid := WorkerThreadPool.add_group_task(job, infos.size(), -1, true)
	WorkerThreadPool.wait_for_group_task_completion(gid)
	return out


static func _read_webp(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	var img := Image.new()
	if bytes.is_empty() or img.load_webp_from_buffer(bytes) != OK:
		return null
	return img


## Высоты (float32) -> картинка RGB8 с 24-битным кодом от минимума. Код вне 0..2^24-1 обрезается.
static func encode_rgb24(h: PackedFloat32Array, w: int, hh: int, h_min: float, step: float) -> Image:
	var n := h.size()
	var inv := 1.0 / step
	var slots := _chunk_slots(n)
	var job := func(ci: int) -> void:
		var a: int = ci * CHUNK
		var b: int = mini(a + CHUNK, n)
		var out := PackedByteArray()
		out.resize((b - a) * 3)
		var o := 0
		for k in range(a, b):
			var v := clampi(int(roundf((h[k] - h_min) * inv)), 0, 0xFFFFFF)
			out[o] = v >> 16
			out[o + 1] = (v >> 8) & 255
			out[o + 2] = v & 255
			o += 3
		slots[ci] = out
	_run_chunks(job, slots.size())
	return Image.create_from_data(w, hh, false, Image.FORMAT_RGB8, _join(slots))


## RGB8-байты (3 на клетку) -> высоты; работа делится по ядрам.
static func decode_rgb24(data: PackedByteArray, n: int, h_min: float, step: float) -> PackedFloat32Array:
	var slots := _chunk_slots(n)
	var job := func(ci: int) -> void:
		var a: int = ci * CHUNK
		var b: int = mini(a + CHUNK, n)
		var out := PackedFloat32Array()
		out.resize(b - a)
		var o := a * 3
		for k in b - a:
			out[k] = h_min + step * float((data[o] << 16) | (data[o + 1] << 8) | data[o + 2])
			o += 3
		slots[ci] = out
	_run_chunks(job, slots.size())
	return _join(slots)


const CHUNK := 1 << 14


static func _chunk_slots(n: int) -> Array:
	var slots := []
	slots.resize(maxi(1, (n + CHUNK - 1) / CHUNK))
	return slots


static func _run_chunks(job: Callable, count: int) -> void:
	var gid := WorkerThreadPool.add_group_task(job, count, -1, true)
	WorkerThreadPool.wait_for_group_task_completion(gid)


static func _join(slots: Array) -> Variant:
	var out = slots[0]
	for i in range(1, slots.size()):
		out.append_array(slots[i])
	return out


func update_min_max() -> void:
	if heights.is_empty():
		return
	var lo := heights[0]
	var hi := heights[0]
	for v in heights:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	min_h = lo
	max_h = hi


func size_x() -> float:
	return (width - 1) * spacing


func size_z() -> float:
	return (height - 1) * spacing


func contains(x: float, z: float) -> bool:
	return x >= origin_x and z >= origin_z and x <= origin_x + size_x() and z <= origin_z + size_z()


## Высота в узле сетки (с обрезкой по краю).
func node(i: int, j: int) -> float:
	i = clampi(i, 0, width - 1)
	j = clampi(j, 0, height - 1)
	return heights[j * width + i]


## Билинейная интерполяция. За краем — значение края.
func sample(x: float, z: float) -> float:
	var fx := clampf((x - origin_x) * _inv_spacing, 0.0, width - 1.0)
	var fz := clampf((z - origin_z) * _inv_spacing, 0.0, height - 1.0)
	var i := mini(int(fx), width - 2)
	var j := mini(int(fz), height - 2)
	var tx := fx - i
	var tz := fz - j
	var k := j * width + i
	var a := heights[k]
	var b := heights[k + 1]
	var c := heights[k + width]
	var d := heights[k + width + 1]
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)


## Текстура высот (FORMAT_RF, 32 бита) для вершинного шейдера.
func make_texture() -> ImageTexture:
	var img := Image.create_from_data(
		width, height, false, Image.FORMAT_RF, heights.to_byte_array()
	)
	return ImageTexture.create_from_image(img)
