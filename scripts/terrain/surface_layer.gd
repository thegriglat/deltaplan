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
## Хранится в неизменяемом снимке (CR-18): смена — подстановкой нового массива (replace_in_circle
## правит копию), поэтому читатель из рабочего потока берёт ссылку один раз и видит массив целиком.
var classes: PackedByteArray:
	get:
		return _cls.data
	set(v):
		var c := ClsSnap.new()
		c.data = v
		_cls = c
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
var _mask_dirty := false
## Неизменяемый снимок маски 10 м (CR-18): рабочие потоки разброса читают маску, пока главный поток
## меняет её (смена места, поляны). Снимок собирается целиком и подставляется одной ссылкой;
## читатель берёт ссылку в локальную переменную один раз и работает только с ней, поэтому
## ширина, шаг и байты всегда согласованы. Внутри снимка ничего не правится после публикации.
var _mask: MaskSnap = null
var _cls: ClsSnap = ClsSnap.new()
var _editing := false
var _edit_cls := PackedByteArray()
var _edit_mask: MaskSnap = null


## Снимок классов узлов (один массив под одной ссылкой).
class ClsSnap:
	extends RefCounted
	var data: PackedByteArray = PackedByteArray()


## Снимок маски: размеры, шаг, начало и байты RG8 одним объектом.
class MaskSnap:
	extends RefCounted
	var width: int = 0
	var height: int = 0
	var spacing: float = 10.0
	var origin_x: float = 0.0
	var origin_z: float = 0.0
	var data: PackedByteArray = PackedByteArray()
	## Годна для выборки: не меньше 2×2 и данных хватает (считается в seal()).
	var ok := false
	var inv_spacing := 0.1
	var wm1 := 0.0
	var hm1 := 0.0

	## Вызвать после заполнения полей и data (размер data дальше не меняется).
	func seal() -> void:
		ok = width >= 2 and height >= 2 and data.size() >= width * height * 2
		inv_spacing = 1.0 / spacing
		wm1 = width - 1.0
		hm1 = height - 1.0


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
	var m := MaskSnap.new()
	m.width = img.get_width()
	m.height = img.get_height()
	m.spacing = step
	m.origin_x = ox
	m.origin_z = oz
	m.data = img.get_data()
	m.seal()
	_publish_mask(m, img)


## Подставить снимок одной ссылкой и обновить открытые поля (их читает только главный поток).
func _publish_mask(m: MaskSnap, img: Image) -> void:
	_mask = m
	mask_image = img
	mask_width = m.width
	mask_height = m.height
	mask_spacing = m.spacing
	mask_origin_x = m.origin_x
	mask_origin_z = m.origin_z


## Размытая подложка застройки (NO-10): detail_built10 (L8, 10 м) сжата до клеток ~built_soft_cell_m —
## билинейная выборка в шейдере даёт мягкое пятно без шахматки 25 м. Пустая — как раньше (класс built).
var built_soft_image: Image
var built_soft_spacing: float = 50.0
var built_soft_origin_x: float = 0.0
var built_soft_origin_z: float = 0.0


## Прочитать detail_built10 по surface.json → built10 + detail10 (сетка) и сжать до клеток built_soft_cell_m.
func load_built_soft(path: String, d10: Dictionary, soft_cell_m: float) -> bool:
	var bytes := FileAccess.get_file_as_bytes(path)
	var img := Image.new()
	if bytes.is_empty() or img.load_webp_from_buffer(bytes) != OK:
		return false
	var w := int(d10.width)
	var h := int(d10.height)
	if img.get_width() != w or img.get_height() != h:
		return false
	img.convert(Image.FORMAT_L8)
	var step := float(d10.spacing_m)
	var k := maxi(1, roundi(soft_cell_m / step))
	var nw := ceili(float(w) / k)
	var nh := ceili(float(h) / k)
	img.resize(nw, nh, Image.INTERPOLATE_TRILINEAR)
	built_soft_image = img
	built_soft_spacing = step * float(w - 1) / maxf(float(nw - 1), 1.0)
	built_soft_origin_x = float(d10.origin_x_m)
	built_soft_origin_z = float(d10.origin_z_m)
	return true


func make_built_soft_texture() -> ImageTexture:
	return ImageTexture.create_from_image(built_soft_image) if built_soft_image != null else null


func has_forest_mask() -> bool:
	return _mask != null and _mask.width > 0


func mask_contains(x: float, z: float) -> bool:
	var m := _mask
	return (
		m != null
		and m.width > 0
		and x >= m.origin_x
		and z >= m.origin_z
		and x <= m.origin_x + (m.width - 1) * m.spacing
		and z <= m.origin_z + (m.height - 1) * m.spacing
	)


## Доля леса 0..1 в точке — как кромка в шейдере (без шума): маска 10 м билинейно и порог 0,5
## шириной ±mask_edge_soft; без маски — по классу ближайшего узла (0 или 1).
func forest_at(x: float, z: float) -> float:
	var m := _mask
	if m == null or m.width == 0:
		return 1.0 if class_at(x, z) == FOREST else 0.0
	var soft := mask_edge_soft
	return smoothstep(0.5 - soft, 0.5 + soft, _snap_channel(m, x, z, 0))


## Значение маски 10 м (R, доля леса в клетке 0..1) билинейно между узлами; без маски — 0.
func mask_r(x: float, z: float) -> float:
	return _mask_channel(x, z, 0)


## Значение маски 10 м (G, доля воды 0..1 — реки/ручьи/озёра OSM, T03) билинейно; без маски — 0.
func mask_g(x: float, z: float) -> float:
	return _mask_channel(x, z, 1)


func _mask_channel(x: float, z: float, ch: int) -> float:
	var m := _mask
	if m == null or m.width == 0:
		return 0.0
	return _snap_channel(m, x, z, ch)


## Билинейная выборка канала из снимка (все размеры — из него же). Маска меньше 2×2 или с
## неполными данными — 0 (не выходить за массив).
static func _snap_channel(m: MaskSnap, x: float, z: float, ch: int) -> float:
	if not m.ok:
		return 0.0
	var w := m.width
	var fx := clampf((x - m.origin_x) * m.inv_spacing, 0.0, m.wm1)
	var fz := clampf((z - m.origin_z) * m.inv_spacing, 0.0, m.hm1)
	var i := mini(int(fx), w - 2)
	var j := mini(int(fz), m.height - 2)
	var tx := fx - i
	var tz := fz - j
	var d := m.data
	var k := (j * w + i) * 2 + ch
	var row := w * 2
	var a := lerpf(d[k], d[k + 2], tx)
	var b := lerpf(d[k + row], d[k + row + 2], tx)
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
	if _mask == null or _mask.width == 0:
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
	var cl := _cls.data
	var i := clampi(roundi((x - origin_x) * _inv_spacing), 0, width - 1)
	var j := clampi(roundi((z - origin_z) * _inv_spacing), 0, height - 1)
	return cl[j * width + i]


func node(i: int, j: int) -> int:
	var cl := _cls.data
	return cl[clampi(j, 0, height - 1) * width + clampi(i, 0, width - 1)]


func set_node(i: int, j: int, c: int) -> void:
	classes[j * width + i] = c


## Заменить класс from_class на to_class в круге (поляны у стартов): меняются все узлы,
## чьи клетки задевают круг, — class_at внутри радиуса r гарантированно не вернёт from_class.
func replace_in_circle(cx: float, cz: float, r_in: float, from_class: int, to_class: int) -> void:
	var r := r_in + spacing * 0.71
	# правка копии и замена целиком: читатели в других потоках не видят полуправленый массив
	var cl: PackedByteArray
	if _editing:
		# серия правок: рабочая копия своя, публикуется один раз в end_edit
		cl = _edit_cls
		_edit_cls = PackedByteArray()
	else:
		cl = classes.duplicate()
	var changed := false
	var i0 := maxi(0, floori((cx - r - origin_x) * _inv_spacing))
	var i1 := mini(width - 1, ceili((cx + r - origin_x) * _inv_spacing))
	var j0 := maxi(0, floori((cz - r - origin_z) * _inv_spacing))
	var j1 := mini(height - 1, ceili((cz + r - origin_z) * _inv_spacing))
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var dx := origin_x + i * spacing - cx
			var dz := origin_z + j * spacing - cz
			if dx * dx + dz * dz <= r * r and cl[j * width + i] == from_class:
				cl[j * width + i] = to_class
				changed = true
	if _editing:
		_edit_cls = cl
	elif changed:
		classes = cl
	if from_class == FOREST and _mask != null and _mask.width > 0:
		_clear_mask_circle(cx, cz, r_in)


## Обнулить долю леса маски 10 м в круге (поляны у стартов): узлы до r + диагональ клетки —
## билинейная доля леса (mask_r, forest_at, деревья) внутри r гарантированно ноль.
func _clear_mask_circle(cx: float, cz: float, r_in: float) -> void:
	var old := _mask
	var r := r_in + old.spacing * 1.42
	var inv := 1.0 / old.spacing
	var i0 := maxi(0, floori((cx - r - old.origin_x) * inv))
	var i1 := mini(old.width - 1, ceili((cx + r - old.origin_x) * inv))
	var j0 := maxi(0, floori((cz - r - old.origin_z) * inv))
	var j1 := mini(old.height - 1, ceili((cz + r - old.origin_z) * inv))
	# правка копии: новый снимок вместо правки опубликованного (в серии — рабочий, публикуется в end_edit)
	var m: MaskSnap = _edit_mask if _editing else null
	if m == null:
		m = MaskSnap.new()
		m.width = old.width
		m.height = old.height
		m.spacing = old.spacing
		m.origin_x = old.origin_x
		m.origin_z = old.origin_z
		m.data = old.data.duplicate()
		m.seal()
	var d := m.data
	m.data = PackedByteArray()
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var dx := old.origin_x + i * old.spacing - cx
			var dz := old.origin_z + j * old.spacing - cz
			if dx * dx + dz * dz <= r * r:
				d[(j * m.width + i) * 2] = 0
	m.data = d
	if _editing:
		_edit_mask = m
	else:
		_mask = m
	_mask_dirty = true


## Серия правок (поляны у стартов): replace_in_circle правит одну рабочую копию классов и маски,
## а не копирует массивы на каждый круг; читатели до end_edit видят прежние снимки (CR-18).
func begin_edit() -> void:
	_edit_cls = classes.duplicate()
	if _mask != null:
		var m := MaskSnap.new()
		m.width = _mask.width
		m.height = _mask.height
		m.spacing = _mask.spacing
		m.origin_x = _mask.origin_x
		m.origin_z = _mask.origin_z
		m.data = _mask.data.duplicate()
		m.seal()
		_edit_mask = m
	_editing = true


## Опубликовать рабочие копии одной подстановкой ссылок.
func end_edit() -> void:
	if not _editing:
		return
	_editing = false
	classes = _edit_cls
	_edit_cls = PackedByteArray()
	if _edit_mask != null:
		_mask = _edit_mask
		_mask_dirty = true
		_edit_mask = null


## Маска 10 м как Image RG8 (с вырезанными полянами), null — маски нет.
func forest_mask_image() -> Image:
	if _mask_dirty:
		mask_image.set_data(mask_width, mask_height, false, Image.FORMAT_RG8, _mask.data)
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
