extends TestCase
## Посадка «Маятника» (PD-К1 v2, PD-3): заход на триме над ровной землёй, выравнивание — «от себя»
## до упора на высоте ступней flare_h; касание ступнями → LandingJudge (пороги flight.json →
## landing не меняются): мягкая / жёсткая / авария. Консоль в землю раньше ступней — авария.
## После посадки без аварии пилот на ногах с крылом: пробежка гасит скорость, run/walk — земля.
## Экранный эффект полос (PD-14) включён. В штиль мягкая — только у учебного: у laminar и sport
## (нагрузка на крыло 7,8 и 8,5 кг/м² против 6,5) лучшая посадка — на пороге, но выше (верт ≈ 5,1–5,5
## или гор ≈ 3,1–3,4 м/с). Это предел самой аэродинамики полос, а не техники: идеальная точка с C_L(α),
## C_D(α) этого крыла и любым законом α(t) даёт max(верт/5, гор/3) = 0,90 / 1,00 / 1,06 (PD-14).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]
const FLARE_HEIGHTS := [1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.5]


## Заход с 12 м на триме курсом на север; встречный ветер wind, м/с. flare_h < 0 — без
## выравнивания; pitch — трапеция до выравнивания, roll — крен. → {result, model, flare}.
static func approach(
	wing: String, wind: float, flare_h: float, pitch := 0.0, roll := 0.0, h0 := 12.0
) -> Dictionary:
	var m := S.make(wing)
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var w := Vector3(0.0, 0.0, wind)
	var air := func(_p: Vector3) -> Vector3: return w
	m.reset_in_air(Vector3(0.0, h0, 0.0), 0.0, 0.0, w)
	var got := []
	m.landed.connect(func(r: Dictionary) -> void: got.append(r))
	var inp := S.input(pitch, roll)
	var t := 0.0
	var flare := 0.0
	while m.mode == FlightModel.Mode.AIR and t < 60.0:
		if flare_h >= 0.0 and m.pilot_position.y - 1.0 < flare_h:
			inp.pitch = 1.0
		m.step(S.DT, inp, air, flat)
		flare = maxf(flare, m.flare_amount())
		t += S.DT
	return {"result": m.landing_result, "model": m, "signals": got, "flare": flare, "air": air,
		"ground": flat}


static func fmt(r: Dictionary) -> String:
	return "%s: вертикальная %.2f, горизонтальная %.2f м/с, крен %.0f°, касание %s" % [
		r.get("grade", "?"), r.get("vertical_speed_ms", NAN), r.get("horizontal_speed_ms", NAN),
		r.get("bank_deg", NAN), r.get("contact", "?")]


## Выравнивание на подходящей высоте даёт мягкую: учебное — в штиль, все — во встречный 3 м/с.
func test_soft_with_flare() -> void:
	var cases := [["training", 0.0], ["training", 3.0], ["laminar", 3.0], ["sport", 3.0]]
	for c: Array in cases:
		var best := {}
		var best_h := NAN
		for h: float in FLARE_HEIGHTS:
			var a := approach(c[0], c[1], h)
			var r: Dictionary = a.result
			check(a.flare > 0.99, "%s: flare_amount у земли = 1 (%.2f)" % [c[0], a.flare])
			if r.get("grade", "") == "soft":
				best = r
				best_h = h
				break
		check(not best.is_empty(), "%s, ветер %.0f: есть высота выравнивания для мягкой посадки" % [c[0], c[1]])
		if not best.is_empty():
			print("    мягкая %s, ветер %.0f, выравнивание с %.2f м — %s" % [c[0], c[1], best_h, fmt(best)])


## Штиль, laminar и sport: мягкой нет, но лучшее выравнивание — у порога (max(верт/5, гор/3) ≤ 1,25;
## сторож предела, PD-14).
func test_calm_near_limit() -> void:
	for w: String in ["laminar", "sport"]:
		var best := 99.0
		var best_r := {}
		for h: float in FLARE_HEIGHTS:
			var r: Dictionary = approach(w, 0.0, h).result
			var sc := maxf(float(r.get("vertical_speed_ms", 99.0)) / 5.0, float(r.get("horizontal_speed_ms", 99.0)) / 3.0)
			if sc < best:
				best = sc
				best_r = r
		print("    штиль %s: лучшее %.2f — %s" % [w, best, fmt(best_r)])
		check(best <= 1.25, "%s: в штиль лучшее выравнивание у порога (%.2f)" % [w, best])


## Без выравнивания (прямо на триме) — жёсткая: горизонтальная больше soft_horizontal_ms.
func test_hard_without_flare() -> void:
	var lc: Dictionary = Config.get_config("flight").landing
	for w: String in WINGS:
		var a := approach(w, 0.0, -1.0)
		var r: Dictionary = a.result
		var m: PendulumModel = a.model
		print("    без выравнивания %s — %s" % [w, fmt(r)])
		check(r.get("grade", "") == "hard", "%s: без выравнивания — жёсткая (%s)" % [w, fmt(r)])
		check(float(r.horizontal_speed_ms) > float(lc.soft_horizontal_ms), "%s: жёсткая по горизонтальной" % w)
		check(m.mode == FlightModel.Mode.LANDED and m.phase() == "landed", "%s: LANDED" % w)
		check(a.signals.size() == 1, "%s: сигнал landed один раз" % w)
		check(r.has("position") and r.has("flight_time_s"), "%s: position и flight_time_s" % w)
		var feet: Vector3 = r.position
		check(absf(feet.y) < 0.01, "%s: точка касания на земле" % w)


## Выравнивание слишком высоко — крыло срывается и падает: вертикальная ≥ hard_vertical_ms.
func test_hard_flare_too_high() -> void:
	var lc: Dictionary = Config.get_config("flight").landing
	for w: String in WINGS:
		var r: Dictionary = approach(w, 0.0, 6.0).result
		print("    выравнивание с 6 м %s — %s" % [w, fmt(r)])
		check(r.get("grade", "") in ["hard", "crash"], "%s: высокое выравнивание — не мягкая" % w)
		check(float(r.vertical_speed_ms) >= float(lc.hard_vertical_ms), "%s: падает ≥ %.0f м/с" % [w, lc.hard_vertical_ms])


## «На себя» до упора к земле — авария (горизонтальная больше crash_horizontal_ms).
func test_crash_dive() -> void:
	var lc: Dictionary = Config.get_config("flight").landing
	for w: String in WINGS:
		var a := approach(w, 0.0, -1.0, -1.0, 0.0, 20.0)
		var r: Dictionary = a.result
		var m: PendulumModel = a.model
		print("    пикирование %s — %s" % [w, fmt(r)])
		check(r.get("grade", "") == "crash", "%s: пикирование в землю — авария" % w)
		check(float(r.horizontal_speed_ms) > float(lc.crash_horizontal_ms), "%s: по горизонтальной" % w)
		var p := m.position
		m.step(S.DT, S.input(), a.air, a.ground)
		check(m.position.is_equal_approx(p), "%s: после аварии всё стоит" % w)


## Крен до упора у земли — консоль касается раньше ступней: авария.
func test_crash_wingtip() -> void:
	for w: String in WINGS:
		var a := approach(w, 0.0, -1.0, 0.0, 1.0, 8.0)
		var r: Dictionary = a.result
		print("    крен у земли %s — %s" % [w, fmt(r)])
		check(r.get("grade", "") == "crash", "%s: консоль в землю — авария" % w)
		check(r.get("contact", "") == "wingtip", "%s: касание консолью (%s)" % [w, r.get("contact")])


## После посадки без аварии: пилот на ногах, пробежка гасит скорость; пошёл — снова на земле.
func test_after_landing() -> void:
	var a := approach("training", 0.0, -1.0)
	var m: PendulumModel = a.model
	check(m.landing_result.grade == "hard", "жёсткая посадка")
	var inp := S.input()
	for i in 600:
		m.step(S.DT, inp, a.air, a.ground)
	check(S.finite(m), "без NaN")
	check(m.mode == FlightModel.Mode.LANDED and m.phase() == "landed", "стоит после посадки")
	check(m.pilot_velocity.length() < 0.1, "остановился (%.2f м/с)" % m.pilot_velocity.length())
	var feet := m.pilot_position.y - 1.0
	check(absf(feet) < 0.1, "на ногах (ступни %.2f м)" % feet)
	check(m.telemetry.on_ground, "телеметрия — на земле")
	inp.walk = 1.0
	m.step(S.DT, inp, a.air, a.ground)
	check(m.mode == FlightModel.Mode.GROUND and m.phase() == "walking", "пошёл — на земле (%s)" % m.phase())
	check(m.landing_result.is_empty(), "результат посадки сброшен")
