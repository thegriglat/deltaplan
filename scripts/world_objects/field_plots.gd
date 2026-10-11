class_name FieldPlots
extends RefCounted
## Участки полей — GDScript-зеркало математики шейдера рельефа (контракт К10, docs/contracts/easter-eggs.md):
## terrain_common.gdshaderinc → hash12, field_plot_color; terrain.gdshader → field_detail.
## Шейдер не меняется: при правке его формул правится и этот файл (и эталон в тесте).
## Мировые координаты те же, что у Terrain.height_at(x, z): x — восток, z — юг (wp.xz шейдера — мировые,
## сдвига начала координат нет: меши слоёв стоят в мире в (x0, 0, z0), v_world = MODEL_MATRIX * VERTEX).
## Чистые функции без состояния мира. Шейдер считает во float32 — здесь он эмулируется (_f32) в hash12
## и сетке, поэтому значения совпадают с шейдером (до порядка fma на конкретной GPU).

enum { STANDING, GREEN, MOWN }

## fh < этого — спелые колосья (field_color); иначе mix(луг, сухая трава, fh): step(0.45, fh) в шейдере.
const STANDING_MAX := 0.45
## Среди не-колосьев (fh 0.45..1): fh < 0.75 — GREEN (середина диапазона: цвет ближе к лугу — луг/всходы),
## fh >= 0.75 — MOWN (ближе к dry_grass_color — сухая трава/стерня). Точная граница зависит от палитры
## места (meadow), поэтому это визуальная середина, а не строгий цвет.
const MOWN_MIN := 0.75
## Сдвиг рядов участков на каждую полосу из 6 рядов (доля участка по x).
const ROW_SHIFT := 0.37
const BAND_ROWS := 6.0

var size_m: Vector2


func _init(p_size_m: Vector2 = Vector2(260.0, 140.0)) -> void:
	size_m = p_size_m


## Размер участка из configs/world.json → terrain_look.field_size_m (тот же ключ, что читает рельеф).
## Переопределение в locations/*.json (terrain_look) сейчас не используется ни одной локацией.
static func from_world_config() -> FieldPlots:
	var a: Variant = Config.value("world", "terrain_look.field_size_m", [260, 140])
	if a is Array and (a as Array).size() == 2:
		return FieldPlots.new(Vector2(float(a[0]), float(a[1])))
	return FieldPlots.new()


## Округление до float32 (как вычисляет шейдер).
static func _f32(v: float) -> float:
	var a := PackedFloat32Array([v])
	return a[0]


static func _fract(v: float) -> float:
	return v - floorf(v)


## hash12 шейдера (mod 4096, 0.1031, 33.33); каждая операция округляется до float32.
static func hash12(p: Vector2) -> float:
	var px := _f32(p.x)
	var py := _f32(p.y)
	px = _f32(px - 4096.0 * floorf(_f32(px / 4096.0)))
	py = _f32(py - 4096.0 * floorf(_f32(py / 4096.0)))
	var k := _f32(0.1031)
	var a := _fract(_f32(px * k))
	var b := _fract(_f32(py * k))
	var c := a  # p3 = fract(vec3(p.xyx) * 0.1031) -> (a, b, a)
	var k2 := _f32(33.33)
	var qa := _f32(b + k2)  # p3.yzx + 33.33
	var qb := _f32(c + k2)
	var qc := _f32(a + k2)
	var d := _f32(_f32(_f32(a * qa) + _f32(b * qb)) + _f32(c * qc))
	a = _f32(a + d)
	b = _f32(b + d)
	c = _f32(c + d)
	return _fract(_f32(_f32(a + b) * c))


## Участок мировой точки: floor(xz / size + (floor(z / (size.y * 6)) * 0.37, 0)).
func cell_at(x: float, z: float) -> Vector2i:
	var sx := _f32(size_m.x)
	var sy := _f32(size_m.y)
	var band := floorf(_f32(_f32(z) / _f32(sy * BAND_ROWS)))
	var qx := _f32(_f32(_f32(x) / sx) + _f32(band * _f32(ROW_SHIFT)))
	var qy := _f32(_f32(z) / sy)
	return Vector2i(int(floorf(qx)), int(floorf(qy)))


## Участок в мире: position = (x_min, z_min), size = size_m; ряд сдвинут на 0,37 участка за каждые 6 рядов.
func rect(cell: Vector2i) -> Rect2:
	var band := floorf(float(cell.y) / BAND_ROWS)
	return Rect2(
		Vector2((float(cell.x) - band * ROW_SHIFT) * size_m.x, float(cell.y) * size_m.y), size_m
	)


func center(cell: Vector2i) -> Vector2:
	return rect(cell).get_center()


## fh шейдера: hash12(cell).
func tone(cell: Vector2i) -> float:
	return hash12(Vector2(cell))


## STANDING (колосья), GREEN (луг/всходы) или MOWN (сухая трава/стерня).
func kind(cell: Vector2i) -> int:
	var fh := tone(cell)
	if fh < _f32(STANDING_MAX):
		return STANDING
	return MOWN if fh >= MOWN_MIN else GREEN


## Единичный вектор (x — восток, z — юг) вдоль борозд и технологических колей участка.
## field_detail: h = hash12(cell + 19.1); dir = h < 0.5 ? (1,0) : (0,1); полосы меняются вдоль
## along = dot(p, (dir.y, dir.x)), т.е. сами борозды идут вдоль dir.
func rows_axis(cell: Vector2i) -> Vector2:
	var h := hash12(Vector2(cell) + Vector2(_f32(19.1), _f32(19.1)))
	return Vector2(1.0, 0.0) if h < 0.5 else Vector2(0.0, 1.0)


## Множитель яркости участка: 0.85 + 0.3 * hash12(cell + 7).
func brightness(cell: Vector2i) -> float:
	return 0.85 + 0.3 * hash12(Vector2(cell) + Vector2(7.0, 7.0))
