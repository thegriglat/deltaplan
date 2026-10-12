extends TestCase
## PH-К1: усилие рук на трапеции (Telemetry.bar_force) в обеих моделях — форма и инварианты.

const FS := preload("res://tests/flight/flight_sim.gd")
const PS := preload("res://tests/flight/pendulum/pendulum_sim.gd")

const WING := "sport"


## Установившийся полёт FlightModel с трапецией pitch: Vector3(v, F.x, F.y) за последние кадры.
func _flight(pitch: float, roll: float = 0.0) -> Vector3:
	var m := FS.make(WING)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	FS.run_for(m, 40.0, FS.input(pitch, roll))
	var f: Vector2 = m.telemetry.bar_force
	return Vector3(m.telemetry.airspeed, f.x, f.y)


func _pendulum(pitch: float, wing: String = WING) -> Vector3:
	var m := PS.make(wing)
	PS.reset(m)
	for i in int(40.0 / PS.DT):
		m.step(PS.DT, PS.input(pitch, 0.0), Callable(), Callable())
	var f: Vector2 = m.telemetry.bar_force
	return Vector3(m.telemetry.airspeed, f.x, f.y)


func _v_trim() -> float:
	return FS.make(WING).trim_speed()


func test_default_zero_and_finite() -> void:
	check(Telemetry.new().bar_force == Vector2.ZERO, "по умолчанию ноль")
	check(FS.make(WING).telemetry.bar_force == Vector2.ZERO, "FlightModel до шага — ноль")
	check(PS.make(WING).telemetry.bar_force == Vector2.ZERO, "PendulumModel до шага — ноль")


func test_flight_model_numbers() -> void:
	var vt := _v_trim()
	var trim := _flight(0.0)
	check(Vector2(trim.y, trim.z).length() < 15.0, "FlightModel трим: |F| < 15 Н: %s" % trim)
	var prev := 0.0
	for p in [-0.3, -0.6, -1.0]:
		var r := _flight(p)
		var f := Vector2(r.y, r.z)
		print("PH1 flight pitch=%.1f v=%.2f (%.2f Vt) F=%s" % [p, r.x, r.x / vt, f])
		check(f.is_finite() and f.length() <= 300.0 + 1e-3, "|F| ≤ 300: %s" % f)
		check(f.y > 0.0, "pitch на себя → y>0: %s" % f)
		check(f.y > prev, "|y| растёт со скоростью: %.1f > %.1f" % [f.y, prev])
		prev = f.y


func test_flight_model_speed_ratio() -> void:
	var m := FS.make(WING)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var vt := m.trim_speed()
	var a: Vector2 = m.bar_force_estimate(1.15 * vt)
	var b: Vector2 = m.bar_force_estimate(1.3 * vt)
	print("PH1 flight est 1.15Vt=%s 1.3Vt=%s" % [a, b])
	check(a.y > 0.0 and b.y > a.y, "1,3·Vt сильнее 1,15·Vt: %s %s" % [a, b])
	check(m.bar_force_estimate(vt).length() < 1.0, "на триме усилия нет")


## Ввод в крен: x того же знака, что крен; установившийся вираж ~30° (ввод = «держащий») — |x| мал.
## Порог 60 Н — по замеру маятника в установившемся вираже 30° (sport, BankHold): среднее x = −39 Н,
## |x| ≤ 42 Н (при вводе пик до предела рук ~300 Н).
func test_flight_model_roll_entry_and_steady_turn() -> void:
	var m := FS.make(WING)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var wsin := FS.input(0.0, 0.3)
	wsin.weight_shift = true
	FS.run_for(m, 1.0, wsin)
	var f: Vector2 = m.telemetry.bar_force
	print("PH1 flight roll entry bank=%.1f F=%s" % [m.telemetry.bank_deg, f])
	check(m.telemetry.bank_deg > 1.0 and f.x > 0.0, "ввод вправо: x>0 при крене вправо: %s" % f)
	# установившийся вираж 30°: крен задан, ввод — «держащий» roll_input_for_bank (установившийся крен модели)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	m.bank = deg_to_rad(30.0)
	var ws := FS.input(0.0, 0.0)
	ws.weight_shift = true
	var mx := 0.0
	for i in int(3.0 / FS.DT):
		var u := m.roll_input_for_bank(m.bank, m.telemetry.airspeed if m.telemetry.airspeed > 1.0 else m.trim_speed())
		ws.roll = u
		m.step(FS.DT, ws, Callable(), Callable())
		mx = maxf(mx, absf(m.telemetry.bar_force.x))
	print("PH1 flight steady turn bank=%.1f max|x|=%.1f N" % [m.telemetry.bank_deg, mx])
	check(absf(m.telemetry.bank_deg - 30.0) < 8.0, "вираж ~30°: %.1f" % m.telemetry.bank_deg)
	check(mx < 60.0, "установившийся вираж: |x| < 60 Н: %.1f" % mx)


func test_flight_model_ground_zero() -> void:
	var m := FS.make(WING)
	m.reset_on_ground(Vector3.ZERO, 0.0)
	FS.run_for(m, 0.5, FS.input())
	check(m.telemetry.bar_force == Vector2.ZERO, "на земле ноль: %s" % m.telemetry.bar_force)


func test_pendulum_numbers() -> void:
	var vt := _v_trim()
	var trim := _pendulum(0.0)
	check(Vector2(trim.y, trim.z).length() < 15.0, "Маятник трим: |F| < 15 Н: %s" % trim)
	var prev := -1.0
	for p in [-0.3, -0.6, -1.0]:
		var r := _pendulum(p)
		var f := Vector2(r.y, r.z)
		print("PH1 pendulum pitch=%.1f v=%.2f (%.2f Vt) F=%s" % [p, r.x, r.x / vt, f])
		check(f.is_finite() and f.length() <= 300.0 + 1e-3, "|F| ≤ 300: %s" % f)
		check(f.y > 0.0, "pitch на себя → y>0: %s" % f)
		check(f.y > prev, "|y| растёт со скоростью: %.1f > %.1f" % [f.y, prev])
		prev = f.y


## Одна скорость — порядок величины в моделях в пределах ×3: маятник на ~1,15 и ~1,3·Vt (подбор трапеции),
## оценка FlightModel — на той же скорости.
func test_models_same_order() -> void:
	var vt := _v_trim()
	for target in [1.15, 1.3]:
		var best := Vector3.ZERO
		var best_d := 1.0e9
		for p in [-0.1, -0.2, -0.3, -0.35, -0.4, -0.45, -0.5]:
			var r := _pendulum(p)
			if absf(r.x / vt - target) < best_d:
				best_d = absf(r.x / vt - target)
				best = r
		var fm := FS.make(WING)
		fm.reset_in_air(Vector3(0, 3000, 0), 0.0)
		var est := fm.bar_force_estimate(best.x)
		print("PH1 same speed v=%.2f (%.2f Vt): pendulum %.1f N, flight %.1f N" % [best.x, best.x / vt, best.z, est.y])
		check(best.z > 0.0 and est.y > 0.0, "обе > 0 на %.2f·Vt" % (best.x / vt))
		var ratio := maxf(best.z, est.y) / maxf(minf(best.z, est.y), 1.0e-3)
		check(ratio <= 3.0, "порядок ×3: %.1f против %.1f Н" % [best.z, est.y])
