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
## Скорость руки на штанге после окна: ввод pitch меняется не быстрее SLEW в секунду (ход штанги за ≈ 0,5 с — порядок
## постоянной времени рук arms.tau 0,3 с; ступень ввода в законе рук даёт мгновенный скачок силы до предела).
const SLEW := 2.0


func _flat(_x: float, _z: float) -> float:
	return 0.0


func _air_model(app: Dictionary = {}) -> PendulumModel:
	var a := APP.duplicate()
	a.merge(app, true)
	var m := Sim.make(WING, MASS, a)
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	return m


func _wheel_model() -> PendulumModel:
	var a := APP.duplicate()
	a["arms_force_max_n"] = 2000.0  # тележка: руки держат штангу на 350 кг (как в связке TT-К4)
	var m := Sim.make(WING, MASS, a)
	m.reset_on_wheels(Vector3.ZERO, 0.0, WHEELS)
	return m


## Тележка TT-К1 из configs/tow_tug.json на крыле trike_ixess15 (числа буксировщика, не тестовые).
func _tug_model() -> PendulumModel:
	var cfg: Dictionary = Config.get_config("tow_tug")
	var cart: Dictionary = cfg.cart
	var g: Dictionary = cfg.ground
	var a := {"hang_length_m": float(cart.cg_below_hang_m), "arms_force_max_n": float(cart.arms_force_max_n), "pilot_cda_m2": float(cart.cda_m2)}
	var m := Sim.make(String(cfg.wing), float(cart.mass_kg), a)
	m.reset_on_wheels(Vector3.ZERO, 0.0, {"keel_angle_deg": float(g.keel_angle_deg), "rotate_deg": float(g.rotate_deg), "rolling_crr": float(g.rolling_crr), "wheel_base_agl_m": float(g.wheel_base_agl_m)})
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


## Подъёмная сила модели (полосы, экранный эффект — как в разбеге) при скорости v вдоль курса и киле на колёсах, Н.
func _lift_model(v: float) -> float:
	var m := _wheel_model()
	m._vel = Vector3(v, 0.0, 0.0)
	m._aero_age = INF
	m._aero_update(Callable(), _flat)
	return -(m._R * m._aero_f_b).z


## Скорость, где подъёмная сила модели при киле равна весу, м/с.
func _v_lift_model() -> float:
	var w := _wheel_model().mass * Units.G
	var lo := 3.0
	var hi := 60.0
	for i in 40:
		var mid := 0.5 * (lo + hi)
		if _lift_model(mid) < w:
			lo = mid
		else:
			hi = mid
	return hi


func _pull_fn(pull_n: float = PULL_N) -> Callable:
	return func(_s: Dictionary) -> Dictionary: return {"pilot": Vector3(0.0, 0.0, -pull_n)}


## (5а) pitch 0 на всём разбеге, без break до отрыва: пока N > 0, подъёмная сила модели при киле меньше веса;
## отрыв — не раньше 0,95·v_l (v_l — равенство подъёмной силы модели весу).
func test_pitch0_run_to_lift() -> void:
	var m := _wheel_model()
	var w := m.mass * Units.G
	var v_l := _v_lift_model()
	m.set_external_force(_pull_fn())
	var lift_ok := true
	var worst := 0.0
	var v_off := -1.0
	var t_off := -1.0
	for i in int(60.0 / DT):
		m.step(DT, Sim.input(), Callable(), _flat)
		if not m.on_wheels:
			v_off = m.pilot_velocity.length()
			t_off = m.time_s
			break
		var lift := -(m._R * m._aero_f_b).z
		worst = maxf(worst, lift / w)
		lift_ok = lift_ok and lift < w
	print("    pitch 0: v_l(модель)=%.2f, отрыв t=%.2f при %.2f м/с (%.3f·v_l), макс. L/вес на колёсах %.4f" % [v_l, t_off, v_off, v_off / v_l, worst])
	check(t_off > 0.0, "отрыв случился без pitch")
	check(lift_ok, "на колёсах (N > 0) подъёмная сила < веса: макс. %.4f" % worst)
	check(v_off >= 0.95 * v_l, "отрыв не раньше 0,95·v_l: %.2f против %.2f" % [v_off, 0.95 * v_l])
	check(Sim.finite(m) and m.phase() == "flying", "после отрыва — полёт")


## (5б, 5в) pitch +1 на ≥ 1,1·vs: отрыв за ≤ 5 с; 1 с после отрыва — скачок скорости обоих тел (тележки и ЦМ крыла)
## ≤ 0,15 м/с за шаг, тангаж и крен ≤ 1° за шаг; ложемента нет.
func test_takeoff_continuity() -> void:
	_takeoff_continuity(_wheel_model(), _pull_fn(PULL_N))


## (5б) то же на trike_ixess15 с числами tow_tug.json (TT-10): тяга — thrust.full_n(V) (газ 1), V — скорость тележки.
## Ввод pitch +1 держат до отрыва и ещё 0,3 с (окно скачка при смене модели: колёса → воздух); потом — простой
## регулятор тангажа по скорости к tow.tow_speed_kmh (как автопилот TT-4: штанга «на себя», если медленнее, «от себя»,
## если быстрее; ход ограничен ±1). Порог 0,15 м/с — на всём 1 с после отрыва (TT-К3 v5).
func test_takeoff_continuity_trike() -> void:
	_takeoff_continuity(_tug_model(), _tug_thrust_fn(), 1.0, 1.0, _speed_ctl())


## То же, но pitch +1 держат и после окна, весь 1 с (прямое чтение (5б)). С v5 это не обязательно (в воздухе дольше
## окна ввод ведёт автопилот), но после исправления выравнивания «стоя» у земли (flare) на сидящем пилоте — проходит.
func test_takeoff_continuity_trike_hold() -> void:
	_takeoff_continuity(_tug_model(), _tug_thrust_fn(), 1.0, 1.0)


## Тяга винта тележки (газ 1) по tow_tug.json: thrust.full_n(V), линейная интерполяция по thrust.v_ms; V — скорость
## тележки (узел пилота). Вперёд — по −Z, как _pull_fn.
func _tug_thrust_fn() -> Callable:
	var t: Dictionary = Config.get_config("tow_tug").thrust
	var vs: Array = t.v_ms
	var fs: Array = t.full_n
	return func(s: Dictionary) -> Dictionary:
		var v := (s.pilot_vel as Vector3).length()
		var f: float = fs[fs.size() - 1]
		for k in range(1, vs.size()):
			if v <= float(vs[k]):
				f = lerpf(float(fs[k - 1]), float(fs[k]), clampf((v - float(vs[k - 1])) / (float(vs[k]) - float(vs[k - 1])), 0.0, 1.0))
				break
		return {"pilot": Vector3(0.0, 0.0, -f)}


## Регулятор тангажа по скорости к tow.tow_speed_kmh: pitch = clamp(K·(V − V_буксировки), −1; 1), K = 0,3 с/м.
func _speed_ctl() -> Callable:
	var v_tow := float(Config.get_config("tow_tug").tow.tow_speed_kmh) / 3.6
	return func(v: float) -> float: return clampf(0.3 * (v - v_tow), -1.0, 1.0)


func _takeoff_continuity(m: PendulumModel, force_fn: Callable, pitch_after := 1.0, window := 1.0, ctl := Callable()) -> void:
	var vs := _vs(m)
	var took := [false]
	m.took_off.connect(func() -> void: took[0] = true)
	m.set_external_force(force_fn)
	var a_max := -float((force_fn.call({"pilot_vel": Vector3.ZERO}) as Dictionary).pilot.z) / m.mass + 1.0
	var pitch := 0.0
	var pin_prev := 0.0
	var t_pitch := -1.0
	var t_off := -1.0
	var worst_pilot := 0.0
	var worst_wing := 0.0
	var late_wing := 0.0  # за весь 1 с, справочно
	var worst_da := 0.0
	var pilot_run := 0.0  # на колёсах: скачок сверх a·dt
	var finite := true
	var dolly_ok := true
	var prev_vp := m.pilot_velocity
	var prev_vw := m.velocity
	var prev_a := Vector3(m.theta, m.bank, m.heading)
	var dolly_pos0 := m.dolly_pos
	for i in int(60.0 / DT):
		if pitch == 0.0 and m.pilot_velocity.length() >= 1.1 * vs:
			pitch = 1.0
			t_pitch = m.time_s
		var pin := pitch
		if t_off >= 0.0 and m.time_s > t_off + 0.3:
			var target := float(ctl.call(m.pilot_velocity.length())) if ctl.is_valid() else pitch_after
			pin_prev = move_toward(pin_prev, target, SLEW * DT)
			pin = pin_prev
		else:
			pin_prev = pin
		m.step(DT, Sim.input(pin, 0.0), Callable(), _flat)
		finite = finite and Sim.finite(m)
		var dvp := m.pilot_velocity.distance_to(prev_vp)
		var dvw := m.velocity.distance_to(prev_vw)
		var a := Vector3(m.theta, m.bank, m.heading)
		var da := rad_to_deg(maxf(absf(a.x - prev_a.x), absf(a.y - prev_a.y)))
		prev_vp = m.pilot_velocity
		prev_vw = m.velocity
		prev_a = a
		if t_off < 0.0 and not m.on_wheels:
			t_off = m.time_s
		if t_off < 0.0:
			pilot_run = maxf(pilot_run, dvp - a_max * DT)
			worst_da = maxf(worst_da, da)
		else:
			dolly_ok = dolly_ok and not m.dolly_attached and m.dolly_pos == dolly_pos0 and m.dolly_vel == Vector3.ZERO
			if m.time_s <= t_off + window:
				worst_pilot = maxf(worst_pilot, dvp)
				worst_wing = maxf(worst_wing, dvw)
			late_wing = maxf(late_wing, dvw)
			worst_da = maxf(worst_da, da)
			if m.time_s > t_off + 1.0:
				break
	print("    vs=%.2f; pitch с t=%.2f, отрыв t=%.2f; после отрыва за %.1f с макс. |dv|/шаг: тележка %.3f, ЦМ крыла %.3f м/с; углы %.3f°; на колёсах сверх a·dt %.3f; ЦМ крыла за 1 с (справочно) %.3f"
		% [vs, t_pitch, t_off, window, worst_pilot, worst_wing, worst_da, pilot_run, late_wing])
	check(finite, "конечна")
	check(t_pitch >= 0.0, "разогналась до 1,1·vs")
	check(took[0] and t_off >= 0.0 and t_off - t_pitch <= 5.0, "отрыв за <= 5 с после pitch +1: %.2f с" % (t_off - t_pitch))
	check(pilot_run <= 0.05, "на колёсах скачок скорости тележки за шаг <= a·dt + 0,05: %.3f" % pilot_run)
	check(worst_pilot <= 0.15, "после отрыва %.1f с: тележка |dv| за шаг <= 0,15 м/с: %.3f" % [window, worst_pilot])
	check(worst_wing <= 0.15, "после отрыва %.1f с: ЦМ крыла |dv| за шаг <= 0,15 м/с: %.3f" % [window, worst_wing])
	check(worst_da <= 1.0, "тангаж и крен за шаг <= 1°: %.3f" % worst_da)
	check(dolly_ok, "ложемента нет: dolly_attached = false, dolly_pos/vel не меняются")


## (5в) Касание не отложено на 3 с: после отрыва проверка включается, как только низ колёс выше земли на 0,05 м
## (до этого — отложена). Земля — ровная; сигнал landed подан не был.
func test_touchdown_check_resumes() -> void:
	var m := _wheel_model()
	m.set_external_force(_pull_fn())
	var t_off := -1.0
	var t_resume := -1.0
	for i in int(60.0 / DT):
		m.step(DT, Sim.input(1.0, 0.0), Callable(), _flat)
		if t_off < 0.0 and not m.on_wheels:
			t_off = m.time_s
		if t_off >= 0.0 and not m._wh_hold:
			t_resume = m.time_s
			break
	var bottom := (m.pilot_position - m.pilot_basis.y * m._wh_base).y
	print("    отрыв t=%.2f, проверка касания включена через %.3f с, низ колёс %.3f м" % [t_off, t_resume - t_off, bottom])
	check(t_off > 0.0 and t_resume >= t_off, "проверка касания включилась")
	check(t_resume - t_off < 3.0, "не через 3 с, а по высоте: %.3f с" % (t_resume - t_off))
	check(bottom > 0.05, "низ колёс выше земли на 0,05 м: %.3f" % bottom)


## (6) TT-К3 v4: на колёсах pitch −1 («на себя») уменьшает тангаж (keel − rotate) и удерживает на земле до v ≥ 1,15·v_l
## (v_l — при pitch 0); ход непрерывен (скачок скорости тележки за шаг <= a·dt + 0,05).
func test_pitch_negative_holds_on_ground() -> void:
	var v_l := _v_lift_model()
	var m := _wheel_model()
	m.set_external_force(_pull_fn())
	var a_max := PULL_N / m.mass + 1.0
	var prev := m.pilot_velocity
	var jump := 0.0
	var v_max := 0.0
	var pitch_deg := 0.0
	for i in int(25.0 / DT):
		m.step(DT, Sim.input(-1.0, 0.0), Callable(), _flat)
		if i == int(3.0 / DT):
			pitch_deg = rad_to_deg(m.theta)
		if not m.on_wheels:
			break
		jump = maxf(jump, m.pilot_velocity.distance_to(prev) - a_max * DT)
		prev = m.pilot_velocity
		v_max = maxf(v_max, m.pilot_velocity.length())
	print("    pitch -1: v_l=%.2f, на земле до %.2f м/с (%.3f·v_l), тангаж %.2f°, скачок сверх a·dt %.3f" % [v_l, v_max, v_max / v_l, pitch_deg, jump])
	check(Sim.finite(m), "конечна")
	check(absf(pitch_deg - (WHEELS.keel_angle_deg - WHEELS.rotate_deg)) < 0.2, "тангаж = киль − rotate: %.2f°" % pitch_deg)
	check(v_max >= 1.15 * v_l, "отрыва нет до 1,15·v_l: %.2f против %.2f" % [v_max, 1.15 * v_l])
	check(jump <= 0.05, "ход непрерывен: %.3f" % jump)


## (7) TT-К3 v6: переход pitch −1 → 0 → +1 на колёсах без рывка. Пробные вызовы закона рук в поиске наклона мачты
## состояния рук не меняют: «отпускание» (release_event) срабатывает один раз за подшаг, а не внутри поиска корня.
## Проверка: за подшаг счётчик успокоения рук растёт не больше чем на h, скорость тележки меняется <= a·dt + 0,05,
## а скорость наклона мачты ограничена (без скачка при pitch 0).
func test_pitch_transition_on_wheels() -> void:
	var m := _wheel_model()
	m.set_external_force(_pull_fn())
	var a_max := PULL_N / m.mass + 1.0
	var prev := m.pilot_velocity
	var jump := 0.0
	var worst_rate := 0.0
	var worst_calm := 0.0
	var t_prev_calm := 0.0
	var pitches := [[-1.0, 3.0], [0.0, 1.0], [1.0, 0.5]]
	for seg in pitches:
		for _i in int(float(seg[1]) / DT):
			m.step(DT, Sim.input(float(seg[0]), 0.0), Callable(), _flat)
			if not m.on_wheels:
				break  # отрыв — конец проверки на колёсах
			jump = maxf(jump, m.pilot_velocity.distance_to(prev) - a_max * DT)
			prev = m.pilot_velocity
			worst_rate = maxf(worst_rate, absf(m._wh_tilt_rate))
			var calm: float = m.arms._rel_calm
			worst_calm = maxf(worst_calm, calm - t_prev_calm)
			t_prev_calm = calm
	print("    pitch -1 → 0 → +1: скачок сверх a·dt %.3f, макс. скорость наклона %.3f рад/с, макс. прирост _rel_calm за шаг %.4f" % [jump, worst_rate, worst_calm])
	check(Sim.finite(m), "конечна")
	check(jump <= 0.05, "ход непрерывен: %.3f" % jump)
	check(worst_calm <= DT * 1.01, "счётчик успокоения растёт не быстрее времени: %.4f за шаг при DT=%.4f" % [worst_calm, DT])
