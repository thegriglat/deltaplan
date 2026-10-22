extends TestCase
## Контракт TT-К3 v1 (docs/contracts/tow-trike.md): тележка дельталёта в «Маятнике» — pilot_cda_m2, arms_force_max_n,
## reset_on_wheels. Инварианты (1)-(5), каждый отдельным тестом. «Пилот» 350 кг (тележка + пилот), hang_length_m 1,2.

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const MASS := 350.0
const APP := {"hang_length_m": 1.2}
## Числа колёс — тестовые, порядка TT-К1 ground (киль 12°, отрыв рукой +8°, качение по траве, ЦМ тележки 0,5 м).
const WHEELS := {"keel_angle_deg": 12.0, "rotate_deg": 8.0, "rolling_crr": 0.04, "wheel_base_agl_m": 0.5}
const WING := "sport"
const PULL_N := 1500.0


func _flat(_x: float, _z: float) -> float:
	return 0.0


func _air_model(app: Dictionary = {}) -> PendulumModel:
	var a := APP.duplicate()
	a.merge(app, true)
	var m := Sim.make(WING, MASS, a)
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	return m


func _wheel_model() -> PendulumModel:
	var m := Sim.make(WING, MASS, APP)
	m.reset_on_wheels(Vector3.ZERO, 0.0, WHEELS)
	return m


## (1) Без новых ключей: явные значения по умолчанию дают то же, что их отсутствие, а число — прежнее
## (сняты до правки: тот же сценарий на коммите feature/tow-trike).
func test_defaults_unchanged() -> void:
	var a := _air_model()
	var b := _air_model({"pilot_cda_m2": float(a.pendulum.pilot_cda_m2), "arms_force_max_n": 300.0})
	var c := Sim.input(0.0, 0.3)
	for i in int(10.0 / DT):
		a.step(DT, c, Callable(), _flat)
		b.step(DT, c, Callable(), _flat)
	check(a.position == b.position and a.velocity == b.velocity, "явные умолчания = без ключей (равенство)")
	check(a.position == GOLD_POS and a.velocity == GOLD_VEL, "позиция и скорость через 10 с равны прежним: %s %s" % [a.position, a.velocity])


const GOLD_POS := Vector3(40.892586, 857.04346, -14.645406)
const GOLD_VEL := Vector3(-42.818306, -22.487007, -7.917438)


## (2) pilot_cda_m2 ×3 — установившаяся скорость ниже.
func test_pilot_cda() -> void:
	var cda0 := float(_air_model().pendulum.pilot_cda_m2)
	var speeds: Array[float] = []
	var glides: Array[float] = []  # скорость снижения / горизонтальная
	for k in [1.0, 3.0]:
		var m := _air_model({"pilot_cda_m2": cda0 * k})
		var c := Sim.input()
		var ok := true
		for i in int(40.0 / DT):
			m.step(DT, c, Callable(), _flat)
		ok = Sim.finite(m)
		check(ok and m.mode == FlightModel.Mode.AIR, "x%s: модель конечна, летит" % k)
		speeds.append(m.velocity.length())
		glides.append(-m.velocity.y / Vector2(m.velocity.x, m.velocity.z).length())
	print("    v уст: CdA %.2f -> %.3f м/с (снижение %.3f); x3 -> %.3f м/с (%.3f)" % [cda0, speeds[0], glides[0], speeds[1], glides[1]])
	check(speeds[1] < speeds[0], "CdA x3: скорость ниже (%.3f < %.3f)" % [speeds[1], speeds[0]])
	check(glides[1] > glides[0], "CdA x3: планирование круче (%.3f > %.3f)" % [glides[1], glides[0]])


## Ход пилота поперёк за первую 1 с полного ввода по крену, доля от shift_y_max.
func _roll_stroke(force_max: float) -> float:
	var m := _air_model({"arms_force_max_n": force_max} if force_max > 0.0 else {})
	for i in int(2.0 / DT):  # пилот у нейтрали
		m.step(DT, Sim.input(), Callable(), _flat)
	var c := Sim.input(0.0, 1.0)
	var best := 0.0
	for i in int(1.0 / DT):
		m.step(DT, c, Callable(), _flat)
		best = maxf(best, absf(Sim.rel_b(m).y - 0.0))
	return best / m.arms.shift_y_max


## (3) arms_force_max_n: 2000 Н на 350 кг — ≥ 90 % хода за 1 с; 300 Н — меньше.
func test_arms_force_max() -> void:
	var big := _roll_stroke(2000.0)
	var small := _roll_stroke(300.0)
	print("    ход за 1 с: 2000 Н %.4f, 300 Н %.4f" % [big, small])
	check(big >= 0.9, "2000 Н: ≥ 90 %% хода (%.2f)" % big)
	check(small < big - 0.05, "300 Н: меньше (%.2f < %.2f)" % [small, big])


## (4) На колёсах без сил — неподвижно, конечно, "wheels".
func test_rest_on_wheels() -> void:
	var m := _wheel_model()
	var p0 := m.position
	var ok := true
	for i in int(10.0 / DT):
		m.step(DT, Sim.input(), Callable(), _flat)
		ok = ok and m.phase() == "wheels" and m.on_wheels
	check(Sim.finite(m), "конечна")
	check(ok, "phase() = \"wheels\", on_wheels")
	check(m.position.distance_to(p0) < 1.0e-3 and m.velocity.length() < 1.0e-3, "неподвижна: сдвиг %.5f м" % m.position.distance_to(p0))
	check(absf(rad_to_deg(m.theta) - WHEELS.keel_angle_deg) < 0.01, "тангаж = киль: %.3f°" % rad_to_deg(m.theta))
	check(absf(m.bank) < 1.0e-4, "крен 0")
	var m2 := _wheel_model()
	for i in int(2.0 / DT):
		m2.step(DT, Sim.input(0.0, 1.0), Callable(), _flat)
	check(absf(m2.bank) < 1.0e-4 and m2.position.distance_to(p0) < 1.0e-3, "roll на земле не действует")


## Подъёмная сила крыла при скорости v вдоль курса и тангаже keel_deg, Н.
func _lift(m: PendulumModel, v: float, keel_deg: float) -> float:
	var R := m.basis_from_euler(0.0, deg_to_rad(keel_deg), 0.0)
	m.strips.aero(Vector3(v, 0.0, 0.0), R, Vector3.ZERO, m._zero_air, Vector3.ZERO, 0.0, m.rho)
	return -(R * m.strips.force_b).z


func _v_lift(m: PendulumModel, keel_deg: float) -> float:
	var lo := 3.0
	var hi := 60.0
	for i in 40:
		var mid := 0.5 * (lo + hi)
		if _lift(m, mid, keel_deg) < m.mass * Units.G:
			lo = mid
		else:
			hi = mid
	return hi


func _vs(m: PendulumModel) -> float:
	return sqrt(2.0 * m.mass * Units.G / (m._rho_ref * m.area * m._polar.cl_max))


## (5) Сила вперёд 1500 Н: разгон, N > 0 до v, где подъёмная сила при киле равна весу; pitch +1 на ≥ 1,1·vs —
## отрыв за ≤ 5 с без скачков.
func test_run_and_takeoff() -> void:
	var m := _wheel_model()
	var vs := _vs(m)
	var v_l := _v_lift(m, WHEELS.keel_angle_deg)
	var took := [false]
	m.took_off.connect(func() -> void: took[0] = true)
	m.set_external_force(func(_s: Dictionary) -> Dictionary: return {"pilot": Vector3(0.0, 0.0, -PULL_N)})
	var a_max := PULL_N / m.mass + 1.0
	var worst_dv := 0.0
	var worst_da := 0.0
	var prev_v := m.pilot_velocity
	var prev_a := Vector3(m.theta, m.bank, m.heading)
	var pitch := 0.0
	var t_pitch := -1.0
	var t_off := -1.0
	var early := false
	var finite := true
	var v_off := 0.0
	for i in int(60.0 / DT):
		var was := m.on_wheels
		var v := m.velocity.length()
		if pitch == 0.0 and v >= 1.1 * vs:
			pitch = 1.0
			t_pitch = m.time_s
		m.step(DT, Sim.input(pitch, 0.0), Callable(), _flat)
		finite = finite and Sim.finite(m)
		var dv := m.pilot_velocity.distance_to(prev_v)
		var a := Vector3(m.theta, m.bank, m.heading)
		var da := rad_to_deg(maxf(absf(a.x - prev_a.x), maxf(absf(a.y - prev_a.y), absf(a.z - prev_a.z))))
		worst_dv = maxf(worst_dv, dv - a_max * DT)
		worst_da = maxf(worst_da, da)
		prev_v = m.pilot_velocity
		prev_a = a
		if was and not m.on_wheels:
			t_off = m.time_s
			v_off = v
			break
		if v < 0.98 * v_l and pitch == 0.0 and not m.on_wheels:
			early = true
	print("    vs=%.2f v_lift(киль)=%.2f; pitch с t=%.2f, отрыв t=%.2f при %.2f м/с; скачок v сверх a·dt %.3f, углов %.3f°"
		% [vs, v_l, t_pitch, t_off, v_off, worst_dv, worst_da])
	check(finite, "конечна")
	check(1.1 * vs < v_l, "тест осмыслен: 1,1·vs < v_подъёма при киле")
	check(not early, "до v_подъёма при киле и pitch 0 — на колёсах")
	check(t_pitch >= 0.0, "разогналась до 1,1·vs")
	check(took[0] and t_off >= 0.0 and t_off - t_pitch <= 5.0, "отрыв за ≤ 5 с после pitch +1: %.2f с" % (t_off - t_pitch))
	check(worst_dv <= 0.05, "скачок скорости тележки за шаг ≤ a·dt + 0,05: %.3f" % worst_dv)
	check(worst_da <= 1.0, "скачок углов за шаг ≤ 1°: %.3f" % worst_da)
	check(m.mode == FlightModel.Mode.AIR and m.phase() == "flying", "после отрыва — полёт: %s" % m.phase())
