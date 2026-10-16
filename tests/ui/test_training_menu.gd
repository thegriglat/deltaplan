extends Node
## TI-16: окно «Тренировка» — карточки из configs/training.json, цели GoalSpec, FlightSettings клика
## (остров, старт, цель, погода набора), кнопка в главном меню.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _cards() -> Array:
	return TrainingMenu.load_cards().get("cards", [])


func test_four_cards_with_valid_goals_and_sites() -> void:
	var cards := _cards()
	check(cards.size() == 4, "4 карточки: %d" % cards.size())
	var sites := []
	for s: Dictionary in Locations.config("training_island").get("start_sites", []):
		sites.append(String(s.id))
	for c: Dictionary in cards:
		var errs := GoalSpec.validate([TrainingMenu.goal_of(c)])
		check(errs.is_empty(), "цель %s: %s" % [c.get("id"), errs])
		check(String(c.site) in sites, "старт %s есть на острове" % c.get("site"))
		check(tr(String(c.title_key)) != String(c.title_key), "название переведено: " + String(c.title_key))
		check(tr(String(c.what_key)) != String(c.what_key), "что отрабатываем переведено: " + String(c.what_key))
		check(TrainingMenu.goal_text(c) != "", "цель словами")


func test_click_gives_island_settings() -> void:
	var m: TrainingMenu = (load("res://scenes/ui/training_menu.tscn") as PackedScene).instantiate()
	add_child(m)
	var got: Array = []
	m.chosen.connect(func(c: Dictionary) -> void: got.append(c))
	check(m.cards.size() == 4, "окно строит 4 карточки")
	var base := FlightSettings.defaults()
	base.wing = "wings/sport"
	base.pilot_mass_kg = 83.0
	base.location_id = "altai"
	base.pick_lat = 50.0
	base.pick_lon = 86.0
	base.start_lat = 50.0
	base.start_lon = 86.0
	base.start_heading_deg = 10.0
	for i in 4:
		m.press_card(i)
		var c: Dictionary = got[i]
		var s := TrainingMenu.settings_for(c, base, m.location_id)
		check(s.location_id == "training_island", "место")
		check(s.site_id == String(c.site), "старт")
		check(not s.has_pick() and not s.has_exact_start(), "точка и точный старт сброшены")
		check(s.wing == base.wing and is_equal_approx(s.pilot_mass_kg, 83.0), "крыло и масса пилота сохранены")
		check(s.goals.size() == 1 and GoalSpec.validate(s.goals).is_empty(), "одна годная цель")
		check(String(s.goals[0].kind) == String(c.goal.kind) and is_equal_approx(float(s.goals[0].value), float(c.goal.value)), "цель карточки")
		var w := StartWeather.for_settings(s)
		check(not w.is_empty(), "у старта есть набор погоды")
		check(is_equal_approx(s.wind_speed_kmh, float(w.wind_speed_ms) * 3.6), "ветер набора")
		check(is_equal_approx(s.wind_from_deg, float(w.wind_from_deg)) and s.sky == String(w.sky), "направление и небо набора")
		check(is_equal_approx(s.start_hour, float(w.start_hour)), "час набора")
	check(base.location_id == "altai" and base.goals.is_empty(), "исходные настройки не тронуты")
	m.queue_free()


func test_goal_values() -> void:
	var by := {}
	for c: Dictionary in _cards():
		by[c.id] = c.goal
	check(by.ridge.kind == "duration" and by.ridge.value == 600, "склон — 600 с")
	check(by.thermals.kind == "height" and by.thermals.value == 300, "термики — 300 м")
	check(by.landing.kind == "landing" and by.landing.value == 25, "посадка — круг 25 м")
	check(by.rotor.kind == "duration" and by.rotor.value == 300, "ротор — 300 с")


func test_main_menu_button_starts_flight() -> void:
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	m.favorites_path = "user://training_menu_test_fav.json"
	add_child(m)
	var btn: Button = null
	for b in m.find_children("*", "Button", true, false):
		if (b as Button).text == tr("menu_training"):
			btn = b
	check(btn != null, "кнопка «Тренировка» в главном меню")
	if btn == null:
		m.queue_free()
		return
	var flown: Array = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: flown.append(s))
	btn.pressed.emit()
	var t: TrainingMenu = null
	for c in m.get_children():
		if c is TrainingMenu:
			t = c
	check(t != null, "окно открылось")
	if t != null:
		t.press_card(3)
		check(flown.size() == 1, "клик сразу даёт fly_requested")
		if flown.size() == 1:
			check(flown[0].site_id == "lee_bowl" and flown[0].goals.size() == 1, "ротор: старт и цель")
	m.queue_free()
