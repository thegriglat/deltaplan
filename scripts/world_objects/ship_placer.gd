class_name ShipPlacer
extends RefCounted
## Расстановка судов на море (контракт S3 v3, docs/contracts/sea-ships.md). Без нод, static.
## Кандидаты — по мировым клеткам cell_deg (хеш клетки TreeCell.hash, без сида): точка, вид (веса placement.types), курс,
## ранг r. Годен: точка внутри far, расстояние до берега по маске S2 в [shore_min_m, shore_max_m], до центра места ≤ center_max_m.
## Число судов места N = n_min + hash(ключ места: клетка центра сетки LocationCache, 0,05°) mod (n_max − n_min + 1);
## берутся N годных с наименьшим r, не ближе min_sep_m друг к другу. Кандидат считается в lat/lon, в метры места — последним шагом,
## поэтому одна точка мира в двух местах даёт то же судно. Значение маски v ⇒ до берега ≥ (v − 1)·100 м.
## Ватерлиния y — высота рельефа в точке (height_fn, в игре Terrain.height_at): после выравнивания S2 v2 это уровень воды L.

const DEFAULTS := {"cell_deg": 0.02, "shore_min_m": 3000.0, "shore_max_m": 15000.0, "center_max_m": 30000.0,
	"n_min": 2, "n_max": 6, "min_sep_m": 1500.0, "types": {"tanker": 1.0, "bulk": 1.0, "container": 1.0}}
## Доля 0…1 из 32-битного значения хеша.
const INV_2_32 := 1.0 / 4294967296.0


## Параметры из configs/sea_ships.json → placement.
static func params_from_config() -> Dictionary:
	var p := DEFAULTS.duplicate(true)
	var c: Variant = Config.get_config("sea_ships").get("placement", {})
	if c is Dictionary:
		p.merge(c, true)
	return p


## Суда места: [{type, x, y (ватерлиния, м), z (м места, оси Terrain), heading_rad (0 — нос на −Z/север, по часовой),
## cell: Vector2i}]. mask — SeaMask.load_for ({image L8, origin — x,z узла (0,0), cell_m}); пусто — [].
## height_fn(x, z) -> м — высота рельефа (недействительный Callable — 0 м). Вызывается из рабочего потока: только чтение.
static func ships_for(mask: Dictionary, center_lat: float, center_lon: float, params: Dictionary,
		height_fn: Callable) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if mask.is_empty() or not (mask.get("image") is Image):
		return out
	var img: Image = mask.image
	var w := img.get_width()
	var h := img.get_height()
	if w == 0 or h == 0:
		return out
	var data := img.get_data()
	if data.size() != w * h:
		return out
	var p := DEFAULTS.duplicate(true)
	p.merge(params, true)
	var cell_deg := float(p.cell_deg)
	var step_m := float(SeaMask.STEP_M)
	var v_min := 1 + int(ceil(float(p.shore_min_m) / step_m))
	var v_max := mini(255, 1 + int(floor(float(p.shore_max_m) / step_m)))
	var n_min := int(p.n_min)
	var n_max := maxi(n_min, int(p.n_max))
	var center_max := float(p.center_max_m)
	var sep2 := float(p.min_sep_m) * float(p.min_sep_m)
	if cell_deg <= 0.0 or v_min > v_max or n_max <= 0:
		return out
	# виды с положительным весом, порядок — по имени (не зависит от порядка ключей конфига)
	var names: Array = (p.types as Dictionary).keys()
	names.sort()
	var kinds: PackedStringArray = []
	var cum := PackedFloat64Array()
	var total := 0.0
	for k: String in names:
		var wt := float(p.types[k])
		if wt > 0.0:
			total += wt
			kinds.append(k)
			cum.append(total)
	if kinds.is_empty():
		return out
	var origin: Vector2 = mask.get("origin", Vector2.ZERO)
	var step := float(mask.get("cell_m", 100.0))
	# прямоугольник поиска в lat/lon: far ∩ квадрат ±center_max вокруг центра
	var lo := Vector2(maxf(origin.x, -center_max), maxf(origin.y, -center_max))
	var hi := Vector2(minf(origin.x + (w - 1) * step, center_max), minf(origin.y + (h - 1) * step, center_max))
	if lo.x > hi.x or lo.y > hi.y:
		return out
	var c0 := TerrainGeo.local_to_latlon(lo.x, lo.y, center_lat, center_lon)
	var c1 := TerrainGeo.local_to_latlon(hi.x, hi.y, center_lat, center_lon)
	var cands: Array[Dictionary] = []
	for cy in range(int(floor(minf(c0.x, c1.x) / cell_deg)), int(floor(maxf(c0.x, c1.x) / cell_deg)) + 1):
		for cx in range(int(floor(minf(c0.y, c1.y) / cell_deg)), int(floor(maxf(c0.y, c1.y) / cell_deg)) + 1):
			var cell := Vector2i(cx, cy)
			var s := ship_in_cell(cell, cell_deg, kinds, cum)
			var xz := TerrainGeo.latlon_to_local(float(s.lat), float(s.lon), center_lat, center_lon)
			if xz.length() > center_max:
				continue
			var i := int(roundf((xz.x - origin.x) / step))
			var j := int(roundf((xz.y - origin.y) / step))
			if i < 0 or j < 0 or i >= w or j >= h:
				continue
			var v := int(data[j * w + i])
			if v < v_min or v > v_max:
				continue
			s["xz"] = xz
			s["cell"] = cell
			cands.append(s)
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.r != b.r:
			return a.r < b.r
		return a.cell.x < b.cell.x or (a.cell.x == b.cell.x and a.cell.y < b.cell.y))
	var n := n_min + (_hash_u32(_place_cell(center_lat, center_lon)) % (n_max - n_min + 1))
	for s in cands:
		if out.size() >= n:
			break
		var xz: Vector2 = s.xz
		var ok := true
		for o in out:
			if (Vector2(o.x, o.z) - xz).length_squared() < sep2:
				ok = false
				break
		if not ok:
			continue
		var y := float(height_fn.call(xz.x, xz.y)) if height_fn.is_valid() else 0.0
		out.append({"type": s.type, "x": xz.x, "y": y, "z": xz.y, "heading_rad": s.heading_rad, "cell": s.cell})
	return out


## Ключ места: клетка центра на сетке LocationCache.snap (0,05°) — (lon, lat) в шагах сетки.
static func _place_cell(center_lat: float, center_lon: float) -> Vector2i:
	var step := float(Config.value("world", "location_builder.snap_deg", 0.05))
	return Vector2i(roundi(center_lon / step), roundi(center_lat / step))


static func _hash_u32(c: Vector2i) -> int:
	# соль (c.x + 7919): ключ места не совпадает с хешем мировой клетки судов
	return TreeCell.hash(Vector2i(c.x + 7919, c.y)).x & 0xFFFFFFFF


## Кандидат мировой клетки (без маски и места): {type, lat, lon, heading_rad, r}; r ∈ [0,1) — ранг отбора.
## kinds/cum — виды и накопленные веса (последний — сумма).
static func ship_in_cell(cell: Vector2i, cell_deg: float, kinds: PackedStringArray, cum: PackedFloat64Array) -> Dictionary:
	var h1 := TreeCell.hash(cell)
	var h2 := TreeCell.hash2(h1)
	var h3 := TreeCell.hash(h2)
	var w := _u(h1.y) * cum[cum.size() - 1]
	var t := 0
	while t < kinds.size() - 1 and w >= cum[t]:
		t += 1
	return {
		"type": kinds[t],
		"lon": (float(cell.x) + _u(h2.x)) * cell_deg,
		"lat": (float(cell.y) + _u(h2.y)) * cell_deg,
		"heading_rad": _u(h3.x) * TAU,
		"r": _u(h1.x),
	}


static func _u(v: int) -> float:
	return float(v & 0xFFFFFFFF) * INV_2_32
