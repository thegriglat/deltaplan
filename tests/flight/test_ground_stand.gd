extends TestCase
## FB-3: крыло стоя на земле в обоих режимах управления («Смещение веса» — FlightModel + GroundRun,
## «Маятник» — PendulumModel + PendulumGround). Стоя 10 с без ввода (штиль и встречный 5 м/с,
## ровно и склон) — киль у горизонта, нос вверх [0°, +10°], размах тангажа ≤ 2°; боковой ветер —
## крыло без ввода встаёт против ветра (флюгер). FB-К2: касание консолью до перехода в лётное
## положение — не срыв, после — срыв, как раньше. Пачка с мышью и порывами —
## tests/flight/ground_pose_diag.tscn.

const FS := preload("res://tests/flight/flight_sim.gd")
const PS := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const WINGS := ["training", "sport"]
const SLOPE_DEG := 15.0


static func _make(mode: String, wing: String) -> Variant:
	return FS.make(wing) if mode == "fm" else PS.make(wing)


static func _flat() -> Callable:
	return func(_x: float, _z: float) -> float: return 0.0


## Склон вниз на север (пилот смотрит на север, −Z).
static func _slope() -> Callable:
	var k := tan(deg_to_rad(SLOPE_DEG))
	return func(_x: float, z: float) -> float: return k * z


## Склон вверх вправо (на восток) на deg — консоль справа ближе к земле.
static func _side_slope(deg: float) -> Callable:
	var k := tan(deg_to_rad(deg))
	return func(x: float, _z: float) -> float: return k * x


static func _wind(v: Vector3) -> Callable:
	if v == Vector3.ZERO:
		return Callable()
	return func(_p: Vector3) -> Vector3: return v


static func _input(roll := 0.0, run := false) -> ControlInput:
	var c := ControlInput.new()
	c.weight_shift = true
	c.roll = roll
	c.run = run
	return c


## → {theta0, lo, hi, heading, failed}, градусы.
static func _stand(m: Variant, seconds: float, inp: ControlInput, af: Callable, gf: Callable) -> Dictionary:
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var out := {"theta0": NAN, "lo": INF, "hi": -INF, "failed": ""}
	for i in int(round(seconds / DT)):
		m.step(DT, inp, af, gf)
		if m.mode == FlightModel.Mode.FAILED:
			out.failed = String(m.takeoff_failure)
			break
		var th: float = rad_to_deg(m.theta)
		if i == 0:
			out.theta0 = th
		out.lo = minf(out.lo, th)
		out.hi = maxf(out.hi, th)
	out.heading = rad_to_deg(m.heading)
	return out


func test_stand_pitch_steady_both_modes() -> void:
	var winds := {"штиль": Vector3.ZERO, "встречный 5": Vector3(0.0, 0.0, 5.0)}
	var grounds := {"ровно": _flat(), "склон": _slope()}
	for mode in ["fm", "pd"]:
		for w: String in WINGS:
			for wn: String in winds:
				for gn: String in grounds:
					var r := _stand(_make(mode, w), 10.0, _input(), _wind(winds[wn]), grounds[gn])
					var tag := "%s %s %s %s" % [mode, w, wn, gn]
					check(r.failed == "", "%s: не падает (%s)" % [tag, r.failed])
					check(r.theta0 >= 0.0 and r.theta0 <= 10.0, "%s: начальный тангаж %.2f° в [0, 10]" % [tag, r.theta0])
					check(r.hi - r.lo <= 2.0, "%s: размах тангажа %.2f° ≤ 2°" % [tag, r.hi - r.lo])


## Ветер с востока 5 м/с, пилот смотрит на север: без ввода крыло встаёт носом на восток.
func test_crosswind_weathervane_both_modes() -> void:
	for mode in ["fm", "pd"]:
		for w: String in WINGS:
			var r := _stand(_make(mode, w), 10.0, _input(), _wind(Vector3(-5.0, 0.0, 0.0)), _flat())
			var tag := "%s %s" % [mode, w]
			check(r.failed == "", "%s: не падает (%s)" % [tag, r.failed])
			check(absf(r.heading - 90.0) < 20.0, "%s: курс %.1f° → против ветра (90°)" % [tag, r.heading])
	# штиль — курс стоит
	for mode in ["fm", "pd"]:
		var r := _stand(_make(mode, "training"), 5.0, _input(), Callable(), _flat())
		check(absf(r.heading) < 1.0, "%s: в штиль курс стоит (%.2f°)" % [mode, r.heading])


## Крен рукой вправо до упора на косогоре 10° вверх вправо: консоль касается склона. До перехода
## в лётное положение — не срыв (стоя 2 с и на бегу 2 с), после start_flight_position() — срыв.
func test_wingtip_contact_before_flight_position() -> void:
	var gf := _side_slope(10.0)
	for mode in ["fm", "pd"]:
		var m: Variant = _make(mode, "training")
		m.reset_on_ground(Vector3.ZERO, 0.0)
		check(not m.flight_position_started, "%s: флаг сброшен" % mode)
		var touched := false
		for i in int(4.0 / DT):
			var inp := _input(1.0, i * DT >= 2.0)
			m.step(DT, inp, Callable(), gf)
			touched = touched or _tip_touch(m, gf)
			if m.mode != FlightModel.Mode.GROUND:
				break
		check(touched, "%s: консоль коснулась склона" % mode)
		check(m.mode != FlightModel.Mode.FAILED, "%s: до перехода касание — не срыв (%s)" % [mode, m.takeoff_failure])
		var m2: Variant = _make(mode, "training")
		m2.reset_on_ground(Vector3.ZERO, 0.0)
		m2.start_flight_position()
		for i in int(2.0 / DT):
			m2.step(DT, _input(1.0), Callable(), gf)
			if m2.mode == FlightModel.Mode.FAILED:
				break
		check(m2.mode == FlightModel.Mode.FAILED, "%s: после перехода касание консолью — срыв" % mode)
		check(m2.takeoff_failure == "wingtip", "%s: причина wingtip (%s)" % [mode, m2.takeoff_failure])


## Консоль на земле или ниже (5 см допуск — контакт пружинный).
static func _tip_touch(m: Variant, gf: Callable) -> bool:
	if m is PendulumModel:
		return m._wing_contact(gf, false) >= 0 or _pd_tip_near(m, gf)
	return m._ground._tip_depth(m, gf, m.bank) >= -0.05


static func _pd_tip_near(m: PendulumModel, gf: Callable) -> bool:
	for i in [1, 2]:
		var p: Vector3 = m._pos + m._R * m._contact_pts[i]
		if -(m._od + p.z) - m._ground_alt(gf, p) < 0.05:
			return true
	return false
