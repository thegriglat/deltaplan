extends TestCase
## Пасхалка E6 «отары и табуны»: место на реальных локациях, условия, разбегание, дрейф.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_herds

const LOCATIONS := ["altai", "askarovo", "aushkul", "ongudai"]
const SEEDS := 8

static var _cache := {}


## Подмена WorldObjects: EggPlace читает только osm и camp.
class Objs:
	extends Node
	var osm: OsmData
	var camp: Array[Dictionary] = []


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.herds


func _load(id: String) -> Dictionary:
	if not _cache.has(id):
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(id)
		var o := Objs.new()
		o.osm = OsmData.load_file("res://data/osm/%s.json" % id, t.center_lat, t.center_lon)
		_cache[id] = {"terrain": t, "place": EggPlace.build(t, o)}
	return _cache[id]


func _ctx(id: String) -> EggContext:
	var d := _load(id)
	var pl: EggPlace = d.place
	var c := EggContext.new()
	c.world_key = "H|" + id
	c.place = pl
	c.terrain = d.terrain
	c.height_at = pl.height_at
	c.month = 7
	c.sun_elev_deg = 50.0
	var s := pl.start_sites()
	if not s.is_empty():
		c.pilot_pos = Vector3(s[0].position.x, s[0].position.y + 100.0, s[0].position.z)
	return c


func _spawn(ctx: EggContext, seed_i: int) -> EggHerds:
	var e := EggHerds.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = ("H|%d" % seed_i).hash()
	e.begin(ctx, _cfg(), rng, 0.0)
	e.update(ctx)
	return e


# ---------------------------------------------------------------- место


func test_placement_on_locations() -> void:
	var cfg := _cfg()
	var total := 0
	for id in LOCATIONS:
		var ctx := _ctx(id)
		var pl := ctx.place
		var found := 0
		var lines: PackedStringArray = []
		for sd in SEEDS:
			var e := _spawn(ctx, sd)
			for k in e.info.size():
				var inf: Dictionary = e.info[k]
				var c: Vector3 = inf.center
				ctx.pilot_pos = c + Vector3(0.0, 1500.0, 0.0)  # разбудить именно эту стайку
				ctx.t += 0.2
				e.update(ctx)
				found += 1
				lines.append(
					"%s:%d×%s деревня %.0f м, старт %.0f м"
					% [sd, inf.count, inf.species, inf.village_m, inf.start_m]
				)
				var s := pl.surface_at(c.x, c.z)
				check(
					s == SurfaceLayer.GRASS or s == SurfaceLayer.SHRUB,
					"%s/%d: центр на лугу, а не %s" % [id, sd, SurfaceLayer.CLASS_NAMES[s]]
				)
				check(pl.slope_deg_at(c.x, c.z) <= 20.0, "%s/%d: склон ≤ 20°" % [id, sd])
				check(not pl.is_mountain(c.x, c.z), "%s/%d: не горы" % [id, sd])
				check(inf.village_m <= 3000.0 + 1.0, "%s/%d: посёлок ≤ 3 км" % [id, sd])
				check(inf.start_m <= 10000.0 + 1.0, "%s/%d: старт ≤ 10 км" % [id, sd])
				# животные: ни леса, ни снега, ни скал, ни воды, ни пашни под ними
				for p in e.animal_positions(k):
					var sa := pl.surface_at(p.x, p.y)
					var bad := (
						sa in [SurfaceLayer.FOREST, SurfaceLayer.SNOW, SurfaceLayer.BARE]
						or sa in [SurfaceLayer.WATER, SurfaceLayer.CROP]
					)
					check(not bad, "%s/%d: животное на %s" % [id, sd, SurfaceLayer.CLASS_NAMES[sa]])
			check(e.info.size() <= 3, "не больше трёх стайок")
			e.free()
		total += found
		print("         %-9s стайки: %d за %d полётов" % [id, found, SEEDS])
		for l in lines.slice(0, 6):
			print("            " + l)
	check(total > 0, "хоть где-то стайки нашлись")
	check(cfg.drift_ms <= 0.2, "дрейф ≤ 0,2 м/с")


func test_deterministic_from_rng() -> void:
	var ctx := _ctx("aushkul")
	var a := _spawn(ctx, 3)
	var b := _spawn(ctx, 3)
	check(a.info.size() == b.info.size(), "один сид — то же число стайк")
	for i in mini(a.info.size(), b.info.size()):
		check(a.info[i].center == b.info[i].center and a.info[i].count == b.info[i].count, "то же место")
	a.free()
	b.free()


# ---------------------------------------------------------------- условия


func test_can_appear() -> void:
	var cfg := _cfg()
	var ctx := _ctx("aushkul")
	check(EggHerds.can_appear(ctx, cfg), "день, июль, посёлок есть")
	ctx.sun_elev_deg = -5.0
	check(not EggHerds.can_appear(ctx, cfg), "ночью нет")
	ctx.sun_elev_deg = 40.0
	for m in [11, 12, 1, 2, 3]:
		ctx.month = m
		check(not EggHerds.can_appear(ctx, cfg), "месяц %d: нет" % m)
	ctx.month = 4
	check(EggHerds.can_appear(ctx, cfg), "апрель: да")
	ctx.month = 10
	check(EggHerds.can_appear(ctx, cfg), "октябрь: да")
	ctx.month = 7
	ctx.wind_ms = 15.0
	check(not EggHerds.can_appear(ctx, cfg), "сильный ветер: нет")
	ctx.wind_ms = 3.0
	ctx.place = null
	check(not EggHerds.can_appear(ctx, cfg), "нет места: нет")
	# рельеф есть, OSM нет — посёлков нет
	var t: Terrain = _load("aushkul").terrain
	ctx.place = EggPlace.build(t, null)
	check(not EggHerds.can_appear(ctx, cfg), "нет посёлков OSM: нет")
	var e := EggHerds.new()
	var rng := RandomNumberGenerator.new()
	e.begin(ctx, cfg, rng, 0.0)
	check(not e.update(ctx), "без посёлков стайки нет — пасхалка снимается")
	e.free()


# ---------------------------------------------------------------- разбегание


func _mean_dist(e: EggHerds, i: int, from: Vector2) -> float:
	var s := 0.0
	var pts := e.animal_positions(i)
	for p in pts:
		s += p.distance_to(from)
	return s / maxf(pts.size(), 1)


func _run(e: EggHerds, ctx: EggContext, secs: float, pilot: Vector3, step := 0.1) -> void:
	var n := int(secs / step)
	for k in n:
		ctx.t += step
		ctx.pilot_pos = pilot
		e.update(ctx)


func _low_ctx() -> Array:
	var ctx := _ctx("aushkul")
	var e := _spawn(ctx, 1)
	return [ctx, e]


func test_flee_when_low() -> void:
	var r := _low_ctx()
	var ctx: EggContext = r[0]
	var e: EggHerds = r[1]
	check(e.herd_count() > 0, "стайка есть")
	if e.herd_count() == 0:
		return
	var c: Vector3 = e.info[0].center
	var g := ctx.height_at.call(c.x, c.z) as float
	var pil := Vector3(c.x + 30.0, g + 25.0, c.z)
	_run(e, ctx, 1.0, Vector3(c.x, g + 2000.0, c.z))
	var before := _mean_dist(e, 0, Vector2(pil.x, pil.z))
	_run(e, ctx, 5.0, pil)
	var after := _mean_dist(e, 0, Vector2(pil.x, pil.z))
	print("         разбегание: среднее расстояние до игрока %.1f → %.1f м" % [before, after])
	check(after > before + 8.0, "низко: животные удаляются от игрока (%.1f → %.1f)" % [before, after])
	# успокоились: смещение остаётся, плавно затухает, скачков нет
	var rest := ctx.pilot_pos
	rest.y += 1500.0
	_run(e, ctx, 8.0, rest)  # добегают
	var p0 := e.animal_positions(0).duplicate()
	_run(e, ctx, 10.0, rest)
	var p1 := e.animal_positions(0)
	var maxstep := 0.0
	for i in p0.size():
		maxstep = maxf(maxstep, p0[i].distance_to(p1[i]))
	check(maxstep < 10.0 * 2.0, "после успокоения за 10 с не дальше 2 м/с: %.1f м" % maxstep)
	var later := _mean_dist(e, 0, Vector2(pil.x, pil.z))
	check(later > before, "остались на новых местах, не телепорт назад")
	e.free()


func test_no_flee_when_high() -> void:
	var r := _low_ctx()
	var ctx: EggContext = r[0]
	var e: EggHerds = r[1]
	if e.herd_count() == 0:
		return
	var c: Vector3 = e.info[0].center
	var g := ctx.height_at.call(c.x, c.z) as float
	var high := Vector3(c.x + 30.0, g + 250.0, c.z)
	_run(e, ctx, 1.0, high)
	var before := _mean_dist(e, 0, Vector2(high.x, high.z))
	_run(e, ctx, 5.0, high)
	var after := _mean_dist(e, 0, Vector2(high.x, high.z))
	check(absf(after - before) < 2.0, "высоко: не разбегаются (%.1f → %.1f)" % [before, after])
	e.free()


# ---------------------------------------------------------------- дрейф


func test_drift_is_function_of_time() -> void:
	var ctx := _ctx("aushkul")
	var a := _spawn(ctx, 2)
	var b := _spawn(ctx, 2)
	if a.herd_count() == 0:
		return
	var c0: Vector3 = a.info[0].center
	var far := c0 + Vector3(0.0, 1500.0, 0.0)  # высоко над стайкой: не пугает, но она не спит
	ctx.pilot_pos = far
	# a — подряд, b — прыжком
	ctx.t = 0.0
	_run(a, ctx, 300.0, far)
	var t_end := ctx.t
	var cb := _ctx("aushkul")
	cb.pilot_pos = far
	cb.t = t_end
	b.update(cb)
	var pa := a.animal_positions(0)
	var pb := b.animal_positions(0)
	var worst := 0.0
	for i in pa.size():
		worst = maxf(worst, pa[i].distance_to(pb[i]))
	check(worst < 0.01, "прыжок = прогон, расхождение %.4f м" % worst)
	# скорость центра ≤ 0,2 м/с
	var vmax := 0.0
	var h: Dictionary = a._herds[0]
	for k in 200:
		var t1 := k * 7.0
		vmax = maxf(vmax, a.center_at(h, t1).distance_to(a.center_at(h, t1 + 1.0)))
	check(vmax <= 0.2, "скорость центра %.3f м/с ≤ 0,2" % vmax)
	a.free()
	b.free()


func test_one_multimesh_per_herd() -> void:
	var ctx := _ctx("aushkul")
	var e := _spawn(ctx, 1)
	check(e.get_child_count() == e.herd_count(), "по одному узлу на стайку")
	for c in e.get_children():
		check(c is MultiMeshInstance3D and (c as MultiMeshInstance3D).multimesh.instance_count >= 6, "MultiMesh")
	e.free()


## Последним: освободить загруженные локации (иначе выход процесса с аварией)
func test_zz_cleanup() -> void:
	for id in _cache:
		var d: Dictionary = _cache[id]
		d.place = null
		(d.terrain as Terrain).free()
	_cache.clear()
