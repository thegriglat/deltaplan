extends TestCase
## Контракт TW-К10 v2 (docs/contracts/tow.md): старт с тележки в «Маятнике». Инварианты (1)-(4).

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const ROPE_M := 60.0
const EA := 3.0e4  # аэробуксировка: 2…4·10⁴ Н (docs/research/tow/kinds.md#Параметры модели троса)
const V_TOW := 17.0  # ≈61 км/ч — скорость аэробуксировки (kinds.md)
const A_TOW := 1.5  # разгон якоря, м/с²


func _flat(_x: float, _z: float) -> float:
	return 0.0


func _dolly_model() -> PendulumModel:
	var m := Sim.make("sport")
	m.reset_on_dolly(Vector3.ZERO, 0.0, {})
	return m


## Скорость сваливания по поляре модели, м/с: вес / (½ρS·C_L max).
func _vs(m: PendulumModel) -> float:
	return sqrt(2.0 * m.mass * Units.G / (m._rho_ref * m.area * m._polar.cl_max))


## Якорь: на ROPE_M впереди пилота (север = −Z), на его высоте; разгон A_TOW до V_TOW. → fn для модели.
func _tow_fn(m: PendulumModel, cut: Array = [INF]) -> Callable:
	var p0 := m.pilot_position
	return func(s: Dictionary) -> Dictionary:
		if s.t > cut[0]:
			return {}
		var t: float = s.t
		var ta := V_TOW / A_TOW
		var d := 0.5 * A_TOW * t * t if t < ta else 0.5 * A_TOW * ta * ta + V_TOW * (t - ta)
		var v := minf(A_TOW * t, V_TOW)
		return {"link": {
			"anchor": p0 + Vector3(0.0, 0.0, -(ROPE_M + d)), "anchor_vel": Vector3(0.0, 0.0, -v),
			"length_m": ROPE_M, "compliance_m_per_n": ROPE_M / EA, "damping_s": 0.02, "at": "pilot"}}


func test_rest_without_rope() -> void:
	var m := _dolly_model()
	var p0 := m.position
	var c := Sim.input()
	var phase_ok := true
	for i in int(10.0 / DT):
		m.step(DT, c, Callable(), _flat)
		phase_ok = phase_ok and m.phase() == "dolly"
	check(Sim.finite(m), "на тележке без троса: модель конечна")
	check(phase_ok and m.dolly_attached, "phase() = \"dolly\", dolly_attached")
	check(m.position.distance_to(p0) < 1.0e-3, "неподвижна: сдвиг %.5f м" % m.position.distance_to(p0))
	check(m.velocity.length() < 1.0e-3, "скорость ~0: %.5f" % m.velocity.length())
	check(absf(rad_to_deg(m.theta) - 18.0) < 0.01, "тангаж = киль 18°: %.3f" % rad_to_deg(m.theta))
	check(absf(m.bank) < 1.0e-4, "крен 0")
	check(m.pilot_shift.length() < 0.05, "пилот у нейтрали (лётное положение): %s" % m.pilot_shift)


func test_takeoff_between_vs_and_1_4_vs() -> void:
	var m := _dolly_model()
	var vs := _vs(m)
	var took := [false]
	m.took_off.connect(func() -> void: took[0] = true)
	m.set_external_force(_tow_fn(m))
	var c := Sim.input()
	var v_air := 0.0
	var t_off := -1.0
	var worst_dv := 0.0
	var worst_da := 0.0
	var prev_v := m.velocity
	var prev_a := Vector3(m.theta, m.bank, m.heading)
	var tmax := 0.0
	var finite := true
	for i in int(40.0 / DT):
		var was_dolly := m.dolly_attached
		m.step(DT, c, Callable(), _flat)
		finite = finite and Sim.finite(m)
		tmax = maxf(tmax, m.link_tension_n)
		worst_dv = maxf(worst_dv, m.velocity.distance_to(prev_v))
		var a := Vector3(m.theta, m.bank, m.heading)
		worst_da = maxf(worst_da, rad_to_deg(maxf(absf(a.x - prev_a.x), maxf(absf(a.y - prev_a.y), absf(a.z - prev_a.z)))))
		prev_v = m.velocity
		prev_a = a
		if was_dolly and not m.dolly_attached:
			t_off = m.time_s
			v_air = m.telemetry.airspeed
			break
	print("    vs = %.2f м/с; отрыв t = %.2f с при воздушной скорости %.2f м/с (%.2f·vs), макс. натяжение %.0f Н, макс. скачок v %.3f м/с, углов %.3f°"
		% [vs, t_off, v_air, v_air / vs, tmax, worst_dv, worst_da])
	check(finite, "модель конечна")
	check(took[0] and t_off > 0.0, "сигнал took_off был")
	check(v_air >= vs and v_air <= 1.4 * vs, "отрыв при V в [vs, 1,4·vs]: %.2f не в [%.2f, %.2f]" % [v_air, vs, 1.4 * vs])
	check(worst_dv < 1.0, "скачок скорости за шаг < 1 м/с: %.3f" % worst_dv)
	check(worst_da < 2.0, "скачок углов за шаг < 2°: %.3f" % worst_da)
	check(m.mode == FlightModel.Mode.AIR and m.phase() == "flying", "после отрыва — обычный полёт: %s" % m.phase())


func test_cart_stops_after_takeoff_wing_flies() -> void:
	var m := _dolly_model()
	var cut := [INF]
	m.set_external_force(_tow_fn(m, cut))
	var c := Sim.input()
	var steps := 0
	while steps < int(40.0 / DT) and m.dolly_attached:
		m.step(DT, c, Callable(), _flat)
		steps += 1
	check(not m.dolly_attached, "отрыв случился")
	var v0 := m.dolly_vel.length()
	var pos0 := m.dolly_pos
	var x_off := m.dolly_pos.z
	# после отрыва: тележка сама (трос остаётся у крыла — 2 с, затем отцеп)
	var t_stop := -1.0
	var moved_back := false
	var tt := 0.0
	cut[0] = m.time_s + 2.0
	for i in int(60.0 / DT):
		m.step(DT, c, Callable(), _flat)
		tt += DT
		moved_back = moved_back or m.dolly_pos.z > pos0.z + 1.0e-3
		if t_stop < 0.0 and m.dolly_vel.length() == 0.0:
			t_stop = tt
		if i == int(1.0 / DT):
			check(m.phase() == "flying", "через 1 с после отрыва крыло летит: %s" % m.phase())
	print("    тележка в момент отрыва %.2f м/с, остановилась через %.1f с, путь %.1f м" % [v0, t_stop, absf(m.dolly_pos.z - x_off)])
	check(Sim.finite(m), "модель конечна")
	check(not m.dolly_attached, "dolly_attached = false")
	check(t_stop > 0.0, "тележка остановилась за конечное время")
	check(not moved_back and m.dolly_pos.z <= pos0.z + 1.0e-3, "тележка не едет назад")
	check(m.dolly_vel == Vector3.ZERO, "скорость тележки 0")


func test_no_dolly_unchanged() -> void:
	var a := Sim.make("sport")
	Sim.reset(a)
	var b := Sim.make("sport")
	Sim.reset(b)
	var c := Sim.input()
	for i in int(5.0 / DT):
		a.step(DT, c, Callable(), Callable())
		b.step(DT, c, Callable(), Callable())
	check(a.position == b.position and a.velocity == b.velocity, "без тележки поведение прежнее")
	check(not a.dolly_attached and a.dolly_pos == Vector3.ZERO, "поля тележки нулевые")
