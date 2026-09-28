extends Node
## NET-50: экран «Сетевая игра». Адрес сервера переживает «перезапуск» (запись → сброс кеша
## Config → чтение); переходы экрана на подставном клиенте (NetUiFakeBackend): ввод →
## подключение → зона (код и список пилотов), каждая ошибка — свой текст; «сети нет» по
## умолчанию — «Сервер недоступен». Профиль пилота (user://configs/game.json) восстанавливается.

const TMP_DIR := "user://test_net_screen_tmp"
const GAME_JSON := "user://configs/game.json"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _backup() -> Variant:
	return FileAccess.get_file_as_string(GAME_JSON) if FileAccess.file_exists(GAME_JSON) else null


func _restore(raw: Variant) -> void:
	if raw == null:
		if FileAccess.file_exists(GAME_JSON):
			DirAccess.remove_absolute(GAME_JSON)
	else:
		var f := FileAccess.open(GAME_JSON, FileAccess.WRITE)
		f.store_string(String(raw))
		f.close()
	Config.reload()


func _screen(backend: NetUiBackend) -> NetScreen:
	var s: NetScreen = (load("res://scenes/ui/net_screen.tscn") as PackedScene).instantiate()
	s.backend = backend
	s.settings = FlightSettings.defaults()
	add_child(s)
	return s


func _frames(n: int = 2) -> void:
	for i in n:
		await get_tree().process_frame


## Адрес сервера: запись в профиль → сброс кеша Config (как новый запуск) → чтение.
func test_server_address_persists() -> void:
	var raw: Variant = _backup()
	UserSettings.save_server_address("  192.168.1.5:8765 ")
	Config._cache.clear()  # «новый запуск»: конфиги перечитываются с диска
	check(UserSettings.server_address() == "192.168.1.5:8765", "адрес читается после сброса кеша")
	UserSettings.save_server_address("deltaplan.example.org:8765")
	Config.reload()
	check(UserSettings.server_address() == "deltaplan.example.org:8765", "адрес перезаписан")
	# Прочие ключи game.json не затёрты (язык и т. п. живут в том же файле).
	var d := UserSettings.read_json(GAME_JSON)
	check(d.get("net", {}).get("server_address", "") == "deltaplan.example.org:8765", "в файле")
	# Экран подхватывает сохранённый адрес.
	var s := _screen(NetUiFakeBackend.new())
	check(s.server_text() == "deltaplan.example.org:8765", "поле «Сервер» из профиля")
	s.queue_free()
	_restore(raw)
	# Запись в отдельную папку не трогает профиль.
	UserSettings.save_server_address("10.0.0.1:1", TMP_DIR)
	var tmp := UserSettings.read_json(TMP_DIR.path_join("game.json"))
	check(tmp.get("net", {}).get("server_address", "") == "10.0.0.1:1", "запись во временную папку")
	DirAccess.remove_absolute(TMP_DIR.path_join("game.json"))
	DirAccess.remove_absolute(TMP_DIR)
	Config.reload()


## Создать: ввод → «Подключение…» → зона: код крупно и список пилотов с пометками.
func test_create_success_shows_code_and_peers() -> void:
	var raw: Variant = _backup()
	var fake := NetUiFakeBackend.new()
	fake.auto_resolve = false
	var s := _screen(fake)
	check(s.view == NetScreen.View.INPUT, "начало — ввод")
	s.set_server("")
	check(s.get("_create_btn").disabled, "без адреса «Создать» недоступна")
	s.set_server("127.0.0.1:8765")
	s.create_zone()
	check(s.view == NetScreen.View.CONNECTING, "подключение")
	check(fake.created and fake.last_address == "127.0.0.1:8765", "создание с адресом")
	check(fake.last_name == UserSettings.pilot_name(), "имя пилота из настроек")
	check(UserSettings.server_address() == "127.0.0.1:8765", "адрес запомнен при подключении")
	# Место по умолчанию — из «Полёт…»; крыло и прочее — оттуда же.
	var zp := s.zone_params()
	var d := FlightSettings.defaults()
	check(zp.location_id == d.location_id, "место зоны: %s" % zp.location_id)
	check(zp.site_id == d.site_id or d.site_id == "", "старт зоны: %s" % zp.site_id)
	check(zp.wing == d.wing, "крыло из «Полёт…»")
	fake.resolve()
	check(s.view == NetScreen.View.ZONE, "в зоне")
	check(s.code_text() == "4721", "код зоны: %s" % s.code_text())
	var lines := s.peer_lines()
	check(lines.size() == 3, "три пилота: %s" % [lines])
	if lines.size() == 3:
		check(lines[0].begins_with("Папа") and lines[0].contains(tr("net_leader")), "ведущий")
		check(not lines[1].contains(tr("net_leader")), "Мама не ведущая")
		check(lines[2].begins_with("Alex") and lines[2].contains(tr("net_you")), "это вы")
	# Ведущий сменился — список обновился.
	fake.set_peers([
		{"id": "7", "name": "Мама", "join_order": 2, "is_leader": true, "is_me": false},
		{"id": "9", "name": "Alex", "join_order": 3, "is_leader": false, "is_me": true},
	])
	lines = s.peer_lines()
	check(lines.size() == 2 and lines[0].contains(tr("net_leader")), "новый ведущий: %s" % [lines])
	# «Лететь» — параметры зоны наверх.
	var got: Array = []
	s.fly_requested.connect(func(zs: FlightSettings) -> void: got.append(zs))
	s.call("_on_fly")
	check(got.size() == 1 and got[0] is FlightSettings, "fly_requested")
	# Выйти из зоны — снова ввод.
	s.call("_on_leave")
	check(s.view == NetScreen.View.INPUT and s.error_text() == "", "выход из зоны")
	s.queue_free()
	_restore(raw)


## Присоединиться: код — 4 цифры (буквы отбрасываются); каждая ошибка — свой текст.
func test_join_errors_shown() -> void:
	var raw: Variant = _backup()
	var fake := NetUiFakeBackend.new()
	fake.auto_resolve = false
	var s := _screen(fake)
	s.set_server("127.0.0.1:8765")
	s.set_code("12")
	check(s.get("_join_btn").disabled, "короткий код — «Присоединиться» недоступна")
	var edit: LineEdit = s.get("_code_edit")
	edit.text = "4a7b"
	edit.text_changed.emit(edit.text)
	check(edit.text == "47", "в коде только цифры: %s" % edit.text)
	for kind: String in NetUiBackend.ERROR_KINDS:
		check(NetScreen.ERROR_KEYS.has(kind), "текст ошибки %s" % kind)
	for kind in ["unreachable", "zone_not_found", "version_mismatch", "zone_full", "bad_message"]:
		fake.outcome = kind
		s.set_code("4721")
		check(not s.get("_join_btn").disabled, "код из 4 цифр")
		s.join_zone()
		check(s.view == NetScreen.View.CONNECTING, "%s: подключение" % kind)
		check(fake.last_code == "4721" and not fake.created, "%s: вход по коду" % kind)
		fake.resolve()
		check(s.view == NetScreen.View.INPUT, "%s: назад к вводу" % kind)
		var want := tr(NetScreen.ERROR_KEYS[kind])
		var ok: bool = s.error_text() == want and want != NetScreen.ERROR_KEYS[kind]
		check(ok, "%s: «%s»" % [kind, s.error_text()])
	# Успешный вход после ошибки — ошибка пропадает; обрыв в зоне — «связь потеряна».
	fake.outcome = "ok"
	s.join_zone()
	fake.resolve()
	check(s.view == NetScreen.View.ZONE and s.code_text() == "4721", "вход по коду")
	fake.drop()
	check(s.view == NetScreen.View.INPUT, "обрыв: назад к вводу")
	check(s.error_text() == tr(NetScreen.ERROR_KEYS.disconnected), "обрыв: «%s»" % s.error_text())
	# Отмена подключения — ввод без ошибки.
	s.join_zone()
	s.call("_on_cancel")
	check(s.view == NetScreen.View.INPUT and s.error_text() == "", "отмена")
	check(not fake.is_busy(), "отмена отменяет подключение")
	s.queue_free()
	_restore(raw)


## Без клиента сети (по умолчанию) — «Сервер недоступен»; «Назад» закрывает экран.
func test_default_backend_unreachable_and_back() -> void:
	var raw: Variant = _backup()
	var s := _screen(null)
	s.set_server("127.0.0.1:1")
	s.create_zone()
	await _frames()
	check(s.view == NetScreen.View.INPUT, "назад к вводу")
	check(s.error_text() == tr(NetScreen.ERROR_KEYS.unreachable), "«%s»" % s.error_text())
	var closed := [false]
	s.closed.connect(func() -> void: closed[0] = true)
	s.go_back()
	check(closed[0], "«Назад» — closed")
	s.queue_free()
	_restore(raw)


## Главное меню: кнопка «Сетевая игра» шлёт net_requested.
func test_start_menu_button() -> void:
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	add_child(m)
	var got := [false]
	m.net_requested.connect(func() -> void: got[0] = true)
	var found := false
	for b in m.find_children("*", "Button", true, false):
		if (b as Button).text == tr("menu_net_game"):
			found = true
			(b as Button).pressed.emit()
	check(found, "кнопка «Сетевая игра» есть")
	check(got[0], "net_requested")
	m.queue_free()
