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


## 1. Главное меню: 6 кнопок по центру, в порядке FR-27 (плоские кнопки «◀ язык ▶» — отдельно).
func test_start_menu_has_six_buttons_in_order() -> void:
	var m: StartMenu = _scene("res://scenes/ui/start_menu.tscn")
	var expected := [
		tr("menu_fly"),
		tr("menu_flight_setup"),
		tr("menu_controls"),
		tr("menu_settings"),
		tr("menu_about"),
		tr("menu_quit"),
	]
	var buttons := m.find_children("*", "Button", true, false)
	var texts: Array = []
	for b in buttons:
		if not (b as Button).flat:
			texts.append((b as Button).text)
	check(texts.size() == 6, "ровно 6 кнопок, получили %d: %s" % [texts.size(), texts])
	check(texts == expected, "порядок кнопок FR-27: %s" % [texts])
	m.queue_free()


## 2. «Полёт…» → «Готово»: done с выбранными крылом/массой/местом.
func test_flight_setup_done_carries_choice() -> void:
	var m: FlightSetupScreen = _scene("res://scenes/ui/flight_setup_screen.tscn")
	var got: Array = []
	m.done.connect(func(s: FlightSettings) -> void: got.append(s))
	var s := FlightSettings.defaults()
	s.wing = "wings/training"
	s.location_id = "altai"
	s.site_id = "tugaya_south"
	m.set_settings(s)
	m.get("_mass").value = m.get("_mass").min_value
	m.call("_on_done")
	check(got.size() == 1, "«Готово» шлёт настройки")
	if got.size() == 1:
		var r: FlightSettings = got[0]
		check(r.wing == "wings/training", "крыло выбрано")
		check(r.pilot_mass_kg > 0.0, "масса выбрана (%.1f)" % r.pilot_mass_kg)
		check(r.location_id == "altai" and r.site_id == "tugaya_south", "место старта выбрано")
	m.queue_free()


## 3. Выбор на карте: FlightSettings с pick_lat/lon доходит до done (site или latlon).
func test_flight_setup_carries_map_pick() -> void:
	var m: FlightSetupScreen = _scene("res://scenes/ui/flight_setup_screen.tscn")
	var got: Array = []
	m.done.connect(func(s: FlightSettings) -> void: got.append(s))
	var s := FlightSettings.defaults()
	s.pick_lat = 51.83
	s.pick_lon = 85.81
	m.set_settings(s)
	check(m.get("_pick_label").text != "", "подпись «точка на карте: …» показана")
	m.call("_on_done")
	check(got.size() == 1, "«Готово» шлёт настройки после выбора на карте")
	if got.size() == 1:
		var r: FlightSettings = got[0]
		check(r.has_pick(), "точка карты (latlon) сохранена в настройках")
		check(
			is_equal_approx(r.pick_lat, 51.83) and is_equal_approx(r.pick_lon, 85.81),
			"координаты не потерялись"
		)
	m.queue_free()


## 3б. Главное меню: под «Лететь» — строка с текущим выбором (место, старт, погода, время).
func test_start_menu_shows_choice_summary() -> void:
	var m: StartMenu = _scene("res://scenes/ui/start_menu.tscn")
	var s := FlightSettings.defaults()
	s.location_id = "ongudai"
	s.site_id = ""
	s.weather = "weather/medium"
	s.start_hour = 13.0
	m.set_settings(s)
	var text: String = m.get("_summary").text
	var loc_name := tr(String(Config.value("locations/ongudai", "name")))
	check(text.contains(loc_name), "в строке выбора — локация: %s" % text)
	check(text.contains(tr("weather_medium")) and text.contains("13:00"), "погода и время: %s" % text)
	s.pick_lat = 50.6
	s.pick_lon = 86.4
	m.set_settings(s)
	text = m.get("_summary").text
	check(text.contains("50.6000, 86.4000"), "точка на карте — координатами: %s" % text)
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


## 7. Экран загрузки: этап и полоса по LoadProgress, точки бегут, закрывается.
func test_loading_screen_follows_progress() -> void:
	var l: LoadingScreen = _scene("res://scenes/ui/loading_screen.tscn")
	check(not l.visible, "экран загрузки скрыт до open")
	var p := LoadProgress.new({"a": 1.0, "b": 3.0})
	p.begin()
	l.open(p, "50.6000, 86.4000")
	check(l.visible, "open показывает экран")
	p.stage("b", tr("loading_dem"))
	p.sub(1, 2)
	check(is_equal_approx(p.fraction, 0.25 + 0.75 * 0.5), "доля внутри этапа (%.3f)" % p.fraction)
	for i in 30:
		await get_tree().process_frame
	var stage: Label = l.get("_stage")
	check(stage.text.begins_with(tr("loading_dem").trim_suffix("…")), "этап: %s" % stage.text)
	check((l.get("_bar") as ProgressBar).value > 0.0, "полоса двинулась")
	l.close()
	check(not l.visible, "close прячет экран")
	l.queue_free()
