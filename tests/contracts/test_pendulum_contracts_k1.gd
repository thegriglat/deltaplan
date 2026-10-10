extends TestCase
## Контрактный тест PD-К1 (docs/contracts/pendulum.md): поверхность PendulumModel — члены, типы,
## сигналы, методы и смысл производных величин. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pendulum.md"
const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")


func _props(o: Object) -> Dictionary:
	var out := {}
	for p: Dictionary in o.get_property_list():
		out[String(p.name)] = int(p.type)
	return out


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/pendulum.md читается")
	var re := RegEx.create_from_string("(?m)^## PD-К1\\. .* \\(v(\\d+)\\)\\s*$")
	var m := re.search(text)
	check(m != null and int(m.get_string(1)) == 3, "заголовок «## PD-К1. … (v3)»")


func test_surface_members() -> void:
	var m := PendulumModel.new()
	check(m is RefCounted, "PendulumModel extends RefCounted")
	var p := _props(m)
	var want := {
		"telemetry": TYPE_OBJECT, "mode": TYPE_INT, "load": TYPE_OBJECT,
		"landing_result": TYPE_DICTIONARY, "takeoff_failure": TYPE_STRING,
		"wing": TYPE_DICTIONARY, "pilot": TYPE_DICTIONARY, "flight": TYPE_DICTIONARY,
		"pendulum": TYPE_DICTIONARY, "apparatus": TYPE_DICTIONARY,
		"pilot_mass": TYPE_FLOAT, "mass": TYPE_FLOAT, "area": TYPE_FLOAT, "span": TYPE_FLOAT,
		"position": TYPE_VECTOR3, "velocity": TYPE_VECTOR3, "heading": TYPE_FLOAT,
		"bank": TYPE_FLOAT, "theta": TYPE_FLOAT, "roll_rate": TYPE_FLOAT, "alpha": TYPE_FLOAT,
		"stalled": TYPE_BOOL, "time_s": TYPE_FLOAT, "hang_position": TYPE_VECTOR3,
		"pilot_position": TYPE_VECTOR3, "pilot_velocity": TYPE_VECTOR3,
		"pilot_basis": TYPE_BASIS, "pilot_rel": TYPE_VECTOR3, "head_position": TYPE_VECTOR3,
		"bar_force": TYPE_VECTOR3, "strap_tension": TYPE_FLOAT,
	}
	for k: String in want:
		check(p.has(k), "PendulumModel.%s" % k)
		check(p.get(k, -1) == want[k], "PendulumModel.%s: тип %s" % [k, type_string(want[k])])
	check(m.telemetry is Telemetry and m.load is LoadMeter, "telemetry: Telemetry, load: LoadMeter")
	check(m.mode is int and m.mode in FlightModel.Mode.values(), "mode — FlightModel.Mode")
	for sg: String in ["took_off", "landed", "takeoff_failed"]:
		check(m.has_signal(sg), "сигнал %s" % sg)
	var args := {}
	for sd: Dictionary in m.get_signal_list():
		args[String(sd.name)] = sd.args.size()
	check(args.get("landed", -1) == 1 and args.get("takeoff_failed", -1) == 1, "аргументы сигналов")
	var methods := {}
	for md: Dictionary in m.get_method_list():
		methods[String(md.name)] = md.args.size()
	var want_m := {
		"setup": 4, "reset_in_air": 4, "reset_on_ground": 2, "step": 4, "phase": 0,
		"flare_amount": 0, "stall_amount": 0, "set_kinematic": 5,
	}
	for k: String in want_m:
		check(methods.get(k, -1) == want_m[k], "метод %s (%d арг.)" % [k, want_m[k]])


func test_derived_quantities() -> void:
	var m := S.make("sport")
	m.reset_in_air(Vector3(10.0, 800.0, -20.0), 40.0)
	var inp := S.input(0.2, 0.5)
	for i in 240:
		m.step(1.0 / 120.0, inp, Callable(), Callable())
	var t := m.telemetry
	var b := Basis.from_euler(Vector3(m.theta, -m.heading, -m.bank))
	check(t.basis.is_equal_approx(b), "telemetry.basis = from_euler(theta, −heading, −bank)")
	var hh := float(m.flight.visual.hang_height_m)
	check((m.hang_position - t.basis * Vector3(0, hh, 0)).distance_to(m.position) < 1.0e-3,
		"position = hang_position − basis·(0, hang_height, 0)")
	check((t.basis.inverse() * (m.pilot_position - m.hang_position)).distance_to(m.pilot_rel) < 1.0e-3,
		"pilot_rel = basis⁻¹·(pilot_position − hang_position)")
	var up := (m.hang_position - m.pilot_position).normalized()
	check(m.pilot_basis.y.distance_to(up) < 1.0e-3, "pilot_basis.y — от пилота к подвеске")
	var head := m.pilot_position + m.pilot_basis * Vector3(0.0, 0.15, -0.75)
	check(m.head_position.distance_to(head) < 1.0e-3, "head_position: +0,75 вперёд, +0,15 вверх")
	check(t.pilot_position == m.pilot_position and t.pilot_velocity == m.pilot_velocity
		and t.pilot_basis == m.pilot_basis, "телеметрия pilot_* — из маятника (MR-К1)")
	check(m.strap_tension > 0.0, "стропа натянута")
	check(m.phase() == "flying" and t.phase == "flying", "фаза flying")
	approx(m.mass, m.pilot_mass + float(m.wing.wing_mass_kg), 1.0e-6, "mass = пилот + крыло")
	check(m.load.load_factor > 0.5 and m.load.load_factor < 2.0, "перегрузка по стропе ~1")
	check(m.flare_amount() == 0.0, "flare_amount на высоте — 0")
	check(m.stall_amount() >= 0.0 and m.stall_amount() <= 1.0, "stall_amount 0…1")
	# скорость точки position — производная position
	var p0 := m.position
	m.step(1.0 / 120.0, inp, Callable(), Callable())
	var v_fd := (m.position - p0) * 120.0
	check(v_fd.distance_to(m.velocity) < 0.3, "velocity — скорость точки position")


## v2: земля — reset_on_ground ставит пилота на ноги с крылом (GROUND), фазы земли, отрыв из сил.
func test_ground_v2() -> void:
	var m := S.make("training")
	var g := func(_x: float, z: float) -> float: return tan(deg_to_rad(15.0)) * z
	m.reset_on_ground(Vector3.ZERO, 0.0)
	check(m.mode == FlightModel.Mode.GROUND, "reset_on_ground → GROUND")
	check(m.phase() == "standing" and m.telemetry.phase == "standing", "фаза standing")
	check(m.telemetry.on_ground, "telemetry.on_ground")
	var feet := m.pilot_position.y - 1.0
	check(absf(feet) < 0.05, "ступни пилота в pos (%.3f м)" % feet)
	check(m.pilot_position.y < m.hang_position.y, "крыло над пилотом")
	var inp := S.input()
	inp.walk = 1.0
	m.step(1.0 / 120.0, inp, Callable(), g)
	check(m.phase() == "walking", "фаза walking")
	inp.walk = 0.0
	inp.run = true
	var got := []
	m.took_off.connect(func() -> void: got.append(true))
	for i in 120 * 12:
		m.step(1.0 / 120.0, inp, Callable(), g)
		if i == 10:
			check(m.phase() == "running", "фаза running")
		if m.mode == FlightModel.Mode.AIR:
			break
	check(m.mode == FlightModel.Mode.AIR and got.size() == 1, "отрыв: AIR и took_off")
	check(m.phase() == "flying", "фаза flying")


func test_set_kinematic() -> void:
	var m := S.make("laminar")
	m.set_kinematic(Vector3(0.0, 500.0, 0.0), Vector3(0.0, 0.0, -12.0), 0.0, 0.1, 0.05)
	check(m.mode == FlightModel.Mode.AIR, "mode = AIR")
	approx(m.bank, 0.1, 1.0e-4, "крен задан")
	approx(m.theta, 0.05, 1.0e-4, "тангаж задан")
	check(m.position.distance_to(Vector3(0.0, 500.0, 0.0)) < 1.0e-3, "position задан")
	check(m.pilot_position.y < m.hang_position.y - 1.0, "пилот под подвеской")


## v3: пропуски apparatus в setup — сначала умолчания крыла (wing.pendulum.apparatus_defaults),
## потом общие (configs/pendulum.json → apparatus_defaults); заданное пилотом — главнее.
func test_apparatus_defaults_v3() -> void:
	var wing: Dictionary = Config.get_config("wings/training")
	var wd: Dictionary = wing.pendulum.apparatus_defaults
	var gd: Dictionary = Config.get_config("pendulum").apparatus_defaults
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	var m := PendulumModel.new()
	m.setup(wing, pilot, {}, {"sail_flex": 0.5})
	check(float(m.apparatus.dihedral_eff_deg) == float(wd.dihedral_eff_deg), "V — из крыла")
	check(float(m.apparatus.sail_flex) == 0.5, "заданное пилотом — главнее")
	check(float(m.apparatus.hang_length_m) == float(gd.hang_length_m), "чего нет у крыла — общее")
	check(float(m.apparatus.hang_shift_cm) == float(gd.hang_shift_cm), "сдвиг подвески — общее")
