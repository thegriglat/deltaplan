extends TestCase
## Расстановка судов (ShipPlacer, контракт S3): детерминизм по миру, расстояние до берега, пустая маска.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=ship_placer

const N := 1601  # 160 км при шаге 100 м — как far
const STEP := 100.0


func _params() -> Dictionary:
	return {"cell_deg": 0.02, "shore_min_m": 3000, "shore_max_m": 15000, "center_max_m": 30000, "n_min": 2, "n_max": 6,
		"min_sep_m": 1500, "types": {"tanker": 1, "bulk": 1, "container": 1}}


## Расстояние до центра места (0, 0), м.
func _dist(s: Dictionary) -> float:
	return Vector2(float(s.x), float(s.z)).length()


## Маска N×N с центром места в середине: значение столбца i — col_fn(i) (0…255).
func _mask(col_fn: Callable) -> Dictionary:
	var row := PackedByteArray()
	row.resize(N)
	for i in N:
		row[i] = int(col_fn.call(i))
	var data := PackedByteArray()
	for j in N:
		data.append_array(row)
	var half := (N - 1) * 0.5 * STEP
	return {"image": Image.create_from_data(N, N, false, Image.FORMAT_L8, data), "origin": Vector2(-half, -half), "cell_m": STEP}


func _all_sea() -> Dictionary:
	return _mask(func(_i: int) -> int: return 255)


## Маска: полоса моря шириной 40 км в середине (берег — столбец 0, значение растёт на 1 за 100 м).
func _shore_mask() -> Dictionary:
	return _mask(func(i: int) -> int: return 0 if i == 0 else mini(255, 1 + i))


func test_count_and_band() -> void:
	# берег у западного края far: 80 км от центра, до центра ≤ 30 км — полоса 3–15 км от берега не достаёт; ставим центр у берега
	var m := _mask(func(i: int) -> int: return 0 if i < 700 else mini(255, 1 + (i - 700)))
	var counts := {}
	var kinds := {}
	var p := _params()
	for k in 12:
		var lat := 10.0 + 0.05 * k
		var a := ShipPlacer.ships_for(m, lat, 20.0, p, Callable())
		var b := ShipPlacer.ships_for(m, lat, 20.0, p, Callable())
		check(a == b, "повтор — те же суда")
		check(a.size() >= 2 and a.size() <= 6, "N ∈ [2, 6]: %d" % a.size())
		counts[a.size()] = true
		for s in a:
			check(s.has_all(["type", "x", "y", "z", "heading_rad", "cell"]), "поля элемента")
			check(s.cell is Vector2i and float(s.heading_rad) >= 0.0 and float(s.heading_rad) < TAU, "клетка и курс")
			kinds[s.type] = true
			check(_dist(s) <= 30000.0 + 1.0, "≤ 30 км от центра: %.0f" % _dist(s))
			var i := int(roundf((float(s.x) - m.origin.x) / STEP))
			var j := int(roundf((float(s.z) - m.origin.y) / STEP))
			var v := int((m.image as Image).get_pixel(i, j).r8)
			check(v >= 31 and v <= 151, "полоса 3–15 км: маска %d" % v)
		for x in a.size():
			for y in range(x + 1, a.size()):
				check(Vector2(a[x].x - a[y].x, a[x].z - a[y].z).length() >= 1500.0, "попарно ≥ min_sep_m")
	check(counts.size() >= 2, "N зависит от места: %s" % str(counts.keys()))
	check(kinds.size() == 3, "все три вида при весах 1/1/1: %s" % str(kinds.keys()))


func test_n_by_place_key() -> void:
	# центры в пределах одной клетки 0,05° — тот же N и тот же набор
	var m := _all_sea_coast()
	var a := ShipPlacer.ships_for(m, 10.0, 20.0, _params(), Callable())
	var b := ShipPlacer.ships_for(m, 10.0, 20.0, _params(), Callable())
	check(a == b and a.size() >= 2 and a.size() <= 6, "N=%d" % a.size())


## Везде полоса: значение 100 (берег ~9,9 км) — суда годны по всему квадрату 30 км.
func _all_sea_coast() -> Dictionary:
	return _mask(func(_i: int) -> int: return 100)


func test_same_ship_from_two_places() -> void:
	var m := _all_sea_coast()
	var p := _params()
	p["n_min"] = 6
	p["n_max"] = 6
	p["min_sep_m"] = 0
	p["center_max_m"] = 60000
	var c1 := Vector2(-27.7176, -48.7799)
	var c2 := c1 + Vector2(0.1, 0.1)
	var by_cell := {}
	for s in ShipPlacer.ships_for(m, c1.x, c1.y, p, Callable()):
		by_cell[s.cell] = s
	var cells := ShipPlacer.ships_for(m, c2.x, c2.y, p, Callable())
	var kinds := PackedStringArray(["bulk", "container", "tanker"])
	var cum := PackedFloat64Array([1.0, 2.0, 3.0])
	for s in cells:
		var o: Dictionary = ShipPlacer.ship_in_cell(s.cell, 0.02, kinds, cum)
		var ll2 := TerrainGeo.local_to_latlon(s.x, s.z, c2.x, c2.y)
		var dn := (float(o.lat) - ll2.x) * TerrainGeo.meters_per_deg_lat()
		var de := (float(o.lon) - ll2.y) * TerrainGeo.meters_per_deg_lon(ll2.x)
		check(sqrt(dn * dn + de * de) < 1.0, "клетка %s: точка до 1 м" % s.cell)
		check(s.type == o.type and is_equal_approx(float(s.heading_rad), float(o.heading_rad)), "клетка %s: вид и курс" % s.cell)
		if by_cell.has(s.cell):
			var q: Dictionary = by_cell[s.cell]
			check(q.type == s.type and is_equal_approx(float(q.heading_rad), float(s.heading_rad)), "клетка %s: то же судно из двух мест" % s.cell)
			var ll1 := TerrainGeo.local_to_latlon(q.x, q.z, c1.x, c1.y)
			var d1 := (ll1.x - ll2.x) * TerrainGeo.meters_per_deg_lat()
			var d2 := (ll1.y - ll2.y) * TerrainGeo.meters_per_deg_lon(ll1.x)
			check(sqrt(d1 * d1 + d2 * d2) < 1.0, "клетка %s: точка из двух мест до 1 м" % s.cell)
	check(cells.size() == 6, "6 судов: %d" % cells.size())


func test_shore_distance() -> void:
	var m := _shore_mask()
	var ships := ShipPlacer.ships_for(m, 10.0, 20.0, _params(), Callable())
	# берег — 80 км западнее центра: полоса 3–15 км от него дальше 30 км от центра — судов нет
	check(ships.is_empty(), "полоса далеко от центра — судов нет")
	# вся вода дальше 15 км от берега или ближе 3 км
	check(ShipPlacer.ships_for(_mask(func(_i: int) -> int: return 20), 10.0, 20.0, _params(), Callable()).is_empty(), "маска 20 (< 31) — нет")
	check(ShipPlacer.ships_for(_mask(func(_i: int) -> int: return 152), 10.0, 20.0, _params(), Callable()).is_empty(), "маска 152 (> 151) — нет")
	check(ShipPlacer.ships_for(_mask(func(_i: int) -> int: return 255), 10.0, 20.0, _params(), Callable()).is_empty(), "открытое море далеко от берега — нет")
	check(not ShipPlacer.ships_for(_mask(func(_i: int) -> int: return 31), 10.0, 20.0, _params(), Callable()).is_empty(), "маска 31 — есть")
	check(not ShipPlacer.ships_for(_mask(func(_i: int) -> int: return 151), 10.0, 20.0, _params(), Callable()).is_empty(), "маска 151 — есть")


func test_waterline_from_height_fn() -> void:
	var m := _all_sea_coast()
	var level := func(x: float, _z: float) -> float: return -28.0 if x < 0.0 else 0.0
	var ships := ShipPlacer.ships_for(m, 42.0, 50.0, _params(), level)
	check(not ships.is_empty(), "суда есть")
	for s in ships:
		check(float(s.y) == (-28.0 if float(s.x) < 0.0 else 0.0), "y = высота рельефа в точке")
	for s in ShipPlacer.ships_for(m, 42.0, 50.0, _params(), Callable()):
		check(float(s.y) == 0.0, "без height_fn — 0 м")


func test_empty_mask() -> void:
	check(ShipPlacer.ships_for({}, 0.0, 0.0, _params(), Callable()).is_empty(), "нет маски — []")
	var zero := _mask(func(_i: int) -> int: return 0)
	check(ShipPlacer.ships_for(zero, -27.0, -48.0, _params(), Callable()).is_empty(), "маска без моря — []")


func test_cell_candidate_and_weights() -> void:
	var kinds := PackedStringArray(["a", "b"])
	var cum := PackedFloat64Array([1.0, 1.0])  # вес b = 0
	var sum_r := 0.0
	var tot := 0
	for cy in range(-100, 100):
		for cx in range(-100, 100):
			var s := ShipPlacer.ship_in_cell(Vector2i(cx, cy), 0.02, kinds, cum)
			tot += 1
			sum_r += float(s.r)
			check(s.type == "a", "вид с весом 0 не выбирается")
			check(float(s.r) >= 0.0 and float(s.r) < 1.0, "ранг в [0,1)")
			check(float(s.lon) >= cx * 0.02 - 1e-9 and float(s.lon) < (cx + 1) * 0.02 + 1e-9, "точка в клетке по долготе")
			check(float(s.lat) >= cy * 0.02 - 1e-9 and float(s.lat) < (cy + 1) * 0.02 + 1e-9, "точка в клетке по широте")
	check(absf(sum_r / tot - 0.5) < 0.02, "средний ранг ≈ 0,5: %.3f" % (sum_r / tot))
