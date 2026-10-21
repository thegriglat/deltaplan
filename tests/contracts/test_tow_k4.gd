extends TestCase
## Контракт TW-К4 v3 (docs/contracts/tow.md): внешняя сила и звено троса в модели полёта. Инварианты (1)-(10).

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const FlightSim := preload("res://tests/flight/flight_sim.gd")
const DT := 1.0 / 120.0
const FWD20 := Vector3(0.0, 0.34202014, -0.9396926)  # север (−Z) и вверх под 20°


func _fly(fn: Callable, secs: float) -> PendulumModel:
	var m := Sim.make("sport")
	Sim.reset(m)
	if fn.is_valid():
		m.set_external_force(fn)
	var c := Sim.input()
	for i in int(secs / DT):
		m.step(DT, c, Callable(), Callable())
	return m


func test_empty_fn_is_bit_identical() -> void:
	var a := _fly(Callable(), 10.0)
	var b := _fly(func(_s: Dictionary) -> Dictionary: return {}, 10.0)
	check(a.position == b.position, "позиция без функции и с {} совпадает")
	check(a.velocity == b.velocity, "скорость без функции и с {} совпадает")
	check(b.external_force_n == Vector3.ZERO, "external_force_n = 0")


func _max_shift(fn: Callable, secs: float) -> Vector2:
	var m := Sim.make("sport")
	Sim.reset(m)
	m.set_external_force(fn)
	var c := Sim.input()
	var worst := Vector2.ZERO
	for i in int(secs / DT):
		m.step(DT, c, Callable(), Callable())
		worst = Vector2(maxf(worst.x, absf(m.pilot_shift.x)), maxf(worst.y, absf(m.pilot_shift.y)))
	check(Sim.finite(m), "модель конечна")
	return worst


## Инвариант (2)/(3): постоянная сила — пилот у нейтрали (≤ 0,05 хода по оси) и управление сохраняется:
## полный ввод в каждую сторону с той же силой даёт ≥ 90 % хода (установившийся: тангаж — среднее за последние 2 с
## из 6 с удержания; крен — за последнюю 1 с из 2,5 с: дальше крыло уходит в вираж и пилот возвращается к нейтрали).
func _reach(fn: Callable, pitch: float, roll: float, secs: float, window: float = 2.0) -> Vector2:
	var m := Sim.make("sport")
	Sim.reset(m)
	m.set_external_force(fn)
	var c := Sim.input(pitch, roll)
	var sum := Vector2.ZERO
	var n := 0
	var steps := int(secs / DT)
	for i in steps:
		m.step(DT, c, Callable(), Callable())
		if i >= steps - int(window / DT):  # установившийся ход: среднее за последние window с удержания ввода
			sum += Vector2(m.pilot_shift.x, m.pilot_shift.y)
			n += 1
	check(Sim.finite(m), "модель конечна")
	return sum / float(n)


func _check_neutral_and_control(f: Vector3, label: String) -> void:
	var fn := func(_s: Dictionary) -> Dictionary: return {"pilot": f}
	var w := _max_shift(fn, 10.0)
	print("    %s: max |pilot_shift| = %s" % [label, w])
	check(w.x <= 0.05 and w.y <= 0.05, "%s: пилот у нейтрали (≤ 0,05 хода): %s" % [label, w])
	# ход: +x вправо (roll +1), +y к носу (pitch −1: на себя) / к хвосту (pitch +1: от себя)
	var r_pos := _reach(fn, 0.0, 1.0, 2.5, 1.0)
	var r_neg := _reach(fn, 0.0, -1.0, 2.5, 1.0)
	var p_pull := _reach(fn, -1.0, 0.0, 6.0)
	var p_push := _reach(fn, 1.0, 0.0, 6.0)
	print("    %s: ход крен ±%s/%s, тангаж %s/%s" % [label, r_pos.x, r_neg.x, p_pull.y, p_push.y])
	check(absf(r_pos.x) >= 0.9 and absf(r_neg.x) >= 0.9, "%s: крен в обе стороны ≥ 90 %% хода: %.2f / %.2f" % [label, r_pos.x, r_neg.x])
	check(absf(p_pull.y) >= 0.9 and absf(p_push.y) >= 0.9, "%s: тангаж в обе стороны ≥ 90 %% хода: %.2f / %.2f" % [label, p_pull.y, p_push.y])


func test_along_pilot_keeps_neutral_and_control() -> void:
	_check_neutral_and_control(FWD20 * 300.0, "вдоль 300 Н")


func test_across_pilot_keeps_neutral_and_control() -> void:
	_check_neutral_and_control(Vector3(100.0, 0.0, 0.0), "поперёк 100 Н")


func test_hang_force_finite_and_bank() -> void:
	var f := FWD20 * 300.0
	var m := Sim.make("sport")
	Sim.reset(m)
	m.set_external_force(func(_s: Dictionary) -> Dictionary: return {"hang": f})
	var c := Sim.input()
	var bank := 0.0
	for i in int(10.0 / DT):
		m.step(DT, c, Callable(), Callable())
		bank = maxf(bank, absf(m.bank))
	check(Sim.finite(m), "сила на подвеску: модель конечна")
	check(bank < deg_to_rad(30.0), "|крен| < 30°: %.1f°" % rad_to_deg(bank))


func test_flight_model_force_raises_speed() -> void:
	var speeds := []
	for f in [0.0, 200.0]:
		var m := FlightSim.make("sport")
		m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
		m.external_force = Vector3(0.0, 0.0, -f)
		var vmax := 0.0
		for i in int(5.0 / DT):
			m.step(DT, ControlInput.new(), Callable(), Callable())
			vmax = maxf(vmax, m.telemetry.airspeed)
		speeds.append(vmax)
	check(speeds[1] > speeds[0] + 0.3, "FlightModel: сила 200 Н вперёд — воздушная скорость выше: %s" % [speeds])


func test_force_removed_stays_finite() -> void:
	var f := FWD20 * 300.0
	var t := [0.0]
	var m := Sim.make("sport")
	Sim.reset(m)
	m.set_external_force(func(s: Dictionary) -> Dictionary: return {"pilot": f} if s.t < 3.0 else {})
	var c := Sim.input()
	for i in int(10.0 / DT):
		m.step(DT, c, Callable(), Callable())
	check(Sim.finite(m), "сила снята: модель конечна 10 с")
	m.set_external_force(func(_s: Dictionary) -> Dictionary: return {"pilot": Vector3(NAN, 0, 0)})
	m.step(DT, c, Callable(), Callable())
	check(Sim.finite(m) and m.external_force_n == Vector3.ZERO, "нечисловое — ноль")


func test_glider_input() -> void:
	var g := Glider.new()
	g.setup("sport")
	g.set_external_force(func(_s: Dictionary) -> Dictionary: return {"pilot": Vector3(10, 0, 0)})
	g.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	g.step(DT)
	check(g.model.external_force_n.x > 9.0, "Glider → PendulumModel")
	g.clear_external_force()
	g.step(DT)
	check(g.model.external_force_n == Vector3.ZERO, "clear")
	g.free()


## Инвариант (7): жёсткое короткое звено — модель конечна, натяжение конечно; звено убрано на ходу — нет силы.
func _link_fn(at: String, anchor_off: Vector3, length: float, comp: float, tau: float, until: float) -> Callable:
	return func(s: Dictionary) -> Dictionary:
		if s.t > until:
			return {}
		var base: Vector3 = s.pilot_pos if at == "pilot" else s.hang_pos
		var anchor := Vector3(0.0, 1000.0, 0.0) + anchor_off if s.t < 0.01 else base + anchor_off
		return {"link": {
			"anchor": anchor, "length_m": length, "compliance_m_per_n": comp,
			"damping_s": tau, "at": at,
		}}


func test_link_stiff_short_rope() -> void:
	for at in ["pilot", "hang"]:
		var m := Sim.make("sport")
		Sim.reset(m)
		var a0 := Sim.cg(m) + Vector3(0.0, 0.0, 10.0)  # якорь на 10 м позади ЦМ: трос натянется, когда крыло уйдёт вперёд
		var anchor := a0
		var fn := func(s: Dictionary) -> Dictionary:
			return {"link": {
				"anchor": anchor, "length_m": 10.0, "compliance_m_per_n": 10.0 / 2.0e6,
				"damping_s": 0.005, "at": at,
			}} if s.t < 10.0 else {}
		m.set_external_force(fn)
		var c := Sim.input()
		var tmax := 0.0
		var ok := true
		for i in int(10.0 / DT):
			anchor = a0 + Vector3(0.0, 0.0, -float(i) * DT * 6.0)  # якорь идёт вперёд 6 м/с — медленнее крыла: трос натягивается
			m.step(DT, c, Callable(), Callable())
			tmax = maxf(tmax, m.link_tension_n)
			ok = ok and is_finite(m.link_tension_n) and Sim.finite(m)
		check(ok and tmax > 0.0, "звено (%s): модель конечна, натяжение конечно, > 0: %.0f Н" % [at, tmax])
		print("    звено %s: max натяжение %.0f Н, bank %.1f°" % [at, tmax, rad_to_deg(m.bank)])
		m.set_external_force(func(_s: Dictionary) -> Dictionary: return {})
		m.step(DT, c, Callable(), Callable())
		check(m.link_tension_n == 0.0 and m.external_force_n == Vector3.ZERO, "звено убрано — силы нет (%s)" % at)
		for i in int(10.0 / DT):
			m.step(DT, c, Callable(), Callable())
		check(Sim.finite(m), "после отцепа модель конечна 10 с (%s)" % at)


func test_link_slack_no_force() -> void:
	var m := Sim.make("sport")
	Sim.reset(m)
	var a := Sim.cg(m) + Vector3(0.0, 0.0, -10.0)
	m.set_external_force(func(_s: Dictionary) -> Dictionary: return {"link": {
		"anchor": a, "length_m": 50.0, "compliance_m_per_n": 1.0e-5, "damping_s": 0.0, "at": "pilot"}})
	for i in 120:
		m.step(DT, Sim.input(), Callable(), Callable())
	check(m.link_tension_n == 0.0 and m.external_force_n == Vector3.ZERO, "провисшее звено силы не даёт")


## Инвариант (8): на земле на стойках постоянная сила 500 Н вперёд-вверх 10° — конечно, хват не плывёт:
## max по времени |Δ растяжения| относительно того же момента без силы < 0,05 м, пилот всё время на стойках.
func test_ground_pull() -> void:
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var res := []
	var series := []
	var on_stands := true
	for f in [0.0, 500.0, 1500.0]:
		var m := Sim.make("sport")
		m.reset_on_ground(Vector3.ZERO, 0.0)
		var dir := Vector3(0.0, sin(deg_to_rad(10.0)), -cos(deg_to_rad(10.0)))
		var c := Sim.input()
		var st := []
		for i in int(3.0 / DT):
			if i == int(1.0 / DT) and f > 0.0:
				m.set_external_force(func(_s: Dictionary) -> Dictionary: return {"pilot": dir * f})
			m.step(DT, c, Callable(), flat)
			var rg: Vector3 = m._R * m.ground.grip_b
			var sh: Vector3 = m.chain.pilot() + m.ground.fwd() * m.ground.shoulder_fwd + m.ground.UP_NED * m.ground.shoulder_up
			st.append((sh - (m._pos + rg)).length())
			if f == 500.0 and not m._uprights:
				on_stands = false
		series.append(st)
		res.append({"fwd": m.pilot_position.z, "fin": Sim.finite(m), "mode": m.mode})
	var dmax := 0.0
	for i in series[0].size():
		dmax = maxf(dmax, absf(series[1][i] - series[0][i]))
	print("    земля: %s, max |Δрастяжения| %.4f м" % [res, dmax])
	check(res[1].fin, "на земле с силой: конечна")
	check(on_stands, "500 Н: пилот всё время на стойках")
	check(res[1].fwd < res[0].fwd - 0.01, "пилота тянет вперёд (−Z): %.3f против %.3f" % [res[1].fwd, res[0].fwd])
	check(res[2].fin and res[2].fwd < -0.5, "выше сцепления (1500 Н) — пилота потащит, конечно: %.2f м" % res[2].fwd)
	check(dmax < 0.05, "хват не плывёт: max |Δрастяжения| %.4f м" % dmax)


## Звено XPBD само по себе: груз на тросе в покое — натяжение = вес, растяжение = податливость × вес.
func test_link_static_weight() -> void:
	var ch := PendulumPilotChain.new()
	ch.setup({"links": 1, "compliance_m_per_n": 1.0e-5, "strap_mass_kg": 0.0}, 85.0, 1.0)
	var anchor := Vector3.ZERO
	ch.x[0] = Vector3(0.0, 0.0, 10.0)  # NED: z вниз, груз под якорем
	ch.v[0] = Vector3.ZERO
	var h := 1.0 / 480.0
	var t := 0.0
	for i in 960:
		ch.integrate(h, Vector3(0.0, 0.0, 85.0 * Units.G))
		t = ch.project_anchor(h, anchor, 10.0, 1.0e-5, 0.01)
		ch.velocities_from_prev(h)
	var stretch: float = ch.x[0].z - 10.0
	check(absf(t - 85.0 * Units.G) < 0.02 * 85.0 * Units.G, "натяжение = вес: %.1f Н против %.1f" % [t, 85.0 * Units.G])
	check(absf(stretch - 1.0e-5 * 85.0 * Units.G) < 2.0e-4, "растяжение = α·вес: %.5f м" % stretch)


## Инвариант (9): демпфирование по скорости растяжения. Якорь и груз движутся вместе 25 м/с — натяжение статическое
## (±2 %); лебёдка выбирает трос 2 м/с — нет ложного провиса (натяжение держится у веса).
func test_link_damping_relative() -> void:
	var w := 85.0 * Units.G
	var h := 1.0 / 480.0
	for case in ["co_moving", "winch"]:
		var ch := PendulumPilotChain.new()
		ch.setup({"links": 1, "compliance_m_per_n": 1.0e-5, "strap_mass_kg": 0.0}, 85.0, 1.0)
		var av := Vector3(25.0, 0.0, 0.0) if case == "co_moving" else Vector3.ZERO
		var lrate := 0.0 if case == "co_moving" else -2.0
		var vp := av + (Vector3(0.0, 0.0, lrate))  # NED: z вниз; трос короче — груз поднимается
		var anchor := Vector3.ZERO
		var length := 10.0
		ch.x[0] = Vector3(0.0, 0.0, length + 1.0e-5 * w)
		ch.v[0] = vp
		var tmin := INF
		var tmax := 0.0
		var t := 0.0
		for i in 1920:
			anchor += av * h
			length += lrate * h
			ch.integrate(h, Vector3(0.0, 0.0, w))
			t = ch.project_anchor(h, anchor, length, 1.0e-5, 0.01, av, lrate)
			ch.velocities_from_prev(h)
			if i > 480:
				tmin = minf(tmin, t)
				tmax = maxf(tmax, t)
		print("    демпфирование (%s): натяжение %.1f..%.1f Н, вес %.1f" % [case, tmin, tmax, w])
		check(tmin > 0.98 * w and tmax < 1.02 * w, "%s: натяжение = статическое ±2 %%: %.1f..%.1f против %.1f" % [case, tmin, tmax, w])


## Инвариант (10): установившаяся буксировка. Якорь выходит на 12 м/с по курсу впереди-сверху (20°), трос 50 м
## (EA = 3·10⁵ Н — полиэфирный шнур, демпфирование 0,02 с), 40 с: колебания натяжения < 10 % среднего, средняя
## скорость = скорость якоря ±0,5 м/с, натяжение ненулевое и < 1250 Н (слабое звено 125 даН).
## Ввод — пилот держит тангаж крыла как на старте (П-регулятор 0,2 на градус). Нулевой ввод установившегося режима
## не даёт: сила троса на пилота даёт кабрирующий момент r_hang × F (≈ 900 Н·м/рад жёсткость по тангажу — 100 Н
## поднимают нос на ~7°), крыло теряет скорость и уходит в кабрирование (lock-out TW-К5) — см. отчёт TW-5.
func _steady_tow(at: String) -> void:
	var m := Sim.make("sport")
	Sim.reset(m)
	var rope := 50.0
	var dir := Vector3(0.0, sin(deg_to_rad(20.0)), -cos(deg_to_rad(20.0)))
	var v0: float = -m.velocity.z  # скорость полёта на старте; дальше якорь плавно (0,2 м/с²) выходит на 12 м/с
	var a_acc := 0.2
	var t_ramp := (12.0 - v0) / a_acc
	var a0: Vector3 = (m.pilot_position if at == "pilot" else Sim.cg(m)) + dir * rope
	m.set_external_force(func(s: Dictionary) -> Dictionary:
		var te := minf(s.t, t_ramp)
		var x := v0 * te + 0.5 * a_acc * te * te + 12.0 * maxf(s.t - t_ramp, 0.0)
		var v := v0 + a_acc * te
		return {"link": {
			"anchor": a0 + Vector3(0.0, 0.0, -x), "anchor_vel": Vector3(0.0, 0.0, -v), "length_m": rope,
			"compliance_m_per_n": rope / 3.0e5, "damping_s": 0.02, "at": at,
		}})
	var th0 := m.theta
	var tens := []
	var vsum := Vector3.ZERO
	var n := 0
	for i in int(40.0 / DT):
		m.step(DT, Sim.input(clampf(-0.2 * rad_to_deg(m.theta - th0), -1.0, 1.0)), Callable(), Callable())
		if i >= int(30.0 / DT):
			tens.append(m.link_tension_n)
			vsum += m.velocity
			n += 1
	var mean := 0.0
	for x: float in tens:
		mean += x
	mean /= tens.size()
	var dev := 0.0
	for x: float in tens:
		dev = maxf(dev, absf(x - mean))
	var vmean := vsum / float(n)
	print("    буксировка (%s): T средн %.1f Н, откл %.1f Н, v средн %s, bank %.1f°" % [at, mean, dev, vmean, rad_to_deg(m.bank)])
	check(Sim.finite(m), "буксировка (%s): модель конечна" % at)
	check(mean > 1.0 and mean < 1250.0, "буксировка (%s): натяжение ненулевое и ниже слабого звена: %.1f Н" % [at, mean])
	check(dev < 0.1 * mean, "буксировка (%s): колебания < 10 %% среднего: %.1f из %.1f Н" % [at, dev, mean])
	check(absf(-vmean.z - 12.0) < 0.5, "буксировка (%s): скорость = скорости якоря ±0,5 м/с: %s" % [at, vmean])


func test_steady_tow_pilot() -> void:
	_steady_tow("pilot")
