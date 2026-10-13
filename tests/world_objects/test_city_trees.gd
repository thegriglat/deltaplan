extends TestCase
## Деревья города и сёл (CityTreePlan): детерминизм, не на домах и дорогах, отступ от дороги, шаг рядов,
## сады только у малых жилых домов, density_mult 0 — пусто. Синтетический город: сетка домов 40 м, дороги между ними.

const BLOCK := 40.0


func _cfg() -> Dictionary:
	return (Config.get_config("world_objects").city_trees as Dictionary).duplicate(true)


## Город 12×12 домов-многоэтажек (тип 2) + дороги по линиям x = k·40 − 20; в углу — 30 частных домов (тип 1).
func _world() -> Dictionary:
	var houses: Array = []
	for i in 12:
		for j in 12:
			houses.append([i * BLOCK, j * BLOCK, 22.0, 22.0, 0.0, 15.0, 1, 2, 0])
	for i in 30:
		houses.append([-400.0 - (i % 6) * 25.0, (i / 6) * 25.0, 8.0, 10.0, 15.0, 3.0, 0, 1, 0])
	var roads: Array = []
	for k in 13:
		roads.append({"t": "residential", "p": PackedVector2Array([Vector2(k * BLOCK - 20.0, -20.0), Vector2(k * BLOCK - 20.0, 12 * BLOCK - 20.0)]), "w": 6.0})
		roads.append({"t": "tertiary", "p": PackedVector2Array([Vector2(-20.0, k * BLOCK - 20.0), Vector2(12 * BLOCK - 20.0, k * BLOCK - 20.0)]), "w": 8.0})
	roads.append({"t": "motorway", "p": PackedVector2Array([Vector2(-200.0, 700.0), Vector2(800.0, 700.0)]), "w": 12.0})
	return {"houses": houses, "roads": roads}


func _plan(cfg: Dictionary, w: Dictionary, extra: Array = []) -> CityTreePlan:
	var p := CityTreePlan.new()
	var wc := Config.get_config("world_objects")
	p.setup(cfg, w.roads, [], w.houses, extra, wc.roads, wc.city_ground, 200.0, func(_x: float, _z: float) -> float: return 0.0)
	p.model_height.fill(14.0)
	p.prepare()
	return p


func _all(p: CityTreePlan, rng: float) -> Dictionary:
	var out := {"xf": PackedFloat32Array(), "street": 0, "yard": 0, "garden": 0}
	var t := 192.0
	for tz in range(floori(-rng / t), floori(rng / t) + 1):
		for tx in range(floori(-rng / t), floori(rng / t) + 1):
			var d := p.build_tile(tx, tz)
			out.xf.append_array(d.xf)
			for k in ["street", "yard", "garden"]:
				out[k] += int(d[k])
	return out


func test_deterministic_and_nonempty() -> void:
	var w := _world()
	var a := _all(_plan(_cfg(), w), 800.0)
	var b := _all(_plan(_cfg(), _world()), 800.0)
	check(a.xf == b.xf, "две расстановки совпадают")
	check(int(a.street) > 50, "улицы: %d" % a.street)
	check(int(a.garden) > 20, "сады: %d" % a.garden)
	check(int(a.street) + int(a.garden) + int(a.yard) == a.xf.size() / 12, "счётчики сходятся с буфером")


func test_not_on_houses_or_roads() -> void:
	var w := _world()
	var a := _all(_plan(_cfg(), w), 800.0)
	var xf: PackedFloat32Array = a.xf
	var bad_h := 0
	var bad_r := 0
	for i in xf.size() / 12:
		var x := xf[i * 12 + 3]
		var z := xf[i * 12 + 11]
		for h: Array in w.houses:
			var ang := deg_to_rad(float(h[4]))
			var dx := x - float(h[0])
			var dz := z - float(h[1])
			var lx := dx * cos(ang) + dz * sin(ang)
			var lz := -dx * sin(ang) + dz * cos(ang)
			if absf(lx) < float(h[2]) * 0.5 and absf(lz) < float(h[3]) * 0.5:
				bad_h += 1
		for r: Dictionary in w.roads:
			var pts: PackedVector2Array = r.p
			var q := Vector2(x, z)
			var c := Geometry2D.get_closest_point_to_segment(q, pts[0], pts[1])
			if q.distance_to(c) < float(r.w) * 0.5 + 0.5:
				bad_r += 1
	check(bad_h == 0, "деревьев на домах: %d" % bad_h)
	check(bad_r == 0, "деревьев на дорогах: %d" % bad_r)
	check(xf.size() > 0, "есть что проверять")


func test_street_offset_and_no_motorway() -> void:
	var w := _world()
	var cfg := _cfg()
	cfg.yard.enabled = false
	cfg.garden.enabled = false
	var a := _all(_plan(cfg, w), 800.0)
	var xf: PackedFloat32Array = a.xf
	for i in xf.size() / 12:
		var x := xf[i * 12 + 3]
		var z := xf[i * 12 + 11]
		var dmin := INF
		for r: Dictionary in w.roads:
			var pts: PackedVector2Array = r.p
			var q := Vector2(x, z)
			var d := q.distance_to(Geometry2D.get_closest_point_to_segment(q, pts[0], pts[1])) - float(r.w) * 0.5
			if String(r.t) != "motorway":
				dmin = minf(dmin, d)
			else:
				check(d > 0.0, "не на автомагистрали")
		check(dmin >= 1.4, "просвет до края любой дороги ≥ 1,5 м: %.2f" % dmin)


func test_gardens_only_small_houses() -> void:
	var w := _world()
	var cfg := _cfg()
	cfg.yard.enabled = false
	cfg.street.enabled = false
	var a := _all(_plan(cfg, w), 800.0)
	var xf: PackedFloat32Array = a.xf
	check(xf.size() > 0, "сады есть")
	for i in xf.size() / 12:
		# частные дома — слева (x ≈ −400…−275), многоэтажки (x ≥ 0) садов не дают
		check(xf[i * 12 + 3] < -200.0, "сад не у многоэтажки: x=%.1f" % xf[i * 12 + 3])


func test_density_zero_and_low() -> void:
	var w := _world()
	var cfg := _cfg()
	cfg.density_mult = 0.0
	var a := _all(_plan(cfg, w), 800.0)
	check(int(a.yard) == 0, "дворов при density 0: %d" % a.yard)
	check(int(a.garden) == 0, "садов при density 0: %d" % a.garden)
	var hi := _all(_plan(_cfg(), w), 800.0)
	cfg = _cfg()
	cfg.density_mult = 0.35
	var lo := _all(_plan(cfg, w), 800.0)
	check(int(lo.street) + int(lo.garden) + int(lo.yard) < int(hi.street) + int(hi.garden) + int(hi.yard), "low реже high")


func test_village_gardens() -> void:
	var extra: Array = []
	for i in 20:
		extra.append([1000.0 + (i % 5) * 30.0, (i / 5) * 30.0, 8.0, 10.0, 0.0, 3.0, 0])
	var p := CityTreePlan.new()
	var wc := Config.get_config("world_objects")
	p.setup(_cfg(), [], [], [], extra, wc.roads, wc.city_ground, 200.0, func(_x: float, _z: float) -> float: return 1.0)
	p.model_height.fill(14.0)
	p.prepare()
	var n := 0
	var t := 192.0
	for tz in range(0, 2):
		for tx in range(floori(900.0 / t), floori(1300.0 / t) + 1):
			var d := p.build_tile(tx, tz)
			n += int(d.garden)
			check(int(d.street) == 0 and int(d.yard) == 0, "в селе только сады")
	check(n >= 15, "садов у 20 домов села: %d" % n)


## Деревья на местах крон рельефа: только в лесных клетках города, на сетке 6 м как в terrain.gdshader.
func _crown_plan(forest: Callable) -> CityTreePlan:
	var w := _world()
	var p := CityTreePlan.new()
	var wc := Config.get_config("world_objects")
	p.setup(_cfg(), w.roads, [], w.houses, [], wc.roads, wc.city_ground, 200.0, func(_x: float, _z: float) -> float: return 0.0, forest)
	p.model_height.fill(14.0)
	p.prepare()
	return p


func _crowns(p: CityTreePlan, rng: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var t := 192.0
	for tz in range(floori(-rng / t), floori(rng / t) + 1):
		for tx in range(floori(-rng / t), floori(rng / t) + 1):
			var d := p.build_tile(tx, tz)
			# крон-деревья идут последними в буфере тайла
			var n := int(d.crown)
			var xf: PackedFloat32Array = d.xf
			out.append_array(xf.slice(xf.size() - n * 12))
	return out


func test_crown_trees_in_city_only_where_forest() -> void:
	var none := _crowns(_crown_plan(Callable()), 800.0)
	check(none.is_empty(), "без маски леса крон-деревьев нет")
	var zero := _crowns(_crown_plan(func(_x: float, _z: float) -> float: return 0.0), 800.0)
	check(zero.is_empty(), "лес 0 — крон-деревьев нет")
	var half := func(x: float, _z: float) -> float: return 1.0 if x < 200.0 else 0.0
	var a := _crowns(_crown_plan(half), 800.0)
	var all := _crowns(_crown_plan(func(_x: float, _z: float) -> float: return 1.0), 800.0)
	check(a.size() / 12 > 20, "крон-деревья есть: %d" % (a.size() / 12))
	check(all.size() > a.size(), "лесная клетка даёт больше деревьев")
	for i in a.size() / 12:
		check(a[i * 12 + 3] < 200.0, "дерево только в лесной клетке")
	# вне города (далеко от домов) деревьев нет
	for i in all.size() / 12:
		var x := all[i * 12 + 3]
		var z := all[i * 12 + 11]
		if x > 2000.0 or z > 2000.0 or x < -2000.0 or z < -2000.0:
			check(false, "крон-дерево вне города: %.0f %.0f" % [x, z])
	check(_crowns(_crown_plan(half), 800.0) == a, "расстановка детерминирована")


func test_crown_trees_on_shader_grid_and_off_houses() -> void:
	var w := _world()
	var a := _crowns(_crown_plan(func(_x: float, _z: float) -> float: return 1.0), 800.0)
	var bad_cell := 0
	var bad_h := 0
	for i in a.size() / 12:
		var x := a[i * 12 + 3]
		var z := a[i * 12 + 11]
		# центр кроны в клетке: (c + 0.5 ± 0.35) · 6 м
		var fx := fposmod(x / 6.0, 1.0)
		var fz := fposmod(z / 6.0, 1.0)
		if fx < 0.15 - 1e-3 or fx > 0.85 + 1e-3 or fz < 0.15 - 1e-3 or fz > 0.85 + 1e-3:
			bad_cell += 1
		for h: Array in w.houses:
			if absf(x - float(h[0])) < float(h[2]) * 0.5 and absf(z - float(h[1])) < float(h[3]) * 0.5 and float(h[4]) == 0.0:
				bad_h += 1
	check(bad_cell == 0, "все деревья на сетке крон шейдера: %d вне" % bad_cell)
	check(bad_h == 0, "ни одного дерева на доме: %d" % bad_h)


func test_city_mask_and_shader_gate() -> void:
	var p := _crown_plan(Callable())
	var m := p.city_mask()
	check(not m.is_empty(), "маска города есть")
	var img: Image = m.image
	check(img.get_format() == Image.FORMAT_L8, "маска L8")
	var o: Vector2 = m.origin
	var cell: float = m.cell
	var ix := clampi(int((200.0 - o.x) / cell + 0.5), 0, img.get_width() - 1)
	var iz := clampi(int((200.0 - o.y) / cell + 0.5), 0, img.get_height() - 1)
	check(img.get_pixel(ix, iz).r > 0.9, "центр города в маске: %.2f" % img.get_pixel(ix, iz).r)
	check(img.get_pixel(0, 0).r < 0.05, "край вне города 0")
	# вне города (и без CityTrees) рельеф рисует кроны как раньше: шейдер выключен по умолчанию
	var src := FileAccess.get_file_as_string("res://scripts/terrain/terrain.gdshader")
	check(src.contains("uniform bool use_city_canopy = false;"), "гашение крон по умолчанию выключено")
