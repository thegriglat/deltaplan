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


## Загрузить слой из файла .f32.br (float32 LE, brotli; встроенные места) или .f32.zst (zstd;
## кеш мест, OA-К1) по описанию из meta.json. Способ распаковки — по расширению.
static func load_from_file(path: String, info: Dictionary) -> HeightLayer:
	var w := int(info.width)
	var h := int(info.height)
	var packed := FileAccess.get_file_as_bytes(path)
	if packed.is_empty():
		push_error("HeightLayer: не прочитан %s" % path)
		return null
	var mode := FileAccess.COMPRESSION_ZSTD if path.ends_with(".zst") else FileAccess.COMPRESSION_BROTLI
	var raw := packed.decompress(w * h * 4, mode)
	if raw.size() != w * h * 4:
		push_error("HeightLayer: неверный размер данных %s: %d" % [path, raw.size()])
		return null
	var l := HeightLayer.new()
	l.id = String(info.id)
	l.width = w
	l.height = h
	l.spacing = float(info.spacing_m)
	l.origin_x = float(info.origin_x_m)
	l.origin_z = float(info.origin_z_m)
	l._inv_spacing = 1.0 / l.spacing
	l.heights = raw.to_float32_array()
	l.min_h = float(info.get("min_height_m", 0.0))
	l.max_h = float(info.get("max_height_m", 0.0))
	if l.max_h <= l.min_h:
		l.update_min_max()
	return l


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
