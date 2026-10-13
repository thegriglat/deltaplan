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


## Текстура высот (FORMAT_RF, 32 бита) для вершинного шейдера; с мипмапами (среднее высот —
## уклон, отфильтрованный по следу пикселя: нормаль рельефа во фрагментном шейдере). Уровень 0 —
## узлы как есть (texelFetch вершин и height_at не меняются); мипы — ~5 мс и +1/3 памяти на слой.
func make_texture() -> ImageTexture:
	var img := Image.create_from_data(
		width, height, false, Image.FORMAT_RF, heights.to_byte_array()
	)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Пирамида максимумов высот (MLK-К2 v2, силуэт вдали): уровень k ≥ 1 — сетка max(1, W>>k) ×
## max(1, H>>k), тексель (i, j) — максимум узлов [i·2^k, (i+1)·2^k − 1] (последний тексель уровня
## захватывает и остаток нечётного края, без потерь). Возвращает [PackedFloat32Array уровня 1, 2, …]
## до 1×1; уровень 0 — сами heights.
func max_pyramid() -> Array:
	if _max_pyr.is_empty():
		_max_pyr = _build_max_pyramid()
	return _max_pyr


## Пирамида средних высот (как Image.generate_mipmaps для FORMAT_RF: 2×2 среднее, у нечётного края
## последний столбец/строка отбрасывается) — CPU-зеркало textureLod(height_mip_tex) для ReliefLook.
func mean_pyramid() -> Array:
	if not _mean_pyr.is_empty():
		return _mean_pyr
	var out: Array = []
	var src := heights
	var sw := width
	var sh := height
	while sw > 1 or sh > 1:
		var dw := maxi(1, sw >> 1)
		var dh := maxi(1, sh >> 1)
		var dst := PackedFloat32Array()
		dst.resize(dw * dh)
		for j in dh:
			var j0 := mini(2 * j, sh - 1)
			var j1 := mini(2 * j + 1, sh - 1)
			for i in dw:
				var i0 := mini(2 * i, sw - 1)
				var i1 := mini(2 * i + 1, sw - 1)
				dst[j * dw + i] = (
					(src[j0 * sw + i0] + src[j0 * sw + i1] + src[j1 * sw + i0] + src[j1 * sw + i1]) * 0.25
				)
		out.append(dst)
		src = dst
		sw = dw
		sh = dh
	_mean_pyr = out
	return out


## [heights, уровень 1, 2, …] пирамиды средних — цепочка мипов height_mip_tex (кешируется).
func mean_levels() -> Array:
	if _mean_levels.is_empty():
		_mean_levels = [heights]
		_mean_levels.append_array(mean_pyramid())
	return _mean_levels


## Максимум уровня k ≥ 1 пирамиды в текселе (i, j) (с обрезкой по краю); k = 0 — узел.
func max_texel(k: int, i: int, j: int) -> float:
	if k <= 0:
		return node(i, j)
	var pyr := max_pyramid()
	k = mini(k, pyr.size())
	var w := maxi(1, width >> k)
	var h := maxi(1, height >> k)
	var a: PackedFloat32Array = pyr[k - 1]
	return a[clampi(j, 0, h - 1) * w + clampi(i, 0, w - 1)]


## Текстура пирамиды максимумов: базовый уровень = уровень 1 пирамиды (уровень 0 — сама высота,
## его хранить незачем), мипы — уровни 2, 3, … (свои, max, не среднее). FORMAT_RF: ~1/3 памяти
## текстуры высот без мипов (1601² → 3,4 МБ). Пирамида на CPU не кешируется (только на время сборки).
func make_max_texture() -> ImageTexture:
	var pyr := _max_pyr if not _max_pyr.is_empty() else _build_max_pyramid()
	if pyr.is_empty():
		return null
	var data := PackedByteArray()
	for a: PackedFloat32Array in pyr:
		data.append_array(a.to_byte_array())
	var img := Image.create_from_data(
		maxi(1, width >> 1), maxi(1, height >> 1), true, Image.FORMAT_RF, data
	)
	return ImageTexture.create_from_image(img)


var _max_pyr: Array = []
var _mean_pyr: Array = []
var _mean_levels: Array = []


func _build_max_pyramid() -> Array:
	var out: Array = []
	var src := heights
	var sw := width
	var sh := height
	while sw > 1 or sh > 1:
		var dw := maxi(1, sw >> 1)
		var dh := maxi(1, sh >> 1)
		out.append(_max_level(src, sw, sh, dw, dh))
		src = out[out.size() - 1]
		sw = dw
		sh = dh
	return out


## Уровень пирамиды максимумов из src (sw×sh) в dw×dh: строки делятся по ядрам.
static func _max_level(
	src: PackedFloat32Array, sw: int, sh: int, dw: int, dh: int
) -> PackedFloat32Array:
	var rows_per := maxi(1, CHUNK / dw)
	var n_jobs := (dh + rows_per - 1) / rows_per
	var slots := []
	slots.resize(n_jobs)
	var job := func(ci: int) -> void:
		var r0: int = ci * rows_per
		var r1: int = mini(r0 + rows_per, dh)
		var out := PackedFloat32Array()
		out.resize((r1 - r0) * dw)
		for j in range(r0, r1):
			var ja := 2 * j
			var jb := sh - 1 if j == dh - 1 else 2 * j + 1   # остаток нечётного края — в последний
			var o := (j - r0) * dw
			var ra := ja * sw
			var rb := (ja + 1) * sw
			var last := dw - 1
			if jb == ja + 1:
				# обычный случай — 2×2 (кроме последнего столбца)
				for i in last:
					var c := 2 * i
					out[o + i] = maxf(maxf(src[ra + c], src[ra + c + 1]), maxf(src[rb + c], src[rb + c + 1]))
			else:
				last = 0
			for i in range(last, dw):
				var ia := 2 * i
				var ib := sw - 1 if i == dw - 1 else 2 * i + 1
				var m := -INF
				for jj in range(ja, jb + 1):
					var row := jj * sw
					for ii in range(ia, ib + 1):
						m = maxf(m, src[row + ii])
				out[o + i] = m
		slots[ci] = out
	_run_chunks(job, n_jobs)
	return _join(slots)
