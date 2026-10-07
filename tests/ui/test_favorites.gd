extends Node
## QL-12: избранные условия — добавить на «Полёт…», список в меню, щелчок → fly_requested
## с теми же настройками, удаление, не больше 8 (девятое вытесняет самое старое).

const TMP_PATH := "user://test_favorites_tmp.json"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _clean() -> void:
	if FileAccess.file_exists(TMP_PATH):
		DirAccess.remove_absolute(TMP_PATH)


func _settings(hour: float, wind_kmh: float = 10.8) -> FlightSettings:
	var s := FlightSettings.defaults()
	s.start_hour = hour
	s.wind_speed_kmh = wind_kmh
	s.wind_into_launch = false
	s.wind_from_deg = 315.0
	s.sky = "partly"
	s.wing = "wings/sport"
	return s


func test_add_list_roundtrip_and_name() -> void:
	_clean()
	var s := _settings(13.0)
	var id := Favorites.add(s, TMP_PATH)
	var items := Favorites.list(TMP_PATH)
	check(items.size() == 1 and int(items[0].id) == id, "одна запись")
	var back := Favorites.settings_of(id, TMP_PATH)
	check(back != null and back.to_dict() == s.to_dict(), "настройки те же")
	var n := Favorites.auto_name(s)
	check(n.contains("13:00") and n.contains("3 ") and n.contains("Sport"), "автоназвание: " + n)
	Favorites.add(s, TMP_PATH)
	check(Favorites.list(TMP_PATH).size() == 1, "дубль не плодится")
	_clean()


func test_limit_eight_evicts_oldest() -> void:
	_clean()
	for i in 9:
		Favorites.add(_settings(6.0 + i), TMP_PATH, 1000.0 + i)
	var items := Favorites.list(TMP_PATH)
	check(items.size() == 8, "не больше 8: %d" % items.size())
	check(is_equal_approx(float(items[-1].settings.start_hour), 7.0), "самое старое (6:00) вытеснено")
	check(is_equal_approx(float(items[0].settings.start_hour), 14.0), "новое — первым")
	_clean()


func test_menu_list_click_and_remove() -> void:
	_clean()
	var a := _settings(9.0)
	var b := _settings(15.0, 18.0)
	Favorites.add(a, TMP_PATH)
	Favorites.add(b, TMP_PATH)
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	m.favorites_path = TMP_PATH
	add_child(m)
	var rows := m.find_children("Fav*", "HBoxContainer", true, false)
	check(rows.size() == 2, "две строки в меню: %d" % rows.size())
	var got: Array[FlightSettings] = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: got.append(s))
	(rows[0].get_node("Fly") as Button).pressed.emit()
	check(got.size() == 1 and got[0].to_dict() == b.to_dict(), "щелчок → fly_requested с теми же настройками")
	(rows[0].get_node("Remove") as Button).pressed.emit()
	check(Favorites.list(TMP_PATH).size() == 1, "удалена из файла")
	check(m.find_children("Fav*", "HBoxContainer", true, false).size() == 1, "строка исчезла")
	m.queue_free()
	_clean()


func test_setup_screen_adds_favorite() -> void:
	_clean()
	var sc: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	sc.favorites_path = TMP_PATH
	sc.recent_places_path = "user://test_favorites_recent_tmp.json"
	add_child(sc)
	sc.set_settings(_settings(12.0))
	sc._on_add_favorite()
	var items := Favorites.list(TMP_PATH)
	check(items.size() == 1, "добавлено с экрана")
	if items.size() == 1:
		check(is_equal_approx(float(items[0].settings.start_hour), 12.0), "час 12:00")
	sc.queue_free()
	_clean()
