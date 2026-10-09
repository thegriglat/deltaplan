extends TestCase
## Пасхалка E7 «УАЗик с пылевым шлейфом»: условия, положение на дороге, детерминизм, пыль.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_uaz

const LOCATIONS := ["askarovo", "aushkul"]

static var _cache := {}


class Objs:
	extends Node
	var osm: OsmData
	var camp: Array[Dictionary] = []


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.uaz


func _place(id: String) -> EggPlace:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		var o := Objs.new()
		o.osm = OsmData.load_file(Locations.osm_path(id), t.center_lat, t.center_lon)
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
		check(EggUaz.can_appear(_ctx(p), cfg), "%s: день, track-дороги — да" % id)
		var night := _ctx(p)
		night.sun_elev_deg = -5.0
		check(not EggUaz.can_appear(night, cfg), "%s: ночью — нет" % id)
	check(not EggUaz.can_appear(_ctx(null), cfg), "без мира — нет")
	var no_track := cfg.duplicate()
	no_track["road_classes"] = ["no_such_class"]
	check(not EggUaz.can_appear(_ctx(_place("askarovo")), no_track), "нет дорог класса — нет")


func test_on_road() -> void:
	var cfg := _cfg()
	for id in LOCATIONS:
		var p := _place(id)
		var ctx := _ctx(p)
		var e := _egg(ctx)
		check(e.car_count() >= 1, "%s: машина есть" % id)
		for i in e.car_count():
			for t in [10.0, 40.0, 95.0, 300.0, 1234.5]:
				var q := e.car_position(i, t)
				var d := p.nearest_road_m(q.x, q.y, EggUaz._classes(cfg))
				check(d < 1.0, "%s: машина %d, t=%s в %.2f м от дороги" % [id, i, t, d])
		e.free()


func test_trajectory_deterministic_and_moves() -> void:
	var p := _place("askarovo")
	var a := _egg(_ctx(p), 11)
	var b := _egg(_ctx(p), 11)
	var c := _egg(_ctx(p), 12)
	check(a.car_count() == b.car_count(), "одинаковое число машин")
	for t in [20.0, 77.0, 500.0]:
		check(a.car_position(0, t).is_equal_approx(b.car_position(0, t)), "один rng — один путь")
	var moved := a.car_position(0, 20.0).distance_to(a.car_position(0, 30.0))
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
	check(e.car_count() >= 1, "без мира — машина на запасной дороге")
	check(e.update(_ctx(null, 50.0)), "update без мира")
	e.free()
