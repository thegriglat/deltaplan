extends TestCase
## Земля «Маятника» (PD-К1 v2, PD-3): разбег со склона против эталона прототипа
## (reference.json → ground_run*, tools/research/pendulum/export_reference.py --ground; допуск
## ±15 %), встречный ветер, стоять с крылом, падение на крыло, ходьба.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]
const TOL := 0.15
const SLOPE_DEG := 15.0


## Склон вниз на север (−Z игры) под углом deg, высота 0 в начале координат.
static func slope_fn(deg: float) -> Callable:
	var k := tan(deg_to_rad(deg))
	return func(_x: float, z: float) -> float: return k * z


## Встречный ветер speed, м/с, вдоль склона slope_deg (у земли поток обтекает склон): пилот бежит
## на север под горку, воздух идёт на юг и вверх по склону.
static func wind_fn(speed: float, slope_deg := SLOPE_DEG) -> Callable:
	var a := deg_to_rad(slope_deg)
	return func(_p: Vector3) -> Vector3: return Vector3(0.0, speed * sin(a), speed * cos(a))


## Разбег как в прототипе: стоит 1 с, потом бежит (run); pitch — трапеция всё время. → {t, x (путь ЦМ пилота на север),
## v_kmh (воздушная скорость крыла), took_off, failure, model, run_s, v_after_kmh (через 4 с)}.
static func run_up(
	wing: String, wind: float, slope := SLOPE_DEG, t_max := 25.0, pitch := 0.0
) -> Dictionary:
	var m := S.make(wing)
	var g := slope_fn(slope)
	var air := wind_fn(wind)
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var x0 := m.pilot_position
	var out := {"took_off": false, "failure": "", "model": m}
	var t := 0.0
	var inp := S.input(pitch)
	while t < t_max:
		inp.run = t > 1.0 - 1.0e-9
		m.step(S.DT, inp, air, g)
		t += S.DT
		if m.mode == FlightModel.Mode.FAILED:
			out.failure = m.takeoff_failure
			break
		if not out.took_off and m.mode == FlightModel.Mode.AIR:
			out.took_off = true
			out.t = t
			out.run_s = t - 1.0
			out.x = -(m.pilot_position.z - x0.z)
			out.v_kmh = m.telemetry.airspeed * 3.6
		if out.took_off and t >= out.t + 4.0:
			out.v_after_kmh = m.telemetry.airspeed * 3.6
			out.flying_after = m.mode == FlightModel.Mode.AIR
			break
	return out


func _against_ref(name: String, wind: float) -> Dictionary:
	var res := {}
	for w: String in WINGS:
		var ref := S.scenario(name, w)
		var r := run_up(w, wind)
		res[w] = r
		check(r.took_off, "%s %s: отрыв (срыв «%s»)" % [name, w, r.failure])
		if not r.took_off:
			continue
		print("    %s %s: отрыв %.2f с (эталон %.2f), путь %.1f м (%.1f), V %.1f км/ч (%.1f), через 4 с %.1f км/ч" % [
			name, w, r.t, ref.t_liftoff, r.x, ref.x_liftoff, r.v_kmh, ref.v_liftoff_kmh,
			r.get("v_after_kmh", NAN)])
		approx(r.t, ref.t_liftoff, TOL * ref.t_liftoff, "%s %s: время до отрыва, с" % [name, w])
		approx(r.x, ref.x_liftoff, TOL * ref.x_liftoff, "%s %s: путь до отрыва, м" % [name, w])
		approx(r.v_kmh, ref.v_liftoff_kmh, TOL * ref.v_liftoff_kmh,
			"%s %s: воздушная скорость отрыва, км/ч" % [name, w])
		var m: PendulumModel = r.model
		check(S.finite(m), "%s %s: без NaN" % [name, w])
	return res


func test_run_up_calm() -> void:
	var res := _against_ref("ground_run", 0.0)
	for w: String in WINGS:
		var r: Dictionary = res[w]
		if not r.took_off or not r.has("v_after_kmh"):
			continue
		# после отрыва руки на штанге в нейтрали: крыло само держит скорость около трима и летит
		var trim := float(Config.get_config("wings/" + w).trim_speed_kmh)
		check(r.flying_after, "%s: через 4 с после отрыва летит" % w)
		check(absf(r.v_after_kmh - trim) < 0.2 * trim,
			"%s: через 4 с после отрыва %.1f км/ч (отрыв %.1f, трим %.0f)" % [w, r.v_after_kmh, r.v_kmh, trim])


func test_run_up_headwind_shorter() -> void:
	var res := _against_ref("ground_run_wind3", 3.0)
	for w: String in WINGS:
		var calm := run_up(w, 0.0)
		var r: Dictionary = res[w]
		if r.took_off and calm.took_off:
			check(r.x < 0.8 * calm.x, "%s: встречный 3 м/с — путь короче (%.1f против %.1f м)" % [w, r.x, calm.x])


## Пилот: «встречный 6 м/с — отрыв за 2 шага» — отрыв за 1–3 с бега.
func test_run_up_headwind_6() -> void:
	var res := _against_ref("ground_run_wind6", 6.0)
	for w: String in WINGS:
		var r: Dictionary = res[w]
		if r.took_off:
			check(r.run_s >= 0.5 and r.run_s <= 3.0, "%s: встречный 6 м/с — отрыв за %.2f с бега (1–3)" % [w, r.run_s])


## Для отчёта: разбег в штиль со склона 15° у нынешнего GroundRun (FlightModel) и у маятника.
func test_compare_ground_run() -> void:
	for w: String in WINGS:
		var fm := FlightModel.new()
		var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
		pilot.mass_kg = float(Config.get_config("wings/" + w).pilot_mass_ref_kg)
		fm.setup(Config.get_config("wings/" + w), pilot, {"air_density": {"altitude_dependent": false}})
		fm.reset_on_ground(Vector3.ZERO, 0.0)
		var g := slope_fn(SLOPE_DEG)
		var inp := ControlInput.new()
		var t := 0.0
		while t < 25.0 and fm.mode == FlightModel.Mode.GROUND:
			inp.run = t > 1.0 - 1.0e-9
			fm.step(S.DT, inp, Callable(), g)
			t += S.DT
		var r := run_up(w, 0.0)
		check(fm.mode == FlightModel.Mode.AIR, "%s: GroundRun отрыв" % w)
		print("    штиль 15° %s: GroundRun %.2f с бега, %.1f м, %.1f км/ч; маятник %.2f с, %.1f м, %.1f км/ч" % [
			w, t - 1.0, -fm.position.z, fm.telemetry.airspeed * 3.6, r.get("run_s", NAN), r.get("x", NAN),
			r.get("v_kmh", NAN)])


## Стоять на склоне 15° с крылом 10 с: без дрожи и сползания.
func test_stand_still() -> void:
	for w: String in WINGS:
		var m := S.make(w)
		var g := slope_fn(SLOPE_DEG)
		m.reset_on_ground(Vector3(3.0, 0.0, 4.0), 30.0)
		var inp := S.input()
		for i in 120:
			m.step(S.DT, inp, Callable(), g)
		var p0 := m.pilot_position
		var th0 := m.theta
		var vmax := 0.0
		var wmax := 0.0
		for i in 1200:
			m.step(S.DT, inp, Callable(), g)
			vmax = maxf(vmax, maxf(m.pilot_velocity.length(), m.velocity.length()))
			wmax = maxf(wmax, absf(m.theta - th0))
		check(S.finite(m), "%s: без NaN" % w)
		check(m.mode == FlightModel.Mode.GROUND and m.phase() == "standing", "%s: стоит (%s)" % [w, m.phase()])
		check(vmax < 0.02, "%s: скорость ≈ 0 (наибольшая %.4f м/с)" % [w, vmax])
		check(m.pilot_position.distance_to(p0) < 0.01, "%s: не сползает (%.4f м за 10 с)" % [w, m.pilot_position.distance_to(p0)])
		check(wmax < deg_to_rad(0.2), "%s: крыло не качается (%.3f°)" % [w, rad_to_deg(wmax)])
		var feet: float = m.pilot_position.y - 1.0 - g.call(m.pilot_position.x, m.pilot_position.z)
		check(absf(feet) < 0.05, "%s: ступни на земле (%.3f м)" % [w, feet])
		check(m.telemetry.on_ground and m.telemetry.phase == "standing", "%s: телеметрия — на земле" % w)
		check(m.strap_tension < 0.5 * m.pilot_mass * Units.G, "%s: стропа провисает (%.0f Н)" % [w, m.strap_tension])


## Ходьба и поворот на месте.
func test_walk_and_turn() -> void:
	var m := S.make("sport")
	var flat := func(_x: float, _z: float) -> float: return 100.0
	m.reset_on_ground(Vector3(0.0, 100.0, 0.0), 0.0)
	var inp := S.input()
	inp.walk = 1.0
	for i in 600:
		m.step(S.DT, inp, Callable(), flat)
	check(m.phase() == "walking", "идёт: %s" % m.phase())
	var walk := float(Config.value("pilot", "walk.speed_ms"))
	approx(-m.pilot_position.z, walk * 5.0, 1.0, "прошёл на север за 5 с")
	inp.walk = 0.0
	inp.turn = 1.0
	for i in 240:
		m.step(S.DT, inp, Callable(), flat)
	var hd := m.telemetry.heading_deg
	check(hd > 45.0 and hd < 135.0, "поворот на месте вправо: курс %.0f°" % hd)
	check(m.mode == FlightModel.Mode.GROUND and S.finite(m), "на земле, без NaN")


## Падение на крыло: крен руками до упора на разбеге — бег уходит дугой поперёк склона, нижняя
## (к склону) консоль касается земли → takeoff_failed.
func test_wing_drop_fails() -> void:
	for w: String in WINGS:
		var m := S.make(w)
		var got := []
		m.takeoff_failed.connect(func(reason: String) -> void: got.append(reason))
		m.reset_on_ground(Vector3.ZERO, 0.0)
		var g := slope_fn(SLOPE_DEG)
		var inp := S.input(0.0, 1.0)
		inp.run = true
		var t := 0.0
		while t < 20.0 and m.mode != FlightModel.Mode.FAILED:
			m.step(S.DT, inp, Callable(), g)
			t += S.DT
		check(m.mode == FlightModel.Mode.FAILED, "%s: срыв взлёта (режим %d, фаза %s)" % [w, m.mode, m.phase()])
		check(got == ["wingtip"], "%s: takeoff_failed(wingtip): %s" % [w, got])
		check(m.phase() == "failed", "%s: фаза failed" % w)
		print("    падение на крыло %s: %.1f с, крен %.0f°" % [w, t, rad_to_deg(m.bank)])
