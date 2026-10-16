extends Node
## GL-3: вкладка «Цели» окна «Полёт…» (GL-К1/К2): выбор → FlightSettings.goals, to_dict/from_dict,
## пересчёт чисел, «своя» цифра не трогается, скорость без маршрутной цели, сетевая зона.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _screen(loc := "altai") -> FlightSetupScreen:
	var m: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	add_child(m)
	var s := FlightSettings.defaults()
	s.location_id = loc
	m.set_settings(s)
	return m


func _tab(m: FlightSetupScreen) -> GoalsTab:
	return m.get("_goals_tab")


func _row(t: GoalsTab, kind: String) -> Dictionary:
	return t.get("_rows")[kind]


func test_tab_exists_and_goals_valid() -> void:
	var m := _screen()
	var t := _tab(m)
	check(t != null, "вкладка «Цели» есть")
	if t == null:
		return
	(_row(t, "height").check as CheckBox).button_pressed = true
	(_row(t, "duration").check as CheckBox).button_pressed = true
	(_row(t, "triangle").check as CheckBox).button_pressed = true
	var s: FlightSettings = m.call("_collect")
	check(s.goals.size() == 3, "три цели: %d" % s.goals.size())
	check(GoalSpec.validate(s.goals).is_empty(), "validate: %s" % [GoalSpec.validate(s.goals)])
	for g: Dictionary in s.goals:
		check(float(g.value) > 0.0, "значение > 0: %s" % [g])
	m.queue_free()


func test_settings_roundtrip() -> void:
	var s := FlightSettings.defaults()
	s.goals = [GoalSpec.make("height", "hard", 1200.0), GoalSpec.make("route", "medium", 0.0, "altai_demo")]
	s.show_last_track = true
	s.track_paths = PackedStringArray(["/tmp/a.igc"])
	var r := FlightSettings.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	check(r.goals == s.goals or (r.goals.size() == 2 and r.goals[0].kind == "height"), "goals")
	check(is_equal_approx(float(r.goals[0].value), 1200.0), "value")
	check(r.show_last_track, "show_last_track")
	check(r.track_paths == s.track_paths, "track_paths")
	var d := s.duplicate()
	check(d.goals.size() == 2 and d.show_last_track, "duplicate")
	check(FlightSettings.defaults().goals.is_empty(), "по умолчанию пусто")


func test_custom_value_kept_on_weather_change() -> void:
	var m := _screen()
	var t := _tab(m)
	if t == null:
		check(false, "нет вкладки")
		return
	(_row(t, "distance").check as CheckBox).button_pressed = true
	(_row(t, "height").check as CheckBox).button_pressed = true
	t.refresh()
	var dist: SpinBox = _row(t, "distance").spin
	dist.value = 77.0  # руками
	check((_row(t, "distance").level as OptionButton).selected == 3, "уровень «своя»")
	var h0: float = (_row(t, "height").spin as SpinBox).value
	var d0 := dist.value
	var sky: OptionButton = m.get("_sky_opt")
	sky.select(2)
	sky.item_selected.emit(2)
	m.get("_temp").value = 8.0
	t.refresh()
	check(dist.value == d0, "своё число не перезаписано")
	var s: FlightSettings = m.call("_collect")
	var got := {}
	for g: Dictionary in s.goals:
		got[g.kind] = g
	check(got.has("distance") and got.distance.level == "custom", "custom в goals")
	check(is_equal_approx(float(got.distance.value), 77000.0), "77 км в СИ")
	check(h0 > 0.0, "высота посчитана")
	m.queue_free()


func test_level_numbers_follow_weather() -> void:
	var m := _screen()
	var t := _tab(m)
	if t == null:
		check(false, "нет вкладки")
		return
	var hours: SpinBox = _row(t, "duration").spin
	(_row(t, "duration").check as CheckBox).button_pressed = true
	m.get("_temp").value = 35.0
	m.get("_sky_opt").select(0)
	t.refresh()
	var a := hours.value
	m.get("_temp").value = 5.0
	m.get("_sky_opt").select(2)
	t.refresh()
	check(hours.value <= a, "в плохую погоду время не растёт: %f -> %f" % [a, hours.value])
	m.queue_free()


func test_speed_needs_route_goal() -> void:
	var m := _screen()
	var t := _tab(m)
	if t == null:
		check(false, "нет вкладки")
		return
	t.refresh()
	var sp: CheckBox = _row(t, "speed").check
	check(sp.disabled, "скорость недоступна без маршрутной цели")
	(_row(t, "triangle").check as CheckBox).button_pressed = true
	t.refresh()
	check(not sp.disabled, "с треугольником доступна")
	sp.button_pressed = true
	var s: FlightSettings = m.call("_collect")
	check(GoalSpec.validate(s.goals).is_empty(), "validate: %s" % [GoalSpec.validate(s.goals)])
	(_row(t, "triangle").check as CheckBox).button_pressed = false
	t.refresh()
	check(sp.disabled and not sp.button_pressed, "без маршрутной снова серая")
	m.queue_free()


func test_pick_point_has_no_landing_or_route() -> void:
	var m := _screen()
	var t := _tab(m)
	if t == null:
		check(false, "нет вкладки")
		return
	var s: FlightSettings = m.get("settings")
	s.pick_lat = 50.0
	s.pick_lon = 80.0
	t.refresh()
	check((_row(t, "landing").check as CheckBox).disabled, "посадка у точки с карты недоступна")
	check((_row(t, "route").check as CheckBox).disabled, "маршрут у точки с карты недоступен")
	m.queue_free()


func test_restore_from_settings() -> void:
	var m := _screen()
	var t := _tab(m)
	if t == null:
		check(false, "нет вкладки")
		return
	var s := FlightSettings.defaults()
	s.goals = [GoalSpec.make("height", "custom", 800.0), GoalSpec.make("duration", "easy", 3600.0)]
	m.set_settings(s)
	check((_row(t, "height").check as CheckBox).button_pressed, "галочка восстановлена")
	var r: FlightSettings = m.call("_collect")
	var got := {}
	for g: Dictionary in r.goals:
		got[g.kind] = g
	check(got.has("height") and is_equal_approx(float(got.height.value), 800.0), "800 м восстановлено")
	check(got.has("duration") and got.duration.level == "easy", "уровень восстановлен")
	m.queue_free()


func test_no_tab_in_net_zone() -> void:
	var z: Node = get_tree().root.get_node_or_null("NetZone")
	check(z != null, "автозагрузка NetZone")
	if z == null:
		return
	var was: bool = z.in_zone
	z.in_zone = true
	var m := _screen()
	check(_tab(m) == null, "в зоне вкладки нет")
	var s: FlightSettings = m.call("_collect")
	check(s.goals.is_empty() and not s.show_last_track, "цели в сеть не уходят")
	m.queue_free()
	z.in_zone = was


func test_route_goal_and_speed() -> void:
	var m := _screen("altai")
	var t := _tab(m)
	if t == null:
		check(false, "нет вкладки")
		return
	t.refresh()
	var rc: CheckBox = _row(t, "route").check
	check(not rc.disabled, "для altai есть маршрут")
	if rc.disabled:
		return
	rc.button_pressed = true
	t.refresh()
	check(not (_row(t, "speed").check as CheckBox).disabled, "скорость доступна с маршрутом")
	(_row(t, "speed").check as CheckBox).button_pressed = true
	var s: FlightSettings = m.call("_collect")
	check(GoalSpec.validate(s.goals).is_empty(), "validate: %s" % [GoalSpec.validate(s.goals)])
	var ok := false
	for g: Dictionary in s.goals:
		ok = ok or (g.kind == "route" and String(g.task) != "")
	check(ok, "route с заданием")
	m.queue_free()
