extends TestCase
## «Догнать» — буксир (NET-42, scripts/game/catch_up_tow.gd): синтетический рельеф и
## движущаяся цель, шаг 1/120 с (как физика игры).

const DT := 1.0 / 120.0


## Синтетическая цель: летит прямо со скоростью vel; turn_at_s ≥ 0 — с этого момента
## разворачивается со скоростью turn_rate (рад/с) по кругу. Время ведёт тест (t).
class Target:
	extends RefCounted
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var climb := 0.0
	var turn_at_s := -1.0
	var turn_rate := 0.0
	var t := 0.0
	var landed_at_s := -1.0

	func advance(dt: float) -> void:
		t += dt
		if turn_at_s >= 0.0 and t >= turn_at_s:
			vel = vel.rotated(Vector3.UP, turn_rate * dt)
		pos += (vel + Vector3.UP * climb) * dt

	func get_state() -> Dictionary:
		if landed_at_s >= 0.0 and t >= landed_at_s:
			return {}
		return {"position": pos, "velocity": vel + Vector3.UP * climb}


func _cfg() -> Dictionary:
	return Config.value("net", "catch_up", {}).duplicate(true)


static func _flat(_x: float, _z: float) -> float:
	return 0.0


## Долина с хребтом: дно 500 м, склон на север (−Z) до 1500 м (старт на z=−3000).
static func _mountain(x: float, z: float) -> float:
	var ridge := 1000.0 * smoothstep(0.0, 1.0, clampf(-z / 3000.0, 0.0, 1.0))
	return 500.0 + ridge + 20.0 * sin(x * 0.01) * cos(z * 0.013)


## Хребет поперёк пути (гребень 1400 м на x = 1000, ширина ~600 м), остальное — 400 м.
static func _ridge(x: float, _z: float) -> float:
	var u := (x - 1000.0) / 300.0
	return 400.0 + 1000.0 * maxf(0.0, 1.0 - u * u)


## Прогон: шагаем цель и буксир до конца (или max_s). Возвращает сводку.
func _run(tow: CatchUpTow, tg: Target, height: Callable, max_s: float = 40.0) -> Dictionary:
	var out := {
		"min_agl": INF,
		"arrive_t": -1.0,
		"max_rel": 0.0,
		"max_jerk": 0.0,
		"acc": PackedFloat32Array(),
		"t": 0.0,
		"last": tow.last,
	}
	var prev_v: Vector3 = tow.last.velocity
	var prev_a := Vector3.ZERO
	var n := 0
	while tow.is_active() and out.t < max_s:
		tg.advance(DT)
		var r := tow.step(DT)
		out.t += DT
		n += 1
		var p: Vector3 = r.position
		if out.t > 1.0:  # с земли первые кадры — у самой земли
			out.min_agl = minf(out.min_agl, p.y - float(height.call(p.x, p.z)))
		out.max_rel = maxf(out.max_rel, r.rel_speed)
		# прибыли — купол кончился: скорость относительно цели < 1 % середины
		if out.arrive_t < 0.0 and out.t > 1.0 and r.rel_speed < 0.01 * out.max_rel:
			out.arrive_t = out.t
		var a: Vector3 = (r.velocity - prev_v) / DT
		out.acc.append(a.length())
		if n > 1:
			out.max_jerk = maxf(out.max_jerk, (a - prev_a).length() / DT)
		prev_a = a
		prev_v = r.velocity
		out.last = r
	check(tow.ground_hits == 0, "страховка «не ниже земли» сработала %d раз" % tow.ground_hits)
	return out


func _level_target(dist: float) -> Target:
	var tg := Target.new()
	tg.pos = Vector3(dist, 3000.0, 0.0)
	tg.vel = Vector3(0.0, 0.0, -12.0)
	return tg


## Путь до точки прибытия (позади-сбоку цели) — для сравнения с «10 с».
func _start(tow: CatchUpTow, tg: Target, own: Vector3, own_vel: Vector3) -> void:
	tow.start(own, own_vel, tg.get_state)


func test_profile_300m_and_2km_arrive_in_10s() -> void:
	for dist in [300.0, 2000.0]:
		var tow := CatchUpTow.new(_cfg(), _flat)
		var tg := _level_target(dist)
		# точка прибытия — в dist от нас: ставим цель так, чтобы d0 = dist
		_start(tow, tg, Vector3(0.0, 3000.0, 0.0), tg.vel)
		var d0: float = tow.last.distance
		tg.pos.x += dist - d0
		tow = CatchUpTow.new(_cfg(), _flat)
		_start(tow, tg, Vector3(0.0, 3000.0, 0.0), tg.vel)
		approx(tow.last.distance, dist, 1.0, "d0 %d" % dist)
		var r := _run(tow, tg, _flat)
		approx(r.arrive_t, 10.0, 0.5, "прибытие за 10 с, %d м" % dist)
		check(r.last.state == "done", "закончили: %s" % r.last.state)
		var tgt_d: float = r.last.target_distance
		check(tgt_d > 30.0 and tgt_d < 80.0, "до цели %.1f м" % tgt_d)


func test_profile_beyond_cap_holds_v_max() -> void:
	var cfg := _cfg()
	var v_max := float(cfg.v_max_kmh) / 3.6
	var tow := CatchUpTow.new(cfg, _flat)
	var tg := _level_target(6000.0)
	_start(tow, tg, Vector3(0.0, 3000.0, 0.0), tg.vel)
	var d0: float = tow.last.distance
	var r := _run(tow, tg, _flat)
	check(r.max_rel <= v_max + 0.01, "потолок %.1f > %.1f" % [r.max_rel, v_max])
	check(r.max_rel > v_max * 0.99, "дошли до потолка %.1f" % r.max_rel)
	approx(r.arrive_t, d0 / v_max + float(cfg.ramp_s), 0.5, "T = d/v_max + t_a")


func test_profile_smooth_no_jerk() -> void:
	var cfg := _cfg()
	var t_a := float(cfg.ramp_s)
	var tow := CatchUpTow.new(cfg, _flat)
	var tg := _level_target(2000.0)
	_start(tow, tg, Vector3(0.0, 3000.0, 0.0), tg.vel)
	var v_c: float = float(tow.last.distance) / (float(cfg.t_target_s) - t_a)
	var r := _run(tow, tg, _flat)
	var acc: PackedFloat32Array = r.acc
	var peak := 0.0
	for a in acc:
		peak = maxf(peak, a)
	# пик smootherstep: 15/8 · v / t_a
	approx(peak, 1.875 * v_c / t_a, 0.1 * peak, "пик ускорения")
	var at := func(t: float) -> float: return acc[clampi(int(round(t / DT)) - 1, 0, acc.size() - 1)]
	check(float(at.call(DT)) < 0.02 * peak, "старт: a=%.2f" % at.call(DT))
	check(float(at.call(t_a)) < 0.02 * peak, "конец разгона: a=%.2f" % at.call(t_a))
	var t_brake: float = float(cfg.t_target_s) - t_a
	check(float(at.call(t_brake)) < 0.05 * peak, "начало торможения: a=%.2f" % at.call(t_brake))
	var t_end := float(cfg.t_target_s)
	check(float(at.call(t_end)) < 0.02 * peak, "конец торможения: a=%.2f" % at.call(t_end))
	# рывок не больше теоретического (60 · v / t_a³) с запасом — без скачков ускорения
	var jerk_max := 60.0 * v_c / pow(t_a, 3.0)
	check(r.max_jerk < 1.5 * jerk_max, "рывок %.0f > %.0f" % [r.max_jerk, 1.5 * jerk_max])


## Случай 1: «отошёл за кофе» — с посадочной площадки (стоим, скорость 0) к другу
## на 1500 м над стартом.
func test_case1_from_landing_field_to_friend_above_launch() -> void:
	var tow := CatchUpTow.new(_cfg(), _mountain)
	var tg := Target.new()
	tg.pos = Vector3(200.0, 1500.0 + 1500.0, -3100.0)  # старт ~1500 м, друг на 1500 м выше
	tg.vel = Vector3(11.0, 0.0, 0.0)
	tg.climb = 1.5
	var own := Vector3(0.0, _mountain(0.0, 0.0), 0.0)
	tow.start(own, Vector3.ZERO, tg.get_state)
	var r := _run(tow, tg, _mountain)
	check(r.last.state == "done", "закончили: %s" % r.last.state)
	check(r.min_agl > 5.0, "не касаемся рельефа: %.1f" % r.min_agl)
	var p: Vector3 = r.last.position
	approx(p.y, tg.pos.y, 10.0, "на высоте цели")
	var tgt_d: float = r.last.target_distance
	check(tgt_d > 30.0 and tgt_d < 80.0, "рядом: %.1f м" % tgt_d)
	# после старта с земли — ноги не ниже земли даже в первые кадры
	var t0 := CatchUpTow.new(_cfg(), _mountain)
	t0.start(own, Vector3.ZERO, tg.get_state)
	tg.advance(DT)
	var r0 := t0.step(DT)
	check(r0.velocity.length() < 0.5, "старт с места: %.2f м/с" % r0.velocity.length())


## Случай 2: «поднять к другу» — из долины в 50 м над рельефом к другу в 2 км в стороне
## и на 1000 м выше.
func test_case2_from_valley_to_friend_2km_aside_1000m_up() -> void:
	var tow := CatchUpTow.new(_cfg(), _mountain)
	var own := Vector3(0.0, _mountain(0.0, 0.0) + 50.0, 0.0)
	var tg := Target.new()
	tg.pos = Vector3(2000.0, own.y + 1000.0, -300.0)
	tg.vel = Vector3(0.0, 0.0, -12.0)
	tow.start(own, Vector3(10.0, -1.0, 5.0), tg.get_state)
	var r := _run(tow, tg, _mountain)
	check(r.last.state == "done", "закончили: %s" % r.last.state)
	check(r.min_agl > 5.0, "не касаемся рельефа: %.1f" % r.min_agl)
	var p: Vector3 = r.last.position
	approx(p.y, tg.pos.y, 10.0, "на высоте цели")
	var tgt_d: float = r.last.target_distance
	check(tgt_d > 30.0 and tgt_d < 80.0, "рядом: %.1f м" % tgt_d)
	check(r.t < 14.0, "быстро: %.1f с" % r.t)


## Хребет выше цели поперёк пути — ни разу не ближе 30 м к рельефу.
func test_ridge_higher_than_target_clearance() -> void:
	for v_kmh in [1000.0, 300.0]:
		var cfg := _cfg()
		cfg.v_max_kmh = v_kmh
		var tow := CatchUpTow.new(cfg, _ridge)
		var own := Vector3(0.0, 450.0, 0.0)
		var tg := Target.new()
		tg.pos = Vector3(2200.0, 1100.0, 0.0)  # цель ниже гребня (1400)
		tg.vel = Vector3(0.0, 0.0, 12.0)
		tow.start(own, Vector3(12.0, 0.0, 0.0), tg.get_state)
		var r := _run(tow, tg, _ridge)
		check(r.min_agl >= 30.0, "%d км/ч: запас над рельефом %.1f м" % [v_kmh, r.min_agl])
		check(r.last.state == "done", "закончили: %s" % r.last.state)
		var p: Vector3 = r.last.position
		approx(p.y, tg.pos.y, 15.0, "%d км/ч: на высоте цели" % v_kmh)


## Цель разворачивается во время перелёта — всё равно догоняем, 30–80 м от цели.
func test_target_turning_around() -> void:
	for turn_at in [2.0, 6.0, 8.5]:
		var tow := CatchUpTow.new(_cfg(), _flat)
		var tg := Target.new()
		tg.pos = Vector3(1500.0, 2000.0, 0.0)
		tg.vel = Vector3(12.0, 0.0, 0.0)
		tg.turn_at_s = turn_at
		tg.turn_rate = PI / 8.0  # разворот за 8 с, потом кружит
		tow.start(Vector3(0.0, 1800.0, 0.0), Vector3(-10.0, 0.0, 0.0), tg.get_state)
		var r := _run(tow, tg, _flat)
		check(r.last.state == "done", "разворот на %.1f с: %s" % [turn_at, r.last.state])
		var tgt_d: float = r.last.target_distance
		check(tgt_d > 30.0 and tgt_d < 80.0, "разворот на %.1f с: до цели %.1f" % [turn_at, tgt_d])
		check(r.t < 20.0, "разворот на %.1f с: время %.1f" % [turn_at, r.t])


## Отмена — сразу стоп на месте.
func test_abort_returns_in_place() -> void:
	var tow := CatchUpTow.new(_cfg(), _flat)
	var tg := _level_target(2000.0)
	tow.start(Vector3(0.0, 2500.0, 0.0), tg.vel, tg.get_state)
	var r: Dictionary = {}
	for i in 600:
		tg.advance(DT)
		r = tow.step(DT)
	tow.abort()
	check(not tow.is_active(), "не активен")
	check(tow.last.state == "aborted", "state %s" % tow.last.state)
	check(tow.last.position == r.position, "на месте")
	var r2 := tow.step(DT)
	check(r2.position == r.position, "после отмены не двигается")


## Цель ушла из зоны / села → буксир останавливается и отдаёт управление.
func test_target_lost_stops() -> void:
	var tow := CatchUpTow.new(_cfg(), _flat)
	var tg := _level_target(2000.0)
	tg.landed_at_s = 3.0
	tow.start(Vector3(0.0, 2500.0, 0.0), tg.vel, tg.get_state)
	var r := _run(tow, tg, _flat)
	check(r.last.state == "lost", "state %s" % r.last.state)
	approx(r.t, 3.0, 0.05, "остановились сразу")
	var tow2 := CatchUpTow.new(_cfg(), _flat)
	tow2.start(Vector3.ZERO, Vector3.ZERO, tg.get_state)
	tow2.lose_target()
	check(not tow2.is_active(), "lose_target останавливает")
