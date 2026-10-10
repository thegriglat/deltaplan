class_name SurfaceLayer
extends RefCounted
## Карта поверхности (земной покров, VR-4): регулярная сетка классов.
## Узел (i, j): x = origin_x + i·spacing, z = origin_z + j·spacing; строки с севера на юг.
## Класс в точке — ближайший узел (клетка узла — квадрат со стороной spacing вокруг него).
## Из этой карты берутся и цвет земли (шейдер рельефа), и деревья, и сила источников термиков.

## Классы поверхности (значения в файле/текстуре).
const NONE := 0
const FOREST := 1
const GRASS := 2
const CROP := 3
const SHRUB := 4
const BARE := 5
const WATER := 6
const BUILT := 7
const SNOW := 8
const CLASS_COUNT := 9
## Имена классов — ключи в configs/world.json → surface.thermal.class_strength.
const CLASS_NAMES: PackedStringArray = [
	"none", "forest", "grass", "crop", "shrub", "bare", "water", "built", "snow"
]

var id: String = ""
var width: int = 0
var height: int = 0
var spacing: float = 1.0
var origin_x: float = 0.0
var origin_z: float = 0.0
## Классы узлов, width·height байт.
var classes: PackedByteArray = PackedByteArray()
## Откуда карта: "worldcover", "worldcover_runtime", "procedural".
var source: String = ""

## Маска «деталь 10 м» (T02/T03, <слой>_detail10.webp): RG8, R — доля леса в клетке (0..255, T02),
## G — доля воды (0..255, T03: реки/ручьи/каналы/озёра OSM, tools/terrain/osm_water.py).
## Узел (i, j): x = mask_origin_x + i·mask_spacing (как у карты классов).
## Пустая — маски нет (рантайм-локации, дальние слои). Снаружи — через forest_mask_image().
var mask_image: Image
var mask_width: int = 0
var mask_height: int = 0
var mask_spacing: float = 10.0
var mask_origin_x: float = 0.0
var mask_origin_z: float = 0.0
## Полуширина порога кромки (terrain_look.forest_edge_soft, как в шейдере).
var mask_edge_soft: float = 0.12

var _inv_spacing: float = 1.0
var _mask_data: PackedByteArray = PackedByteArray()
var _mask_dirty := false


static func from_classes(
	layer_id: String, w: int, h: int, step: float, ox: float, oz: float, data: PackedByteArray
) -> SurfaceLayer:
	var s := SurfaceLayer.new()
	s.id = layer_id
	s.width = w
	s.height = h
	s.spacing = step
	s.origin_x = ox
	s.origin_z = oz
	s.classes = data
	s._inv_spacing = 1.0 / step
	return s


## Загрузить из WebP lossless (N5; значение пикселя = класс, канал R) по описанию из surface.json.
## Файл читается байтами (в проекте он не импортируется: importer="keep").
static func load_webp(path: String, info: Dictionary) -> SurfaceLayer:
	var bytes := FileAccess.get_file_as_bytes(path)
	var img := Image.new()
	if bytes.is_empty() or img.load_webp_from_buffer(bytes) != OK:
		push_error("SurfaceLayer: не прочитан %s" % path)
		return null
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_L8)
	var w := int(info.width)
	var h := int(info.height)
	if img.get_width() != w or img.get_height() != h:
		push_error("SurfaceLayer: размер %s не совпадает с surface.json" % path)
		return null
	var s := from_classes(
		String(info.id),
		w,
		h,
		float(info.spacing_m),
		float(info.origin_x_m),
		float(info.origin_z_m),
		img.get_data()
	)
	s.source = "worldcover"
	return s


## Прочитать WebP маски 10 м (можно в рабочем потоке), null — ошибка. Результат — LA8
## (в файле RGBA8: R = G = B = L, A = вода).
static func decode_detail10(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	var img := Image.new()
	if bytes.is_empty() or img.load_webp_from_buffer(bytes) != OK:
		push_error("SurfaceLayer: не прочитана маска %s" % path)
		return null
	if img.get_format() != Image.FORMAT_LA8:
		img.convert(Image.FORMAT_LA8)
	return img


## Подключить маску 10 м из WebP по описанию surface.json → detail10.
## img — уже прочитанная маска (decode_detail10), null — прочитать здесь.
func load_detail10(path: String, info: Dictionary, img: Image = null) -> bool:
	if img == null:
		img = decode_detail10(path)
	if img == null:
		return false
	var w := int(info.width)
	var h := int(info.height)
	if img.get_width() != w or img.get_height() != h:
		push_error("SurfaceLayer: размер %s не совпадает с surface.json" % path)
		return false
	# LA8 и RG8 — одинаковая раскладка байтов (2 канала), пересборка без конвертации
	var data := img.get_data()
	if img.get_format() != Image.FORMAT_LA8:
		img.convert(Image.FORMAT_RG8)
		data = img.get_data()
	set_forest_mask(
		Image.create_from_data(w, h, false, Image.FORMAT_RG8, data),
		float(info.spacing_m),
		float(info.origin_x_m),
		float(info.origin_z_m)
	)
	return true


## Маска 10 м (Image RG8), узел (0, 0) в мире (ox, oz).
func set_forest_mask(img: Image, step: float, ox: float, oz: float) -> void:
	mask_image = img
	mask_width = img.get_width()
	mask_height = img.get_height()
	mask_spacing = step
	mask_origin_x = ox
	mask_origin_z = oz
	_mask_data = img.get_data()


func has_forest_mask() -> bool:
	return mask_width > 0


func mask_contains(x: float, z: float) -> bool:
	return (
		mask_width > 0
		and x >= mask_origin_x
		and z >= mask_origin_z
		and x <= mask_origin_x + (mask_width - 1) * mask_spacing
		and z <= mask_origin_z + (mask_height - 1) * mask_spacing
	)


## Доля леса 0..1 в точке — как кромка в шейдере (без шума): маска 10 м билинейно и порог 0,5
## шириной ±mask_edge_soft; без маски — по классу ближайшего узла (0 или 1).
func forest_at(x: float, z: float) -> float:
	if mask_width == 0:
		return 1.0 if class_at(x, z) == FOREST else 0.0
	return smoothstep(0.5 - mask_edge_soft, 0.5 + mask_edge_soft, mask_r(x, z))


## Значение маски 10 м (R, доля леса в клетке 0..1) билинейно между узлами; без маски — 0.
func mask_r(x: float, z: float) -> float:
	return _mask_channel(x, z, 0)


## Значение маски 10 м (G, доля воды 0..1 — реки/ручьи/озёра OSM, T03) билинейно; без маски — 0.
func mask_g(x: float, z: float) -> float:
	return _mask_channel(x, z, 1)


func _mask_channel(x: float, z: float, ch: int) -> float:
	if mask_width == 0:
		return 0.0
	var fx := clampf((x - mask_origin_x) / mask_spacing, 0.0, mask_width - 1.0)
	var fz := clampf((z - mask_origin_z) / mask_spacing, 0.0, mask_height - 1.0)
	var i := mini(int(fx), mask_width - 2)
	var j := mini(int(fz), mask_height - 2)
	var tx := fx - i
	var tz := fz - j
	var k := (j * mask_width + i) * 2 + ch
	var row := mask_width * 2
	var a := lerpf(_mask_data[k], _mask_data[k + 2], tx)
	var b := lerpf(_mask_data[k + row], _mask_data[k + row + 2], tx)
	return lerpf(a, b, tz) / 255.0


## Самый частый не-лесной класс среди 3×3 узлов карты вокруг точки (луг, если вокруг только лес):
## чем считать лесную клетку 25 м там, где маска 10 м говорит «не лес».
func open_class_near(x: float, z: float) -> int:
	var i0 := roundi((x - origin_x) * _inv_spacing)
	var j0 := roundi((z - origin_z) * _inv_spacing)
	var counts := PackedInt32Array()
	counts.resize(CLASS_COUNT)
	for dj in range(-1, 2):
		for di in range(-1, 2):
			var c := node(i0 + di, j0 + dj)
			if c != FOREST and c != NONE and c < CLASS_COUNT:
				counts[c] += 1
	var best := GRASS
	for c in CLASS_COUNT:
		if counts[c] > counts[best]:
			best = c
	return best


## Текстура маски 10 м (RG8, линейная фильтрация в шейдере), null — маски нет.
func make_mask_texture() -> ImageTexture:
	if mask_width == 0:
		return null
	return ImageTexture.create_from_image(forest_mask_image())


func size_x() -> float:
	return (width - 1) * spacing


func size_z() -> float:
	return (height - 1) * spacing


func contains(x: float, z: float) -> bool:
	var h := spacing * 0.5
	return (
		x >= origin_x - h
		and z >= origin_z - h
		and x <= origin_x + size_x() + h
		and z <= origin_z + size_z() + h
	)


## Класс ближайшего узла (за краем — край).
func class_at(x: float, z: float) -> int:
	var i := clampi(roundi((x - origin_x) * _inv_spacing), 0, width - 1)
	var j := clampi(roundi((z - origin_z) * _inv_spacing), 0, height - 1)
	return classes[j * width + i]


func node(i: int, j: int) -> int:
	return classes[clampi(j, 0, height - 1) * width + clampi(i, 0, width - 1)]


func set_node(i: int, j: int, c: int) -> void:
	classes[j * width + i] = c


## Заменить класс from_class на to_class в круге (поляны у стартов): меняются все узлы,
## чьи клетки задевают круг, — class_at внутри радиуса r гарантированно не вернёт from_class.
func replace_in_circle(cx: float, cz: float, r_in: float, from_class: int, to_class: int) -> void:
	var r := r_in + spacing * 0.71
	var i0 := maxi(0, floori((cx - r - origin_x) * _inv_spacing))
	var i1 := mini(width - 1, ceili((cx + r - origin_x) * _inv_spacing))
	var j0 := maxi(0, floori((cz - r - origin_z) * _inv_spacing))
	var j1 := mini(height - 1, ceili((cz + r - origin_z) * _inv_spacing))
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var dx := origin_x + i * spacing - cx
			var dz := origin_z + j * spacing - cz
			if dx * dx + dz * dz <= r * r and classes[j * width + i] == from_class:
				classes[j * width + i] = to_class
	if from_class == FOREST and mask_width > 0:
		_clear_mask_circle(cx, cz, r_in)


## Обнулить долю леса маски 10 м в круге (поляны у стартов): узлы до r + диагональ клетки —
## билинейная доля леса (mask_r, forest_at, деревья) внутри r гарантированно ноль.
func _clear_mask_circle(cx: float, cz: float, r_in: float) -> void:
	var r := r_in + mask_spacing * 1.42
	var inv := 1.0 / mask_spacing
	var i0 := maxi(0, floori((cx - r - mask_origin_x) * inv))
	var i1 := mini(mask_width - 1, ceili((cx + r - mask_origin_x) * inv))
	var j0 := maxi(0, floori((cz - r - mask_origin_z) * inv))
	var j1 := mini(mask_height - 1, ceili((cz + r - mask_origin_z) * inv))
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var dx := mask_origin_x + i * mask_spacing - cx
			var dz := mask_origin_z + j * mask_spacing - cz
			if dx * dx + dz * dz <= r * r:
				_mask_data[(j * mask_width + i) * 2] = 0
	_mask_dirty = true


## Маска 10 м как Image RG8 (с вырезанными полянами), null — маски нет.
func forest_mask_image() -> Image:
	if _mask_dirty:
		mask_image.set_data(mask_width, mask_height, false, Image.FORMAT_RG8, _mask_data)
		_mask_dirty = false
	return mask_image


## Доли классов по площади (CLASS_COUNT значений).
func fractions() -> PackedFloat32Array:
	var counts := PackedInt32Array()
	counts.resize(CLASS_COUNT)
	for c in classes:
		counts[mini(c, CLASS_COUNT - 1)] += 1
	var out := PackedFloat32Array()
	out.resize(CLASS_COUNT)
	for k in CLASS_COUNT:
		out[k] = counts[k] / float(maxi(classes.size(), 1))
	return out


## Текстура классов (R8, значение = класс / 255) для шейдеров рельефа и деревьев.
func make_texture() -> ImageTexture:
	var img := Image.create_from_data(width, height, false, Image.FORMAT_R8, classes)
	return ImageTexture.create_from_image(img)
