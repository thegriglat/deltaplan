extends TestCase
## ASM-К3: «В воздухе» в окне «Старт».


func _under_runner(n: Node) -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	root.get_child(root.get_child_count() - 1).add_child(n)


func _menu() -> StartMenu:
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	_under_runner(m)
	return m


func test_open_defaults() -> void:
	var d := StartChoiceDialog.new()
	_under_runner(d)
	var s := FlightSettings.defaults()
	d.open(s, {})
	check(not d.air_check.button_pressed, "без воздуха — отметки нет")
	check(not d.tow_opt.disabled, "буксировка доступна")
	check(not d.air_height.get_parent().get_parent().visible, "ползунок скрыт")
	check(is_equal_approx(d.air_height.value, 300.0), "умолчание 300")
	s.set_air_start(450.0)
	d.open(s, {})
	check(d.air_check.button_pressed and d.tow_opt.disabled, "воздух: отмечено, буксировка disabled")
	check(is_equal_approx(d.air_height.value, 450.0), "высота из настроек")
	check(d.air_height.get_parent().get_parent().visible, "ползунок виден")
	d.hide()
	d.queue_free()


func test_chosen_air_and_save() -> void:
	var m := _menu()
	var got: Array = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: got.append(s))
	m.call("_on_fly")
	var d := m.choice_dialog
	d.air_check.button_pressed = true
	d.air_height.value = 200.0
	d.glider_btn.pressed.emit()
	check(got.size() == 1, "fly_requested")
	var s: FlightSettings = got[0]
	check(s.vehicle == "glider" and s.tow_kind == "" and is_equal_approx(s.air_start_agl_m, 200.0), "воздух 200 м")
	check(is_equal_approx(FlightSettings.from_dict(s.to_dict()).air_start_agl_m, 200.0), "сохраняется в to_dict")
	m.call("_on_fly")
	check(m.choice_dialog.air_check.button_pressed, "окно помнит прошлый выбор")
	m.choice_dialog.trike_btn.pressed.emit()
	check(got[1].vehicle == "trike" and not got[1].has_air_start() and m.choice_dialog.air_start_agl_m < 0.0, "дельталёт — без воздуха")
	m.queue_free()


func test_air_off_keeps_tow() -> void:
	var d := StartChoiceDialog.new()
	_under_runner(d)
	var s := FlightSettings.defaults()
	s.tow_kind = "aerotow"
	d.open(s, {})
	var got: Array = []
	d.chosen.connect(func(v: String, t: String) -> void: got.append([v, t]))
	d.air_check.button_pressed = true
	d.air_check.button_pressed = false
	d.glider_btn.pressed.emit()
	check(got == [["glider", "aerotow"]] and d.air_start_agl_m < 0.0, "снятая отметка возвращает буксировку: %s" % [got])
	d.hide()
	d.queue_free()
