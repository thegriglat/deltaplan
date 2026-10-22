extends TestCase
## Контракты roll-modes (docs/contracts/roll-modes.md, RM-К1 v1): игрок — только «Маятник»,
## FlightModel (rate) — боты. Правка контракта (версия +1) — вместе с этим файлом.

const DT := 1.0 / 120.0
const PROTO := "res://server/proto/deltaplan/v1/net.proto"


func _glider_with_mode(value: Variant) -> Glider:
	var cfg := Config.get_config("controls")
	var had := cfg.has("roll_control_mode")
	var old: Variant = cfg.get("roll_control_mode")
	cfg["roll_control_mode"] = value
	var g := Glider.new()
	g.setup("sport", 0.0, {})
	if had:
		cfg["roll_control_mode"] = old
	else:
		cfg.erase("roll_control_mode")
	return g


func test_glider_always_pendulum() -> void:
	for v in ["rate", "weight_shift", "pendulum", "нечто"]:
		var g := _glider_with_mode(v)
		check(g.model is PendulumModel, "roll_control_mode = %s → PendulumModel" % v)
		check(g.is_pendulum(), "is_pendulum() = true (%s)" % v)
		check(not g.has_method("is_pendulum_mode"), "Glider.is_pendulum_mode удалён")
		g.free()


func test_control_input_shape() -> void:
	var c := ControlInput.new()
	check(not ("weight_shift" in c), "ControlInput без weight_shift")
	for p in ["pitch", "roll", "run", "walk", "turn", "pull_full"]:
		check(p in c, "ControlInput.%s на месте" % p)


func test_flight_model_rate_only() -> void:
	var m := FlightModel.new()
	for f in ["_roll_weight_shift", "roll_stability", "roll_input_for_bank", "roll_authority"]:
		check(not m.has_method(f), "FlightModel без %s" % f)
	check(m.has_method("bar_force_estimate"), "bar_force_estimate остаётся")


func test_configs_clean() -> void:
	var dir := DirAccess.open("res://configs/wings")
	var n := 0
	for f in dir.get_files():
		if f.ends_with(".json"):
			n += 1
			var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/wings/" + f))
			check(d is Dictionary and not (d as Dictionary).has("weight_shift"), "%s: без weight_shift" % f)
	check(n > 10, "крыльев проверено: %d" % n)
	var ctl: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/controls.json"))
	check(not ctl.has("roll_control_mode") and not ctl.has("roll_control_mode_doc"), "controls.json без roll_control_mode")


func test_settings_panel_no_roll_modes() -> void:
	var consts: Dictionary = load("res://scripts/ui/settings_panel.gd").get_script_constant_map()
	check(not consts.has("ROLL_MODES"), "SettingsPanel без ROLL_MODES")
	var sp: SettingsPanel = load("res://scenes/ui/settings_panel.tscn").instantiate()
	sp._ready()
	check(sp.get("_roll_mode") == null, "нет строки «Управление креном»")
	check(sp.get("_roll_input") != null, "«Крен мышью» остаётся")
	sp.queue_free()
	var f := FileAccess.open("res://locale/ui.csv", FileAccess.READ)
	var bad := ["settings_roll_control", "settings_roll_pendulum", "settings_roll_weight_shift", "settings_roll_simple", "setup_app_pendulum_only"]
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() > 0:
			check(not (row[0] in bad), "ui.csv: ключ %s удалён" % row[0])


func test_net() -> void:
	check(NetFlight.control_mode_name() == "PENDULUM", "локальный игрок шлёт PENDULUM")
	var names: Array = NetMessages.ENUMS["ControlMode"]
	check(not names.has("CONTROL_MODE_WEIGHT_SHIFT"), "WEIGHT_SHIFT нет в ENUMS")
	check(names.size() == 4 and names[2] == "", "номер 2 — пустое место: %s" % [names])
	var spec := "enum:ControlMode"
	check(NetMessages.decode_value(spec, 1) == "CONTROL_MODE_RATE", "1 → RATE")
	check(NetMessages.decode_value(spec, 2) == "", "2 → пусто (как не передано)")
	check(NetMessages.decode_value(spec, 3) == "CONTROL_MODE_PENDULUM", "3 → PENDULUM")
	check(NetMessages.encode_value(spec, 3) == "CONTROL_MODE_PENDULUM", "encode 3 → PENDULUM")
	check(NetMessages.encode_value(spec, 2) == null, "encode 2 → не передавать")
	var text := FileAccess.get_file_as_string(PROTO)
	check(text.contains("CONTROL_MODE_RATE = 1;") and text.contains("CONTROL_MODE_PENDULUM = 3;"), "номера 1 и 3 на месте")
	check(not text.contains("CONTROL_MODE_WEIGHT_SHIFT = "), "WEIGHT_SHIFT не объявлен")
	check(text.contains("reserved 2;") and text.contains('reserved "CONTROL_MODE_WEIGHT_SHIFT";'), "номер и имя reserved")


func test_input_sign_air_and_ground() -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	for pair in [["bar", -1.0], ["body", 1.0]]:
		for ground: bool in [false, true]:
			var ic := InputController.new()
			root.get_child(root.get_child_count() - 1).add_child(ic)
			check(not ("roll_mode" in ic), "InputController без roll_mode")
			check(not ic.has_method("weight_shift"), "InputController без weight_shift()")
			ic._cfg = ic._cfg.duplicate(true)
			ic._cfg.invert_pitch = false
			ic.roll_input = pair[0]
			ic.mouse_captured = true
			ic.reset()
			ic.on_ground = ground
			var ev := InputEventMouseMotion.new()
			ev.relative = Vector2(4000.0, 0.0)
			ic._unhandled_input(ev)
			var r := 0.0
			for i in 60:
				r = ic.update(DT).roll
			check(r * float(pair[1]) > 0.2, "%s, %s: мышь вправо → roll %.2f" % [pair[0], "земля" if ground else "полёт", r])
			ic.get_parent().remove_child(ic)
			ic.free()
