extends Node
## Окно «Красивые места» (SCP-К3): страны, места, выбор → точка и курс, кнопка скрыта без каталога,
## окно целиком в области. Данные — tests/ui/fixtures/scenic_places_test.json.

const FIXTURE := "res://tests/ui/fixtures/scenic_places_test.json"
const TMP_RECENT := "user://test_scenic_places_recent.json"
const SETUP_SCREEN := preload("res://scenes/ui/flight_setup_screen.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _clean() -> void:
	if FileAccess.file_exists(TMP_RECENT):
		DirAccess.remove_absolute(TMP_RECENT)


func _screen(path: String, parent: Node) -> FlightSetupScreen:
	_clean()
	var screen: FlightSetupScreen = SETUP_SCREEN.instantiate()
	screen.recent_places_path = TMP_RECENT
	screen.popular_places_path = "res://tests/ui/fixtures/hg_takeoffs_test.json"
	screen.scenic_places_path = path
	screen.settings = FlightSettings.defaults()
	parent.add_child(screen)
	return screen


func _window(catalog: Dictionary, parent: Node) -> ScenicPlacesWindow:
	var w := ScenicPlacesWindow.new()
	parent.add_child(w)
	w.open(catalog)
	return w


func test_group_and_sort() -> void:
	var cat := ScenicPlaces.load_catalog(FIXTURE)
	check(cat.places.size() == 3, "3 места")
	var en := ScenicPlaces.group_by_country(cat, "en")
	check(en.size() == 2 and en[0].name == "Norway" and en[1].name == "Switzerland", "страны (en) по алфавиту")
	check(en[1].count == 2 and en[1].places[0].id == "ch/test-alpine-valley", "места по названию (en)")
	var ru := ScenicPlaces.group_by_country(cat, "ru")
	check(ru[0].name == "Норвегия" and ru[1].name == "Швейцария", "страны (ru)")
	check(ru[1].places[0].id == "ch/test-alpine-valley", "места по названию (ru): «Тестовая» раньше «Тестовый»: %s" % ru[1].places[0].id)
	var p: Dictionary = cat.places[0]
	check(ScenicPlaces.name(p, "ru") == "Тестовая альпийская долина" and ScenicPlaces.name(p, "en") == "Test alpine valley", "name по языку")
	check(ScenicPlaces.why(p, "ru").begins_with("Тест: крутые") and ScenicPlaces.why(p, "en").begins_with("Test: steep"), "why по языку")


func test_empty_and_broken() -> void:
	for path in ["res://tests/ui/fixtures/no_such_file.json", "res://tests/ui/fixtures/hg_takeoffs_test.json"]:
		var cat := ScenicPlaces.load_catalog(path)
		check(cat.get("places", null) is Array and cat.places.is_empty() and cat.countries.is_empty(), "пустой каталог: %s" % path)
		check(ScenicPlaces.group_by_country(cat, "en").is_empty(), "нет групп")


func test_window_levels() -> void:
	TranslationServer.set_locale("en")
	var w := _window(ScenicPlaces.load_catalog(FIXTURE), self)
	var rows := w.row_texts()
	check(rows == PackedStringArray(["Norway — 1", "Switzerland — 2"]), "страны: %s" % [rows])
	w.press_row(1)
	var places := w.row_texts()
	check(places.size() == 2 and places[0].begins_with("Test alpine valley · Valley · Test: steep"), "место: %s" % [places])
	w.call("_go_back")
	check(w.row_texts().size() == 2, "«Назад» — к странам")
	var closed: Array = []
	w.closed.connect(func() -> void: closed.append(1))
	w.call("_go_back")
	check(closed.size() == 1 and not w.visible, "«Назад» на уровне стран закрывает")
	w.queue_free()
	TranslationServer.set_locale("ru")


func test_choice_sets_start_and_heading() -> void:
	TranslationServer.set_locale("en")
	var screen := _screen(FIXTURE, self)
	var btn: Button = screen.get("_scenic_btn")
	check(btn != null and btn.visible, "кнопка видна с каталогом")
	btn.pressed.emit()
	var w: ScenicPlacesWindow = screen.get("_scenic_window")
	check(w != null and w.visible, "окно открыто")
	var chosen: Array = []
	w.place_chosen.connect(func(p: Dictionary) -> void: chosen.append(p))
	w.press_row(0)  # Norway
	w.press_row(0)
	check(chosen.size() == 1 and not w.visible, "place_chosen и закрытие")
	var s: FlightSettings = screen.settings
	check(absf(s.pick_lat - 62.1) < 1e-6 and absf(s.pick_lon - 7.1) < 1e-6, "pick_lat/lon")
	check(s.has_exact_start() and absf(s.start_lat - 62.1) < 1e-6 and absf(s.start_heading_deg - 270.0) < 1e-6, "точный старт и курс")
	check(is_nan(float(screen.get("_pick_elev_m"))), "высота не задана")
	check(String(screen.get("_picked_place_name")) == "Test fjord", "название на языке интерфейса")
	screen.call("_on_done")
	var list := RecentPlaces.list(TMP_RECENT)
	check(list.size() == 1 and RecentPlaces.display_name(list[0]) == "Test fjord", "в недавних — название")
	# выбор другим способом снимает красивое место
	var row: PlacePickRow = screen.get("_row")
	s = row.settings  # «Готово» могло заменить объект настроек
	check(row.scenic_id == "no/test-fjord", "scenic_id")
	screen.call("_select_recent", {"lat": 51.6, "lon": 86.4})
	check(row.scenic_id == "" and not s.has_exact_start(), "«Недавние» снимают выбор: id=%s exact=%s" % [row.scenic_id, s.has_exact_start()])
	row.choose_scenic(chosen[0])
	screen.call("_on_place_chosen", {"name": "X", "lat": 45.9, "lon": 13.7})
	check(row.scenic_id == "" and not s.has_exact_start(), "«Популярные» снимают выбор")
	screen.queue_free()
	_clean()
	TranslationServer.set_locale("ru")


func test_no_catalog_hides_button() -> void:
	var screen := _screen("res://tests/ui/fixtures/no_such_file.json", self)
	var btn: Button = screen.get("_scenic_btn")
	check(btn != null and not btn.visible, "без каталога кнопка скрыта")
	screen.queue_free()
	_clean()


func test_no_button_on_net_screen() -> void:
	var host := Control.new()
	add_child(host)
	var row := PlacePickRow.new()
	row.settings = FlightSettings.defaults()
	host.add_child(row)
	row.build(host)  # как net_screen: по умолчанию без «Красивых мест»
	check(row.scenic_btn == null, "на экране сети кнопки нет")
	host.queue_free()


func test_button_after_popular() -> void:
	var screen := _screen(FIXTURE, self)
	var row: PlacePickRow = screen.get("_row")
	check(row.scenic_btn.get_index() == row.places_btn.get_index() + 1, "кнопка сразу после «Популярные места»")
	screen.queue_free()
	_clean()


func test_window_inside_area() -> void:
	var cat := ScenicPlaces.load_catalog(FIXTURE)
	for sz: Vector2i in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(640, 800)]:
		var vp := SubViewport.new()
		vp.size = sz
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var w := _window(cat, vp)
		await get_tree().process_frame
		await get_tree().process_frame
		var area := Rect2(Vector2.ZERO, Vector2(sz))
		var r := w.panel_rect()
		check(area.encloses(r), "%s: окно %s внутри %s" % [sz, r, area])
		for b: Button in [w.get("_back"), w.get("_cancel")]:
			check(b.is_visible_in_tree() and r.encloses(Rect2(b.global_position, b.size)), "%s: кнопка «%s» видна" % [sz, b.text])
		check(w.get("_scroll") is ScrollContainer, "список в ScrollContainer")
		w.enter_country("CH")
		await get_tree().process_frame
		check(area.encloses(w.panel_rect()), "%s: в стране окно внутри" % sz)
		vp.queue_free()
