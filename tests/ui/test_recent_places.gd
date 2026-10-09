extends Node
## «Недавние места» на экране «Полёт…» (RecentPlaces, scripts/game/recent_places.gd):
## добавление, дубль по расстоянию (~300 м), лимит 8 непристёгнутых, закреплённые не вытесняются,
## переименование сохраняется, выбор в UI ставит pick_lat/pick_lon.

const TMP_PATH := "user://test_recent_places_tmp.json"
const SETUP_SCREEN := preload("res://scenes/ui/flight_setup_screen.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _clean() -> void:
	if FileAccess.file_exists(TMP_PATH):
		DirAccess.remove_absolute(TMP_PATH)


func _before() -> void:
	_clean()


func _after() -> void:
	_clean()


## 1) Новая точка — в списке, подпись по умолчанию — координаты (нет place_name/custom_name).
func test_add_creates_entry_with_coord_label() -> void:
	_before()
	var id := RecentPlaces.add(51.6, 86.4, "", TMP_PATH)
	var places := RecentPlaces.list(TMP_PATH)
	check(places.size() == 1, "одна запись после add")
	check(int(places[0].id) == id, "id совпадает")
	check(
		RecentPlaces.display_name(places[0]) == "51.6000, 86.4000",
		"подпись по умолчанию — координаты: %s" % RecentPlaces.display_name(places[0])
	)
	_after()


## 2) Точка ближе ~300 м к уже сохранённой — обновляет её же (не плодит дубль).
func test_near_point_merges_as_duplicate() -> void:
	_before()
	var id1 := RecentPlaces.add(51.6, 86.4, "", TMP_PATH, 1000.0)
	# ~150 м к северу (0.00135° по широте ≈ 150 м)
	var id2 := RecentPlaces.add(51.60135, 86.4, "", TMP_PATH, 2000.0)
	check(id1 == id2, "точка в пределах 300 м — та же запись (id %d == %d)" % [id1, id2])
	check(RecentPlaces.list(TMP_PATH).size() == 1, "дубль не добавился")
	_after()


## 3) Точка дальше 300 м — отдельная запись.
func test_far_point_is_separate_entry() -> void:
	_before()
	RecentPlaces.add(51.6, 86.4, "", TMP_PATH, 1000.0)
	RecentPlaces.add(51.7, 86.4, "", TMP_PATH, 2000.0)
	check(RecentPlaces.list(TMP_PATH).size() == 2, "две разные точки — две записи")
	_after()


## 4) Не больше 8 непристёгнутых — лишние (самые старые) убираются.
func test_limit_8_unpinned_drops_oldest() -> void:
	_before()
	var first_id := -1
	for i in 9:
		var id := RecentPlaces.add(51.0 + float(i) * 0.05, 86.0, "", TMP_PATH, float(i))
		if i == 0:
			first_id = id
	var places := RecentPlaces.list(TMP_PATH)
	check(places.size() == 8, "не больше 8 записей, получено %d" % places.size())
	var has_first := false
	for p: Dictionary in places:
		if int(p.id) == first_id:
			has_first = true
	check(not has_first, "самая старая запись убрана лимитом")
	_after()


## 5) Закреплённые не вытесняются лимитом и остаются даже когда непристёгнутых уже 8.
func test_pinned_not_evicted() -> void:
	_before()
	var pinned_id := RecentPlaces.add(40.0, 70.0, "", TMP_PATH, 0.0)
	RecentPlaces.set_pinned(pinned_id, true, TMP_PATH)
	for i in 9:
		RecentPlaces.add(51.0 + float(i) * 0.05, 86.0, "", TMP_PATH, float(i + 1))
	var places := RecentPlaces.list(TMP_PATH)
	var has_pinned := false
	var unpinned_count := 0
	for p: Dictionary in places:
		if int(p.id) == pinned_id:
			has_pinned = true
		elif not bool(p.get("pinned", false)):
			unpinned_count += 1
	check(has_pinned, "закреплённая запись осталась")
	check(unpinned_count == 8, "непристёгнутых по-прежнему не больше 8, получено %d" % unpinned_count)
	check(places.size() == 9, "всего записей: 8 непристёгнутых + 1 закреплённая")
	_after()


## Закреплённые — всегда первыми в списке (sorted: pinned, затем недавние).
func test_pinned_listed_first() -> void:
	_before()
	RecentPlaces.add(51.0, 86.0, "", TMP_PATH, 5.0)
	var pinned_id := RecentPlaces.add(52.0, 87.0, "", TMP_PATH, 1.0)
	RecentPlaces.set_pinned(pinned_id, true, TMP_PATH)
	var places := RecentPlaces.list(TMP_PATH)
	check(int(places[0].id) == pinned_id, "закреплённая запись — первая, несмотря на время")
	_after()


## 6) Переименование — своё имя сохраняется и переживает перечитывание с диска.
func test_rename_persists() -> void:
	_before()
	var id := RecentPlaces.add(51.6, 86.4, "", TMP_PATH, 1.0)
	RecentPlaces.rename(id, "Наш старт", TMP_PATH)
	var reloaded := RecentPlaces.list(TMP_PATH)
	check(
		RecentPlaces.display_name(reloaded[0]) == "Наш старт",
		"своё имя сохранилось после перечитывания: %s" % RecentPlaces.display_name(reloaded[0])
	)
	_after()


## 7) Удаление убирает запись из списка.
func test_remove() -> void:
	_before()
	var id := RecentPlaces.add(51.6, 86.4, "", TMP_PATH, 1.0)
	RecentPlaces.remove(id, TMP_PATH)
	check(RecentPlaces.list(TMP_PATH).is_empty(), "запись удалена")
	_after()


## 8) Выбор недавнего места на экране «Полёт…» ставит pick_lat/pick_lon (клик по месту).
func test_select_recent_sets_pick_lat_lon() -> void:
	_before()
	RecentPlaces.add(51.6, 86.4, "Тестовое", TMP_PATH, 1.0)
	var screen: FlightSetupScreen = SETUP_SCREEN.instantiate()
	screen.recent_places_path = TMP_PATH
	screen.settings = FlightSettings.defaults()
	add_child(screen)
	var recent_list: VBoxContainer = screen.get("_recent_list")
	check(recent_list != null and recent_list.get_child_count() == 1, "одна строка недавнего места")
	if recent_list != null and recent_list.get_child_count() == 1:
		var row: HBoxContainer = recent_list.get_child(0)
		var name_btn: Button = row.get_child(0)
		check(name_btn.text.contains("Тестовое"), "подпись строки — «Тестовое»: %s" % name_btn.text)
		name_btn.pressed.emit()
	check(screen.settings.has_pick(), "pick стоит после выбора недавнего места")
	check(absf(screen.settings.pick_lat - 51.6) < 0.0001, "pick_lat поставлен")
	check(absf(screen.settings.pick_lon - 86.4) < 0.0001, "pick_lon поставлен")
	screen.queue_free()
	_after()


## Пустой список — блок «Недавние места» скрыт.
func test_empty_recent_hides_section() -> void:
	_before()
	var screen: FlightSetupScreen = SETUP_SCREEN.instantiate()
	screen.recent_places_path = TMP_PATH
	screen.settings = FlightSettings.defaults()
	add_child(screen)
	var section: VBoxContainer = screen.get("_recent_section")
	check(section != null and not section.visible, "секция скрыта, когда список пуст")
	screen.queue_free()
	_after()
