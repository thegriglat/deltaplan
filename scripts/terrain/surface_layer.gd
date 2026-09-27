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

var _inv_spacing: float = 1.0


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


## Загрузить из 8-битного PNG (значение пикселя = класс) по описанию из surface.json.
## Файл читается байтами (в проекте он не импортируется: importer="keep").
static func load_png(path: String, info: Dictionary) -> SurfaceLayer:
	var bytes := FileAccess.get_file_as_bytes(path)
	var img := Image.new()
	if bytes.is_empty() or img.load_png_from_buffer(bytes) != OK:
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
