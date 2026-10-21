extends TestCase
## Контракт TW-К5 v6 (docs/contracts/tow.md): трос и статическая лебёдка, TowLine, configs/tow.json. Инварианты (1)-(9).
## Среда как tests/contracts/test_tow_k4.gd: «Маятник», крыло sport, шаг 1/120 с, ровная земля, лебёдка на
## rope_length_m впереди по курсу. W = TowLine.start() + бег пилота; в воздухе пилот держит тангаж (П-регулятор 0,2/град).

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const ANCHOR_H := 1.5  ## высота узла выхода троса над землёй, м
const T_START := 1.0  ## с: W нажата


class Run:
	extends RefCounted
	var m: PendulumModel
	var tow: TowLine
	var t := 0.0
	var th0 := 0.0
	var roll := 0.0
	var started := false
	var flat := func(_x: float, _z: float) -> float: return 0.0

	func _init(cfg: Dictionary = {}, start_at := T_START) -> void:
		var ref := Sim.make("sport")
		Sim.reset(ref)
		th0 = ref.theta
		m = Sim.make("sport")
		m.reset_on_ground(Vector3.ZERO, 0.0)
		var rope := float(Config.get_config("tow").winch_static.rope_length_m)
		tow = TowLine.create("winch_static", Vector3(0.0, ANCHOR_H, -rope), cfg)
		m.set_external_force(tow.force_fn())
		_start_at = start_at

	var _start_at := 1.0

	## Один шаг физики 1/120 с: бег после старта, в воздухе — удержание тангажа.
	func step() -> void:
		if not started and t >= _start_at:
			started = true
			tow.start()
		var c := Sim.input(0.0, roll)
		c.run = started
		if m.mode == FlightModel.Mode.AIR:
			c.pitch = clampf(-0.2 * rad_to_deg(m.theta - th0), -1.0, 1.0)
		m.step(DT, c, Callable(), flat)
		t += DT

	func alt() -> float:
		return m.pilot_position.y


func test_slack_is_slack() -> void:
	# (1) d < L → T = 0, slack: сразу после start() и до выбора слабины
	var r := Run.new()
	var tmax := 0.0
	for i in int(2.0 / DT):
		r.step()
		tmax = maxf(tmax, r.m.link_tension_n)
	check(tmax == 0.0, "d < L: натяжение нулевое: %.1f Н" % tmax)
	check(r.tow.state == "slack" and r.tow.phase == "slack", "состояние slack/slack: %s/%s" % [r.tow.state, r.tow.phase])
	check(r.tow.length_m > 1000.0 and r.tow.length_m < 1000.0 + 5.0 + 1.0, "L = d + слабина: %.2f" % r.tow.length_m)


func test_idle_then_slack_then_ground() -> void:
	# (9) до start() 10 с — пилот стоит, T = 0, idle; после — slack → ground без скачка
	var r := Run.new({}, 10.0)
	var x0 := r.m.pilot_position
	for i in int(10.0 / DT) - 1:
		r.step()
	check(r.tow.phase == "idle" and r.tow.tension_n == 0.0 and r.m.link_tension_n == 0.0, "idle: T = 0, фаза idle")
	check(r.m.pilot_position.distance_to(x0) < 0.05, "пилот стоит: %.3f м" % r.m.pilot_position.distance_to(x0))
	check(r.tow.force_fn().call({"h": 0.01, "pilot_pos": Vector3.ZERO, "hang_pos": Vector3.ZERO,
		"pilot_vel": Vector3.ZERO, "hang_vel": Vector3.ZERO, "link_tension_n": 0.0, "on_ground": true,
		"wing_basis": Basis.IDENTITY, "t": 0.0}) == {}, "idle: звена нет")
	var seen := {}
	var tmax := 0.0
	var prev := 0.0
	var jump := 0.0
	for i in int(40.0 / DT):
		r.step()
		seen[r.tow.phase] = true
		tmax = maxf(tmax, r.m.link_tension_n)
		jump = maxf(jump, absf(r.m.link_tension_n - prev))
		prev = r.m.link_tension_n
		if r.tow.phase == "ground" and r.tow.tension_n > 0.0 and r.m.mode == FlightModel.Mode.AIR:
			break
	print("    idle→ground: фазы %s, T max %.0f Н, макс скачок за подшаг %.0f Н" % [seen.keys(), tmax, jump])
	check(seen.has("slack") and seen.has("ground"), "после start(): slack → ground: %s" % [seen.keys()])
	var tg: float = r.tow.cfg_rope.weak_link_daN
	check(tmax <= Config.get_config("tow").winch_static.tension_ground_daN * 10.0 * 1.25,
		"натяжение на старте не выше tension_ground·1,25: %.0f Н" % tmax)
	check(tg > 0.0, "конфиг прочитан")


## Подъём до фазы top (или до таймаута). → {top: bool, h_top, t_max, shift_max, monotone, took_off, hist}.
func _climb(cfg: Dictionary = {}, roll_after := -1.0, roll := 0.0) -> Dictionary:
	var r := Run.new(cfg)
	var res := {"run": r, "top": false, "t_max": 0.0, "shift_max": 0.0, "monotone": true, "h_top": 0.0,
		"took_off": false, "t_air": -1.0, "lock": -1.0, "broken": false, "peak": 0.0}
	var hmax := 0.0
	var phases := {}
	for i in int(240.0 / DT):
		r.step()
		phases[r.tow.phase] = true
		res.t_max = maxf(res.t_max, r.m.link_tension_n)
		res.shift_max = maxf(res.shift_max, maxf(absf(r.m.pilot_shift.x), absf(r.m.pilot_shift.y)))
		if r.m.mode == FlightModel.Mode.AIR and res.t_air < 0.0:
			res.t_air = r.t
			res.took_off = true
		if res.took_off:
			if r.t > res.t_air + 3.0:  # первые секунды после отрыва — выход на высоту
				if r.alt() < hmax - 2.0:
					res.monotone = false
			hmax = maxf(hmax, r.alt())
		res.peak = hmax
		if roll_after >= 0.0 and res.took_off and r.t > res.t_air + roll_after:
			r.roll = roll
			if res.lock < 0.0 and r.tow.lockout_angle_deg > r.tow.cfg.lockout_deg:
				res.lock = r.t - (res.t_air + roll_after)
				break
		if r.tow.state == "broken":
			res.broken = true
			break
		if r.tow.phase == "top" and roll_after < 0.0:
			res.top = true
			res.h_top = r.alt()
			break
		if r.m.mode == FlightModel.Mode.FAILED or not Sim.finite(r.m):
			break
	res.phases = phases.keys()
	return res


func test_climb_to_top() -> void:
	# (2) набор до фазы top: высота растёт, T < слабого звена, высота ≥ 0,25·rope_length
	var res := _climb()
	var r: Run = res.run
	print("    набор: отрыв %.1f с, фазы %s, top=%s, h %.0f м, T max %.0f Н, shift max %.3f, угол %.1f°, t %.1f с, L %.0f" % [
		res.t_air, res.phases, res.top, res.h_top, res.t_max, res.shift_max, r.tow.rope_angle_deg, r.t, r.tow.length_m])
	check(Sim.finite(r.m), "модель конечна")
	check(res.took_off, "пилот оторвался")
	check(res.top, "достигнута фаза top")
	check(res.monotone, "высота растёт (просадка ≤ 2 м)")
	check(res.h_top >= 0.25 * 1000.0, "высота к концу набора ≥ 0,25·L: %.0f м" % res.h_top)
	check(res.t_max < 1250.0, "T ниже слабого звена: %.0f Н" % res.t_max)


## (2) v7: порог pilot_shift снят (управляемость на тросе решает шлюз Q3, TW-16) — тест только печатает замер.
func test_climb_pilot_shift() -> void:
	var res := _climb()
	print("    pilot_shift max в наборе: %.3f (T max %.0f Н)" % [res.shift_max, res.t_max])
	check(Sim.finite(res.run.m), "модель конечна")


func test_lockout_reproduced() -> void:
	# (3)+(8) постоянный ввод крена в наборе → угол lock-out выше lockout_deg за ≤ 20 с (поправка рук TW-К4 включена)
	for roll in [0.5, -0.5]:
		var res := _climb({}, 3.0, roll)
		var r: Run = res.run
		print("    lock-out (крен %+.1f): за %.1f с, угол %.1f°, T max %.0f Н, broken=%s" % [
			roll, res.lock, r.tow.lockout_angle_deg, res.t_max, res.broken])
		check(res.lock >= 0.0 and res.lock <= 20.0, "крен %+.1f: lock-out за ≤ 20 с: %.1f с" % [roll, res.lock])


func test_release_instant() -> void:
	# (4)
	var res := _climb()  # до фазы top
	var r: Run = res.run
	check(r.m.mode == FlightModel.Mode.AIR, "в воздухе")
	var got := []
	r.tow.released.connect(func(reason: String) -> void: got.append(reason))
	r.tow.release("pilot")
	r.tow.release("pilot")
	r.step()
	check(r.m.link_tension_n == 0.0 and r.m.external_force_n == Vector3.ZERO, "сила 0 на ближайшем подшаге")
	check(r.tow.state == "released", "state released")
	check(got == ["pilot"], "сигнал released(pilot) один раз: %s" % [got])
	for i in int(10.0 / DT):
		r.step()
	check(Sim.finite(r.m), "после отцепа модель конечна 10 с")


func test_weak_link_breaks() -> void:
	# (5)
	var res := _climb({"winch_static": {"tension_climb_daN": 200.0, "tension_ground_daN": 41.0}})
	var r: Run = res.run
	var got := [0]
	print("    слабое звено: broken=%s, T max %.0f Н, t %.1f с" % [res.broken, res.t_max, r.t])
	check(res.broken and r.tow.state == "broken", "tension_climb 200 даН > слабого звена 125 → broken")
	check(res.t_max >= 1249.0, "обрыв при T ≥ 1250 Н (125 даН): %.0f" % res.t_max)
	check(r.tow.force_fn().call({"h": 0.01, "pilot_pos": Vector3.ZERO, "hang_pos": Vector3.ZERO,
		"pilot_vel": Vector3.ZERO, "hang_vel": Vector3.ZERO, "link_tension_n": 0.0, "on_ground": false,
		"wing_basis": Basis.IDENTITY, "t": 0.0}) == {}, "после обрыва звена нет")
	for i in int(10.0 / DT):
		r.step()
	check(Sim.finite(r.m), "после обрыва модель конечна 10 с")
	got.clear()


func test_points() -> void:
	# (6)
	var tow := TowLine.create("winch_static", Vector3(0.0, 1.5, -1000.0))
	var f := tow.force_fn()
	f.call({"h": 0.002, "pilot_pos": Vector3(0.0, 1.0, 0.0), "hang_pos": Vector3(0.0, 2.0, 0.0),
		"pilot_vel": Vector3.ZERO, "hang_vel": Vector3.ZERO, "link_tension_n": 0.0, "on_ground": true,
		"wing_basis": Basis.IDENTITY, "t": 0.0})
	var p := tow.points(8)
	check(p.size() == 8, "8 точек")
	check(p[0].distance_to(Vector3(0.0, 1.0, 0.0)) < 1.0e-6, "первая — точка крепления")
	check(p[7].distance_to(Vector3(0.0, 1.5, -1000.0)) < 1.0e-6, "последняя — якорь")
	check(tow.points(2).size() == 2, "n = 2")


func test_free_rope_reeled_in() -> void:
	# (7)
	var res := _climb()
	var r: Run = res.run
	r.tow.release("pilot")
	r.step()
	var y0 := r.tow.end_pos.y
	var vmax := 0.0
	var tt := 0.0
	var ymin := y0
	r.tow.ground_fn = r.flat
	while not r.tow.reeled_in and tt < 300.0:
		r.tow.step_free(DT)
		tt += DT
		vmax = maxf(vmax, r.tow.end_vel.length())
		ymin = minf(ymin, r.tow.end_pos.y)
	print("    свободный трос: с высоты %.0f м, v max %.1f м/с, выбран за %.1f с, ymin %.2f" % [y0, vmax, tt, ymin])
	check(ymin < y0 - 5.0, "конец снижается")
	check(vmax < 60.0, "скорость конца ограничена (парашют): %.1f м/с" % vmax)
	check(r.tow.reeled_in, "reeled_in за конечное время: %.1f с" % tt)
	check(r.tow.points(8).is_empty(), "после выбора points пусто")
