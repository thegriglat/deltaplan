extends Node
## Пасхалки «шар» и «фестиваль»: условия, место на реальных локациях, снос по ветру, прыжок
## времени = прогон, MultiMesh фестиваля.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_balloon

static var _cache := {}

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Подмена WorldObjects: EggPlace читает только osm и camp.
class Objs:
	extends Node
	var osm: OsmData
	var camp: Array[Dictionary] = []


func _cfg(id := "balloon") -> Dictionary:
	return Config.get_config("easter_eggs").eggs[id]


func _place(id: String) -> EggPlace:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		var o := Objs.new()
		o.osm = OsmData.load_file("res://data/osm/%s.json" % id, t.center_lat, t.center_lon)
		_cache[id] = EggPlace.build(t, o)
	return _cache[id]


## Утро, июль, слабый ветер с запада; place — по желанию.
func _ctx(t := 100.0, place: EggPlace = null) -> EggContext:
	var c := EggContext.new()
	c.t = t
	c.world_key = "K"
	c.hour = 7.5
	c.sun_elev_deg = 12.0
	c.month = 7
	c.wind_ms = 2.0
	c.wind_from_deg = 270.0
	c.sky = "clear"
	c.place = place
	c.pilot_pos = Vector3(0.0, 500.0, 0.0)
	return c


func _egg(id: String, t0: float, ctx: EggContext, seed_v := 7) -> EggBalloon:
	var e := EggBalloon.new()
	e.t0 = t0
	e.lifetime_s = float(_cfg(id).lifetime_s)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	e.begin(ctx, _cfg(id), rng, t0)
	return e


func test_can_appear_conditions() -> void:
	var p := _place("askarovo")
	var cfg := _cfg()
	check(EggBalloon.can_appear(_ctx(0.0, p), cfg), "askarovo: утро, слабый ветер — да")
	var c := _ctx(0.0, p)
	c.hour = 13.0
	c.sun_elev_deg = 60.0
	check(not EggBalloon.can_appear(c, cfg), "днём — нет")
	c = _ctx(0.0, p)
	c.hour = 19.0
	c.sun_elev_deg = 10.0
	check(not EggBalloon.can_appear(c, cfg), "вечером — нет")
	c = _ctx(0.0, p)
	c.wind_ms = 8.0
	check(not EggBalloon.can_appear(c, cfg), "ветер 8 м/с — нет")
	c = _ctx(0.0, p)
	c.month = 1
	check(not EggBalloon.can_appear(c, cfg), "зимой — нет")
	c = _ctx(0.0, p)
	c.sky = "overcast"
	check(not EggBalloon.can_appear(c, cfg), "overcast — нет")
	check(not EggBalloon.can_appear(_ctx(0.0, null), cfg), "нет места — нет")


## Пробный контекст на локации: пилот у первого старта, ветер 2 м/с с направления from_deg.
func _loc_ctx(p: EggPlace, from_deg: float) -> EggContext:
	var c := _ctx(0.0, p)
	c.wind_from_deg = from_deg
	c.height_at = p.height_at
	var st := p.start_sites()
	if not st.is_empty():
		c.pilot_pos = st[0].position
	return c


## Askarovo: место находится при любом ветре (таблица выше), время t.
func _lc(t: float, from_deg := 270.0) -> EggContext:
	var c := _loc_ctx(_place("askarovo"), from_deg)
	c.t = t
	return c


func test_sites_on_locations() -> void:
	print(
		"         локация   ветер  место    до посёлка, км  мин. до стартов по пути, км  до пилота, км"
	)
	for id in ["askarovo", "altai", "aushkul", "ongudai"]:
		var p := _place(id)
		var found_any := false
		for from_deg in [270.0, 90.0, 0.0, 180.0]:
			var c := _loc_ctx(p, from_deg)
			var e := _egg("balloon", 0.0, c)
			var life := float(_cfg().lifetime_s)
			if e.count() == 0:
				print("         %-9s %4.0f°  нет" % [id, from_deg])
				e.free()
				continue
			found_any = true
			var b0 := e.balloon_pos(0, 0.0)
			var v := p.nearest_place(b0.x, b0.z)
			var min_st := INF
			for k in 31:
				var q := e.balloon_pos(0, life * k / 30.0)
				for st in p.start_sites():
					min_st = minf(
						min_st, Vector2(q.x - st.position.x, q.z - st.position.z).length()
					)
			var to_pilot := Vector2(b0.x - c.pilot_pos.x, b0.z - c.pilot_pos.z).length()
			print(
				(
					"         %-9s %4.0f°  нашлось  %6.1f  %20.1f  %20.1f"
					% [id, from_deg, float(v.dist_m) / 1000.0, min_st / 1000.0, to_pilot / 1000.0]
				)
			)
			check(float(v.dist_m) <= 10000.0, "%s: до посёлка ≤ 10 км" % id)
			check(
				min_st >= 5000.0 - 1.0,
				"%s/%.0f°: путь ≥ 5 км от стартов (%.0f)" % [id, from_deg, min_st]
			)
			check(to_pilot >= 5000.0, "%s: ≥ 5 км от пилота" % id)
			check(not p.is_mountain(b0.x, b0.z), "%s: точка не в горах" % id)
			check(b0.y <= 1500.0 + 1.0, "%s: рельеф ≤ 1500 м" % id)
			var sf := p.surface_at(b0.x, b0.z)
			check(
				sf != SurfaceLayer.SNOW and sf != SurfaceLayer.BARE and sf != SurfaceLayer.FOREST,
				"%s: не снег/скалы/лес" % id
			)
			check(sf != SurfaceLayer.WATER, "%s: не вода" % id)
			e.free()
		if not found_any:
			print("         %-9s ни при каком ветре места нет — шаров на карте нет" % id)


func test_no_fallback_without_place() -> void:
	var e := _egg("balloon", 0.0, _ctx(0.0, null))
	check(e.count() == 0, "нет места (рельеф не загружен) — шара нет")
	check(e.update(_ctx(10.0, null)), "пустая пасхалка живёт до конца срока, не падает")
	e.free()


func test_drift_downwind() -> void:
	# ветер с запада (270) — сносит на восток (+X); с севера (0) — на юг (+Z)
	for from_deg in [270.0, 0.0, 135.0]:
		var c := _lc(100.0, from_deg)
		var e := _egg("balloon", 100.0, c)
		var p0 := e.position
		c.t = 100.0 + 1200.0
		e.update(c)
		var d := e.position - p0
		var want := Vector2(-sin(deg_to_rad(from_deg)), cos(deg_to_rad(from_deg)))
		var got := Vector2(d.x, d.z)
		check(got.length() > 1000.0, "снос за 20 мин > 1 км (%.0f)" % got.length())
		var ang := rad_to_deg(absf(got.angle_to(want)))
		check(ang < 3.0, "ветер с %.0f°: снос по ветру ± 3° (%.2f°)" % [from_deg, ang])
		e.free()


func test_time_jump_equals_run() -> void:
	var a := _egg("balloon", 100.0, _lc(100.0))
	var b := _egg("balloon", 100.0, _lc(100.0))
	var c := _lc(100.0)
	for s in [10.0, 90.0, 300.0, 700.0, 1500.0]:
		c.t = 100.0 + s
		a.update(c)
	c.t = 100.0 + 1500.0
	b.update(c)
	check(a.position.is_equal_approx(b.position), "прыжок = прогон: узел")
	var ma := a.envelopes().multimesh
	var mb := b.envelopes().multimesh
	check(
		ma.get_instance_transform(0).origin.is_equal_approx(mb.get_instance_transform(0).origin),
		"прыжок = прогон: шар"
	)
	c.t = 100.0 + 5000.0
	check(not a.update(c), "после lifetime_s — конец")
	a.free()
	b.free()


func test_festival_multimesh() -> void:
	var counts := {}
	for seed_v in [1, 2, 3, 4, 5, 6]:
		var e := _egg("balloon_festival", 100.0, _lc(100.0), seed_v)
		var n := e.count()
		counts[n] = true
		check(n >= 15 and n <= 40, "фестиваль: %d шаров в 15–40" % n)
		check(e.envelopes().multimesh.instance_count == n, "все оболочки в одном MultiMesh")
		var mmi := 0
		for ch in e.get_children():
			if ch is MultiMeshInstance3D:
				mmi += 1
		check(mmi == 2, "два MultiMeshInstance3D (оболочки, корзины), не %d узлов" % n)
		e.free()
	check(counts.size() > 1, "число шаров зависит от rng")
	var one := _egg("balloon", 100.0, _lc(100.0))
	check(one.count() == 1, "одиночный — один шар")
	one.free()
