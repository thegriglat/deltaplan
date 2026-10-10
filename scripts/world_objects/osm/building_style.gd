class_name BuildingStyle
extends RefCounted
## Стиль домов (OL-1, контракт L2, docs/contracts/osm-look.md): classify — город / село / промзона по записи
## дома; adjust — поправка этажности мегаполиса и «стекляшки» в плотном ядре. Без нод и GPU, O(n) по домам:
## плотность застройки — сетка клеток (интегральное изображение), не перебор пар.
## Запись дома: [x, z, w, l, угол, высота_стен, крыша, тип, по_правилу] (L1); 7 полей (процедурные) = тип −1,
## по_правилу 1.

const CITY := 0
const VILLAGE := 1
const INDUSTRIAL := 2

## Имена типов O3 по коду (docs/contracts/osm-tiles.md, O3 BUILDINGS).
const TYPE_NAMES: PackedStringArray = [
	"yes", "house", "apartments", "residential", "commercial", "industrial", "retail", "garage", "garages",
	"shed", "detached", "terrace", "church", "school", "roof", "office", "hotel", "warehouse", "farm", "barn",
	"hut", "cabin", "service", "public", "civic", "construction", "other"
]

## Сетка площади под домами последнего вызова (общая для classify и adjust): ключ — тот же массив домов.
static var _grid_src: Array = []
static var _grid_n := -1
static var _grid_cell := 0.0
static var _grid_ext := 0.0
static var _grid: PackedFloat32Array = PackedFloat32Array()
static var _grid_dim := 0


## Стиль на запись (CITY / VILLAGE / INDUSTRIAL), в порядке записей. cfg — world_objects.json → buildings.style.
static func classify(buildings: Array, cfg: Dictionary) -> PackedByteArray:
	var n := buildings.size()
	var out := PackedByteArray()
	out.resize(n)
	out.fill(VILLAGE)
	if n == 0:
		return out
	# все записи 7-польные (процедурные дома посёлка) — всё село без сетки
	if (buildings[0] as Array).size() < 8 and (buildings[n - 1] as Array).size() < 8:
		return out
	var table := _type_table(cfg)  # код типа → стиль или 255 («решает площадь и плотность»)
	var cell := float(cfg.get("cell_m", 200.0))
	var ext := float(cfg.get("extent_m", 32000.0))
	var grid := _area_grid(buildings, cell, ext)
	var dim := _grid_dim
	var inv := 1.0 / cell
	var cell_a := cell * cell
	var ind_a := float(cfg.get("industrial_min_area_m2", 1200.0))
	var ind_r := float(cfg.get("industrial_min_ratio", 1.8))
	var ind_cov := float(cfg.get("industrial_max_coverage", 0.15))
	var city_a := float(cfg.get("city_min_area_m2", 500.0))
	var city_cov := float(cfg.get("city_coverage", 0.22))
	for i in n:
		var b: Array = buildings[i]
		if b.size() < 8:
			continue
		var s: int = table[b[7] as int]
		if s != 255:
			out[i] = s
			continue
		var w: float = b[2]
		var l: float = b[3]
		var a := w * l
		var bx: float = b[0]
		var bz: float = b[1]
		var cx := int((bx + ext) * inv)
		var cz := int((bz + ext) * inv)
		var cov := 0.0
		if cx >= 0 and cz >= 0 and cx < dim and cz < dim:
			cov = grid[cz * dim + cx] / cell_a
		var ratio := maxf(w, l) / maxf(minf(w, l), 0.1)
		if a >= ind_a and ratio >= ind_r and cov < ind_cov:
			out[i] = INDUSTRIAL
		elif a >= city_a or cov >= city_cov:
			out[i] = CITY
	return out


## Поправка этажности мегаполиса: меняет на месте высоту стен (поле 5) записей CITY с по_правилу = 1,
## возвращает флаг фасада на запись (0 обычный, 1 стекло). rule — osm_tiles.json → height_rule (+ metro).
static func adjust(buildings: Array, style: PackedByteArray, rule: Dictionary) -> PackedByteArray:
	var n := buildings.size()
	var glass := PackedByteArray()
	glass.resize(n)
	var m: Dictionary = rule.get("metro", {})
	if n == 0 or m.is_empty():
		return glass
	var level := float(rule.get("level_m", 3.0))
	var cell := float(m.get("cell_m", 200.0))
	var ext := float(m.get("extent_m", 32000.0))
	var grid := _area_grid(buildings, cell, ext)
	var dim := _grid_dim
	var inv := 1.0 / cell
	# интегральное изображение: ii[(z)*(dim+1)+x] — сумма клеток [0,x)×[0,z)
	var d1 := dim + 1
	var ii := PackedFloat32Array()
	ii.resize(d1 * d1)
	for z in dim:
		var run := 0.0
		var row := (z + 1) * d1
		var prev := z * d1
		var grow := z * dim
		for x in dim:
			run += grid[grow + x]
			ii[row + x + 1] = ii[prev + x + 1] + run
	var core_r := maxi(1, int(round(float(m.get("core_radius_m", 750.0)) * inv)))
	var city_r := maxi(1, int(round(float(m.get("city_radius_m", 9000.0)) * inv)))
	var cov_lo := float(m.get("core_cov_lo", 0.1))
	var cov_hi := float(m.get("core_cov_hi", 0.3))
	var ar_lo := float(m.get("city_area_lo_m2", 4.0e6))
	var ar_hi := float(m.get("city_area_hi_m2", 3.0e7))
	var max_mult := float(m.get("max_mult", 2.2))
	var yes_a := float(m.get("yes_min_area_m2", 600.0))
	var g_frac := float(m.get("glass_fraction", 0.25))
	var g_area := float(m.get("glass_min_area_m2", 700.0))
	var g_core := float(m.get("glass_min_core", 0.8))
	var g_scale := float(m.get("glass_min_scale", 0.6))
	var gf: Array = m.get("glass_floors", [15, 30])
	var g_lo := float(gf[0])
	var g_hi := float(gf[1])
	var mult_t := PackedByteArray()
	mult_t.resize(27)
	for t: Variant in m.get("types", []):
		mult_t[int(t)] = 1
	var glass_t := PackedByteArray()
	glass_t.resize(27)
	for t: Variant in m.get("glass_types", []):
		glass_t[int(t)] = 1
	# по клетке: множитель, плотность центра, масштаб города — считаются при первом обращении
	var cell_n := dim * dim
	var c_mult := PackedFloat32Array()
	c_mult.resize(cell_n)
	c_mult.fill(-1.0)
	var c_core := PackedFloat32Array()
	c_core.resize(cell_n)
	var c_scale := PackedFloat32Array()
	c_scale.resize(cell_n)
	for i in n:
		if style[i] != CITY:
			continue
		var b: Array = buildings[i]
		if b.size() < 9 or int(b[8]) == 0:
			continue
		var ty: int = b[7]
		var is_mult: bool = mult_t[ty] == 1
		var is_glass: bool = glass_t[ty] == 1
		if not (is_mult or is_glass):
			continue
		var a: float = float(b[2]) * float(b[3])
		if ty == 0 and a < yes_a:
			is_mult = false
			is_glass = false
		if not (is_mult or is_glass):
			continue
		var bx: float = b[0]
		var bz: float = b[1]
		var cx := int((bx + ext) * inv)
		var cz := int((bz + ext) * inv)
		if cx < 0 or cz < 0 or cx >= dim or cz >= dim:
			continue
		var ci := cz * dim + cx
		var mu := c_mult[ci]
		if mu < 0.0:
			var core := _box(ii, d1, dim, cx, cz, core_r) / _box_area(dim, cx, cz, core_r, cell)
			var dens := smoothstep(cov_lo, cov_hi, core)
			var city := smoothstep(ar_lo, ar_hi, _box(ii, d1, dim, cx, cz, city_r))
			mu = 1.0 + (max_mult - 1.0) * dens * city
			c_mult[ci] = mu
			c_core[ci] = dens
			c_scale[ci] = city
		var hsh := (roundi(bx) * 73856093) ^ (roundi(bz) * 19349663)
		hsh = (hsh & 0x7fffffff) % 10007
		if (
			is_glass and a >= g_area and c_core[ci] >= g_core and c_scale[ci] >= g_scale
			and float(hsh) / 10007.0 < g_frac
		):
			var fl := roundf(lerpf(g_lo, g_hi, float((hsh * 31) % 1000) / 999.0))
			b[5] = fl * level
			glass[i] = 1
		elif is_mult and mu > 1.001:
			var fl2 := maxf(1.0, roundf(float(b[5]) / level * mu))
			b[5] = fl2 * level
	return glass


## Освободить кеш сетки (держит ссылку на массив домов).
static func release() -> void:
	_grid_src = []
	_grid_n = -1
	_grid = PackedFloat32Array()


# ---------- палитры (контраст крыша / стены) ----------

## Относительная яркость sRGB-цвета (Rec.709 по линейным каналам).
static func luminance(c: Array) -> float:
	var r := _lin(float(c[0]))
	var g := _lin(float(c[1]))
	var b := _lin(float(c[2]))
	return 0.2126 * r + 0.7152 * g + 0.0722 * b


static func _lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)


## Палитры стиля (sRGB): style.city / village / industrial → {wall_colors, roof_colors}.
static func palette(cfg: Dictionary, style: int) -> Dictionary:
	return cfg.get(["city", "village", "industrial"][style], {})


## Минимальная разница яркости любой стены и любой крыши палитры стиля (для теста и проверки конфига).
static func min_palette_contrast(pal: Dictionary) -> float:
	var best := INF
	for w: Array in pal.get("wall_colors", []):
		for r: Array in pal.get("roof_colors", []):
			best = minf(best, absf(luminance(w) - luminance(r)))
	return best


# ---------- внутреннее ----------

static func _type_table(cfg: Dictionary) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(32)
	t.fill(255)
	for pair: Array in [["industrial_types", INDUSTRIAL], ["city_types", CITY], ["village_types", VILLAGE]]:
		for nm: Variant in cfg.get(pair[0], []):
			var k := TYPE_NAMES.find(String(nm))
			if k >= 0:
				t[k] = pair[1]
	return t


## Площадь под домами по клеткам cell × cell, квадрат ±ext вокруг центра; результат кешируется для того же массива.
static func _area_grid(buildings: Array, cell: float, ext: float) -> PackedFloat32Array:
	if (
		is_same(buildings, _grid_src) and buildings.size() == _grid_n and cell == _grid_cell and ext == _grid_ext
	):
		return _grid
	var dim := maxi(1, int(ceil(2.0 * ext / cell)))
	var g := PackedFloat32Array()
	g.resize(dim * dim)
	var inv := 1.0 / cell
	for b: Array in buildings:
		var bx: float = b[0]
		var bz: float = b[1]
		var cx := int((bx + ext) * inv)
		var cz := int((bz + ext) * inv)
		if cx >= 0 and cz >= 0 and cx < dim and cz < dim:
			var bw: float = b[2]
			var bl: float = b[3]
			g[cz * dim + cx] += bw * bl
	_grid = g
	_grid_src = buildings
	_grid_n = buildings.size()
	_grid_cell = cell
	_grid_ext = ext
	_grid_dim = dim
	return g


## Сумма клеток в квадрате радиуса r клеток вокруг (cx, cz) по интегральному изображению.
static func _box(ii: PackedFloat32Array, d1: int, dim: int, cx: int, cz: int, r: int) -> float:
	var x0 := maxi(cx - r, 0)
	var x1 := mini(cx + r + 1, dim)
	var z0 := maxi(cz - r, 0)
	var z1 := mini(cz + r + 1, dim)
	return ii[z1 * d1 + x1] - ii[z0 * d1 + x1] - ii[z1 * d1 + x0] + ii[z0 * d1 + x0]


## Площадь квадрата радиуса r клеток (обрезанного по сетке), м².
static func _box_area(dim: int, cx: int, cz: int, r: int, cell: float) -> float:
	var w := mini(cx + r + 1, dim) - maxi(cx - r, 0)
	var h := mini(cz + r + 1, dim) - maxi(cz - r, 0)
	return float(w * h) * cell * cell
