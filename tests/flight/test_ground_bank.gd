extends TestCase
## Крен крыла на плечах пилота на земле (SF-3, К3 v3): «рука пилота» ведёт крыло к заданному крену
## (input.roll) с пределом ∝ доле веса на ногах; поворот стоя — на месте (input.turn), на бегу —
## дугой от крена крыла; переход в полёт без рывка. docs/flight.md.

const Sim := preload("res://tests/flight/flight_sim.gd")
const FLAT := 500.0
## Склон, спускающийся на север (−Z), уклон 0,3 (~17°), как в test_takeoff.
const SLOPE := 0.3
## Порыв на 20 % выше порога должен опрокинуть не дольше чем за столько, с: избыток момента
## мал, крен нарастает медленно (аэродемпфирование крыла ~1200 Н·м·с при 4–5 м/с).
const GUST_FAIL_S := 20.0
## Прогон порыва, с.
const GUST_S := 30.0


static func flat(_x: float, _z: float) -> float:
	return FLAT


static func slope(_x: float, z: float) -> float:
	return 1000.0 + SLOPE * z


static func wind_fn(v: Vector3) -> Callable:
	return func(_p: Vector3) -> Vector3: return v


static func m_max() -> float:
	return float(Config.get_config("flight").ground_bank.pilot_moment_max_nm)


## 1. Штиль, стоит 10 с с зажатой A (D) — input.turn: крен < 0,5°, курс поворачивается.
func test_standing_turn_stays_level() -> void:
	for roll in [-1.0, 1.0]:
		var m := Sim.make("sport")
		m.reset_on_ground(Vector3.ZERO, 0.0)
		var inp := Sim.input()
		inp.turn = roll
		var max_bank := 0.0
		var turned := 0.0
		var h_prev := m.heading
		for i in int(10.0 / Sim.DT):
			m.step(Sim.DT, inp, Callable(), flat)
			max_bank = maxf(max_bank, absf(m.telemetry.bank_deg))
			turned += wrapf(m.heading - h_prev, -PI, PI)
			h_prev = m.heading
		print(
			(
				"    стоит, roll=%+.0f 10 с: max|крен| %.3f°, повернул %.0f°, фаза %s"
				% [roll, max_bank, rad_to_deg(turned), m.phase()]
			)
		)
		check(m.phase() == "standing", "стоит: " + m.phase())
		check(max_bank < 0.5, "стоя поворот (turn) крыло не кренит: %.3f°" % max_bank)
		check(absf(rad_to_deg(turned)) > 30.0, "курс поворачивается: %.0f°" % rad_to_deg(turned))
		check(signf(turned) == signf(roll), "D — вправо, A — влево")


## 2. Слабый боковой ветер 2,5 м/с (+ встречный 4), без ввода: установившийся крен < 5°, взлёт.
func test_light_crosswind_holds() -> void:
	for w in ["sport", "apogee", "combat"]:
		var r := _run(w, Vector3(2.5, 0, 4.0), 0.0, slope)
		print(
			(
				"    %s боковой 2,5+встречный 4: крен N/W>0,5 %.2f°, разбег %.2f°, отрыв %.2f°, %s %.1f с %s"
				% [w, r.max_bank_loaded, r.max_bank, r.bank_liftoff, r.took_off, r.t, r.failure]
			)
		)
		check(r.took_off, "%s: слабый боковой ветер — взлёт (срыв %s)" % [w, r.failure])
		check(
			r.max_bank_loaded < 5.0, "%s: установившийся крен %.2f° < 5°" % [w, r.max_bank_loaded]
		)


## 3. Порыв сбоку выше порога (M_ветра = M_max·N/W) опрокидывает, на 20 % ниже — держит.
func test_side_gust_threshold() -> void:
	var head := 4.0
	var s_thr := crosswind_threshold("sport", head)
	print("    порог бокового порыва стоя, sport, встречный %.0f м/с: %.2f м/с" % [head, s_thr])
	check(s_thr > 1.0 and s_thr < 15.0, "порог в разумных пределах: %.2f" % s_thr)
	for side in [1.0, -1.0]:
		var hi := _gust("sport", head, 1.2 * s_thr * side)
		var hi2 := _gust("sport", head, 2.0 * s_thr * side)
		var lo := _gust("sport", head, 0.8 * s_thr * side)
		print(
			(
				"    порыв ×1,2 (%+.2f м/с): '%s' за %.2f с; ×2: '%s' за %.2f с; ×0,8: '%s', max|крен| %.2f°"
				% [
					1.2 * s_thr * side,
					hi.failure,
					hi.t,
					hi2.failure,
					hi2.t,
					lo.failure,
					lo.max_bank
				]
			)
		)
		check(hi.failure == "crosswind", "порыв выше порога опрокидывает: '%s'" % hi.failure)
		check(hi.t < GUST_FAIL_S, "опрокидывает за %.2f с" % hi.t)
		check(hi2.failure == "crosswind" and hi2.t < hi.t, "сильнее порыв — быстрее")
		check(lo.failure == "", "порыв на 20 %% ниже порога — держит: '%s'" % lo.failure)
		check(lo.max_bank < 5.0, "держит почти ровно: %.2f°" % lo.max_bank)


## 1б. Стоя крен крыла — заданный рукой (input.roll · command_max_deg): штиль и встречный 6 м/с,
## «Славутич» и «спорт». В штиль рука доводит до заданного; в 6 м/с — сколько позволяет M_max·N/W.
func test_standing_bank_command() -> void:
	var phi_max := float(Config.get_config("flight").ground_bank.command_max_deg)
	for w in ["slavutich_ut", "sport"]:
		for head in [0.0, 6.0]:
			for roll in [1.0, -1.0, 0.5]:
				var m := Sim.make(w)
				m.reset_on_ground(Vector3.ZERO, 0.0)
				var inp := Sim.input(0.0, roll)
				var af := wind_fn(Vector3(0, 0, head))
				Sim.run_for(m, 3.0, inp, af, slope)
				var gr: GroundRun = m._ground
				var b := m.telemetry.bank_deg
				print(
					(
						"    %s встречный %.0f, roll %+.1f: крен %.2f° (задано %.1f°), N/W %.2f, %s"
						% [w, head, roll, b, roll * phi_max, gr.feet_load, m.phase()]
					)
				)
				check(m.mode == FlightModel.Mode.GROUND, "%s %.0f: стоит (%s)" % [w, head, m.phase()])
				check(signf(b) == signf(roll), "%s: крен в сторону ввода: %.2f" % [w, b])
				if head == 0.0:
					approx(b, roll * phi_max, 0.5, "%s штиль: крен к заданному" % w)
				else:
					check(absf(b) > 0.5 * absf(roll) * phi_max, "%s 6 м/с: крен заметен %.2f" % [w, b])
				check(absf(m.telemetry.heading_deg) < 0.5, "крен стоя не поворачивает курс")
			# отпустил — снова горизонт
			var m2 := Sim.make(w)
			m2.reset_on_ground(Vector3.ZERO, 0.0)
			Sim.run_for(m2, 2.0, Sim.input(0.0, 1.0), wind_fn(Vector3(0, 0, head)), slope)
			# в сильный ветер к рулю руки добавляется аэродемпфирование — медленная мода ≈ 1 с
			Sim.run_for(m2, 6.0, Sim.input(), wind_fn(Vector3(0, 0, head)), slope)
			check(absf(m2.telemetry.bank_deg) < 0.5, "%s: отпустил — горизонт %.2f" % [w, m2.telemetry.bank_deg])


## 4. Разбег с креном вправо (roll): дуга от крена, |a| ≤ a_max, радиус ≥ R_min; без крена — прямо.
func test_run_arc() -> void:
	var a_max := float(Config.value("pilot", "run.turn_accel_max_ms2"))
	var w_walk := deg_to_rad(float(Config.value("pilot", "walk.turn_rate_dps")))
	for roll in [1.0, 0.5, -1.0, 0.0]:
		var m := Sim.make("sport")
		m.reset_on_ground(Vector3.ZERO, 0.0)
		var inp := Sim.input(0.0, roll, true)
		var max_bank := 0.0
		var min_ratio := INF  # R / R_min
		var max_a := 0.0
		var h_prev := m.heading
		var turned := 0.0
		for i in int(8.0 / Sim.DT):
			m.step(Sim.DT, inp, Callable(), slope)
			if m.mode != FlightModel.Mode.GROUND:
				break
			max_bank = maxf(max_bank, absf(m.telemetry.bank_deg))
			var dh := wrapf(m.heading - h_prev, -PI, PI)
			h_prev = m.heading
			turned += dh
			var v := Vector2(m.velocity.x, m.velocity.z).length()
			if absf(dh) > 1.0e-6 and v > 0.5:
				var r := v * Sim.DT / absf(dh)
				var r_min := maxf(v * v / a_max, v / w_walk)
				min_ratio = minf(min_ratio, r / r_min)
				max_a = maxf(max_a, v * absf(dh) / Sim.DT)
		print(
			(
				"    разбег roll %+.1f: повернул %.1f°, max|крен| %.2f°, max|a| %.2f м/с² (≤ %.1f), R/R_min %.3f, %s"
				% [roll, rad_to_deg(turned), max_bank, max_a, a_max, min_ratio, m.phase()]
			)
		)
		if roll == 0.0:
			check(absf(rad_to_deg(turned)) < 0.5, "без крена — прямо: %.2f°" % rad_to_deg(turned))
			check(max_bank < 1.0, "без ввода крен ≈ 0: %.2f°" % max_bank)
		else:
			check(
				signf(turned) == signf(roll) and absf(turned) > deg_to_rad(10.0),
				"дуга в сторону крена: %.0f°" % rad_to_deg(turned)
			)
			check(max_a <= a_max * 1.01, "|a| ≤ a_max: %.3f" % max_a)
			check(min_ratio > 0.99, "радиус не меньше R_min: %.3f" % min_ratio)


## 5. Переход: крен и скорость крена непрерывны на отрыве (штиль и слабый боковой ветер).
func test_liftoff_continuity() -> void:
	# в штиль «спорт» на 17° отрывается только с носом чуть выше нейтрали (pitch 0,3)
	for wind in [Vector3(0, 0, 0), Vector3(2.5, 0, 4.0)]:
		var r := _run("sport", wind, 0.3 if wind == Vector3.ZERO else 0.0, slope)
		print(
			(
				"    ветер %s: отрыв Δкрен %.4f°, Δp %.3f°/с (%.3f → %.3f °/с), N/W до отрыва %.3f"
				% [wind, r.d_bank, r.d_rate, r.rate_before, r.rate_after, r.load_before]
			)
		)
		check(r.took_off, "взлёт при %s" % wind)
		check(r.d_bank < 0.1, "скачок крена на отрыве %.4f°" % r.d_bank)
		check(r.d_rate < 1.0, "скачок скорости крена на отрыве %.3f°/с" % r.d_rate)
		check(r.load_before < 0.1, "перед отрывом ноги почти разгружены: %.3f" % r.load_before)


## 5б. Удержание ∝ доле веса на ногах: при разгрузке 50 % предел вдвое меньше.
func test_hold_scales_with_feet_load() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var inertia := GroundRun.roll_inertia(m)
	var full := GroundRun.pilot_moment(m, deg_to_rad(30.0), 0.0, 1.0, inertia)
	var half := GroundRun.pilot_moment(m, deg_to_rad(30.0), 0.0, 0.5, inertia)
	var none := GroundRun.pilot_moment(m, deg_to_rad(30.0), 0.0, 0.0, inertia)
	print(
		(
			"    I = %.0f кг·м²; предел: N/W=1 → %.0f, 0,5 → %.0f, 0 → %.0f Н·м"
			% [inertia, full, half, none]
		)
	)
	approx(full, -m_max(), 0.01, "полный вес на ногах — M_max")
	approx(half, -0.5 * m_max(), 0.01, "разгрузка 50 % — вдвое меньше")
	approx(none, 0.0, 1.0e-6, "оторвался — рука не держит")
	# живой разбег: предел в каждом шаге = M_max · N/W
	var gr: GroundRun = m._ground
	var worst := 0.0
	var saw_half := false
	for i in int(8.0 / Sim.DT):
		m.step(Sim.DT, Sim.input(0.0, 0.0, true), wind_fn(Vector3(0, 0, 3.0)), slope)
		if m.mode != FlightModel.Mode.GROUND:
			break
		worst = maxf(worst, absf(gr.hold_limit_nm - m_max() * gr.feet_load))
		saw_half = saw_half or absf(gr.feet_load - 0.5) < 0.05
	check(worst < 1.0e-3, "на разбеге предел = M_max·N/W: %.5f" % worst)
	check(saw_half, "разбег проходит через N/W ≈ 0,5")


## 6. Косой склон 15°: крыло ровно по горизонту (не по склону), стоя, шагом и на бегу.
func test_cross_slope_level() -> void:
	var tilt := tan(deg_to_rad(15.0))
	var ground := func(x: float, z: float) -> float: return 1000.0 + SLOPE * z + tilt * x
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var max_bank := 0.0
	var inp := Sim.input()
	for part in [["stand", 3.0], ["walk", 3.0], ["run", 8.0]]:
		inp.walk = 1.0 if part[0] == "walk" else 0.0
		inp.run = part[0] == "run"
		for i in int(float(part[1]) / Sim.DT):
			m.step(Sim.DT, inp, Callable(), ground)
			if m.mode != FlightModel.Mode.GROUND:
				break
			max_bank = maxf(max_bank, absf(m.telemetry.bank_deg))
	print("    косой склон 15°: max|крен| %.4f°, итог %s" % [max_bank, m.phase()])
	check(max_bank < 0.5, "на косом склоне крен к горизонту ≈ 0: %.4f°" % max_bank)


## Порог бокового ветра стоя лицом во встречный head_ms: M_ветра(s) = M_max·N/W(s).
## Моменты берутся из самой модели (GroundRun.wind_moment_nm, hold_limit_nm) — бисекция.
static func crosswind_threshold(w: String, head_ms: float) -> float:
	var lo := 0.0
	var hi := 20.0
	for k in 16:
		var s := 0.5 * (lo + hi)
		var m := Sim.make(w)
		m.reset_on_ground(Vector3(0, 0, 0), 0.0)
		Sim.run_for(m, 1.0, Sim.input(), wind_fn(Vector3(s, 0, head_ms)), flat)
		var gr: GroundRun = m._ground
		if m.mode == FlightModel.Mode.GROUND and absf(gr.wind_moment_nm) < gr.hold_limit_nm:
			lo = s
		else:
			hi = s
	return 0.5 * (lo + hi)


## Стоит во встречном head_ms 2 с, затем боковой порыв side_ms на 10 с.
func _gust(w: String, head_ms: float, side_ms: float) -> Dictionary:
	var m := Sim.make(w)
	m.reset_on_ground(Vector3.ZERO, 0.0)
	Sim.run_for(m, 2.0, Sim.input(), wind_fn(Vector3(0, 0, head_ms)), flat)
	var res := {"failure": "", "t": 0.0, "max_bank": 0.0}
	var af := wind_fn(Vector3(side_ms, 0, head_ms))
	var t := 0.0
	while t < GUST_S:
		m.step(Sim.DT, Sim.input(), af, flat)
		t += Sim.DT
		res.max_bank = maxf(res.max_bank, absf(m.telemetry.bank_deg))
		if m.mode == FlightModel.Mode.FAILED:
			res.failure = m.takeoff_failure
			res.t = t
			break
	return res


## Разбег со склона без ввода крена; числа крена и перехода.
func _run(w: String, wind: Vector3, pitch: float, ground: Callable) -> Dictionary:
	var m := Sim.make(w)
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var gr: GroundRun = m._ground
	var res := {
		"took_off": false,
		"failure": "",
		"t": 0.0,
		"max_bank": 0.0,
		"max_bank_loaded": 0.0,
		"bank_liftoff": 0.0,
		"d_bank": 0.0,
		"d_rate": 0.0,
		"rate_before": 0.0,
		"rate_after": 0.0,
		"load_before": 1.0,
	}
	var af := wind_fn(wind)
	var inp := Sim.input(pitch, 0.0, true)
	var t := 0.0
	var prev_bank := 0.0
	var prev_rate := 0.0
	var prev_load := 1.0
	while t < 12.0:
		m.step(Sim.DT, inp, af, ground)
		t += Sim.DT
		var b := rad_to_deg(m.bank)
		var p := rad_to_deg(m.roll_rate)
		if m.mode == FlightModel.Mode.AIR:
			res.took_off = true
			res.t = t
			res.bank_liftoff = b
			# шаг отрыва ещё земной; скачок смотрим на первом воздушном шаге
			m.step(Sim.DT, inp, af, ground)
			var b2 := rad_to_deg(m.bank)
			var p2 := rad_to_deg(m.roll_rate)
			res.d_bank = absf((b2 - b) - (b - prev_bank))
			res.d_rate = absf((p2 - p) - (p - prev_rate))
			res.rate_before = p
			res.rate_after = p2
			res.load_before = prev_load
			break
		if m.mode == FlightModel.Mode.FAILED:
			res.failure = m.takeoff_failure
			res.t = t
			break
		res.max_bank = maxf(res.max_bank, absf(b))
		if gr.feet_load > 0.5:
			res.max_bank_loaded = maxf(res.max_bank_loaded, absf(b))
		prev_bank = b
		prev_rate = p
		prev_load = gr.feet_load
	return res
