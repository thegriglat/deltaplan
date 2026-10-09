extends TestCase
## Пасхалка E11 «орёл»: обгон у законцовки (5–15 м, +2–4 м/с), путь задан при появлении,
## уход в ближайший термик с набором, без термика — вдаль, условия появления, жизнь без места.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_eagle

const SEEDS := 24
const WING_POS := Vector3(100.0, 1800.0, -200.0)
const WING_VEL := Vector3(7.0, -1.1, -9.5)  # ~11,8 м/с по земле, курс на северо-восток

static var _place_cache: EggPlace


## Подмена воздуха: орёл читает только field.thermals и time_s.
class FakeField:
	extends RefCounted
	var thermals := {}


class FakeAir:
	extends Node3D
	var field := FakeField.new()
	var time_s := 0.0


class Objs:
	extends Node
	var osm: OsmData
	var camp: Array[Dictionary] = []


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.eagle


func _thermal(at: Vector3, strength := 2.5) -> AtmoThermal:
	var th := AtmoThermal.new()
	th.is_static = true
	th.src = at
	th.top = at.y + 2500.0
	th.strength = strength
	th.radius = 80.0
	th.lean = Vector2(0.05, -0.02)
	return th


func _ctx(air: Node3D = null) -> EggContext:
	var c := EggContext.new()
	c.pilot_pos = WING_POS
	c.air = air
	return c


func _spawn(ctx: EggContext, sd: int, wing_vel := WING_VEL) -> EggEagle:
	var e := EggEagle.new()
	e.lifetime_s = float(_cfg().lifetime_s)
	e.wing = {"pos": ctx.pilot_pos, "vel": wing_vel}
	var rng := RandomNumberGenerator.new()
	rng.seed = ("E|%d" % sd).hash()
	e.t0 = ctx.t
	e.begin(ctx, _cfg(), rng, ctx.t)
	return e


# ---------------------------------------------------------------- обгон


func test_pass_near_wingtip() -> void:
	var ctx := _ctx()
	var dmin_all := INF
	var dmax_all := 0.0
	var vmin := INF
	var vmax := 0.0
	var sides := {}
	var f := Vector3(WING_VEL.x, 0.0, WING_VEL.z).normalized()
	for sd in SEEDS:
		var e := _spawn(ctx, sd)
		sides[e.side] = true
		var dmin := INF
		var a := 0.0
		while a <= e.pass_s:
			dmin = minf(dmin, e.pos_at(a).distance_to(e.wingtip_at(a)))
			var rel_v := (e.pos_at(a + 0.05) - e.pos_at(a)) / 0.05 - WING_VEL
			vmin = minf(vmin, rel_v.length())
			vmax = maxf(vmax, rel_v.length())
			a += 0.05
		check(dmin >= 5.0 and dmin <= 15.0, "seed %d: до законцовки %.2f м ∉ [5, 15]" % [sd, dmin])
		dmin_all = minf(dmin_all, dmin)
		dmax_all = maxf(dmax_all, dmin)
		# появляется сзади-сбоку, уходит вперёд-вбок наружу
		var r0 := e.pos_at(0.0) - (WING_POS)
		var r1 := e.pos_at(e.pass_s) - (WING_POS + WING_VEL * e.pass_s)
		var right := f.cross(Vector3.UP) * e.side
		check(r0.dot(f) < -20.0, "seed %d: появляется сзади (%.1f м)" % [sd, r0.dot(f)])
		check(r0.dot(right) > 0.0, "seed %d: сбоку со своей стороны" % sd)
		check(r1.dot(f) > 20.0, "seed %d: уходит вперёд (%.1f м)" % [sd, r1.dot(f)])
		check(r1.dot(right) > r0.dot(right), "seed %d: уходит вбок наружу" % sd)
		e.free()
	check(vmin >= 2.0 - 1e-3 and vmax <= 4.0 + 1e-3, "отн. скорость %.2f–%.2f ∉ [2, 4]" % [vmin, vmax])
	check(sides.size() == 2, "бывают обе стороны")
	print(
		(
			"         мин. до законцовки %.1f–%.1f м, отн. скорость %.2f–%.2f м/с (%d сидов)"
			% [dmin_all, dmax_all, vmin, vmax, SEEDS]
		)
	)


func test_path_fixed_at_spawn() -> void:
	var ctx := _ctx()
	var e := _spawn(ctx, 5)
	var ref: Array[Vector3] = []
	for k in 60:
		ctx.t = k * 0.5
		ctx.pilot_pos = WING_POS + WING_VEL * ctx.t
		check(e.update(ctx), "жива на обгоне")
		ref.append(e.position)
	# тот же сид, но крыло после появления круто отвернуло — путь орла тот же
	var ctx2 := _ctx()
	var e2 := _spawn(ctx2, 5)
	for k in 60:
		ctx2.t = k * 0.5
		var turned := WING_VEL.rotated(Vector3.UP, 1.2)
		ctx2.pilot_pos = WING_POS + turned * ctx2.t
		e2.update(ctx2)
		check(e2.position == ref[k], "t=%.1f: путь не зависит от крыла после появления" % ctx2.t)
	e.free()
	e2.free()


# ---------------------------------------------------------------- термик


func test_goes_to_nearest_thermal_and_climbs() -> void:
	var air := FakeAir.new()
	var f := Vector3(WING_VEL.x, 0.0, WING_VEL.z).normalized()
	var near_p := WING_POS + f * 600.0 + f.cross(Vector3.UP) * 150.0
	var far_p := WING_POS + f * 1300.0 - f.cross(Vector3.UP) * 400.0
	air.field.thermals[7] = _thermal(Vector3(near_p.x, 1000.0, near_p.z))
	air.field.thermals[9] = _thermal(Vector3(far_p.x, 1000.0, far_p.z))
	air.field.thermals[11] = _thermal(Vector3(near_p.x + 50.0, 1000.0, near_p.z), 0.5)  # слабый
	var ctx := _ctx(air)
	var times: PackedFloat32Array = []
	for sd in 8:
		var e := _spawn(ctx, sd)
		check(e.thermal == air.field.thermals[7], "seed %d: выбран ближайший сильный термик" % sd)
		if e.thermal == null:
			e.free()
			continue
		var t_in := e.pass_s + e.arc_s
		times.append(t_in)
		check(t_in < 120.0, "seed %d: до термика %.0f с" % [sd, t_in])
		# дуга плавная: нет скачков положения и резких изломов курса
		var prev := e.pos_at(e.pass_s - 0.1)
		var prev_v := Vector3.ZERO
		var a := e.pass_s
		var max_jump := 0.0
		var max_turn := 0.0
		while a < t_in + 5.0:
			var p := e.pos_at(a)
			var v := (p - prev) / 0.1
			max_jump = maxf(max_jump, v.length())
			if prev_v != Vector3.ZERO:
				var h1 := Vector2(prev_v.x, prev_v.z)
				var h2 := Vector2(v.x, v.z)
				max_turn = maxf(max_turn, absf(h1.angle_to(h2)) / 0.1)
			prev = p
			prev_v = v
			a += 0.1
		check(max_jump < 40.0, "seed %d: без скачков (%.1f м/с)" % [sd, max_jump])
		check(max_turn < 1.2, "seed %d: без изломов курса (%.2f рад/с)" % [sd, max_turn])
		# кружит у оси и набирает высоту
		var th: AtmoThermal = air.field.thermals[7]
		var y0 := e.pos_at(t_in + 1.0).y
		var worst := 0.0
		for k in 60:
			var p := e.pos_at(t_in + 1.0 + k)
			var ax := th.axis_at(p.y)
			worst = maxf(worst, absf(Vector2(p.x - ax.x, p.z - ax.y).length() - 25.0))
		var y1 := e.pos_at(t_in + 61.0).y
		check(worst < 2.0, "seed %d: на круге у оси термика (±%.1f м)" % [sd, worst])
		check(y1 - y0 > 30.0, "seed %d: набор за минуту %.0f м" % [sd, y1 - y0])
		e.free()
	times.sort()
	print("         до термика %.0f–%.0f с" % [times[0], times[times.size() - 1]])
	air.free()


func test_no_thermal_leaves_far() -> void:
	var ctx := _ctx()
	var e := _spawn(ctx, 3)
	check(e.thermal == null, "термика нет")
	var gone_t := -1.0
	var k := 0
	while k < int(e.lifetime_s * 2.0):
		ctx.t = k * 0.5
		ctx.pilot_pos = WING_POS + WING_VEL * ctx.t
		if not e.update(ctx):
			gone_t = ctx.t
			break
		k += 1
	var gone_ok := gone_t > e.pass_s and gone_t < e.lifetime_s
	check(gone_ok, "исчезает вдали до конца жизни (%.0f с)" % gone_t)
	print("         без термика исчез в %.0f с" % gone_t)
	e.free()


# ---------------------------------------------------------------- условия


func _place() -> EggPlace:
	if _place_cache == null:
		var t := Terrain.new()
		t.location_id = ""
		t.load_location("altai")
		var o := Objs.new()
		o.osm = OsmData.load_file(Locations.osm_path("altai"), t.center_lat, t.center_lon)
		_place_cache = EggPlace.build(t, o)
	return _place_cache


func test_conditions() -> void:
	var cfg := _cfg()
	var pl := _place()
	var rocky := Vector3.INF
	var plain := Vector3.INF
	for i in 41:
		for j in 41:
			var x := -10000.0 + i * 500.0
			var z := -10000.0 + j * 500.0
			var p := Vector3(x, pl.height_at(x, z) + 300.0, z)
			if rocky == Vector3.INF and EggEagle.rocky_mountains(pl, p, cfg):
				rocky = p
			if plain == Vector3.INF and not pl.is_mountain(x, z):
				plain = p
	check(rocky != Vector3.INF, "на Алтае есть горы со скалами")
	check(plain != Vector3.INF, "на Алтае есть долина")
	if rocky == Vector3.INF or plain == Vector3.INF:
		return
	var air := FakeAir.new()
	air.field.thermals[1] = _thermal(Vector3(rocky.x + 300.0, rocky.y - 800.0, rocky.z))
	air.field.thermals[2] = _thermal(Vector3(plain.x + 300.0, plain.y - 800.0, plain.z))
	var c := EggContext.new()
	c.place = pl
	c.height_at = pl.height_at
	c.air = air
	c.sun_elev_deg = 40.0
	c.pilot_pos = rocky
	check(EggEagle.can_appear(c, cfg), "горы, скалы, термик, день — да")
	c.sun_elev_deg = -3.0
	check(not EggEagle.can_appear(c, cfg), "ночь/сумерки — нет")
	c.sun_elev_deg = 40.0
	c.sky = "overcast"
	check(not EggEagle.can_appear(c, cfg), "пасмурно — нет")
	c.sky = "partly"
	check(EggEagle.can_appear(c, cfg), "переменная облачность — да")
	c.pilot_pos = plain
	check(not EggEagle.can_appear(c, cfg), "равнина — нет")
	c.pilot_pos = Vector3(rocky.x, pl.height_at(rocky.x, rocky.z) + 10.0, rocky.z)
	check(not EggEagle.can_appear(c, cfg), "у самой земли — нет")
	c.pilot_pos = rocky
	air.field.thermals.clear()
	check(not EggEagle.can_appear(c, cfg), "термика рядом нет — нет")
	c.air = null
	check(not EggEagle.can_appear(c, cfg), "воздуха нет — нет")
	c.place = null
	check(not EggEagle.can_appear(c, cfg), "места нет — нет")
	air.free()


# ---------------------------------------------------------------- жизнь


func test_forced_without_place_lives() -> void:
	var ctx := EggContext.new()  # ни места, ни воздуха, ни камеры
	var e := EggEagle.new()
	e.lifetime_s = float(_cfg().lifetime_s)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	e.begin(ctx, _cfg(), rng, 0.0)
	check(e.get_child_count() == 1, "есть меш")
	check(e.update(ctx), "жива в начале")
	ctx.t = e.lifetime_s + 0.5
	check(not e.update(ctx), "кончилась после lifetime_s")
	e.free()
