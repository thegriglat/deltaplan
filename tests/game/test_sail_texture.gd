extends Node
## SLT-2: выбор своей картинки паруса на экране «Полёт…» (отложенный выбор/сброс).

const DIR := "user://slt_ui_test"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _screen() -> FlightSetupScreen:
	var m: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	add_child(m)
	m.recent_places_path = DIR + "/recent.json"
	m.favorites_path = DIR + "/fav.json"
	var s := FlightSettings.defaults()
	s.location_id = "altai"
	s.site_id = "tugaya_south"
	m.set_settings(s)
	return m


func test_sail_texture_screen() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	SailTexture.path = DIR + "/sail.png"
	var img := Image.create(120, 60, false, Image.FORMAT_RGB8)
	img.fill(Color(0.8, 0.2, 0.1))
	var src := DIR + "/src.png"
	img.save_png(src)

	var m := _screen()
	var prev: TextureRect = m.get("_sail_preview")
	var native: Button = m.get("_sail_native_btn")
	check(native.disabled, "«Родная» недоступна без своей")
	m.on_sail_file_selected(src)
	check(prev.texture != null, "предпросмотр не пуст")
	check(not SailTexture.has_custom(), "профиль не тронут до «Готово»")
	check(not native.disabled, "«Родная» доступна после выбора")
	m.call("_on_done")
	check(SailTexture.has_custom(), "«Готово» — файл записан")
	m.queue_free()

	# сброс: отложенный, «Назад» ничего не пишет
	m = _screen()
	check(m.get("_sail_preview").texture != null, "своя картинка в предпросмотре")
	m.call("_on_sail_reset")
	check(SailTexture.has_custom(), "сброс отложен")
	check(m.get("_sail_preview").texture == null, "предпросмотр пуст после сброса")
	m.queue_free()
	check(SailTexture.has_custom(), "«Назад» — без изменений")

	m = _screen()
	m.call("_on_sail_reset")
	m.call("_on_done")
	check(not SailTexture.has_custom(), "«Готово» после сброса — файла нет")
	# «Назад» после выбора
	m.on_sail_file_selected(src)
	m.queue_free()
	check(not SailTexture.has_custom(), "«Назад» после выбора — профиль без изменений")

	m = _screen()
	m.on_sail_file_selected(DIR + "/нет.png")
	check(String(m.get("_sail_err").text) != "" and m.get("_sail_pending") == null, "ошибка показана")
	m.queue_free()

	SailTexture.path = SailTexture.DEFAULT_PATH
	for d in [DIR]:
		var da := DirAccess.open(d)
		for f in da.get_files():
			da.remove(f)
		DirAccess.remove_absolute(d)
