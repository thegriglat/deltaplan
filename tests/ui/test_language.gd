extends Node
## Язык интерфейса (NFR-4): у каждого ключа tr() есть ru и en, в коде нет tr() с русским текстом
## вместо ключа, названия из конфигов — ключи, переключение языка работает и перестраивает меню.

const CSV := "res://locale/ui.csv"
const TMP_DIR := "user://test_language_tmp"
const MAIN_SCENE := "res://scenes/main.tscn"
const MAX_MENU_FRAMES := 600
## Ключи, которые код собирает не литералом tr("…"), а из списков/констант.
const CODE_SCANS := ["res://scripts", "res://scenes"]

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## {ключ: [ru, en]} из locale/ui.csv.
static func load_csv() -> Dictionary:
	var out := {}
	var f := FileAccess.open(CSV, FileAccess.READ)
	if f == null:
		return out
	var header := f.get_csv_line()
	var i_ru := header.find("ru")
	var i_en := header.find("en")
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() < 3 or row[0] == "":
			continue
		out[row[0]] = [row[i_ru], row[i_en]]
	return out


func test_every_csv_key_has_ru_and_en() -> void:
	var rows := load_csv()
	check(rows.size() > 200, "в ui.csv есть строки: %d" % rows.size())
	var key_re := RegEx.create_from_string("^[a-z][a-z0-9_]*$")
	for k: String in rows:
		check(key_re.search(k) != null, "ключ в стиле snake_case: «%s»" % k)
		check(String(rows[k][0]).strip_edges() != "", "нет ru у %s" % k)
		check(String(rows[k][1]).strip_edges() != "", "нет en у %s" % k)
		check(not _has_cyrillic(String(rows[k][1])), "en по-русски у %s: %s" % [k, rows[k][1]])


## Все tr("…") / translate("…") в коде: ключ есть в ui.csv, и это ключ, а не русский текст.
func test_code_keys_exist_and_are_not_russian() -> void:
	var rows := load_csv()
	var call_re := RegEx.create_from_string(
		"\\b(?:tr|translate)\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
	)
	var files: PackedStringArray = []
	for d: String in CODE_SCANS:
		_find_gd(d, files)
	check(files.size() > 50, "просканированы скрипты: %d" % files.size())
	var used := 0
	for p in files:
		var src := FileAccess.get_file_as_string(p)
		for m in call_re.search_all(src):
			var key := m.get_string(1)
			used += 1
			check(not _has_cyrillic(key), "%s: tr() с русским текстом вместо ключа: «%s»" % [p, key])
			check(rows.has(key), "%s: ключа «%s» нет в ui.csv" % [p, key])
	check(used > 150, "найдены вызовы tr(): %d" % used)
	# ключи из констант (страницы планшета, месяцы)
	for key: String in InstrumentDisplay.PAGE_TITLES:
		check(rows.has(key), "страница планшета: нет ключа %s" % key)
	for key: String in FlightSetupScreen.MONTHS:
		check(rows.has(key), "месяц: нет ключа %s" % key)


## Названия, которые берутся из конфигов (крылья, погода, места, старты, пресеты, подсказки
## управления, тексты столкновений) — ключи ui.csv.
func test_config_names_are_keys() -> void:
	var rows := load_csv()
	var names: PackedStringArray = []
	for w in Config.list_configs("wings"):
		names.append(String(Config.get_config(w).get("name", "")))
	for w in Config.list_configs("weather"):
		names.append(String(Config.get_config(w).get("name", "")))
	for l in Config.list_configs("locations"):
		var loc := Config.get_config(l)
		names.append(String(loc.get("name", "")))
		for st: Dictionary in loc.get("start_sites", []):
			names.append(String(st.get("name", "")))
	var game := Config.get_config("game")
	for g: String in game.get("graphics_presets", {}):
		if not g.begins_with("_"):
			names.append(String(game.graphics_presets[g].get("name", "")))
	for k: String in game.get("collision_texts", {}):
		if not k.begins_with("_"):
			names.append(String(game.collision_texts[k]))
	for r: Dictionary in Config.get_config("ui").get("controls_help", []):
		names.append(String(r.get("section", r.get("text", ""))))
	var presets: Dictionary = Config.get_config("audio").get("vario_audio", {}).get("presets", {})
	for k: String in presets:
		if presets[k] is Dictionary:
			names.append(String(presets[k].get("title", "")))
	names.append(String(Config.value("world", "map_picker.attribution", "")))
	check(names.size() > 30, "собраны названия: %d" % names.size())
	for n in names:
		check(rows.has(n), "название из конфига не ключ ui.csv: «%s»" % n)


func test_resolve_default_by_os_locale() -> void:
	check(Language.resolve("", "ru_RU") == "ru", "ОС по-русски — русский")
	check(Language.resolve("", "ru") == "ru", "ru — русский")
	check(Language.resolve("", "en_US") == "en", "ОС по-английски — английский")
	check(Language.resolve("", "de_DE") == "en", "другая ОС — английский")
	check(Language.resolve("en", "ru_RU") == "en", "выбор пилота важнее ОС")
	check(Language.resolve("xx", "ru_RU") == "ru", "неизвестный выбор — по ОС")
	check(Language.neighbour("ru", 1) == "en" and Language.neighbour("en", 1) == "ru", "по кругу")


func test_switch_locale_translates_and_persists() -> void:
	var was := TranslationServer.get_locale()
	check(Language.select("en", TMP_DIR), "запись выбора")
	check(tr("menu_fly") == "Fly", "en: %s" % tr("menu_fly"))
	check(tr("wing_kingpost") == "Kingpost", "en крыло: %s" % tr("wing_kingpost"))
	var saved := UserSettings.read_json(TMP_DIR.path_join("game.json"))
	check(String(saved.get("language", "")) == "en", "выбор записан: %s" % saved)
	Language.apply("ru")
	check(tr("menu_fly") == "Лететь", "ru: %s" % tr("menu_fly"))
	check(tr("wing_kingpost") == "Мачтовое", "ru крыло: %s" % tr("wing_kingpost"))
	Language.apply(was)
	DirAccess.remove_absolute(TMP_DIR.path_join("game.json"))
	DirAccess.remove_absolute(TMP_DIR)


## Кнопка «▶» в главном меню: язык сменился, экраны перестроены на нём, без ошибок в логе.
func test_main_menu_selector_rebuilds_ui() -> void:
	var was := TranslationServer.get_locale()
	Language.apply("ru")
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	main.set("user_config_dir", TMP_DIR)
	add_child(main)
	Language.apply("ru")  # _enter_tree поставил язык по настройкам — тест начинает с русского
	main.call("_rebuild_ui")
	var game: Game = main.get_node("Game")
	for i in MAX_MENU_FRAMES:
		if game.settings != null:
			break
		await get_tree().process_frame
	var old_menu: StartMenu = main.get_node("UI/StartMenu")
	check(old_menu.get("_fly_btn").text == "Лететь", "меню по-русски")
	var next: Button = null
	for b in old_menu.find_children("*", "Button", true, false):
		if (b as Button).text == "▶":
			next = b
	check(next != null, "в меню есть переключатель языка")
	if next != null:
		next.emit_signal("pressed")
	for i in 3:
		await get_tree().process_frame
	var menu: StartMenu = main.get_node("UI/StartMenu")
	check(menu != old_menu, "меню перестроено")
	check(TranslationServer.get_locale() == "en", "язык en: %s" % TranslationServer.get_locale())
	check(menu.get("_fly_btn").text == "Fly", "«Лететь» → %s" % menu.get("_fly_btn").text)
	var pause: PauseMenu = main.get_node("UI/PauseMenu")
	var texts: Array = []
	for b in pause.find_children("*", "Button", true, false):
		texts.append((b as Button).text)
	check(texts.has("Continue"), "пауза по-английски: %s" % [texts])
	check(not menu.get("_summary").text.contains("Алтай"), "выбор — по-английски")
	check(main.get("start_menu") == menu, "main знает новое меню")
	main.call("_on_language_requested", "ru")
	for i in 3:
		await get_tree().process_frame
	menu = main.get_node("UI/StartMenu")
	check(menu.get("_fly_btn").text == "Лететь", "обратно по-русски")
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
	OS.remove_logger(catcher)
	for e in catcher.errors:
		failures.append("ошибка в логе: " + e)
	Language.apply(was)
	DirAccess.remove_absolute(TMP_DIR.path_join("game.json"))
	DirAccess.remove_absolute(TMP_DIR)


static func _has_cyrillic(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x0400 and c <= 0x04FF:
			return true
	return false


static func _find_gd(dir: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_find_gd(dir.path_join(sub), out)
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
