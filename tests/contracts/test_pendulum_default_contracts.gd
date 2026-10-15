extends TestCase
## Контрактные тесты pendulum-default (docs/contracts/pendulum-default.md, PMD-К1 v1):
## режим управления по умолчанию — «Маятник». Правка контракта (версия +1) — вместе с этим файлом.


func _glider(cfg_override: Variant, remove := false) -> Glider:
	var cfg := Config.get_config("controls")
	var had := cfg.has("roll_control_mode")
	var old: Variant = cfg.get("roll_control_mode")
	if remove:
		cfg.erase("roll_control_mode")
	elif cfg_override != null:
		cfg["roll_control_mode"] = cfg_override
	var g := Glider.new()
	g.setup("sport", 0.0, {})
	if had:
		cfg["roll_control_mode"] = old
	else:
		cfg.erase("roll_control_mode")
	return g


func test_config_default() -> void:
	var res: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://configs/controls.json"))
	check(String(res.get("roll_control_mode", "")) == "pendulum", "controls.json: pendulum")


func test_glider_default_pendulum() -> void:
	var g := _glider(null)
	check(g.model is PendulumModel, "controls.json без правок → PendulumModel")
	g.free()


func test_fallbacks_pendulum() -> void:
	var g := _glider(null, true)
	check(g.model is PendulumModel, "нет ключа → PendulumModel")
	g.free()
	g = _glider("нечто_неизвестное")
	check(g.model is PendulumModel, "неизвестное значение → PendulumModel")
	g.free()
	for mode in ["weight_shift", "rate"]:
		g = _glider(mode)
		check(g.model is FlightModel, "%s → FlightModel" % mode)
		g.free()


func test_roll_modes_order() -> void:
	var modes: Array = SettingsPanel.ROLL_MODES
	check(modes[0] == "pendulum", "ROLL_MODES[0] == pendulum")
	check("weight_shift" in modes and "rate" in modes, "weight_shift и rate выбираемы")
	check(modes.size() == 3, "три режима")


func test_labels() -> void:
	var f := FileAccess.open("res://locale/ui.csv", FileAccess.READ)
	var found := false
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() >= 3 and row[0] == "settings_roll_pendulum":
			found = true
			for s in [row[1].to_lower(), row[2].to_lower()]:
				check(not ("эксперимент" in s or "experiment" in s), "подпись без «экспериментальный»: %s" % s)
		if row.size() >= 3 and row[0] == "setup_app_pendulum_only":
			check(row[1] == "Настройки режима «Маятник»; в других режимах не действуют", "ru: " + row[1])
			check(row[2] == "Pendulum mode settings; other modes ignore them", "en: " + row[2])
	check(found, "settings_roll_pendulum есть")
