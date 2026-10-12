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
