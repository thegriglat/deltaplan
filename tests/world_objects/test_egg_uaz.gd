extends TestCase
## Пасхалка E7 «УАЗик с пылевым шлейфом»: условия, положение на дороге, детерминизм, пыль.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_uaz

const LOCATIONS := ["askarovo", "aushkul"]

static var _cache := {}


class Objs:
	extends Node
	var camp: Array[Dictionary] = []


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.uaz


func _place(id: String) -> EggPlace:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		var o := Objs.new()
		_cache[id] = EggPlace.build(t, o)
	return _cache[id]


func _ctx(place: EggPlace, t := 100.0) -> EggContext:
	var c := EggContext.new()
	c.t = t
	c.world_key = "K"
	c.sun_elev_deg = 50.0
	c.month = 7
	c.sky = "clear"
	c.temp_c = 22.0
	c.place = place
	if place != null:
		c.height_at = place.height_at
	var s := place.start_sites() if place != null else ([] as Array[Dictionary])
	c.pilot_pos = s[0].position + Vector3.UP * 100.0 if not s.is_empty() else Vector3.ZERO
	return c


func _egg(ctx: EggContext, seed_v := 5, t0 := 10.0) -> EggUaz:
	var e := EggUaz.new()
	e.t0 = t0
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	e.begin(ctx, _cfg(), rng, t0)
	return e


func test_conditions() -> void:
	var cfg := _cfg()
	for id in LOCATIONS:
		var p := _place(id)
		check(EggUaz.can_appear(_ctx(p), cfg), "%s: день, ровный открытый грунт — да" % id)
		var night := _ctx(p)
		night.sun_elev_deg = -5.0
		check(not EggUaz.can_appear(night, cfg), "%s: ночью — нет" % id)
	check(not EggUaz.can_appear(_ctx(null), cfg), "без мира — нет")
	var no_ground := cfg.duplicate()
	no_ground["max_slope_deg"] = -1.0
	check(not EggUaz.can_appear(_ctx(_place("askarovo")), no_ground), "нет годного грунта — нет")


func test_off_road_route() -> void:
	var cfg := _cfg()
	var rr: Array = cfg.route_m
	for id in LOCATIONS:
		var p := _place(id)
		var ctx := _ctx(p)
		var e := _egg(ctx)
		check(e.car_count() >= 1, "%s: машина есть" % id)
		for inf: Dictionary in e.info:
			check(inf.route_m >= float(cfg.min_route_m) - 1.0, "%s: маршрут %.0f м ≥ min" % [id, inf.route_m])
			check(inf.route_m <= float(rr[1]) + 40.0, "%s: маршрут %.0f м ≤ route_m[1]" % [id, inf.route_m])
		for i in e.car_count():
			for t in [10.0, 40.0, 95.0, 300.0, 1234.5]:
				var q := e.car_position(i, t)
				var s := p.surface_at(q.x, q.y)
				check(
					s in [SurfaceLayer.GRASS, SurfaceLayer.CROP, SurfaceLayer.SHRUB, SurfaceLayer.NONE],
					"%s: машина %d, t=%s на открытом грунте, класс %d" % [id, i, t, s]
				)
				check(
					p.slope_deg_at(q.x, q.y) <= float(cfg.max_slope_deg) + 0.5,
					"%s: машина %d, t=%s: уклон %.1f°" % [id, i, t, p.slope_deg_at(q.x, q.y)]
				)
				check(
					p.above_valley_m(q.x, q.y) <= float((cfg.above_valley_m as Array)[1]) + 1.0,
					"%s: машина %d, t=%s низко над дном" % [id, i, t]
				)
		e.free()


func test_search_is_cheap() -> void:
	for id in LOCATIONS:
		var p := _place(id)
		var ctx := _ctx(p)
		var t0 := Time.get_ticks_usec()
		var ok := EggUaz.can_appear(ctx, _cfg())
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		check(ok and ms < 200.0, "%s: поиск места %.0f мс (≤ 200)" % [id, ms])


func test_trajectory_deterministic_and_moves() -> void:
	var p := _place("askarovo")
	var a := _egg(_ctx(p), 11)
	var b := _egg(_ctx(p), 11)
	var c := _egg(_ctx(p), 12)
	check(a.car_count() == b.car_count(), "одинаковое число машин")
	for t in [20.0, 77.0, 500.0]:
		check(a.car_position(0, t).is_equal_approx(b.car_position(0, t)), "один rng — один путь")
	var moved := 0.0  # путь по секундным шагам: на коротком маршруте машина разворачивается
	for k in 10:
		moved += a.car_position(0, 20.0 + k).distance_to(a.car_position(0, 21.0 + k))
	check(moved > 100.0 and moved < 190.0, "за 10 с проехала %.1f м (55–65 км/ч)" % moved)
	var same := true
	for t in [20.0, 77.0, 500.0]:
		if not a.car_position(0, t).is_equal_approx(c.car_position(0, t)):
			same = false
	check(not same, "другой rng — другой путь")
	a.free()
	b.free()
	c.free()


func test_dust_only_in_dry() -> void:
	var cfg := _cfg()
	var ctx := _ctx(_place("askarovo"))
	check(EggUaz.is_dusty(ctx, cfg), "ясно и тепло — пыль")
	ctx.sky = "overcast"
	check(not EggUaz.is_dusty(ctx, cfg), "overcast — без пыли")
	ctx.sky = "clear"
	ctx.temp_c = 2.0
	check(not EggUaz.is_dusty(ctx, cfg), "холодно — без пыли")
	var e := _egg(_ctx(_place("askarovo")))
	var dry := _ctx(_place("askarovo"), 60.0)
	e.update(dry)
	check(e.dust_visible(0), "update в сухую погоду: пыль видна")
	var wet := _ctx(_place("askarovo"), 61.0)
	wet.sky = "overcast"
	e.update(wet)
	check(not e.dust_visible(0), "update при overcast: пыли нет")
	e.free()


func test_no_world_fallback() -> void:
	var e := _egg(_ctx(null))
	check(e.car_count() >= 1, "без мира — машина на запасном маршруте")
	check(e.update(_ctx(null, 50.0)), "update без мира")
	e.free()
