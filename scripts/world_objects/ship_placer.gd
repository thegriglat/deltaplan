class_name ShipPlacer
extends RefCounted
## Расстановка судов на море (контракт S3, docs/contracts/sea-ships.md). Без нод, static.
## Детерминизм по миру: мировая клетка cell = (floor(lon / cell_deg), floor(lat / cell_deg)); из хеша клетки
## (TreeCell.hash, без RandomNumberGenerator) — есть ли судно (p_cell), точка внутри клетки (lat/lon), вид (веса
## placement.types), курс. Одна точка мира в двух местах с разными центрами даёт то же судно: всё считается в
## lat/lon, в метры места — только последним шагом (TerrainGeo, как у мест).
## Судно ставится, если точка внутри far и значение маски S2 в ближайшем узле far ≥ 1 + ceil(min_shore_m / 100 м).

const DEFAULTS := {"cell_deg": 0.1, "p_cell": 0.15, "min_shore_m": 2000.0, "types": {"tanker": 1.0}}
## Доля 0…1 из 32-битного значения хеша.
const INV_2_32 := 1.0 / 4294967296.0


## Параметры из configs/sea_ships.json → placement.
static func params_from_config() -> Dictionary:
	var p := DEFAULTS.duplicate(true)
	var c: Variant = Config.get_config("sea_ships").get("placement", {})
	if c is Dictionary:
		p.merge(c, true)
	return p


## Суда места: [{type, x, z (м места, оси Terrain), heading_rad (0 — нос на −Z/север, по часовой), cell: Vector2i}].
## mask — SeaMask.load_for ({image L8, origin — x,z узла (0,0), cell_m}); пусто — [].
static func ships_for(mask: Dictionary, center_lat: float, center_lon: float, params: Dictionary) -> Array[Dictionary]:
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
	var p_cell := float(p.p_cell)
	var min_v := 1 + int(ceil(float(p.min_shore_m) / SeaMask.STEP_M))
	if cell_deg <= 0.0 or p_cell <= 0.0 or min_v > 255:
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
	# прямоугольник far в lat/lon: углы квадрата (проекция места — прямоугольная по lat/lon)
	var c0 := TerrainGeo.local_to_latlon(origin.x, origin.y, center_lat, center_lon)
	var c1 := TerrainGeo.local_to_latlon(origin.x + (w - 1) * step, origin.y + (h - 1) * step, center_lat, center_lon)
	var lat_lo := minf(c0.x, c1.x)
	var lat_hi := maxf(c0.x, c1.x)
	var lon_lo := minf(c0.y, c1.y)
	var lon_hi := maxf(c0.y, c1.y)
	for cy in range(int(floor(lat_lo / cell_deg)), int(floor(lat_hi / cell_deg)) + 1):
		for cx in range(int(floor(lon_lo / cell_deg)), int(floor(lon_hi / cell_deg)) + 1):
			var cell := Vector2i(cx, cy)
			var s := ship_in_cell(cell, cell_deg, p_cell, kinds, cum)
			if s.is_empty():
				continue
			var xz := TerrainGeo.latlon_to_local(float(s.lat), float(s.lon), center_lat, center_lon)
			var i := int(roundf((xz.x - origin.x) / step))
			var j := int(roundf((xz.y - origin.y) / step))
			if i < 0 or j < 0 or i >= w or j >= h:
				continue
			if data[j * w + i] < min_v:
				continue
			out.append({"type": s.type, "x": xz.x, "z": xz.y, "heading_rad": s.heading_rad, "cell": cell})
	return out


## Судно мировой клетки (без маски и места): {} — клетка пустая, иначе {type, lat, lon, heading_rad}.
## kinds/cum — виды и накопленные веса (последний — сумма).
static func ship_in_cell(cell: Vector2i, cell_deg: float, p_cell: float, kinds: PackedStringArray,
		cum: PackedFloat64Array) -> Dictionary:
	var h1 := TreeCell.hash(cell)
	if _u(h1.x) >= p_cell:
		return {}
	var h2 := TreeCell.hash2(h1)
	var h3 := TreeCell.hash(h2)
	var r := _u(h1.y) * cum[cum.size() - 1]
	var t := 0
	while t < kinds.size() - 1 and r >= cum[t]:
		t += 1
	return {
		"type": kinds[t],
		"lon": (float(cell.x) + _u(h2.x)) * cell_deg,
		"lat": (float(cell.y) + _u(h2.y)) * cell_deg,
		"heading_rad": _u(h3.x) * TAU,
	}


static func _u(v: int) -> float:
	return float(v & 0xFFFFFFFF) * INV_2_32
