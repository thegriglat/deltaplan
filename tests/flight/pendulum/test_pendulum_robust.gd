extends TestCase
## «Маятник» (PD-2): болтанка σ 1 м/с без развала; шаг 1/120, 1/60, 1/30 с без NaN; временное
## касание (v1, до PD-3) → LANDED и LandingJudge.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")


## Болтанка как в прототипе (поле из reference.json, пилот мягко держит горизонт), 40 с.
## → {blowup, std_phi_deg, std_rel_y_m, max_abs_phi_deg, max_stretch_m}.
func _turbulence(w: String, dt: float, proto_block: bool) -> Dictionary:
	var m := S.make(w, 0.0, {}, proto_block)
	var off := S.reset(m)
	var tb := S.Turbulence.new(S.ref().turbulence, off)
	var air := tb.air
	var bh := S.BankHold.new(0.0, 1.5, 0.8, 0.3)
	var inp := S.input()
	var phi: PackedFloat64Array = []
	var ry: PackedFloat64Array = []
	var blow := false
	for i in int(round(40.0 / dt)):
		inp.roll = bh.roll(m)
		m.step(dt, inp, air, Callable())
		if not S.finite(m) or S.airspeed(m) > 80.0:
			blow = true
			break
		if m.time_s > 10.0:
			phi.append(rad_to_deg(m.bank))
			ry.append(S.rel_b(m).y)
	var out := {"blowup": blow, "max_stretch_m": m.chain.max_stretch}
	out.std_phi_deg = _std(phi)
	out.std_rel_y_m = _std(ry)
	var mx := 0.0
	for v in phi:
		mx = maxf(mx, absf(v))
	out.max_abs_phi_deg = mx
	return out


func _std(x: PackedFloat64Array) -> float:
	if x.is_empty():
		return NAN
	var s := 0.0
	for v in x:
		s += v
	var mean := s / x.size()
	var q := 0.0
	for v in x:
		q += (v - mean) * (v - mean)
	return sqrt(q / x.size())


## Сверка порта: блок прототипа, то же поле и регулятор — статистика ±15 %.
func _check_turb(name: String, w: String, dt: float) -> void:
	var r := S.scenario(name, w)
	var o := _turbulence(w, dt, true)
	var tag := "%s dt 1/%d" % [w, roundi(1.0 / dt)]
	_check_bounded(o, tag)
	approx(o.std_phi_deg, r.std_phi_deg, 0.15 * float(r.std_phi_deg), "%s: СКО крена, °" % tag)
	approx(o.std_rel_y_m, r.std_rel_y_m, 0.15 * float(r.std_rel_y_m), "%s: СКО пилота поперёк, м" % tag)
	print("    %s: СКО крена %.2f° (прототип %.2f°), СКО пилота поперёк %.3f м (%.3f), растяжение %.3f м (%.3f)" % [
		tag, o.std_phi_deg, r.std_phi_deg, o.std_rel_y_m, r.std_rel_y_m, o.max_stretch_m, r.max_stretch_m])


func _check_bounded(o: Dictionary, tag: String) -> void:
	check(not o.blowup, "%s: без развала и NaN" % tag)
	check(o.max_stretch_m < 0.1, "%s: цепь держит (растяжение %.3f м)" % [tag, o.max_stretch_m])
	check(o.max_abs_phi_deg < 45.0, "%s: крен в болтанке ограничен (%.1f°)" % [tag, o.max_abs_phi_deg])


func test_turbulence_120hz() -> void:
	for w: String in ["training", "laminar", "sport"]:
		_check_turb("turbulence", w, 1.0 / 120.0)


func test_turbulence_60_30hz() -> void:
	_check_turb("turbulence_dt60", "sport", 1.0 / 60.0)
	_check_turb("turbulence_dt30", "sport", 1.0 / 30.0)


## Крылья игры (блок PD-1): трим чуть иной — путь через поле другой, статистика не сравнима
## по точкам (хаотичный отклик), проверяем только «без развала».
func test_turbulence_game_blocks() -> void:
	for w: String in ["training", "laminar", "sport"]:
		for dt: float in [1.0 / 120.0, 1.0 / 30.0]:
			var o := _turbulence(w, dt, false)
			_check_bounded(o, "%s (игра) dt 1/%d" % [w, roundi(1.0 / dt)])
			print("    %s (игра) dt 1/%d: СКО крена %.2f°, макс. %.1f°" % [
				w, roundi(1.0 / dt), o.std_phi_deg, o.max_abs_phi_deg])


func test_any_dt_no_nan() -> void:
	# полное смещение и «на себя» на каждом шаге из диапазона PD-К1
	for dt: float in [1.0 / 240.0, 1.0 / 60.0, 1.0 / 30.0]:
		var m := S.make("sport")
		S.reset(m)
		var inp := S.input(-1.0, 1.0)
		for i in int(round(8.0 / dt)):
			m.step(dt, inp, Callable(), Callable())
		check(S.finite(m), "dt %.4f: без NaN" % dt)
		check(m.chain.max_stretch < 0.15, "dt %.4f: цепь держит (%.3f м)" % [dt, m.chain.max_stretch])


func test_touchdown_lands() -> void:
	var m := S.make("laminar")
	m.reset_in_air(Vector3(0.0, 30.0, 0.0), 90.0)
	var got := []
	m.landed.connect(func(res: Dictionary) -> void: got.append(res))
	var ground := func(_x: float, _z: float) -> float: return 0.0
	var inp := S.input()
	var t := 0.0
	while m.mode == FlightModel.Mode.AIR and t < 120.0:
		m.step(S.DT, inp, Callable(), ground)
		t += S.DT
	check(m.mode == FlightModel.Mode.LANDED, "ступни коснулись земли → LANDED")
	check(got.size() == 1, "сигнал landed один раз")
	check(m.phase() == "landed" and m.telemetry.on_ground, "фаза landed")
	var res := m.landing_result
	check(res.get("grade", "") in ["soft", "hard", "crash"], "оценка LandingJudge: %s" % res)
	check(res.has("position") and res.has("flight_time_s"), "position и flight_time_s в результате")
	var feet: Vector3 = m.pilot_position - m.pilot_basis.y * 1.0
	check(absf(feet.y) < 0.2, "ступни у земли (%.2f м)" % feet.y)
	# прямое планирование на триме: горизонтальная ~10 м/с — «жёсткая», не авария по вертикали
	check(float(res.vertical_speed_ms) < 3.0, "вертикальная %.2f м/с" % res.vertical_speed_ms)
	var p := m.position
	m.step(S.DT, inp, Callable(), ground)
	check(m.position.is_equal_approx(p), "после касания step не интегрирует")
	print("    касание: %s за %.1f с" % [res, t])


func test_reset_on_ground_starts_in_air() -> void:
	var m := S.make("sport")
	m.reset_on_ground(Vector3(5.0, 200.0, 7.0), 30.0)
	check(m.mode == FlightModel.Mode.AIR, "v1: старт в воздухе")
	approx(m.position.y, 300.0, 0.5, "на 100 м выше")
	approx(m.telemetry.heading_deg, 30.0, 0.5, "курс")
