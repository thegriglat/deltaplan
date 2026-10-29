extends TestCase
## Клубы пыли от порывов (GustDustModel, GustDust): порог, поверхность, сырость, детерминизм, пул.
## Модель получает порыв пачкой от вызываемого значения (в игре — Atmosphere.surface_gust_many, W2 v4):
## логика события проверяется на синтетическом порыве с известным средним, пул и слой — на фасаде.


## Синтетический порыв: среднее u м/с и пульсация ±25 % по (x, z, t) — как порыв фасада по форме
## (функция точки и момента, пачкой).
static func _gust(u: float) -> Callable:
	return func(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		for i in mini(xz.size(), t.size()):
			out.append(
				maxf(u * (1.0 + 0.25 * sin(xz[i].x * 0.0131 + xz[i].y * 0.0217 + t[i] * 0.37)), 0.0)
			)
		return out


func _model(weather: Dictionary = {}, dust_over: Dictionary = {}) -> GustDustModel:
	var m := GustDustModel.new()
	var cfg := Config._deep_merge(Config.get_config("atmosphere").gust_dust, dust_over)
	m.setup(cfg, weather)
	return m


## Число событий в квадрате 40×40 клеток за 20 слотов (пачкой на слот).
func _count(m: GustDustModel, surf: Callable, gust: Callable) -> int:
	var n := 0
	var cells: Array[Vector2i] = []
	for i in 40:
		for j in 40:
			cells.append(Vector2i(i, j))
	for s in range(100, 120):
		for e in m.events(cells, s, surf, gust):
			if not e.is_empty():
				n += 1
	return n


static func _crop(_x: float, _z: float) -> int:
	return 3


static func _forest(_x: float, _z: float) -> int:
	return 1


static func _snow(_x: float, _z: float) -> int:
	return 8


func test_below_threshold_no_dust() -> void:
	var m := _model()
	check(_count(m, _crop, _gust(2.3)) == 0, "слабый ветер: клубов нет")


func test_above_threshold_has_dust_and_grows() -> void:
	var m := _model()
	var cw := _count(m, _crop, _gust(8.3))
	var cs := _count(m, _crop, _gust(15.3))
	print("gust_dust: событий за 20 слотов на 1600 клеток: порыв 8.3 м/с %d, 15.3 м/с %d" % [cw, cs])
	var t0 := Time.get_ticks_usec()
	var cells: Array[Vector2i] = []
	for i in 1000:
		cells.append(Vector2i(i, 3))
	m.events(cells, 5, Callable(), _gust(15.3))
	print("gust_dust: %.1f мкс на клетку" % ((Time.get_ticks_usec() - t0) / 1000.0))
	check(cs > 0, "сильный ветер: клубы есть (%d)" % cs)
	check(cs > cw, "чем сильнее ветер, тем больше клубов: %d > %d" % [cs, cw])
	check(m.strength(m.threshold - 0.1) == 0.0, "ниже порога сила 0")
	check(m.strength(m.threshold + m.span) == 1.0, "сила растёт до 1")
	var hmax := 0.0
	var hmin := 1.0e9
	var grid: Array[Vector2i] = []
	for i in 40:
		for j in 40:
			grid.append(Vector2i(i, j))
	for s in range(100, 110):
		for e in m.events(grid, s, _crop, _gust(15.3)):
			if not e.is_empty():
				hmax = maxf(hmax, e.h)
				hmin = minf(hmin, e.h)
				check(e.life >= 4.0 and e.life <= 19.0, "жизнь 4–19 с: %.1f" % e.life)
	check(hmin >= 2.0 and hmax <= 40.0, "высота клубов 2–40 м: %.1f…%.1f" % [hmin, hmax])


## Порыв нужен в точке кандидата и его момент: пачка получает ровно (x, z, t0) клеток по порядку.
func test_batch_gets_candidates() -> void:
	var m := _model()
	var got: Array = []
	var spy := func(xz: PackedVector2Array, t: PackedFloat64Array) -> PackedFloat32Array:
		got.append([xz, t])
		var out := PackedFloat32Array()
		out.resize(xz.size())
		return out
	var cells: Array[Vector2i] = [Vector2i(3, 4), Vector2i(-2, 7), Vector2i(0, 0)]
	m.events(cells, 42, Callable(), spy)
	check(got.size() == 1, "один вызов на пачку: %d" % got.size())
	var xz: PackedVector2Array = got[0][0]
	var ts: PackedFloat64Array = got[0][1]
	check(xz.size() == 3 and ts.size() == 3, "точка и момент на клетку")
	for i in cells.size():
		var cd := m.candidate(cells[i].x, cells[i].y, 42)
		check(
			is_equal_approx(xz[i].x, float(cd.x)) and is_equal_approx(xz[i].y, float(cd.z))
			and ts[i] == float(cd.t0),
			"кандидат %d: (x, z, t0) клетки" % i
		)
		check(
			int(floor(xz[i].x / m.cell_m)) == cells[i].x and ts[i] >= 42.0 * m.slot_s
			and ts[i] < 43.0 * m.slot_s,
			"точка внутри клетки, момент внутри слота"
		)


func test_surface_and_wet_exclude() -> void:
	var m := _model()
	var g := _gust(15.3)
	check(_count(m, _crop, g) > 0, "пашня пылит")
	check(_count(m, _forest, g) == 0, "лес не пылит")
	check(_count(m, _snow, g) == 0, "снег не пылит")
	var wet := _model({"wet": true})
	check(wet.is_wet() and _count(wet, _crop, g) == 0, "сырая погода: пыли нет")
	var ov := _model({"sky": "overcast"})
	check(_count(ov, _crop, g) == 0, "пасмурно (сырой грунт): пыли нет")


func test_deterministic_and_world_not_pilot() -> void:
	var m1 := _model()
	var m2 := _model()
	var cells: Array[Vector2i] = []
	for i in 40:
		for j in 40:
			cells.append(Vector2i(i, j))
	var e1 := m1.events(cells, 105, _crop, _gust(15.3))
	var e2 := m2.events(cells, 105, _crop, _gust(15.3))
	var found := 0
	for e in e1:
		if not e.is_empty():
			found += 1
	check(e1 == e2 and found > 0, "одинаковые события при одинаковом мире (%d)" % found)
	check(m1.event(7, 9, 105, _crop, _gust(15.3)) == e1[7 * 40 + 9], "одна клетка = та же клетка в пачке")


func _atmo(w_over: Dictionary = {}) -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(Config.get_config("weather/strong"), w_over)
	a.configure(Config.get_config("atmosphere"), w)
	a.turbulence_enabled = false
	return a


func test_node_scan_fills_pool() -> void:
	var a := _atmo({"wind_speed_kmh": 55.0})
	a.set_ground(func(_x: float, _z: float) -> float: return 0.0, func(_x: float, _z: float) -> float: return 1.0, _crop)
	var g := GustDust.new()
	a.add_child(g)
	g.setup(a, Callable(a, "_v_ground_height"), Callable(a, "_v_surface_class"))
	var t := 400.0
	a.time_s = t
	var eye := Vector3(5000, 100, 5000)
	for k in 20:
		g.step_scan(eye, t)
	var live := g.live_count(t + 3.0)
	check(live > 0, "пул заполнен, живых клубов: %d" % live)
	check(live <= int(g.cfg.events_max), "пул не больше events_max")
	check(g.mm.instance_count == int(g.cfg.events_max) * int(g.cfg.puffs_max), "один MultiMesh фиксированного размера")
	g.free()
	a.free()


## Сравнение «до/после» (RW-12z): события клеток слоя на кадре ongudai (число и позиции) при том
## же ветре равны событиям модели, которой пачку порывов отдаёт тот же фасад surface_gust_many, —
## пачка по одной клетке и по всему слоту дают одно. Эталон «до» (GustDustModel.gust_ms на WindModel)
## снимается итоговым прогоном модуля: tools/wind_fixtures на ветке до RW-12z, сверка по (x, z, t0).
func test_slot_batch_equals_single_cells() -> void:
	var a := _atmo({"wind_speed_kmh": 55.0})
	a.set_ground(func(_x: float, _z: float) -> float: return 0.0, func(_x: float, _z: float) -> float: return 1.0, _crop)
	a.time_s = 400.0
	var m := _model()
	var gust := Callable(a, "surface_gust_many")
	var cells: Array[Vector2i] = []
	for i in range(20, 40):
		for j in range(20, 40):
			cells.append(Vector2i(i, j))
	var batch := m.events(cells, 100, _crop, gust)
	var single_ok := true
	var n := 0
	for i in cells.size():
		var one := m.event(cells[i].x, cells[i].y, 100, _crop, gust)
		single_ok = single_ok and one == batch[i]
		if not one.is_empty():
			n += 1
	check(single_ok, "пачка и одиночные клетки дают те же события (событий %d)" % n)
	a.free()


## RW-3b → RW-3c: направление пыли — фоновый ветер фасада на 10 м над долиной (background_wind) —
## идёт по румбу погоды: «откуда» wind_from_deg -> единичный вектор (-sin, cos) в осях W1.
func test_dust_direction_matches_wind_dir() -> void:
	for case: Array in [["weather/weak", 270.0, 11.0], ["weather/medium", 45.0, 25.0], ["weather/strong", 135.0, 40.0]]:
		var a := Atmosphere.new()
		var w := Config.get_config(String(case[0])).duplicate(true)
		w.wind_from_deg = float(case[1])
		w.wind_speed_kmh = float(case[2])
		a.configure(Config.get_config("atmosphere"), w)
		a.set_ground(func(_x: float, _z: float) -> float: return 300.0, func(_x: float, _z: float) -> float: return 0.8)
		var g := GustDust.new()
		g.atmo = a
		var d: Vector2 = g._wind_dir()
		var d_rad := deg_to_rad(float(case[1]))
		var want := Vector2(-sin(d_rad), cos(d_rad))
		check(d.distance_to(want) < 1.0e-3, "%s %.0f°: направление %s против румба %s" % [case[0], case[1], d, want])
		g.free()
		a.free()
