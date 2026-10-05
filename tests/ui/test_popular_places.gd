extends Node
## Окно «Популярные места» (PP-К2): страны, вход в страну, поиск (в стране и по всем), выбор → точка старта
## экрана «Полёт», название места — в «Недавние» на «Готово»; окно целиком в области при разных
## разрешениях; без каталога кнопка скрыта. Данные — tests/ui/fixtures/hg_takeoffs_test.json.

const FIXTURE := "res://tests/ui/fixtures/hg_takeoffs_test.json"
const TMP_RECENT := "user://test_popular_places_recent.json"
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
	screen.popular_places_path = path
	screen.settings = FlightSettings.defaults()
	parent.add_child(screen)
	return screen


func _window(catalog: Dictionary, parent: Node) -> PopularPlacesWindow:
	var w := PopularPlacesWindow.new()
	parent.add_child(w)
	w.open(catalog)
	return w


func test_countries_and_enter() -> void:
	TranslationServer.set_locale("en")
	var cat := PopularPlaces.load_catalog(FIXTURE)
	var w := _window(cat, self)
	var rows := w.row_texts()
	check(rows.size() == 4, "4 группы: %s" % rows)
	check(rows[0] == "Austria — 2", "первая строка: %s" % rows[0])
	check(rows[3].ends_with("— 1"), "группа без страны последняя: %s" % rows[3])
	w.press_row(2)  # Slovenia
	var places := w.row_texts()
	check(places.size() == 4, "в Словении 4 места: %s" % places)
	check(places[0].begins_with("Kobala") and places[0].contains("1000 m"), "Kobala с высотой: %s" % places[0])
	check(places[0].contains("S, SSW, SW"), "ориентация: %s" % places[0])
	check(places[3].contains("—"), "нет высоты — прочерк: %s" % places[3])
	w.queue_free()
	TranslationServer.set_locale("ru")


func test_search_in_country_and_global() -> void:
	var cat := PopularPlaces.load_catalog(FIXTURE)
	var w := _window(cat, self)
	var search: LineEdit = w.get("_search")
	search.text = "ГОР"
	search.text_changed.emit(search.text)
	var all := w.row_texts()
	check(all.size() == 2, "«гор» по всем странам: Ёлочная гора, Шелковая горка: %s" % all)
	check(all.size() > 0 and all[0].contains(" · "), "в результате указана страна: %s" % all)
	search.text = "zzz"
	search.text_changed.emit(search.text)
	check(w.row_texts().size() == 0, "ничего не найдено — без кнопок")
	search.text = ""
	search.text_changed.emit("")
	w.enter_country("RU")
	search.text = "елочная"
	search.text_changed.emit(search.text)
	var in_ru := w.row_texts()
	check(in_ru.size() == 1, "в стране: ё = е: %s" % in_ru)
	search.text = "kob"
	search.text_changed.emit(search.text)
	check(w.row_texts().size() == 0, "внутри страны ищет только по ней")
	w.queue_free()


func test_choice_sets_pick_and_recent_name() -> void:
	var screen := _screen(FIXTURE, self)
	var btn: Button = screen.get("_places_btn")
	check(btn != null and btn.visible, "кнопка видна с каталогом")
	btn.pressed.emit()
	var w: PopularPlacesWindow = screen.get("_places_window")
	check(w != null and w.visible, "окно открыто")
	var chosen: Array = []
	w.place_chosen.connect(func(p: Dictionary) -> void: chosen.append(p))
	var search: LineEdit = w.get("_search")
	search.text = "lijak"
	search.text_changed.emit(search.text)
	w.press_row(0)
	check(chosen.size() == 1, "place_chosen пришёл")
	check(not w.visible, "окно закрылось")
	check(screen.settings.has_pick(), "точка стоит")
	check(absf(screen.settings.pick_lat - 45.964) < 0.0001, "pick_lat")
	check(absf(screen.settings.pick_lon - 13.725) < 0.0001, "pick_lon")
	check(is_nan(float(screen.get("_pick_elev_m"))), "_pick_elev_m = NAN")
	screen.call("_on_done")
	var list := RecentPlaces.list(TMP_RECENT)
	check(list.size() == 1 and RecentPlaces.display_name(list[0]) == "Lijak", "в недавних — название места")
	screen.queue_free()
	_clean()


func test_other_pick_resets_name() -> void:
	var screen := _screen(FIXTURE, self)
	screen.call("_on_place_chosen", {"name": "Lijak", "lat": 45.964, "lon": 13.725})
	check(String(screen.get("_picked_place_name")) == "Lijak", "название запомнено")
	screen.call("_select_recent", {"lat": 51.6, "lon": 86.4})
	check(String(screen.get("_picked_place_name")) == "", "другой выбор сбрасывает название")
	screen.queue_free()
	_clean()


func test_no_catalog_hides_button() -> void:
	var screen := _screen("res://tests/ui/fixtures/no_such_file.json", self)
	var btn: Button = screen.get("_places_btn")
	check(btn != null and not btn.visible, "без каталога кнопка скрыта")
	screen.queue_free()
	_clean()


func test_window_inside_area() -> void:
	var cat := PopularPlaces.load_catalog(FIXTURE)
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
		var back: Button = w.get("_back")
		var cancel: Button = w.get("_cancel")
		for b: Button in [back, cancel]:
			var br := Rect2(b.global_position, b.size)
			check(b.is_visible_in_tree() and r.encloses(br), "%s: кнопка «%s» видна: %s" % [sz, b.text, br])
		check(w.get("_scroll") is ScrollContainer, "список в ScrollContainer")
		w.enter_country("SI")
		await get_tree().process_frame
		check(area.encloses(w.panel_rect()), "%s: в стране окно внутри" % sz)
		vp.queue_free()
