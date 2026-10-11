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
