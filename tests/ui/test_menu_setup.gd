extends Node
## Карточка ui/01: меню (FR-27), «Полёт…» (FR-17/FR-34), «Управление». Без сети (карта — только
## через FlightSettings.pick_lat/lon, без TerrariumLoader).

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _scene(path: String) -> Control:
	var c: Control = (load(path) as PackedScene).instantiate()
	add_child(c)
	return c


## 1. Главное меню: 6 кнопок по центру, в порядке FR-27.
func test_start_menu_has_six_buttons_in_order() -> void:
	var m: StartMenu = _scene("res://scenes/ui/start_menu.tscn")
	var expected := [
		tr("Лететь"), tr("Полёт…"), tr("Управление"), tr("Настройки"), tr("Об игре"), tr("Выход")
	]
	var buttons := m.find_children("*", "Button", true, false)
	var texts: Array = []
	for b in buttons:
		texts.append((b as Button).text)
	check(texts.size() == 6, "ровно 6 кнопок, получили %d: %s" % [texts.size(), texts])
	check(texts == expected, "порядок кнопок FR-27: %s" % [texts])
	m.queue_free()


## 2. «Полёт…»: fly_requested с выбранными крылом/массой/местом.
func test_flight_setup_fly_requested_carries_choice() -> void:
	var m: FlightSetupScreen = _scene("res://scenes/ui/flight_setup_screen.tscn")
	var got: Array = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: got.append(s))
	var s := FlightSettings.defaults()
	s.wing = "wings/training"
	s.location_id = "altai"
	s.site_id = "tugaya_south"
	m.set_settings(s)
	m.get("_mass").value = m.get("_mass").min_value
	m.call("_on_fly")
	check(got.size() == 1, "«Лететь» шлёт настройки")
	if got.size() == 1:
		var r: FlightSettings = got[0]
		check(r.wing == "wings/training", "крыло выбрано")
		check(r.pilot_mass_kg > 0.0, "масса выбрана (%.1f)" % r.pilot_mass_kg)
		check(r.location_id == "altai" and r.site_id == "tugaya_south", "место старта выбрано")
	m.queue_free()


## 3. Выбор на карте: FlightSettings с pick_lat/lon доходит до fly_requested (site или latlon).
func test_flight_setup_carries_map_pick() -> void:
	var m: FlightSetupScreen = _scene("res://scenes/ui/flight_setup_screen.tscn")
	var got: Array = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: got.append(s))
	var s := FlightSettings.defaults()
	s.pick_lat = 51.83
	s.pick_lon = 85.81
	m.set_settings(s)
	check(m.get("_pick_label").text != "", "подпись «точка на карте: …» показана")
	m.call("_on_fly")
	check(got.size() == 1, "«Лететь» шлёт настройки после выбора на карте")
	if got.size() == 1:
		var r: FlightSettings = got[0]
		check(r.has_pick(), "точка карты (latlon) сохранена в настройках")
		check(
			is_equal_approx(r.pick_lat, 51.83) and is_equal_approx(r.pick_lon, 85.81),
			"координаты не потерялись"
		)
	m.queue_free()


## 4. Все 4 встроенные локации — в списке стартов.
func test_flight_setup_lists_all_locations() -> void:
	var m: FlightSetupScreen = _scene("res://scenes/ui/flight_setup_screen.tscn")
	var locations := Config.list_configs("locations")
	check(locations.size() == 4, "4 встроенные локации в configs/locations/ (%d)" % locations.size())
	var sites: Array = m.get("_sites")
	var seen := {}
	for e: Dictionary in sites:
		seen[String(e.location)] = true
	for loc_name in locations:
		check(seen.has(loc_name.get_file()), "локация %s есть в списке стартов" % loc_name.get_file())
	m.queue_free()


## 5. «Управление»: каждое действие InputMap (configs/controls.json) видно на экране —
## своей клавишей (в колонке keys) или явным упоминанием клавиши в тексте строки.
func test_controls_screen_covers_all_input_actions() -> void:
	var c: ControlsScreen = _scene("res://scenes/ui/controls_screen.tscn")
	var rows := ControlsScreen.rows()
	var blob := ""
	for r in rows:
		blob += String(r.get("keys", "")) + " " + String(r.get("text", r.get("section", ""))) + "\n"
	var nice := {
		"Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Escape": "Esc", "Shift": "Shift",
	}
	var keys: Dictionary = Config.get_config("controls").get("keys", {})
	for action in keys:
		var a := String(action)
		if a.ends_with("_doc") or a.begins_with("_"):
			continue
		var list: Array = keys[action]
		var found := false
		for k: String in list:
			var token: String = nice.get(k, k)
			if blob.contains(token):
				found = true
				break
		check(found, "действие «%s» (%s) видно на экране «Управление»" % [a, list])
	c.queue_free()


## 6. Нет строк без tr(): все подписи меню/«Полёт…»/«Управление» проходят через перевод
## (UiKit.label/menu_button/row всегда получают уже переведённый текст от вызывающего кода).
func test_no_raw_strings_in_ui_sources() -> void:
	for path in [
		"res://scripts/ui/start_menu.gd",
		"res://scripts/ui/flight_setup_screen.gd",
		"res://scripts/ui/controls_screen.gd",
	]:
		var f := FileAccess.open(path, FileAccess.READ)
		check(f != null, "файл читается: %s" % path)
		if f == null:
			continue
		var text := f.get_as_text()
		var rx := RegEx.new()
		# Label/menu_button/button/row с текстовым литералом сразу — только если это tr(...).
		rx.compile('UiKit\\.(?:label|menu_button|button|row|heading)\\s*\\([^,]+,\\s*"[^"]')
		var m := rx.search(text)
		check(m == null, "строка без tr() в %s: %s" % [path, m.get_string() if m else ""])
