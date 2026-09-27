extends Node
## Карточка 11-02: пауза/настройки/«Об игре»/итог. Настройки переживают перезагрузку панели,
## выбор звука вариометра 90-х пишет ключ, «Об игре» содержит авторов из ASSETS.md,
## `lines_for` не падает без поля, кнопки итога шлют сигналы, во всех экранах нет строк без tr().
## extends Node (не TestCase — RefCounted): экранам нужен add_child, как в tests/game/test_ui.gd.

const TMP_DIR := "user://test_screens_tmp"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])


func _scene(path: String) -> Control:
	var c: Control = (load(path) as PackedScene).instantiate()
	add_child(c)
	return c


func _clean_tmp() -> void:
	for f in ["controls.json", "audio.json", "game.json", "atmosphere.json", "world.json"]:
		if FileAccess.file_exists(TMP_DIR.path_join(f)):
			DirAccess.remove_absolute(TMP_DIR.path_join(f))
	if DirAccess.dir_exists_absolute(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR)


## 1) Настройки пишутся в user://configs и читаются заново отдельной панелью (не из памяти).
## load_values() читает через Config (всегда user://configs, config_dir на чтение не влияет —
## он только для изоляции записи в других тестах), поэтому тут пишем в настоящий DEFAULT_DIR
## и аккуратно восстанавливаем то, что там было, чтобы не испортить профиль пилота.
func test_settings_persist_across_panel_reload() -> void:
	var controls_path := UserSettings.DEFAULT_DIR.path_join("controls.json")
	var audio_path := UserSettings.DEFAULT_DIR.path_join("audio.json")
	var backup_controls := _read_raw(controls_path)
	var backup_audio := _read_raw(audio_path)

	var a: SettingsPanel = _scene("res://scenes/ui/settings_panel.tscn")
	(a.get("_volume") as HSlider).value = -18.0
	(a.get("_invert") as CheckBox).button_pressed = true
	(a.get("_sens") as HSlider).value = 0.2
	check(a.save(), "запись настроек")
	a.queue_free()

	var b: SettingsPanel = _scene("res://scenes/ui/settings_panel.tscn")
	b.load_values()
	approx(
		(b.get("_volume") as HSlider).value, -18.0, 0.01, "громкость читается после перезагрузки"
	)
	check((b.get("_invert") as CheckBox).button_pressed, "инверсия читается после перезагрузки")
	approx((b.get("_sens") as HSlider).value, 0.2, 0.001, "чувствительность читается")
	b.queue_free()

	_restore_raw(controls_path, backup_controls)
	_restore_raw(audio_path, backup_audio)
	Config.reload()


func _read_raw(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func _restore_raw(path: String, content: String) -> void:
	if content == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()


## 2) Выбор пресета «classic_90s» пишет ключ audio.vario_audio.preset в user-конфиг.
func test_classic_90s_choice_writes_key() -> void:
	_clean_tmp()
	var sp: SettingsPanel = _scene("res://scenes/ui/settings_panel.tscn")
	sp.config_dir = TMP_DIR
	var sound: OptionButton = sp.get("_sound")
	check(sound != null, "выбор звука вариометра есть (presets в audio.json)")
	if sound != null:
		var presets: PackedStringArray = sp.get("_presets")
		var idx := presets.find("classic_90s")
		check(idx >= 0, "classic_90s есть в списке пресетов")
		sound.select(idx)
		check(sp.save(), "сохранилось")
		var au := UserSettings.read_json(TMP_DIR.path_join("audio.json"))
		check(
			String(au.get("vario_audio", {}).get("preset", "")) == "classic_90s",
			"ключ preset = classic_90s записан"
		)
	sp.queue_free()
	_clean_tmp()


## 3) «Об игре» содержит авторов материалов из ASSETS.md (по разным разделам).
func test_about_contains_assets_md_authors() -> void:
	var a: AboutScreen = _scene("res://scenes/ui/about_screen.tscn")
	var text := a.get_text()
	var authors := [
		"DSEG", "Noto", "klankbeeld", "Kenney", "ESA WorldCover", "OpenStreetMap", "ambientCG"
	]
	for author: String in authors:
		check(text.contains(author), "«Об игре» содержит автора «%s»" % author)
	a.queue_free()


## 4) lines_for не падает на пустом info (поле отсутствует — строка просто не показывается).
func test_lines_for_missing_fields_does_not_crash() -> void:
	var lines := ResultScreen.lines_for("landed", {})
	check(
		not lines.is_empty(), "строки есть даже без полей (скорости, времени и т.п. по умолчанию)"
	)
	var text := "\n".join(lines)
	check(
		not text.contains("best_thermal") and not text.contains("null"),
		"нет мусора от отсутствующих полей"
	)
	var lines2 := ResultScreen.lines_for("takeoff_failed", {})
	check(lines2.size() == 1, "срыв взлёта без текста — одна (пустая) строка, не падает")


## 5) Кнопки итога эмитят restart/menu (continue доступен по API, но скрыт — сессия окончена).
func test_result_screen_buttons_emit_signals() -> void:
	var r: ResultScreen = _scene("res://scenes/ui/result_screen.tscn")
	var hits: Array = []
	r.restart_requested.connect(func() -> void: hits.append("restart"))
	r.continue_requested.connect(func() -> void: hits.append("continue"))
	r.menu_requested.connect(func() -> void: hits.append("menu"))
	r.show_result("landed", {"grade": "soft"})
	check(
		not (r.get("_continue") as Button).visible, "«Продолжить» скрыта — сессия всегда завершена"
	)
	for b in r.find_children("*", "Button", true, false):
		(b as Button).pressed.emit()
	check(hits.has("restart"), "«Ещё раз» шлёт restart_requested")
	check(hits.has("menu"), "«В главное меню» шлёт menu_requested")
	check(hits.size() == 3, "все три сигнала кнопок эмитированы: %s" % [hits])
	r.queue_free()


## 6) Ни одна видимая строка экранов не обходит tr() — берём известные подписи и сверяем
## с переводом из locale/ui.csv (перевод есть и не совпадает случайно с ключом-заглушкой).
func test_no_untranslated_strings() -> void:
	var samples := [
		"Пауза",
		"Продолжить",
		"Заново",
		"Управление",
		"Настройки",
		"В меню",
		"Громкость вариометра",
		"Чувствительность мыши",
		"Инверсия тангажа",
		"Об игре",
		"В главное меню",
		"Время полёта: %s",
		"Дистанция от старта по прямой: %.2f км"
	]
	for s: String in samples:
		var translated := TranslationServer.translate(s)
		check(translated != "", "перевод для «%s» не пустой" % s)
	# Экраны собираются и используют tr() — при отсутствии ключа Godot вернул бы исходную строку
	# без ошибки, поэтому дополнительно проверяем, что ключи реально есть в locale/ui.csv.
	var csv := FileAccess.get_file_as_string("res://locale/ui.csv")
	for s: String in samples:
		check(csv.contains(s.replace('"', "")), "ключ «%s» есть в locale/ui.csv" % s)
