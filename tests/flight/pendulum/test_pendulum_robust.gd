extends TestCase
## «Маятник» (PD-2): болтанка σ 1 м/с без развала; шаг 1/120, 1/60, 1/30 с без NaN; временное
## касание → LANDED и LandingJudge (земля — test_pendulum_ground*).

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


## Болтанка против прототипа (блок прототипа, то же поле и регулятор). Отклик хаотичен: у самого
## прототипа СКО крена за 30–140 с меняется в 0,6–1,7 раза от одной смены шага (1/120 → 1/60),
## поэтому по точкам не сравнить — только «без развала» и порядок величины (0,5× меньшего — 2× большего
## из прогонов прототипа по шагам: после PD-19 у sport они 4,8–17,1°, среднее одним выбросом не мерило).
## Эталон «turbulence» — среднее прототипа по шагам 1/120, 1/100, 1/60, 1/30 (PD-14); dt60/dt30 — свои прогоны.
func _check_turb(name: String, w: String, dt: float) -> void:
	var r := S.scenario(name, w)
	var o := _turbulence(w, dt, true)
	var tag := "%s dt 1/%d" % [w, roundi(1.0 / dt)]
	_check_bounded(o, tag, w)
	# порядок прототипа: 0,5× меньшего — 2× большего из среднего и прогонов по шагам (by_dt)
	var lo_phi: float = r.std_phi_deg
	var hi_phi: float = r.std_phi_deg
	var lo_y: float = r.std_rel_y_m
	var hi_y: float = r.std_rel_y_m
	# прогоны 1/60 и 1/30 — одиночные: окно — ещё и по шагам эталона-среднего (PD-23: sport на поле
	# эталона у срыва хаотичен — СКО крена прототипа по шагам 6–60°, один прогон окна не задаёт)
	var by: Array = r.get("by_dt", [])
	if by.is_empty():
		by = S.scenario("turbulence", w).get("by_dt", [])
	for b: Dictionary in by:
		lo_phi = minf(lo_phi, float(b.std_phi_deg))
		hi_phi = maxf(hi_phi, float(b.std_phi_deg))
		lo_y = minf(lo_y, float(b.std_rel_y_m))
		hi_y = maxf(hi_y, float(b.std_rel_y_m))
	check(o.std_phi_deg > 0.5 * lo_phi and o.std_phi_deg < 2.0 * hi_phi,
		"%s: СКО крена %.1f° — порядок прототипа (%.1f°, по шагам %.1f–%.1f°)" % [
		tag, o.std_phi_deg, r.std_phi_deg, lo_phi, hi_phi])
	check(o.std_rel_y_m > 0.5 * lo_y and o.std_rel_y_m < 2.0 * hi_y,
		"%s: СКО пилота поперёк %.3f м — порядок прототипа (%.3f, по шагам %.3f–%.3f)" % [
		tag, o.std_rel_y_m, r.std_rel_y_m, lo_y, hi_y])
	print("    %s: СКО крена %.2f° (прототип %.2f°), СКО пилота поперёк %.3f м (%.3f), растяжение %.3f м (%.3f)" % [
		tag, o.std_phi_deg, r.std_phi_deg, o.std_rel_y_m, r.std_rel_y_m, o.max_stretch_m, r.max_stretch_m])


## Без развала, цепь держит, крен ограничен (у всех трёх, как до PD-18; PD-19 — руки без интеграла).
func _check_bounded(o: Dictionary, tag: String, _w := "") -> void:
	check(not o.blowup, "%s: без развала и NaN" % tag)
	check(o.max_stretch_m < 0.1, "%s: цепь держит (растяжение %.3f м)" % [tag, o.max_stretch_m])
	check(o.max_abs_phi_deg < 60.0, "%s: крен в болтанке ограничен (%.1f°)" % [tag, o.max_abs_phi_deg])


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
			_check_bounded(o, "%s (игра) dt 1/%d" % [w, roundi(1.0 / dt)], w)
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
	# v2: после жёсткой посадки пилот на ногах — пробежка, а не заморозка
	for i in 240:
		m.step(S.DT, inp, Callable(), ground)
	check(m.mode == FlightModel.Mode.LANDED and S.finite(m), "стоит на ногах, без NaN")
	check(got.size() == 1, "landed не повторяется")
	print("    касание: %s за %.1f с" % [res, t])


func test_reset_on_ground_stands() -> void:
	var m := S.make("sport")
	m.reset_on_ground(Vector3(5.0, 200.0, 7.0), 30.0)
	check(m.mode == FlightModel.Mode.GROUND, "v2: стоит на земле")
	approx(m.pilot_position.y - 1.0, 200.0, 0.05, "ступни на земле")
	approx(m.telemetry.heading_deg, 30.0, 0.5, "курс")


func test_reset_wind_and_airspeed() -> void:
	var m := S.make("sport")
	m.reset_in_air(Vector3(0.0, 500.0, 0.0), 90.0)
	var v_trim := m.telemetry.airspeed
	var wind := Vector3(0.0, 0.0, 4.0)
	m.reset_in_air(Vector3(0.0, 500.0, 0.0), 90.0, 0.0, wind)
	var air := func(_p: Vector3) -> Vector3: return wind
	m.step(S.DT, S.input(), air, Callable())
	approx(m.telemetry.airspeed, v_trim, 0.1, "ветер при сбросе: воздушная скорость — трим")
	approx(m.velocity.z, wind.z, 0.3, "путевая скорость несёт ветер (курс восток, ветер на юг)")
	m.reset_in_air(Vector3(0.0, 500.0, 0.0), 0.0, 15.0)
	approx(m.telemetry.airspeed, 15.0, 0.05, "airspeed_ms задаёт воздушную скорость")
