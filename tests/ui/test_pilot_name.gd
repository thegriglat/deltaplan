extends Node
## Имя пилота (NET-51, docs/plan/multiplayer.md M5): user-конфиг game.json → net.pilot_name,
## обрезка до UserSettings.PILOT_NAME_MAX символов (не байт), умолчание — по языку интерфейса
## (net_pilot_name_default). Пишем в настоящий user://configs (Config читает только его) и
## восстанавливаем прежнее.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_sanitize_trims_and_cuts_by_characters() -> void:
	check(UserSettings.sanitize_pilot_name("  Орёл-Иван  ") == "Орёл-Иван", "обрезаны края")
	check(UserSettings.sanitize_pilot_name("   \t  ") == "", "пробелы — пусто")
	var long_name := "1234567890123456789012345"  # 25 символов
	check(UserSettings.sanitize_pilot_name(long_name).length() == 20, "обрезано до 20 символов")
	var long_cyrillic := "Кириллическоеимяоченьдлинное"  # >20 кириллических символов
	var cut := UserSettings.sanitize_pilot_name(long_cyrillic)
	check(cut.length() == 20, "кириллица обрезана по символам, не байтам: %d" % cut.length())
	check(cut == long_cyrillic.substr(0, 20), "обрезка совпадает с substr по символам")


func test_pilot_name_round_trips_and_defaults() -> void:
	var path := UserSettings.DEFAULT_DIR.path_join("game.json")
	var backup := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var was_locale := TranslationServer.get_locale()

	UserSettings.save_pilot_name("Орёл-Иван")
	Config.reload()
	check(UserSettings.pilot_name() == "Орёл-Иван", "кириллица сохранилась и читается")

	UserSettings.save_pilot_name("John-Smith")
	Config.reload()
	check(UserSettings.pilot_name() == "John-Smith", "латиница сохранилась и читается")

	var long_name := "ИмяДлиннееДвадцатиСимволов"
	UserSettings.save_pilot_name(long_name)
	Config.reload()
	check(UserSettings.pilot_name() == long_name.substr(0, 20), "длинное имя обрезано при чтении")

	UserSettings.save_pilot_name("   ")
	Config.reload()
	Language.apply("ru")
	var default_ru := UserSettings.pilot_name()
	check(default_ru == tr("net_pilot_name_default"), "пусто/пробелы — умолчание")

	Language.apply("en")
	var default_en := UserSettings.pilot_name()
	check(
		default_en != default_ru,
		"умолчание отличается ru/en: «%s» vs «%s»" % [default_ru, default_en]
	)

	Language.apply(was_locale)
	_restore(path, backup)
	Config.reload()


func test_settings_panel_saves_and_loads_pilot_name() -> void:
	var path := UserSettings.DEFAULT_DIR.path_join("game.json")
	var backup := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""

	var sp: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	add_child(sp)
	var field: LineEdit = sp.get("_pilot_name")
	check(field != null, "в настройках есть поле «Имя пилота»")
	check(field.max_length == UserSettings.PILOT_NAME_MAX, "ограничение поля — 20 символов")
	field.text = "Орёл-Иван"
	check(sp.save(), "сохранилось")
	check(UserSettings.pilot_name() == "Орёл-Иван", "имя применилось")

	sp.queue_free()
	_restore(path, backup)
	Config.reload()


func _restore(path: String, content: String) -> void:
	if content == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()
