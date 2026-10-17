extends TestCase
## Пасхалка start_dog (DOG-K4): появление по месту-дню, покой как функция времени, погоня за
## бегущим, остановка до бровки, лай вслед, путь домой в обход палатки, лапы без скольжения.
## Рельеф синтетический: склон 12° вниз по курсу старта, обрыв 20 м на along = +12 м.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_egg_start_dog

const SLOPE_DEG := 12.0
const CLIFF_ALONG := 12.0
const DT := 1.0 / 60.0


## Фальшивый WorldObjects: лагерь, старт лагеря, индекс препятствий.
class Objs:
	extends Node
	var camp: Array[Dictionary] = []
	var camp_start: Dictionary = {}
	var obstacles := ObstacleIndex.new()


## Старт в начале координат, курс 0 (на север, −Z): along = −z, lat = x.
static func ground(x: float, z: float, cliff := CLIFF_ALONG) -> float:
	var along := -z
	return -tan(deg_to_rad(SLOPE_DEG)) * along - (20.0 if along > cliff else 0.0) + 0.0 * x


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.start_dog


func _tent(along: float, lat: float) -> Dictionary:
	var p := Vector3(lat, ground(lat, -along), -along)
	return {
		"type": "tent", "position": p, "basis": Basis.IDENTITY, "yaw": 0.0, "color": 0, "radius": 1.8
	}


## Лагерь: палатки (along, lat); blockers — «палатки» только в индексе (не точки отдыха).
func _place(tents: Array, blockers: Array = [], gear: Array = []) -> EggPlace:
	var o := Objs.new()
	o.camp_start = {"position": Vector3.ZERO, "heading_deg": 0.0}
	for t: Vector2 in tents:
		var d := _tent(t.x, t.y)
		o.camp.append(d)
		var p: Vector3 = d.position
		o.obstacles.add_box(p.x, p.z, 1.5, 1.0, 0.0, p.y - 0.5, p.y + 1.3, "tent")
	for b: Vector2 in blockers:
		o.obstacles.add_box(b.y, -b.x, 2.0, 1.5, 0.0, -50.0, 50.0, "tent")
	for g: Vector2 in gear:
		o.obstacles.add_box(g.y, -g.x, 1.0, 0.5, 0.0, -50.0, 50.0, "gear")
	var pl := EggPlace.build(null, o)
	o.free()
	return pl


func _ctx(pl: EggPlace, t: float, cliff := CLIFF_ALONG) -> EggContext:
	var c := EggContext.new()
	c.t = t
	c.world_key = "D"
	c.sun_elev_deg = 40.0
	c.month = 7
	c.day = 15
	c.place = pl
	c.height_at = func(x: float, z: float) -> float: return ground(x, z, cliff)
	c.pilot_pos = Vector3(0.0, 1.5, 16.0)
	return c


func _dog(c: EggContext, seed_i := 3) -> EggStartDog:
	var e := EggStartDog.new()
	e.t0 = c.t
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	e.begin(c, _cfg(), rng, c.t)
	e.update(c)
	return e


func _along(p: Vector3) -> float:
	return -p.z


## Бегущий по сценарию: стоит до t_run, бежит 6,5 м/с из along0, на along +10 — отрыв, дальше вверх.
func _runner(t: float, t_run: float, along0: float) -> Dictionary:
	var r := {"id": 0, "heading_deg": 0.0}
	var fwd := Vector3(0.0, 0.0, -1.0)
	if t < t_run:
		r.pos = Vector3(0.0, ground(0.0, -along0) + 1.5, -along0)
		r.vel = Vector3.ZERO
		r.phase = "standing"
		return r
	var a := along0 + 6.5 * (t - t_run)
	if a < 10.0:
		r.pos = Vector3(0.0, ground(0.0, -a) + 1.5, -a)
		r.vel = fwd * 6.5
		r.phase = "running"
		return r
	var tf := t - t_run - (10.0 - along0) / 6.5
	r.pos = Vector3(0.0, ground(0.0, -10.0) + 1.5 + 1.5 * tf, -(10.0 + 9.0 * tf))
	r.vel = fwd * 9.0 + Vector3.UP * 1.5
	r.phase = "flying"
	return r


func test_present_share() -> void:
	var cfg := _cfg()
	var n := 0
	var same := true
	for i in 20:
		for k in 20:
			var s := Vector3(137.0 * i - 1200.0, 300.0, -91.0 * k + 450.0)
			var m := 1 + (i * 7 + k) % 12
			var d := 1 + (i * 3 + k * 5) % 28
			var a := EggStartDog.present(s, m, d, cfg)
			same = same and a == EggStartDog.present(s, m, d, cfg)
			n += 1 if a else 0
	var share := n / 400.0
	check(share >= 0.5 and share <= 0.7, "(g) доля мест-дней %.3f в [0,5; 0,7]" % share)
	check(same, "(g) повтор — тот же ответ")
	var pl := _place([Vector2(-35.0, -15.0)])
	var c := _ctx(pl, 10.0)
	var cs := pl.camp_start()
	var want := EggStartDog.present(cs.position, c.month, c.day, cfg)
	check(EggStartDog.can_appear(c, cfg) == want, "can_appear = present() днём с лагерем")
	c.sun_elev_deg = -10.0
	check(not EggStartDog.can_appear(c, cfg), "ночью нет")
	var empty := _ctx(_place([]), 10.0)
	check(not EggStartDog.can_appear(empty, cfg), "без лагеря нет")


## Сценарий: собака в 15 м от старта, пилот стоит 5 с, бежит, отрывается у бровки.
func test_chase_edge_home() -> void:
	var cfg := _cfg()
	var pl := _place([Vector2(-12.0, -9.0)])
	var t0 := 100.0
	var c := _ctx(pl, t0)
	var e := _dog(c)
	var p0: Vector3 = e.info().pos
	check(absf(Vector2(p0.x, p0.z).length() - 15.0) < 3.5, "собака у старта: %.1f м" % Vector2(p0.x, p0.z).length())
	var t_run := t0 + 5.0
	var along0 := -16.0
	var t_fly := t_run + (10.0 - along0) / 6.5
	var react_max := float((cfg.react_s as Array)[1])
	var t_chase := INF
	var min_aim := INF
	var max_along := -INF
	var bad_y := 0
	var nan := false
	var min_gap := INF
	var slip_max := 0.0
	var t_home := INF
	var barks_run := 0
	var barks_edge := 0
	var t := t0
	var seen_edge := false
	while t < t_fly + 60.0:
		t += DT
		c.t = t
		var r := _runner(t, t_run, along0)
		c.runners = [r] as Array[Dictionary]
		e.update(c)
		var inf := e.info()
		var p: Vector3 = inf.pos
		if not (p.is_finite() and e.position.is_finite() and is_finite(float(inf.speed))):
			nan = true
			break
		if absf(e.position.y - ground(e.position.x, e.position.z)) > 0.05:
			bad_y += 1
		max_along = maxf(max_along, _along(e.position))
		if inf.state == "chase" and t_chase == INF:
			t_chase = t
		if inf.state == "chase" and t <= t_run + 4.0:
			var aim: Vector3 = inf.aim
			min_aim = minf(min_aim, Vector2(aim.x - p.x, aim.z - p.z).length())
		if r.phase == "running":
			var rp: Vector3 = r.pos
			min_gap = minf(min_gap, Vector2(rp.x - p.x, rp.z - p.z).length())
			barks_run = int(inf.barks)
		if inf.state == "edge":
			seen_edge = true
			barks_edge = int(inf.barks)
		var v := float(inf.speed)
		var sp := float(((cfg.anims as Dictionary).get(inf.anim, {}) as Dictionary).get("speed_ms", 0.0))
		if v > 0.5:
			if sp <= 0.0:
				slip_max = INF
			else:
				slip_max = maxf(slip_max, absf(float(inf.anim_scale) * sp - v) / v)
		var home: Vector3 = inf.home
		if (
			t > t_fly
			and t_home == INF
			and seen_edge
			and not inf.state in ["chase", "edge", "return"]
			and Vector2(p.x - home.x, p.z - home.z).length() <= float(inf.home_r)
		):
			t_home = t
	check(not nan, "(c) без NaN")
	check(t_chase - t_run <= react_max + 0.1, "(a) погоня через %.2f с ≤ %.2f" % [t_chase - t_run, react_max + 0.1])
	check(min_aim <= 3.0, "(b) за 4 с бега у своей точки сбоку: %.2f м ≤ 3" % min_aim)
	check(max_along <= 11.5, "(c) не дальше бровки: along %.2f ≤ 11,5" % max_along)
	check(bad_y == 0, "(c) на земле ±0,05 м (мимо %d)" % bad_y)
	check(min_gap >= 1.5 - 1e-3, "(h) не ближе 1,5 м к бегущему: %.2f" % min_gap)
	check(slip_max <= 0.1, "(e) проскальзывание %.3f ≤ 0,1" % slip_max)
	check(seen_edge, "после отрыва — у бровки (edge)")
	check(barks_run >= 1, "лает на бегу (%d)" % barks_run)
	check(barks_edge > barks_run, "лает вслед (%d > %d)" % [barks_edge, barks_run])
	check(t_home - t_fly <= 40.0, "(d) дома через %.1f с ≤ 40" % (t_home - t_fly))
	print("         start_dog: погоня +%.2f с, у цели %.2f м, along ≤ %.2f, зазор %.2f, скольжение %.3f, дома +%.1f с, гавков %d" % [t_chase - t_run, min_aim, max_along, min_gap, slip_max, t_home - t_fly, barks_edge])
	e.free()


## Стоящий и идущий рядом пилот погоню не вызывает.
func test_no_chase_standing() -> void:
	var pl := _place([Vector2(-12.0, -9.0), Vector2(-30.0, -14.0)], [], [Vector2(-6.0, -14.0)])
	var c := _ctx(pl, 0.0)
	var e := _dog(c)
	var chased := false
	var t := 0.0
	while t < 300.0:
		t += 1.0 / 30.0
		c.t = t
		var p: Vector3 = e.info().pos
		var walk := fmod(t, 60.0) > 30.0
		var rp := p + Vector3(3.0, 1.5, 0.0)
		c.runners = [
			{"id": 0, "pos": rp, "vel": Vector3(1.0, 0, 0) if walk else Vector3.ZERO, "phase": "walking" if walk else "standing", "heading_deg": 90.0}
		] as Array[Dictionary]
		e.update(c)
		chased = chased or e.info().state == "chase"
	check(not chased, "(f) стоящий/идущий пилот 300 с рядом — погони нет")
	e.free()


## Палатка (в индексе) на пути домой — собака в её круг не заходит.
func test_tent_on_way_home() -> void:
	var blk := Vector2(-10.0, -2.0)  # along, lat
	var pl := _place([Vector2(-32.0, 0.0)], [blk])
	var r_blk := Vector2(2.0, 1.5).length()
	var c := _ctx(pl, 0.0)
	var e := _dog(c, 11)
	var t_run := 3.0
	var t := 0.0
	var min_d := INF
	var returned := false
	while t < 70.0:
		t += DT
		c.t = t
		c.runners = [_runner(t, t_run, -16.0)] as Array[Dictionary]
		e.update(c)
		var p: Vector3 = e.info().pos
		min_d = minf(min_d, Vector2(p.x - blk.y, p.z + blk.x).length())
		returned = returned or e.info().state == "return"
	check(returned, "(i) шла домой")
	check(min_d >= r_blk, "(i) в круг палатки не заходит: %.2f ≥ %.2f" % [min_d, r_blk])
	check(min_d < r_blk + 3.0, "(i) палатка и правда на пути: ближе всего %.2f м" % min_d)
	e.free()


## Покой без бегущих: шаг 1/30 и 1/60 — к 120 с то же состояние и место.
func test_rest_frame_independent() -> void:
	var pl := _place(
		[Vector2(-30.0, -14.0), Vector2(-34.0, -20.0), Vector2(-28.0, 18.0)], [], [Vector2(-6.0, -14.0), Vector2(-9.0, 16.0)]
	)
	var res: Array = []
	var states := {}
	for fps in [30, 60]:
		var c := _ctx(pl, 0.0)
		var e := _dog(c, 7)
		var corridor := false
		for i in range(1, fps * 600 + 1):
			c.t = float(i) / fps
			e.update(c)
			var inf := e.info()
			states[inf.state] = true
			var p: Vector3 = inf.pos
			if _along(p) > -8.0 and absf(p.x) < 11.0:
				corridor = true
			if i == fps * 120:
				res.append([inf.state, p])
		check(not corridor, "в покое коридор разбега свободен (%d кадр/с)" % fps)
		e.free()
	check(res.size() == 2, "оба прогона дошли до 120 с")
	if res.size() == 2:
		var a: Array = res[0]
		var b: Array = res[1]
		check(a[0] == b[0], "(j) состояние %s / %s" % [a[0], b[0]])
		var pa: Vector3 = a[1]
		var pb: Vector3 = b[1]
		check(pa.distance_to(pb) <= 0.05, "(j) место ±0,05 м: %.3f" % pa.distance_to(pb))
	check(states.has("wander") and states.has("rest"), "бродит и отдыхает: %s" % [states.keys()])


## Без бегущих: ≈ треть времени в движении, есть пробежки (трусца/галоп), не за бровкой, не в коридоре,
## не сквозь палатки и вещи, на земле.
func test_moves_third() -> void:
	var tents := [Vector2(-30.0, -14.0), Vector2(-34.0, -20.0), Vector2(-28.0, 18.0)]
	var pl := _place(tents, [], [Vector2(-6.0, -14.0), Vector2(-9.0, 16.0)])
	var share_all: Array = []
	for seed_i in [7, 21, 33]:
		var c := _ctx(pl, 0.0)
		var e := _dog(c, seed_i)
		var moving := 0
		var fast := 0
		var n := 0
		var bad := ""
		for i in range(1, 10 * 3600 + 1):
			c.t = i / 10.0
			e.update(c)
			var inf := e.info()
			var p: Vector3 = inf.pos
			var v := float(inf.speed)
			n += 1
			moving += 1 if v > 0.15 else 0
			fast += 1 if v > 3.0 else 0
			if _along(p) > 11.5 or (_along(p) > -8.0 and absf(p.x) < 11.0):
				bad = "за бровкой/в коридоре: along %.1f lat %.1f" % [_along(p), p.x]
			for t: Vector2 in tents:
				if Vector2(p.x - t.y, p.z + t.x).length() < 1.8:
					bad = "в палатке"
			if absf(e.position.y - ground(e.position.x, e.position.z)) > 0.05:
				bad = "не на земле"
		var share := float(moving) / n
		share_all.append(share)
		check(share >= 0.25 and share <= 0.42, "сид %d: в движении %.2f времени (≈ треть)" % [seed_i, share])
		check(fast > 0, "сид %d: пробежки быстрее 3 м/с есть (%.1f%%)" % [seed_i, 100.0 * fast / n])
		check(bad == "", "сид %d: %s" % [seed_i, bad])
		e.free()
	print("         start_dog: доля движения по сидам %s" % [share_all])


## Настоящий разбег: бегущий из along 0 разгоняется до 10 м/с за 4 с (2,5 м/с²), отрыв на along +20;
## склон 12° без обрыва до along 40 (вперёд держит max_along_m). Собака в покое у точки (along, lat).
func _real_runner(t: float, t_run: float) -> Dictionary:
	var v_max := 10.0
	var t_acc := 4.0
	var r := {"id": 0, "heading_deg": 0.0}
	var fwd := Vector3(0.0, 0.0, -1.0)
	var tau := t - t_run
	if tau < 0.0:
		r.pos = Vector3(0.0, ground(0.0, 0.0, 40.0) + 1.5, 0.0)
		r.vel = Vector3.ZERO
		r.phase = "standing"
		return r
	var acc := v_max / t_acc
	var a := 0.5 * acc * tau * tau if tau < t_acc else 0.5 * v_max * t_acc + v_max * (tau - t_acc)
	var v := minf(acc * tau, v_max)
	var a_fly := 0.5 * v_max * t_acc
	if a <= a_fly + 1e-6:
		r.pos = Vector3(0.0, ground(0.0, -a, 40.0) + 1.5, -a)
		r.vel = fwd * v
		r.phase = "running"
		return r
	var tf := tau - t_acc
	r.pos = Vector3(0.0, ground(0.0, -a_fly, 40.0) + 1.5 + 1.5 * tf, -a)
	r.vel = fwd * v_max + Vector3.UP * 1.5
	r.phase = "flying"
	return r


## Собака в покое ровно у точки (along, lat): единственная точка отдыха.
func _dog_at(c: EggContext, along: float, lat: float, seed_i := 3) -> EggStartDog:
	var e := EggStartDog.new()
	e.t0 = c.t
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	e.begin(c, _cfg(), rng, c.t)
	e._anchors.clear()
	e._anchors.append(Vector2(lat, -along))
	e._weights = PackedFloat32Array([1.0])
	e._ep_anchor = 0
	e._segs.clear()
	e._seg_i = 0
	e.update(c)
	return e


func test_real_run() -> void:
	var cfg := _cfg()
	var vmax := float(cfg.gallop_max_ms)
	var pl := _place([Vector2(-40.0, -30.0)])
	# (along, lat) старта собаки: 17 м сбоку-позади и 12 м (у вещей, другой бок)
	for start: Vector2 in [Vector2(-8.0, 15.0), Vector2(-9.0, -8.0)]:
		for seed_i in [3, 5, 9]:
			var t0 := 50.0
			var c := _ctx(pl, t0, 40.0)
			var e := _dog_at(c, start.x, start.y, seed_i)
			var p0: Vector3 = e.info().pos
			check(absf(-p0.z - start.x) < 0.01 and absf(p0.x - start.y) < 0.01, "собака на старте сценария")
			var t_run := t0 + 2.0
			var t := t0
			var near := 0.0
			var slip_max := 0.0
			var v_top := 0.0
			var min_gap := INF
			var bad_y := 0
			var max_along := -INF
			var fin := INF
			while t < t_run + 4.0:
				t += DT
				c.t = t
				var r := _real_runner(t, t_run)
				c.runners = [r] as Array[Dictionary]
				e.update(c)
				var inf := e.info()
				var p: Vector3 = inf.pos
				var aim: Vector3 = inf.aim
				var v := float(inf.speed)
				v_top = maxf(v_top, v)
				max_along = maxf(max_along, -p.z)
				if absf(e.position.y - ground(e.position.x, e.position.z, 40.0)) > 0.05:
					bad_y += 1
				if r.phase == "running":
					var rp: Vector3 = r.pos
					min_gap = minf(min_gap, Vector2(rp.x - p.x, rp.z - p.z).length())
					if inf.state == "chase":
						var ds := Vector2(aim.x - p.x, aim.z - p.z).length()
						fin = ds
						near += DT if ds <= 4.0 else 0.0
				var sp := float(((cfg.anims as Dictionary).get(inf.anim, {}) as Dictionary).get("speed_ms", 0.0))
				if v > 0.5:
					slip_max = maxf(slip_max, INF if sp <= 0.0 else absf(float(inf.anim_scale) * sp - v) / v)
			var tag := "старт (%.0f, %.0f) сид %d" % [start.x, start.y, seed_i]
			check(near >= 1.0, "%s: у точки сбоку ≤ 4 м %.2f с ≥ 1 до отрыва (у отрыва %.1f м)" % [tag, near, fin])
			check(slip_max <= 0.1, "%s: проскальзывание %.3f ≤ 0,1" % [tag, slip_max])
			check(v_top <= vmax + 0.05, "%s: скорость %.2f ≤ %.1f" % [tag, v_top, vmax])
			check(min_gap >= 1.5 - 1e-3, "%s: не ближе 1,5 м к бегущему: %.2f" % [tag, min_gap])
			check(bad_y == 0, "%s: на земле (мимо %d)" % [tag, bad_y])
			check(max_along <= float(cfg.max_along_m) + 0.05, "%s: along %.2f ≤ max_along" % [tag, max_along])
			print("         start_dog: %s — у точки сбоку %.2f с, у отрыва %.1f м, скорость ≤ %.1f, скольжение %.3f" % [tag, near, fin, v_top, slip_max])
			e.free()


## Бегущий быстрее собаки (13 м/с): бежит следом не быстрее gallop_max_ms, не телепортируется.
func test_runner_faster() -> void:
	var cfg := _cfg()
	var vmax := float(cfg.gallop_max_ms)
	var pl := _place([Vector2(-40.0, -30.0)])
	var t0 := 50.0
	var c := _ctx(pl, t0, 40.0)
	var e := _dog_at(c, -8.0, 15.0)
	var t := t0
	var v_top := 0.0
	var jump := 0.0
	var prev: Vector3 = e.info().pos
	var chased := false
	while t < t0 + 4.0:
		t += DT
		c.t = t
		var a := -30.0 + 13.0 * (t - t0)  # из-за спины собаки вперёд 13 м/с
		var r := {"id": 0, "heading_deg": 0.0, "phase": "running", "vel": Vector3(0.0, 0.0, -13.0)}
		r.pos = Vector3(0.0, ground(0.0, -a, 40.0) + 1.5, -a)
		c.runners = [r] as Array[Dictionary]
		e.update(c)
		var inf := e.info()
		var p: Vector3 = inf.pos
		chased = chased or inf.state == "chase"
		v_top = maxf(v_top, float(inf.speed))
		jump = maxf(jump, Vector2(p.x - prev.x, p.z - prev.z).length() / DT)
		prev = p
	check(chased, "бегущего быстрее собаки — погоня была")
	check(v_top <= vmax + 0.05, "скорость %.2f ≤ %.1f" % [v_top, vmax])
	check(jump <= vmax + 0.5, "без телепорта: шаг %.2f м/с" % jump)
	e.free()
