extends TestCase
## Контрактные тесты feedback-1012 (docs/contracts/feedback-1012.md): FB-К1 — смещение пилота в телеметрии.
## FB-К2 — флаг начала перехода в лётное положение. Проверки формы и инвариантов дописывают владельцы (FB-К1 — FB-1, FB-К2 — FB-3). Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/feedback-1012.md"
const VERSIONS := {"FB-К1": 1, "FB-К2": 1}


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


# ---------------------------------------------------------------- FB-К2 (владелец FB-3)
static func _fb_k2_models() -> Array:
	var wing: Dictionary = Config.get_config("wings/training")
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = float(wing.pilot_mass_ref_kg)
	var fm := FlightModel.new()
	fm.setup(wing, pilot)
	var pd := PendulumModel.new()
	pd.setup(wing, pilot)
	return [fm, pd]


## Форма: поле, метод, сигнал — одинаково в обеих моделях.
func test_fb_k2_shape() -> void:
	for m: Object in _fb_k2_models():
		var n: String = m.get_script().get_global_name()
		check("flight_position_started" in m, "%s: поле flight_position_started" % n)
		check(m.has_method("start_flight_position"), "%s: start_flight_position()" % n)
		check(m.has_signal("flight_position_started_changed"), "%s: сигнал" % n)
		check(typeof(m.get("flight_position_started")) == TYPE_BOOL, "%s: bool" % n)


## Инварианты: false после reset_on_ground; start → true, сигнал один раз (идемпотентно); шаги на
## земле без ввода флаг не ставят; reset_on_ground снова сбрасывает; старт в воздухе — уже true.
func test_fb_k2_invariants() -> void:
	for m: Object in _fb_k2_models():
		var n: String = m.get_script().get_global_name()
		var got := [0]
		m.flight_position_started_changed.connect(func() -> void: got[0] += 1)
		m.reset_on_ground(Vector3.ZERO, 0.0)
		check(not m.flight_position_started, "%s: false после reset_on_ground" % n)
		var gf := func(_x: float, _z: float) -> float: return 0.0
		for i in 120:
			m.step(1.0 / 120.0, ControlInput.new(), Callable(), gf)
		check(not m.flight_position_started, "%s: стоя флаг не ставится" % n)
		m.start_flight_position()
		m.start_flight_position()
		check(m.flight_position_started, "%s: true после start_flight_position" % n)
		check(got[0] == 1, "%s: сигнал один раз (%d)" % [n, got[0]])
		m.reset_on_ground(Vector3.ZERO, 0.0)
		check(not m.flight_position_started, "%s: новый старт сбрасывает" % n)
		m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
		check(m.flight_position_started, "%s: старт в воздухе — уже в лётном положении" % n)



# ---------------------------------------------------------------- FB-К1: форма и инварианты

const FS := preload("res://tests/flight/flight_sim.gd")
const PS := preload("res://tests/flight/pendulum/pendulum_sim.gd")


func _ok_shift(v: Vector2, what: String) -> void:
	check(v.is_finite(), "%s: pilot_shift конечный: %s" % [what, v])


func test_field_default_zero() -> void:
	var t := Telemetry.new()
	check(t.pilot_shift == Vector2.ZERO, "Telemetry.pilot_shift по умолчанию ноль")
	check(FS.make("sport").telemetry.pilot_shift == Vector2.ZERO, "FlightModel: до шага — ноль")
	check(PS.make("sport").telemetry.pilot_shift == Vector2.ZERO, "PendulumModel: до шага — ноль")


func test_flight_model_neutral_and_full_input() -> void:
	var m := FS.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	FS.run_for(m, 10.0, FS.input())
	_ok_shift(m.telemetry.pilot_shift, "FlightModel нейтраль")
	check(m.telemetry.pilot_shift.length() < 0.1, "FlightModel: без ввода < 0.1: %s" % m.telemetry.pilot_shift)
	FS.run_for(m, 1.0, FS.input(0.0, 1.0))
	check(m.telemetry.pilot_shift.x > 0.5, "FlightModel: roll=+1 → x>0.5: %s" % m.telemetry.pilot_shift)
	FS.run_for(m, 1.0, FS.input(-1.0, 0.0))
	check(m.telemetry.pilot_shift.y > 0.5, "FlightModel: pitch=−1 → y>0.5: %s" % m.telemetry.pilot_shift)
	FS.run_for(m, 1.0, FS.input(1.0, -1.0))
	check(m.telemetry.pilot_shift.y < -0.5 and m.telemetry.pilot_shift.x < -0.5, "FlightModel: pitch=+1, roll=−1 → y<0, x<0")


func test_flight_model_ground() -> void:
	var m := FS.make("sport")
	m.reset_on_ground(Vector3(0, 0, 0), 0.0)
	FS.run_for(m, 0.5, FS.input())
	_ok_shift(m.telemetry.pilot_shift, "FlightModel земля")
	check(m.telemetry.pilot_shift.length() < 0.1, "FlightModel на земле без ввода < 0.1")


func test_pendulum_neutral_and_full_input() -> void:
	for w: String in ["training", "sport"]:
		var m := PS.make(w)
		PS.reset(m)
		for i in int(10.0 / PS.DT):
			m.step(PS.DT, PS.input(), Callable(), Callable())
		_ok_shift(m.telemetry.pilot_shift, "Маятник %s нейтраль" % w)
		check(m.telemetry.pilot_shift.length() < 0.1, "Маятник %s: без ввода < 0.1: %s" % [w, m.telemetry.pilot_shift])
		for i in int(3.0 / PS.DT):
			m.step(PS.DT, PS.input(0.0, 1.0), Callable(), Callable())
		check(m.telemetry.pilot_shift.x > 0.5, "Маятник %s: roll=+1 → x>0.5: %s" % [w, m.telemetry.pilot_shift])
		_ok_shift(m.telemetry.pilot_shift, "Маятник %s крен" % w)
		m = PS.make(w)
		PS.reset(m)
		for i in int(10.0 / PS.DT):
			m.step(PS.DT, PS.input(-1.0, 0.0), Callable(), Callable())
		check(m.telemetry.pilot_shift.y > 0.5, "Маятник %s: pitch=−1 → y>0.5: %s" % [w, m.telemetry.pilot_shift])
		m = PS.make(w)
		PS.reset(m)
		for i in int(10.0 / PS.DT):
			m.step(PS.DT, PS.input(1.0, 0.0), Callable(), Callable())
		check(m.telemetry.pilot_shift.y < -0.3, "Маятник %s: pitch=+1 → y<0: %s" % [w, m.telemetry.pilot_shift])


func test_pendulum_ground_stand() -> void:
	var m := PS.make("sport")
	m.reset_on_ground(Vector3(0.0, 100.0, 0.0), 0.0)
	var gf := func(_x: float, _z: float) -> float: return 100.0
	for i in int(1.0 / PS.DT):
		m.step(PS.DT, PS.input(), Callable(), gf)
	_ok_shift(m.telemetry.pilot_shift, "Маятник земля")
	check(m.telemetry.pilot_shift.length() < 0.1, "Маятник на земле стоя < 0.1: %s" % m.telemetry.pilot_shift)


func test_indicator_geometry() -> void:
	var I := PilotShiftIndicator
	check(I.clamp_shift(Vector2(3.0, 4.0)).length() <= 1.0001, "за пределом — прижато к краю")
	check(I.clamp_shift(Vector2(NAN, 0.0)) == Vector2.ZERO, "NaN — центр")
	check(I.dot_offset(Vector2.ZERO, 40.0) == Vector2.ZERO, "нейтраль — центр")
	check(I.dot_offset(Vector2(0.0, 1.0), 40.0).y < 0.0, "вперёд — вверх по экрану")
	check(I.dot_offset(Vector2(0.0, -1.0), 40.0).y > 0.0, "назад — вниз")
	check(I.dot_offset(Vector2(1.0, 0.0), 40.0).x > 0.0, "вправо — вправо")
