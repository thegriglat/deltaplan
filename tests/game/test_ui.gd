extends Node
## Экраны интерфейса собираются, кнопки шлют сигналы, настройки пишутся в user-конфиг.

const TMP_DIR := "user://test_ui_tmp"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _scene(path: String) -> Control:
	var c: Control = (load(path) as PackedScene).instantiate()
	add_child(c)
	return c


func test_start_menu_emits_signals() -> void:
	var m: StartMenu = _scene("res://scenes/ui/start_menu.tscn")
	var got: Array = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: got.append(s))
	var setup_hits: Array = []
	m.setup_requested.connect(func() -> void: setup_hits.append(true))
	var s := FlightSettings.defaults()
	s.wing = "wings/training"
	m.set_settings(s)
	m.call("_on_fly")
	check(got.size() == 1, "«Лететь» шлёт текущий выбор")
	if got.size() == 1:
		var r: FlightSettings = got[0]
		check(r.wing == "wings/training", "текущий выбор передаётся как есть")
	m.setup_requested.emit()
	check(setup_hits.size() == 1, "«Полёт…» шлёт setup_requested")
	m.set_busy(true)
	check(m.get("_fly_btn").disabled, "во время загрузки «Лететь» недоступна")
	check(m.get("_setup_btn").disabled, "во время загрузки «Полёт…» недоступен")
	m.set_busy(false)
	check(not m.get("_fly_btn").disabled and not m.get("_setup_btn").disabled, "после — доступны")
	m.queue_free()


func test_flight_setup_emits_choice() -> void:
	var m: FlightSetupScreen = _scene("res://scenes/ui/flight_setup_screen.tscn")
	var got: Array = []
	m.done.connect(func(s: FlightSettings) -> void: got.append(s))
	var closed_hits: Array = []
	m.closed.connect(func() -> void: closed_hits.append(true))
	var s := FlightSettings.defaults()
	s.wing = "wings/training"
	s.pilot_mass_kg = 500.0
	s.location_id = "altai"
	s.site_id = "tugaya_south"
	m.set_settings(s)
	m.call("_on_done")
	check(got.size() == 1, "«Готово» шлёт выбор")
	if got.size() == 1:
		var r: FlightSettings = got[0]
		check(r.wing == "wings/training", "крыло")
		var hi := float(Config.value("wings/training", "pilot_mass_max_kg"))
		check(r.pilot_mass_kg == hi, "масса ограничена диапазоном крыла (%.0f)" % r.pilot_mass_kg)
		check(r.site_id == "tugaya_south" and r.location_id == "altai", "локация и площадка")
	m.closed.emit()
	check(closed_hits.size() == 1, "«Назад» шлёт closed")
	var texts: Array = []
	for b in m.find_children("*", "Button", true, false):
		texts.append((b as Button).text)
	check(not texts.has(tr("menu_fly")), "в «Полёт…» нет запуска полёта: %s" % [texts])
	m.queue_free()


func test_pause_and_result_buttons() -> void:
	var p: PauseMenu = _scene("res://scenes/ui/pause_menu.tscn")
	var hits: Array = []
	p.resume_requested.connect(func() -> void: hits.append("resume"))
	p.menu_requested.connect(func() -> void: hits.append("menu"))
	for b in p.find_children("*", "Button", true, false):
		(b as Button).pressed.emit()
	check(hits.has("resume") and hits.has("menu"), "кнопки паузы: %s" % [hits])
	p.queue_free()
	var r: ResultScreen = _scene("res://scenes/ui/result_screen.tscn")
	r.show_result("landed", {"grade": "crash"})
	check(r.visible and not r.get("_continue").visible, "после аварии — только заново / меню")
	r.queue_free()


func test_controls_screen_lists_keys() -> void:
	var c: ControlsScreen = _scene("res://scenes/ui/controls_screen.tscn")
	var rows := ControlsScreen.rows()
	var text := ""
	for r in rows:
		text += String(r.get("keys", "")) + " " + String(r.get("text", r.get("section", ""))) + "\n"
	check(text.contains("Shift") and text.contains("разбег"), "разбег на Shift")
	check(text.contains("W / ↑"), "клавиши из controls.json")
	check(ControlsScreen.key_names(["Escape"]) == "Esc", "имена клавиш по-человечески")
	c.queue_free()


func test_about_has_attribution() -> void:
	var a: AboutScreen = _scene("res://scenes/ui/about_screen.tscn")
	var text := a.get_text()
	check(text.contains("Copernicus"), "данные рельефа")
	check(text.contains("OFL"), "шрифты")
	check(text.contains("CC-BY"), "звуки CC-BY")
	a.queue_free()


func test_settings_saved_to_user_config() -> void:
	var sp: SettingsPanel = _scene("res://scenes/ui/settings_panel.tscn")
	sp.config_dir = TMP_DIR
	(sp.get("_invert") as CheckBox).button_pressed = true
	(sp.get("_volume") as HSlider).value = -12.0
	check(sp.save(), "записалось")
	var c := UserSettings.read_json(TMP_DIR.path_join("controls.json"))
	var au := UserSettings.read_json(TMP_DIR.path_join("audio.json"))
	check(c.get("invert_pitch") == true, "инверсия тангажа")
	check(float(au.get("vario_audio", {}).get("volume_db", 0.0)) == -12.0, "громкость вариометра")
	check(String(c.get("mouse", {}).get("mode", "")) in ["look", "bar"], "режим мыши")
	for f in ["controls.json", "audio.json", "game.json", "atmosphere.json", "world.json"]:
		DirAccess.remove_absolute(TMP_DIR.path_join(f))
	DirAccess.remove_absolute(TMP_DIR)
	sp.queue_free()
