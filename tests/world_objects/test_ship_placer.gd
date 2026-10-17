extends TestCase
## Расстановка судов (ShipPlacer, контракт S3): детерминизм по миру, расстояние до берега, пустая маска.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=ship_placer

const N := 1601  # 160 км при шаге 100 м — как far
const STEP := 100.0


func _params() -> Dictionary:
	return {"cell_deg": 0.1, "p_cell": 0.15, "min_shore_m": 2000, "types": {"tanker": 1, "bulk": 1, "container": 1}}


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


func test_deterministic() -> void:
	var m := _all_sea()
	var a := ShipPlacer.ships_for(m, -27.7176, -48.7799, _params(), Callable())
	var b := ShipPlacer.ships_for(m, -27.7176, -48.7799, _params(), Callable())
	check(a.size() > 20, "в открытом море квадрата 160 км есть суда: %d" % a.size())
	check(a == b, "одинаковый вход — одинаковые суда")
	var kinds := {}
	for s in a:
		check(s.has_all(["type", "x", "y", "z", "heading_rad", "cell"]), "поля элемента")
		check(s.cell is Vector2i and float(s.heading_rad) >= 0.0 and float(s.heading_rad) < TAU, "клетка и курс")
		kinds[s.type] = true
	check(kinds.size() == 3, "все три вида при весах 1/1/1: %s" % str(kinds.keys()))


func test_same_ship_from_two_places() -> void:
	var m := _all_sea()
	var c1 := Vector2(-27.7176, -48.7799)
	var c2 := c1 + Vector2(0.3, 0.3)
	var by_cell := {}
	for s in ShipPlacer.ships_for(m, c1.x, c1.y, _params(), Callable()):
		by_cell[s.cell] = s
	var common := 0
	for s in ShipPlacer.ships_for(m, c2.x, c2.y, _params(), Callable()):
		if not by_cell.has(s.cell):
			continue
		common += 1
		var o: Dictionary = by_cell[s.cell]
		var ll1 := TerrainGeo.local_to_latlon(o.x, o.z, c1.x, c1.y)
		var ll2 := TerrainGeo.local_to_latlon(s.x, s.z, c2.x, c2.y)
		var dn := (ll1.x - ll2.x) * TerrainGeo.meters_per_deg_lat()
		var de := (ll1.y - ll2.y) * TerrainGeo.meters_per_deg_lon(ll1.x)
		check(sqrt(dn * dn + de * de) < 1.0, "клетка %s: точка до 1 м (%.3f м)" % [s.cell, sqrt(dn * dn + de * de)])
		check(s.type == o.type and is_equal_approx(float(s.heading_rad), float(o.heading_rad)), "клетка %s: вид и курс" % s.cell)
	check(common > 10, "общие клетки двух мест: %d" % common)


func test_shore_distance() -> void:
	# значение маски растёт от западного берега: 1 + floor(i·100 / 100) (столбец 0 — суша)
	var m := _mask(func(i: int) -> int: return 0 if i == 0 else mini(255, 1 + i))
	var p := _params()
	var ships := ShipPlacer.ships_for(m, 10.0, 20.0, p, Callable())
	check(not ships.is_empty(), "суда есть")
	var min_v := 1 + int(p.min_shore_m) / 100
	var img: Image = m.image
	for s in ships:
		var i := int(roundf((float(s.x) - m.origin.x) / STEP))
		var j := int(roundf((float(s.z) - m.origin.y) / STEP))
		var v := int(img.get_pixel(i, j).r8)
		check(v >= min_v, "маска под судном %d ≥ %d" % [v, min_v])
		check(float(s.x) - m.origin.x >= float(p.min_shore_m) - STEP, "не ближе 2 км к берегу: %.0f м" % (float(s.x) - m.origin.x))
	# берег везде ближе 2 км — судов нет
	var near := _mask(func(i: int) -> int: return 20 if i > 0 else 0)
	check(ShipPlacer.ships_for(near, 10.0, 20.0, p, Callable()).is_empty(), "маска 20 (< 21) — судов нет")


func test_waterline_from_height_fn() -> void:
	var m := _all_sea()
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


func test_cell_probability_and_weights() -> void:
	var kinds := PackedStringArray(["a", "b"])
	var cum := PackedFloat64Array([1.0, 1.0])  # вес b = 0
	var n := 0
	var tot := 0
	for cy in range(-100, 100):
		for cx in range(-100, 100):
			var s := ShipPlacer.ship_in_cell(Vector2i(cx, cy), 0.1, 0.15, kinds, cum)
			tot += 1
			if s.is_empty():
				continue
			n += 1
			check(s.type == "a", "вид с весом 0 не выбирается")
			check(float(s.lon) >= cx * 0.1 - 1e-9 and float(s.lon) < (cx + 1) * 0.1 + 1e-9, "точка в клетке по долготе")
			check(float(s.lat) >= cy * 0.1 - 1e-9 and float(s.lat) < (cy + 1) * 0.1 + 1e-9, "точка в клетке по широте")
	var f := float(n) / tot
	check(absf(f - 0.15) < 0.01, "доля клеток с судном ≈ p_cell: %.4f" % f)
