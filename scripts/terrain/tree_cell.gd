class_name TreeCell
extends RefCounted
## SL-К5 v1: «дерево в клетке» — общий для CPU-моделей (TreePlacer) и LOD2-крестов в шейдере
## (tree_cell.gdshaderinc, tc_hash) хеш мира. Дерево целиком определяется индексом клетки
## c = floor(p_xz / cell_m) и плотностью леса d8 (0…255) в центре клетки: сдвиг камеры не меняет набор.
## Хеш PCG2D (Jarzynski, Olano 2020), 32-бит без знака, побитово как GLSL uvec2: в GDScript int 64-бит,
## после каждого умножения/сложения — маска 2^32 − 1, сдвиги логические (после маски). Vector2i хранит те же
## 32 бита как знаковые: беззнаковые значения — hx/hy.

const M32 := 0xFFFFFFFF
const MUL := 1664525
const ADD := 1013904223
## Сдвиг внутри клетки: ±SPREAD/2 клетки (0,8 клетки).
const SPREAD := 0.8


static func _s32(v: int) -> int:
	v &= M32
	return v - 0x100000000 if v >= 0x80000000 else v


## PCG2D от индекса клетки; Vector2i с теми же 32 битами, что GLSL uvec2 (беззнаковые — hx, hy).
static func hash(c: Vector2i) -> Vector2i:
	var x := c.x & M32
	var y := c.y & M32
	x = (x * MUL + ADD) & M32
	y = (y * MUL + ADD) & M32
	x = (x + y * MUL) & M32
	y = (y + x * MUL) & M32
	x ^= x >> 16
	y ^= y >> 16
	x = (x + y * MUL) & M32
	y = (y + x * MUL) & M32
	x ^= x >> 16
	y ^= y >> 16
	return Vector2i(_s32(x), _s32(y))


static func hx(h: Vector2i) -> int:
	return h.x & M32


static func hy(h: Vector2i) -> int:
	return h.y & M32


## Индекс клетки мирового места (x, z).
static func cell_of(x: float, z: float, cell_m: float) -> Vector2i:
	return Vector2i(floori(x / cell_m), floori(z / cell_m))


## Есть ли дерево: (h.x & 255) < d8.
static func present(c: Vector2i, d8: int) -> bool:
	return (TreeCell.hash(c).x & 255) < d8


## Сдвиг внутри клетки, доли клетки (−0,4…0,4).
static func offset_h(h: Vector2i) -> Vector2:
	var ox := float((h.x >> 8) & 0xFFF if h.x >= 0 else ((h.x & M32) >> 8) & 0xFFF)
	var oy := float((h.y >> 8) & 0xFFF if h.y >= 0 else ((h.y & M32) >> 8) & 0xFFF)
	return (Vector2(ox, oy) / 4096.0 - Vector2(0.5, 0.5)) * SPREAD


static func offset(c: Vector2i) -> Vector2:
	return offset_h(TreeCell.hash(c))


## Позиция дерева клетки в мире, м: (c + 0,5 + сдвиг) · cell_m.
static func pos(c: Vector2i, cell_m: float) -> Vector2:
	return (Vector2(c) + Vector2(0.5, 0.5) + offset(c)) * cell_m


## Второй хеш (SL-К5, уточнение): PCG2D от переставленных 32 бит h — Vector2i(h.y, h.x).
static func hash2(h: Vector2i) -> Vector2i:
	return TreeCell.hash(Vector2i(h.y, h.x))


## Высота дерева: доля 0…1 между границами height_m породы — (h2.x & 0xFFFF) / 65536.
static func height_t(h2: Vector2i) -> float:
	return float(h2.x & 0xFFFF) / 65536.0


## Разброс цвета: доля 0…1 — (h2.y & 0xFFFF) / 65536; множитель v = 1 + color_variation · (t − 0,5) · 2.
static func color_t(h2: Vector2i) -> float:
	return float(h2.y & 0xFFFF) / 65536.0


## Случайное 0…1 для породы (h.y & 255).
static func species_u(h: Vector2i) -> float:
	return float(hy(h) & 255) / 256.0


## Вариант модели (биты 20…31 h.y — не пересекаются с сдвигом и породой).
static func variant(h: Vector2i, variants: int) -> int:
	return ((hy(h) >> 20) & 0xFFF) % maxi(variants, 1)


## Угол поворота, рад (биты 20…31 h.x).
static func angle(h: Vector2i) -> float:
	return float((hx(h) >> 20) & 0xFFF) / 4096.0 * TAU


## Порода по высоте h над морем, «северности» north −1…1 и u = species_u(hash): веса, границы высот
## (min_m/max_m), экспозиция (aspect) — массивы по породам (TreePlacer.SPECIES), band_blend — мягкая граница
## по высоте, м. −1 — ни одна не подходит. Правила — прежние (TreePlacer.pick_species).
static func species(
	h: float,
	north: float,
	u: float,
	weight: PackedFloat32Array,
	min_m: PackedFloat32Array,
	max_m: PackedFloat32Array,
	aspect: PackedFloat32Array,
	band_blend: float
) -> int:
	var n := weight.size()
	var w := PackedFloat32Array()
	w.resize(n)
	var total := 0.0
	for k in n:
		var band := (
			clampf((h - min_m[k]) / band_blend + 0.5, 0.0, 1.0)
			* clampf((max_m[k] - h) / band_blend + 0.5, 0.0, 1.0)
		)
		w[k] = weight[k] * band * maxf(0.05, 1.0 + aspect[k] * north)
		total += w[k]
	if total <= 0.0:
		return -1
	var t := u * total
	for k in n:
		t -= w[k]
		if t <= 0.0:
			return k
	return n - 1
