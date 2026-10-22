extends TestCase
## Контракт TT-К4 v1 (docs/contracts/tow-trike.md; бывший TW-К9): буксировщик TowTug - дельталёт, модель полёта
## («Маятник», крыло trike_ixess15, тележка TT-К1, колёса TT-К3), автопилот по фазам. Файл остался test_tow_k9.gd.

const DT := 1.0 / 120.0
const FLAT := Vector3(0.0, -0.0871557, 0.9961947)  ## сила троса назад-вниз 5° (курс 0 - на север, назад = +Z)


func _flat(_x: float, _z: float) -> float:
	return 5.0


func _cfg(over: Dictionary = {}) -> Dictionary:
	var c: Dictionary = Config.get_config("tow_tug").duplicate(true)
	for k in over:
		c.tow[k] = over[k]
	return c


func _tug(heading: float = 0.0, over: Dictionary = {}) -> TowTug:
	var t := TowTug.new()
	t.setup(Vector3(10.0, 5.0, -20.0), heading, 80.0, _flat, _cfg(over))
	return t


## Прогон: возвращает наибольшее превышение |Δpos| над |vel|·dt (м); force - сила троса (Н, мир) каждый шаг.
func _run(t: TowTug, seconds: float, glider_agl: float, force: Vector3) -> float:
	var worst := 0.0
	for i in int(seconds / DT):
		var p0 := t.pos
		t.set_rope_force(force)
		t.step(DT, glider_agl)
		worst = maxf(worst, (t.pos - p0).length() - t.vel.length() * DT)
	return worst


func test_idle_and_placement() -> void:
	var cfg := Config.get_config("tow_tug")
	for h in [0.0, 90.0, 225.0]:
		var t := _tug(h)
		check(t.phase == "idle", "idle до start()")
		var f := Vector3(sin(deg_to_rad(h)), 0.0, -cos(deg_to_rad(h)))
		var want := Vector3(10.0, 0.0, -20.0) + f * 80.0
		check(Vector2(t.pos.x - want.x, t.pos.z - want.z).length() < 0.05, "курс %.0f: tow_hook на оси полосы впереди на длину троса: %s против %s" % [h, t.pos, want])
		var p := t.pos
		_run(t, 2.0, 0.0, Vector3.ZERO)
		check(t.vel.length() < 0.01 and t.pos.distance_to(p) < 0.01, "до start() неподвижен")
		check(t.throttle == 0.0, "газ 0 до start()")
		approx(t.prop_rpm, float(cfg.engine.prop_rpm_idle), 1e-6, "холостые обороты")
		check(t.agl_m < 0.05 and not t.gone, "на колёсах")
		check(t.model != null and t.model.on_wheels, "модель на колёсах (TT-К3)")
	# базис тележки: ортонормирован, -Z вперёд (курс 90 - восток), +Y вверх
	var t2 := _tug(90.0)
	check(absf(t2.cart_basis.determinant() - 1.0) < 1e-4, "cart_basis ортонормирован")
	check((-t2.cart_basis.z).dot(Vector3.RIGHT) > 0.97, "-Z тележки - вперёд (на восток): %s" % (-t2.cart_basis.z))
	check(t2.cart_basis.y.y > 0.95 and t2.basis == t2.cart_basis, "+Y (мачта) почти вверх (на колёсах наклон = тангаж киля, TT-К3), basis = cart_basis: %s" % t2.cart_basis.y)
	# точка троса в осях тележки - tow_hook (TT-К1)
	var hk: Array = cfg.cart.tow_hook
	var hv := Vector3(float(hk[0]), float(hk[1]), float(hk[2]))
	check(t2.pos.distance_to(t2.hang_pos + t2.cart_basis * hv) < 1e-3, "pos = подвеска + базис · tow_hook")


func test_slack_roll_hold() -> void:
	var t := _tug(0.0)
	var cfg := Config.get_config("tow_tug")
	var worst := 0.0
	t.start()
	check(t.phase == "slack", "start() - slack")
	worst = maxf(worst, _run(t, 8.0, 0.0, Vector3.ZERO))
	check(t.phase == "slack", "slack: без натяжения фаза держится")
	var v := Vector2(t.vel.x, t.vel.z).length()
	approx(v, float(cfg.tow.slack_speed_ms), 0.25, "slack: скорость выбора слабины")
	worst = maxf(worst, _run(t, 0.1, 0.0, FLAT * 5.0))
	check(t.phase == "roll", "натяжение > 0 - roll")
	check(t.throttle > 0.0, "газ растёт")
	# дельтаплан не поднялся (ниже glider_hold_agl_m): остаёмся на колёсах на полном газе
	worst = maxf(worst, _run(t, 6.5, 1.0, FLAT * 300.0))  # дальше ≈ 1,15·v_l штанга уже не держит (TT-К3 v4)
	check(t.phase == "roll" and t.agl_m < 0.05, "roll: на колёсах, пока дельтаплан ниже hold (agl %.3f)" % t.agl_m)
	check(t.model.on_wheels, "модель всё ещё на колёсах")
	check(t.airspeed_ms > 10.0, "штанга на себя держит на колёсах до скорости отрыва: %.1f м/с" % t.airspeed_ms)
	check(worst <= 0.01, "траектория непрерывна, избыток %f м" % worst)


func test_takeoff_no_rope_and_climb() -> void:
	var t := _tug(0.0)
	t.start()
	var worst := _run(t, 0.1, 0.0, FLAT * 5.0)  # трос лишь выбрал слабину -> roll
	worst = maxf(worst, _run(t, 40.0, 10.0, Vector3.ZERO))  # дальше без троса
	check(t.phase == "climb" or t.phase == "circuit", "без троса отрывается: %s" % t.phase)
	check(t.agl_m > 30.0, "и набирает: agl %.1f м" % t.agl_m)
	check(t.vel.y > 1.0, "вертикальная скорость > 1 м/с: %.2f" % t.vel.y)
	check(worst <= 0.01, "траектория непрерывна, избыток %f м" % worst)
	check(not t.model.on_wheels, "в воздухе")


func test_climb_speed_and_bank_with_rope() -> void:
	var t := _tug(0.0)
	var v_tow := float(Config.get_config("tow_tug").tow.tow_speed_kmh)
	t.start()
	var worst := _run(t, 0.1, 0.0, FLAT * 5.0)
	var f := FLAT * 300.0
	worst = maxf(worst, _run(t, 20.0, 10.0, f))
	var v_sum := 0.0
	var bank_max := 0.0
	var n := 0
	for i in int(10.0 / DT):
		var p0 := t.pos
		t.set_rope_force(f)
		t.step(DT, 10.0)
		worst = maxf(worst, (t.pos - p0).length() - t.vel.length() * DT)
		v_sum += t.airspeed_ms * 3.6
		bank_max = maxf(bank_max, absf(rad_to_deg(t.model.bank)))
		n += 1
	var v_avg := v_sum / n
	print("    climb: V %.1f км/ч (цель %.0f), крен max %.2f°, vz %.2f м/с, agl %.0f м" % [v_avg, v_tow, bank_max, t.vel.y, t.agl_m])
	check(t.phase == "climb", "climb: %s" % t.phase)
	check(absf(v_avg - v_tow) <= 3.0, "воздушная скорость = tow_speed_kmh ± 3 км/ч: %.1f" % v_avg)
	check(bank_max < 5.0, "крен < 5°: %.2f" % bank_max)
	check(worst <= 0.01, "траектория непрерывна, избыток %f м" % worst)
	# -Z тележки примерно вдоль скорости
	var fwd := -t.cart_basis.z
	var vh := Vector3(t.vel.x, 0.0, t.vel.z).normalized()
	check(rad_to_deg(Vector3(fwd.x, 0.0, fwd.z).normalized().angle_to(vh)) < 10.0, "-Z тележки вдоль движения")


func test_circuit_and_away() -> void:
	var t := _tug(0.0, {"circuit_start_agl_m": 40.0})
	var cfg := Config.get_config("tow_tug")
	t.start()
	_run(t, 0.1, 0.0, FLAT * 5.0)
	var f := FLAT * 300.0
	var worst := _run(t, 25.0, 10.0, f)
	check(t.phase == "circuit", "circuit после circuit_start_agl_m (фаза %s, agl %.1f)" % [t.phase, t.agl_m])
	worst = maxf(worst, _run(t, 12.0, 50.0, f))
	var h0 := t.model.heading
	var bank_sum := 0.0
	var n := 0
	for i in int(6.0 / DT):
		var p0 := t.pos
		t.set_rope_force(f)
		t.step(DT, 50.0)
		worst = maxf(worst, (t.pos - p0).length() - t.vel.length() * DT)
		bank_sum += rad_to_deg(t.model.bank)
		n += 1
	var bank := bank_sum / n
	var dh := wrapf(t.model.heading - h0, -PI, PI)
	print("    circuit: крен %.2f° (цель %.0f° влево), поворот за 6 с %.1f°" % [bank, float(cfg.tow.circuit_bank_deg), rad_to_deg(dh)])
	check(absf(absf(bank) - float(cfg.tow.circuit_bank_deg)) <= 3.0, "крен = circuit_bank_deg ± 3°: %.2f" % bank)
	check(dh < 0.0, "круг влево: курс уменьшается")
	check(t.cart_basis.x.y > 0.0 or absf(bank) < 1.0, "левый крен: правая сторона выше")
	check(worst <= 0.01, "траектория непрерывна, избыток %f м" % worst)
	t.release()
	check(t.phase == "away", "release - away")
	_run(t, 8.0, 50.0, Vector3.ZERO)
	approx(t.throttle, float(cfg.away.throttle), 0.01, "away: газ = away.throttle")
	check(not t.gone, "ещё не убран")
	_run(t, float(cfg.away.away_s), 50.0, Vector3.ZERO)
	check(t.gone, "gone после away_s")
	t.step(DT, 50.0)  # после gone шаг безопасен
	check(t.gone, "gone остаётся")


func test_release_on_roll() -> void:
	var t := _tug(0.0)
	var cfg := Config.get_config("tow_tug")
	t.start()
	var worst := _run(t, 0.1, 0.0, FLAT * 5.0)
	worst = maxf(worst, _run(t, 3.0, 0.0, FLAT * 300.0))
	check(t.phase == "roll", "roll")
	var v0 := t.vel.length()
	t.release()
	check(t.phase == "away", "release на разбеге - away")
	worst = maxf(worst, _run(t, 1.0, 0.0, Vector3.ZERO))
	check(t.vel.length() < v0 + 4.0, "скорость не скачет: %f -> %f" % [v0, t.vel.length()])
	worst = maxf(worst, _run(t, float(cfg.away.away_s), 0.0, Vector3.ZERO))
	check(worst <= 0.01, "траектория непрерывна, избыток %f м" % worst)
	check(t.gone, "gone через away_s")


## Повтор проверки TT-К3 (5б) на крыле trike_ixess15 с тележкой tow_tug.json: отрыв непрерывен для обоих тел -
## |Δv| за шаг ≤ 0,15 м/с на интервале 1 с после отрыва, тангаж и крен ≤ 1° за шаг.
func test_liftoff_continuity() -> void:
	var t := _tug(0.0)
	t.start()
	_run(t, 0.1, 0.0, FLAT * 5.0)
	var f := FLAT * 300.0
	var t_off := -1.0
	var dv_c := 0.0
	var dv_w := 0.0
	var dth := 0.0
	var dbank := 0.0
	var tt := 0.0
	var m := t.model
	var pv := m.pilot_velocity
	var wv := m.velocity
	var th := m.theta
	var bk := m.bank
	for i in int(16.0 / DT):
		t.set_rope_force(f)
		t.step(DT, 10.0)
		tt += DT
		if t_off < 0.0 and not m.on_wheels:
			t_off = tt
		if t_off > 0.0 and tt - t_off < 1.0:
			dv_c = maxf(dv_c, (m.pilot_velocity - pv).length())
			dv_w = maxf(dv_w, (m.velocity - wv).length())
			dth = maxf(dth, absf(rad_to_deg(m.theta - th)))
			dbank = maxf(dbank, absf(rad_to_deg(m.bank - bk)))
		pv = m.pilot_velocity
		wv = m.velocity
		th = m.theta
		bk = m.bank
	print("    отрыв на %.2f с: max |Δv| тележки %.3f, крыла %.3f м/с за шаг; Δтангаж %.2f°, Δкрен %.3f° за шаг" % [t_off, dv_c, dv_w, dth, dbank])
	check(t_off > 0.0, "отрыв произошёл")
	check(dv_c <= 0.15, "тележка: |Δv| за шаг ≤ 0,15 м/с: %.3f" % dv_c)
	# непрерывность ЦМ крыла (TT-К3 5б, порог 0,15) ведёт TT-10 в test_tow_trike_k3.gd
	check(dth <= 1.0, "тангаж крыла ≤ 1° за шаг: %.2f" % dth)
	check(dbank <= 1.0, "крен крыла ≤ 1° за шаг: %.3f" % dbank)


func test_thrust_and_rpm() -> void:
	var cfg := Config.get_config("tow_tug")
	var t := _tug(0.0)
	t.start()
	_run(t, 0.1, 0.0, FLAT * 5.0)
	_run(t, 4.0, 10.0, FLAT * 300.0)
	check(t.throttle > 0.99, "полный газ: %.2f" % t.throttle)
	check(t.prop_rpm > float(cfg.engine.prop_rpm_idle) and t.prop_rpm <= float(cfg.engine.prop_rpm_max) + 1.0, "обороты винта между холостыми и максимальными: %.0f" % t.prop_rpm)


## TT-К4 v2: cart_basis - ориентация модели trike.glb. Колёса: +Y по нормали (плоская земля - вверх); воздух: вектор
## подвеска -> ЦМ тележки в осях модели совпадает с модельным; переход колёса -> воздух не быстрее 20 град/с.
func test_cart_basis_model_orientation() -> void:
	var t := _tug(0.0)
	check(t.cart_basis.y.dot(Vector3.UP) > 0.9999, "на колёсах +Y по нормали земли: %s" % t.cart_basis.y)
	t.start()
	_run(t, 0.1, 0.0, FLAT * 5.0)  # трос выбрал слабину -> roll
	var hist: Array[Basis] = []  # окно 0,25 с: угол acos при малом шаге шумит
	var worst := 0.0
	var air_seen := false
	for i in int(45.0 / DT):
		t.set_rope_force(Vector3.ZERO)
		t.step(DT, 10.0)
		worst = maxf(worst, _rate(hist, t.cart_basis))
		if not t.model.on_wheels:
			air_seen = true
			break
	check(air_seen, "оторвался с колёс")
	check(worst <= 20.5, "поворот модели не быстрее 20 град/с: %.2f" % worst)
	# в воздухе (после перехода) вектор подвеска -> ЦМ в осях модели совпадает с модельным
	for i in int(10.0 / DT):
		t.set_rope_force(Vector3.ZERO)
		t.step(DT, 10.0)
		worst = maxf(worst, _rate(hist, t.cart_basis))
	check(worst <= 20.5, "и в воздухе не быстрее 20 град/с: %.2f" % worst)
	var want := (t.model.pilot_position - t.hang_pos).normalized()
	var got: Vector3 = t.cart_basis * TowTug.CART_CM_MODEL.normalized()
	check(got.dot(want) > 0.999, "в воздухе подвеска->ЦМ модели = модель полёта: cos %.5f" % got.dot(want))
	check(absf(t.cart_basis.determinant() - 1.0) < 1e-4, "ортонормирован")


## Скорость поворота (град/с) по окну 30 шагов.
func _rate(hist: Array[Basis], b: Basis) -> float:
	hist.append(b)
	if hist.size() < 31:
		return 0.0
	var old: Basis = hist.pop_front()
	return rad_to_deg(old.get_rotation_quaternion().angle_to(b.get_rotation_quaternion())) / (30.0 * DT)
