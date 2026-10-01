extends Node
## Ан-2 (E3): трасса над долиной 150–500 м над рельефом на постоянной высоте н.у.м., условия
## появления, траектория — функция времени. Рельеф грузится напрямую, как в test_egg_place.

const An2 := preload("res://scripts/world_objects/easter_eggs/an2.gd")

static var _cache := {}

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


class Objs:
	extends Node
	var osm: OsmData
	var camp: Array[Dictionary] = []


func _place(id: String) -> EggPlace:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		var o := Objs.new()
		o.osm = OsmData.load_file("res://data/osm/%s.json" % id, t.center_lat, t.center_lon)
		_cache[id] = EggPlace.build(t, o)
	return _cache[id]


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.an2


func _ctx(place: EggPlace, t := 100.0) -> EggContext:
	var c := EggContext.new()
	c.t = t
	c.world_key = "K"
	c.place = place
	c.month = 7
	c.sun_elev_deg = 45.0
	c.sky = "clear"
	c.wind_ms = 3.0
	c.pilot_pos = _start_pilot(place) if place != null else Vector3(0, 800, 0)
	if place != null:
		c.height_at = func(x: float, z: float) -> float: return place.height_at(x, z)
	return c


## Пробует несколько сидов; возвращает найденные пасхалки.
func _tracks(place: EggPlace, n: int) -> Array:
	var out := []
	for s in n:
		var egg := An2.new()
		var rng := RandomNumberGenerator.new()
		rng.seed = 1000 + s
		egg.t0 = 100.0
		egg.begin(_ctx(place), _cfg(), rng, 100.0)
		if egg.track_ok:
			out.append(egg)
		else:
			egg.free()
	return out


func _start_pilot(place: EggPlace) -> Vector3:
	var st := place.start_sites()
	return st[0].position if not st.is_empty() else Vector3.ZERO


func test_all_locations_table() -> void:
	print(
		"         loc       найдено  высота_мсl      над_рельефом_м   мин_до_старта_км  макс_уклон_°"
	)
	for id in ["altai", "askarovo", "aushkul", "ongudai"]:
		var p := _place(id)
		var ctx := _ctx(p)
		ctx.pilot_pos = _start_pilot(p)
		var found := 0
		var amin := INF
		var amax := -INF
		var hmin := INF
		var hmax := -INF
		var dmin := INF
		var smax := 0.0
		for sd in 12:
			var egg := An2.new()
			var rng := RandomNumberGenerator.new()
			rng.seed = 2000 + sd
			egg.t0 = 100.0
			egg.begin(ctx, _cfg(), rng, 100.0)
			if not egg.track_ok:
				egg.free()
				continue
			found += 1
			hmin = minf(hmin, egg.alt_msl)
			hmax = maxf(hmax, egg.alt_msl)
			for i in int(egg.length_m() / 100.0) + 1:
				var q: Vector3 = egg.pos_at(100.0 + i * 2.0)
				var agl := q.y - p.height_at(q.x, q.z)
				amin = minf(amin, agl)
				amax = maxf(amax, agl)
				check(absf(q.y - egg.alt_msl) < 1e-3, "%s: высота н.у.м. постоянна" % id)
				check(not p.is_mountain(q.x, q.z), "%s: не над горами" % id)
				smax = maxf(smax, p.slope_deg_at(q.x, q.z))
				var pts: Array[Vector3] = [ctx.pilot_pos]
				for site in p.start_sites():
					pts.append(site.position)
				for c in pts:
					dmin = minf(dmin, Vector2(q.x - c.x, q.z - c.z).length())
			check(egg.length_m() >= 8000.0 and egg.length_m() <= 12000.0, "длина 8-12 км")
			egg.free()
		if found > 0:
			check(amin >= 150.0 and amax <= 500.0, "%s: над рельефом %.0f..%.0f" % [id, amin, amax])
			check(smax <= 6.0 + 1e-3, "%s: уклон %.1f" % [id, smax])
			# проба каждые 2 с = 100 м; зона проверена по пробам 200 м, допуск на промежутки
			check(dmin >= 5800.0, "%s: до старта/пилота %.0f м" % [id, dmin])
		print(
			(
				"         %-9s %2d из 12  %5.0f..%-5.0f   %4.0f..%-4.0f        %5.1f            %4.1f"
				% [id, found, hmin, hmax, amin, amax, dmin / 1000.0, smax]
			)
		)


func test_can_appear() -> void:
	var p := _place("askarovo")
	var cfg := _cfg()
	check(An2.can_appear(_ctx(p), cfg), "день, лето, тихо — да")
	var c := _ctx(p)
	c.sun_elev_deg = -10.0
	check(not An2.can_appear(c, cfg), "ночью нет")
	c = _ctx(p)
	c.month = 1
	check(not An2.can_appear(c, cfg), "зимой нет")
	c = _ctx(p)
	c.sky = "overcast"
	check(not An2.can_appear(c, cfg), "overcast нет")
	c = _ctx(p)
	c.wind_ms = 12.0
	check(not An2.can_appear(c, cfg), "сильный ветер нет")
	check(not An2.can_appear(_ctx(null), cfg), "без места нет")


func test_time_function() -> void:
	var p := _place("askarovo")
	var found := _tracks(p, 8)
	check(not found.is_empty(), "трасса есть")
	if found.is_empty():
		return
	var egg: EasterEgg = found[0]
	add_child(egg)
	# прогон подряд и прыжок в то же t дают то же положение
	var pos_run := Vector3.ZERO
	for t in [110.0, 150.0, 200.0]:
		egg.update(_ctx(p, t))
		pos_run = egg.position
	egg.update(_ctx(p, 50.0))
	check(not egg.update(_ctx(p, 50.0)), "до t0 — не существует")
	egg.update(_ctx(p, 200.0))
	check(egg.position.is_equal_approx(pos_run), "прыжок = прогон")
	check(not egg.update(_ctx(p, 100.0 + egg.lifetime_s + 1.0)), "после пролёта — конец")
	egg.free()
