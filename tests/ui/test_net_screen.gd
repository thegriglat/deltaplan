extends Node
## NET-50: экран «Сетевая игра». Адрес сервера переживает «перезапуск» (запись → сброс кеша
## Config → чтение); переходы экрана на подставном клиенте (NetUiFakeBackend): ввод →
## подключение → зона (код и список пилотов), каждая ошибка — свой текст; «сети нет» по
## умолчанию — «Сервер недоступен». Профиль пилота (user://configs/game.json) восстанавливается.

const TMP_DIR := "user://test_net_screen_tmp"
const GAME_JSON := "user://configs/game.json"
const NET_CLIENT_SCRIPT := preload("res://scripts/net/net_client.gd")
const NET_ZONE_SCRIPT := preload("res://scripts/net/net_zone.gd")

var failures: PackedStringArray = []


## Подставной NetClient для тестов повторов первого подключения (К1 edfe390): только сигналы и
## свойства, которые трогает NetUiClientBackend — реальных попыток/таймеров нет, повторы и
## исход эмитируются тестом вручную.
class FakeRetryClient:
	extends Node
	signal connected(reconnect: bool)
	signal disconnected(will_reconnect: bool)
	signal reconnecting(attempt: int)
	signal error(code: String, text: String)

	var is_online := false
	var state := 0  # NetClient.State.IDLE
	var address := ""

	func connect_to_server(addr: String, _name: String) -> bool:
		address = addr
		state = 1  # не IDLE — как реальный CONNECTING
		return true

	func disconnect_from_server() -> void:
		state = 0
		is_online = false


## Подставная NetZone для тех же тестов — зона входится вручную через zone_entered.emit().
class FakeRetryZone:
	extends Node
	signal zone_entered(code: String)
	signal zone_left
	signal zone_error(code: String, text: String)
	signal peer_joined(peer: Dictionary)
	signal peer_left(id: String)
	signal leader_changed(id: String, is_me: bool)

	var code := ""
	var peers: Dictionary = {}
	var leader_id := ""
	var my_id := ""
	var zone_settings: FlightSettings = null

	func create_zone(_params: FlightSettings, _world_seed: int, _bots: int) -> void:
		pass

	func join_zone(_code: String) -> void:
		pass

	func leave_zone() -> void:
		pass


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
	check(
		not s.get("_create_btn").disabled,
		"без адреса «Создать» доступна (NET-22: встроенный сервер)"
	)
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


## NET-53: «Создать» без адреса — на встроенном сервере (адрес "" уходит в backend);
## с адресом — как раньше, на указанном сервере.
func test_create_embedded_vs_remote_address() -> void:
	var raw: Variant = _backup()
	var fake := NetUiFakeBackend.new()
	fake.auto_resolve = false
	var s := _screen(fake)
	s.set_server("")
	check(not s.get("_create_btn").disabled, "без адреса «Создать» доступна")
	s.create_zone()
	check(fake.last_address == "", "создание без адреса — встроенный сервер (NET-22)")
	fake.resolve()
	s.call("_on_leave")
	s.set_server("127.0.0.1:8765")
	s.create_zone()
	check(fake.last_address == "127.0.0.1:8765", "создание с адресом — указанный сервер")
	fake.resolve()
	s.call("_on_leave")
	s.queue_free()
	_restore(raw)


## NET-53: «Рядом» — зоны в локальной сети (NET-23). Пусто → короткая строка; две зоны —
## код и имя хоста; другая версия — с пометкой и без входа; ui_down + ui_accept — вход
## ровно одним Enter в зону выбранной строки.
func test_nearby_list() -> void:
	var raw: Variant = _backup()
	var fake := NetUiFakeBackend.new()
	var s := _screen(fake)
	check(s.view == NetScreen.View.INPUT, "начало — ввод")
	var list: ItemList = s.get("_nearby_list")
	var empty_label: Label = s.get("_nearby_empty")
	check(not list.visible and empty_label.visible, "пусто — список скрыт, строка видна")
	check(empty_label.text == tr("net_nearby_empty"), "«%s»" % empty_label.text)

	fake.set_nearby(
		[
			{
				"code": "4721",
				"host_name": "Коля",
				"address": "192.168.1.5",
				"port": 8765,
				"game_version": "0.7.1",
				"pilots_count": 2,
				"same_version": true,
			},
			{
				"code": "1234",
				"host_name": "Оля",
				"address": "192.168.1.6",
				"port": 8765,
				"game_version": "0.6.0",
				"pilots_count": 1,
				"same_version": false,
			},
		]
	)
	check(list.visible and not empty_label.visible, "список виден, строка «пусто» скрыта")
	check(list.item_count == 2, "две строки: %d" % list.item_count)
	check(
		list.get_item_text(0).contains("4721") and list.get_item_text(0).contains("Коля"), "код+хост"
	)
	check(
		list.get_item_text(1).contains(tr("net_nearby_other_version")),
		"другая версия помечена: %s" % list.get_item_text(1)
	)

	fake.auto_resolve = false
	await _frames()  # дать разрешиться отложенному grab_focus из первого _show_view(INPUT)
	list.grab_focus()
	var down := InputEventAction.new()
	down.action = "ui_down"
	down.pressed = true
	list.get_viewport().push_input(down)
	await _frames()
	check(
		list.get_selected_items() == PackedInt32Array([1]),
		"стрелка вниз — вторая строка: %s" % [list.get_selected_items()]
	)
	var accept := InputEventAction.new()
	accept.action = "ui_accept"
	accept.pressed = true
	list.get_viewport().push_input(accept)
	await _frames()
	check(s.view == NetScreen.View.INPUT, "другая версия — Enter не входит")
	check(not fake.is_busy(), "подключение не начато")

	var up := InputEventAction.new()
	up.action = "ui_up"
	up.pressed = true
	list.get_viewport().push_input(up)
	await _frames()
	check(list.get_selected_items() == PackedInt32Array([0]), "стрелка вверх — первая строка")
	list.get_viewport().push_input(accept)
	await _frames()
	check(s.view == NetScreen.View.CONNECTING, "Enter — вход одним нажатием")
	check(
		fake.last_address == "192.168.1.5:8765" and fake.last_code == "4721" and not fake.created,
		"адрес и код выбранной зоны: %s / %s" % [fake.last_address, fake.last_code]
	)
	fake.resolve()
	check(s.view == NetScreen.View.ZONE, "в зоне")
	s.call("_on_leave")
	s.queue_free()
	_restore(raw)


## «Сети нет» (NetUiBackend) — «Сервер недоступен»; «Назад» закрывает экран.
func test_no_network_unreachable_and_back() -> void:
	var raw: Variant = _backup()
	var s := _screen(NetUiBackend.new())
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


## release_to_flight (NET-40/К3): «Лететь» — экран прячется, зону НЕ покидает (в отличие от
## обычного скрытия/Esc/«Назад» в разгаре зоны, которое зону покидает). Идемпотентен.
func test_release_to_flight_keeps_zone() -> void:
	var raw: Variant = _backup()
	var fake := NetUiFakeBackend.new()
	var s := _screen(fake)
	s.set_server("127.0.0.1:8765")
	s.create_zone()
	fake.resolve()
	check(s.view == NetScreen.View.ZONE, "в зоне")
	fake.stop_nearby_calls = 0
	s.release_to_flight()
	check(not s.visible, "экран спрятан")
	check(fake.stop_nearby_calls == 1, "stop_nearby позвана")
	check(fake.code() == "4721", "зону НЕ покинули")
	# Идемпотентность: повторный вызов ничего не портит.
	s.release_to_flight()
	check(fake.stop_nearby_calls == 1, "повторный release_to_flight — без лишних stop_nearby")
	check(fake.code() == "4721", "зона всё ещё держится")
	s.queue_free()
	fake.leave()
	_restore(raw)


## Обычное скрытие экрана в разгаре зоны — прежнее поведение: зону покидаем.
func test_normal_hide_in_zone_still_leaves() -> void:
	var raw: Variant = _backup()
	var fake := NetUiFakeBackend.new()
	var s := _screen(fake)
	s.set_server("127.0.0.1:8765")
	s.create_zone()
	fake.resolve()
	check(s.view == NetScreen.View.ZONE, "в зоне")
	s.visible = false
	check(fake.code() == "", "обычное скрытие — зону покинули")
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


## Экран по умолчанию — настоящий клиент (NetUiClientBackend на автозагрузках).
## Неразборчивый адрес — «Сервер недоступен» сразу, без сети.
func test_default_backend_is_client_bad_address() -> void:
	var raw: Variant = _backup()
	var s := _screen(null)
	check(s.backend is NetUiClientBackend, "по умолчанию — NetUiClientBackend")
	check((s.backend as NetUiClientBackend).client != null, "есть автозагрузка NetClient")
	s.set_server("host:port")
	s.create_zone()
	await _frames()
	check(s.view == NetScreen.View.INPUT, "назад к вводу")
	check(s.error_text() == tr(NetScreen.ERROR_KEYS.unreachable), "«%s»" % s.error_text())
	s.queue_free()
	_restore(raw)


## Переходник: ошибки NetClient/NetZone → виды ошибок экрана; вход в зону → код и пилоты
## (ведущий, «вы», порядок подключения); зона потеряна → "disconnected".
func test_client_backend_maps_signals() -> void:
	var client: Node = NET_CLIENT_SCRIPT.new()
	add_child(client)
	var zone: Node = NET_ZONE_SCRIPT.new()
	zone.setup(client)
	add_child(zone)
	var b := NetUiClientBackend.new(client, zone)
	var got: Array = []
	b.failed.connect(func(k: String) -> void: got.append(k))
	for pair: Array in [
		["ZONE_NOT_FOUND", "zone_not_found"],
		["ZONE_FULL", "zone_full"],
		["VERSION_MISMATCH", "version_mismatch"],
		["CONNECT_FAILED", "unreachable"],
		["BAD_MESSAGE", "bad_message"],
		["PORT_BUSY", "port_busy"],
		["SERVER_FAILED", "server_failed"],
	]:
		got.clear()
		b.connect_and_join("127.0.0.1:1", "Тест", "4721")
		check(b.is_busy(), "%s: подключение" % pair[0])
		zone.zone_error.emit(pair[0], "")
		check(got == [pair[1]], "%s → %s: %s" % [pair[0], pair[1], got])
		check(not b.is_busy(), "%s: не занят" % pair[0])
	await _frames()
	got.clear()
	var joined: Array = []
	b.zone_joined.connect(func(c: String) -> void: joined.append(c))
	b.connect_and_join("127.0.0.1:1", "Alex", "4721")
	zone.code = "4721"
	zone.leader_id = "3"
	client.my_id = "9"
	zone.peers = {
		"9": {"id": "9", "name": "Alex", "joinOrder": 3},
		"3": {"id": "3", "name": "Папа", "joinOrder": 1},
	}
	zone.zone_entered.emit("4721")
	check(joined == ["4721"] and b.code() == "4721", "вход: %s" % [joined])
	var ps := b.peers()
	check(ps.size() == 2, "два пилота")
	if ps.size() == 2:
		check(ps[0].name == "Папа" and ps[0].is_leader and not ps[0].is_me, "ведущий первым")
		check(ps[1].name == "Alex" and ps[1].is_me and not ps[1].is_leader, "это вы")
	zone.zone_left.emit()
	check(got == ["disconnected"], "зона потеряна: %s" % [got])
	check(b.code() == "" and b.peers().is_empty(), "вне зоны")
	b.leave()
	await _frames()
	client.queue_free()
	zone.queue_free()


## NET-53/NET-22: «Создать» без адреса — на встроенном сервере в этой же игре (LocalServer):
## сквозной путь без внешнего сервера — подключение и создание зоны проходят по-настоящему.
## С адресом — обычное подключение (без встроенного сервера).
## Свободный TCP-порт: пробуем подряд с 38000.
func _free_port() -> int:
	for port in range(38000, 38200):
		var srv := TCPServer.new()
		if srv.listen(port, "127.0.0.1") == OK:
			srv.stop()
			return port
	return 0


func test_client_backend_create_embedded_vs_remote() -> void:
	var client: Node = NET_CLIENT_SCRIPT.new()
	add_child(client)
	var zone: Node = NET_ZONE_SCRIPT.new()
	zone.setup(client)
	add_child(zone)
	var b := NetUiClientBackend.new(client, zone)
	b.embedded_port = _free_port()  # 8080 на машине может быть занят посторонним процессом
	var got: Array = []
	b.failed.connect(func(k: String) -> void: got.append(k))
	var joined: Array = []
	b.zone_joined.connect(func(c: String) -> void: joined.append(c))
	b.connect_and_create("", "Alex", FlightSettings.defaults())
	for i in 60:
		await get_tree().process_frame
		if not joined.is_empty() or not got.is_empty():
			break
	check(
		joined.size() == 1 and got.is_empty(),
		"без адреса — зона на встроенном сервере: %s / %s" % [joined, got]
	)
	check(b.code() != "", "код зоны: %s" % b.code())
	b.leave()
	await _frames()
	check(not b.is_busy(), "не занят после leave")
	got.clear()
	joined.clear()
	b.connect_and_create("host.invalid:1", "Alex", FlightSettings.defaults())
	check(b.is_busy(), "с адресом — обычное подключение начато (без встроенного сервера)")
	b.leave()
	await _frames()
	client.queue_free()
	zone.queue_free()


## Повторы первого подключения (К1 edfe390): NetClient шлёт reconnecting(attempt) между
## попытками и disconnected(true) он вообще не шлёт до Welcome — экран остаётся на
## «Подключение…», ни одна из них не гасит его в ошибку. Успех — обычный connected(false).
func test_client_backend_survives_first_connect_retries_then_zone() -> void:
	var raw: Variant = _backup()
	var fc := FakeRetryClient.new()
	var fz := FakeRetryZone.new()
	add_child(fc)
	add_child(fz)
	var b := NetUiClientBackend.new(fc, fz)
	var s := _screen(b)
	s.set_server("127.0.0.1:8765")
	s.set_code("4721")
	s.join_zone()
	check(s.view == NetScreen.View.CONNECTING, "подключение начато")
	fc.reconnecting.emit(1)
	check(s.view == NetScreen.View.CONNECTING, "reconnecting(1) — экран не меняется")
	fc.reconnecting.emit(2)
	check(s.view == NetScreen.View.CONNECTING, "reconnecting(2) — экран не меняется")
	fc.connected.emit(false)  # Welcome пришёл — первое подключение, не переподключение
	fz.code = "4721"
	fz.zone_entered.emit("4721")
	check(s.view == NetScreen.View.ZONE, "в зоне после повторов: %s" % s.view)
	check(s.code_text() == "4721", "код зоны: %s" % s.code_text())
	s.queue_free()
	fc.queue_free()
	fz.queue_free()
	_restore(raw)


## Повторы кончились без успеха — только тогда CONNECT_FAILED/disconnected(false) → «Сервер
## недоступен»; до этого экран держит «Подключение…».
func test_client_backend_shows_unreachable_after_final_connect_failed() -> void:
	var raw: Variant = _backup()
	var fc := FakeRetryClient.new()
	var fz := FakeRetryZone.new()
	add_child(fc)
	add_child(fz)
	var b := NetUiClientBackend.new(fc, fz)
	var s := _screen(b)
	s.set_server("127.0.0.1:8765")
	s.set_code("4721")
	s.join_zone()
	fc.reconnecting.emit(1)
	fc.reconnecting.emit(2)
	fc.reconnecting.emit(3)
	check(s.view == NetScreen.View.CONNECTING, "всё ещё повторы — без ошибки")
	fc.error.emit("CONNECT_FAILED", "cannot connect: timeout (after 3 retries)")
	fc.disconnected.emit(false)
	check(s.view == NetScreen.View.INPUT, "повторы кончились — назад к вводу")
	check(s.error_text() == tr(NetScreen.ERROR_KEYS.unreachable), "«%s»" % s.error_text())
	s.queue_free()
	fc.queue_free()
	fz.queue_free()
	_restore(raw)


## «Отмена» в разгаре повторов — подключение остановлено, ошибка после этого не всплывает
## (leave() гасит _busy, следующие сигналы клиента уже ни на что не влияют).
func test_client_backend_cancel_during_retries_shows_no_error() -> void:
	var raw: Variant = _backup()
	var fc := FakeRetryClient.new()
	var fz := FakeRetryZone.new()
	add_child(fc)
	add_child(fz)
	var b := NetUiClientBackend.new(fc, fz)
	var s := _screen(b)
	s.set_server("127.0.0.1:8765")
	s.set_code("4721")
	s.join_zone()
	fc.reconnecting.emit(1)
	s.call("_on_cancel")
	check(s.view == NetScreen.View.INPUT and s.error_text() == "", "отмена без ошибки")
	check(not b.is_busy(), "отмена остановила подключение")
	# Запоздавший сигнал уже отменённого подключения — экран не трогает.
	fc.error.emit("CONNECT_FAILED", "too late")
	fc.disconnected.emit(false)
	check(s.view == NetScreen.View.INPUT and s.error_text() == "", "запоздавшая ошибка — молча")
	s.queue_free()
	fc.queue_free()
	fz.queue_free()
	_restore(raw)


## S5 (ST-8): Steam неактивен — экран как был: нет «Друзья в игре» и «Пригласить друзей».
func test_steam_ui_hidden_without_steam() -> void:
	var raw: Variant = _backup()
	for b: NetUiBackend in [NetUiFakeBackend.new(), NetUiBackend.new()]:
		var s := _screen(b)
		check(not b.steam_available() and b.friends_zones().is_empty(), "Steam неактивен — пусто")
		check(s.get("_friends_list") == null and not s.has_invite_button(), "нет Steam-элементов")
		check(s.friend_lines().is_empty(), "строк друзей нет")
		s.queue_free()
	_restore(raw)


## S5 (ST-8): Steam активен — «Друзья в игре» (другая версия — тускло, не войти), вход в лобби
## друга, «Пригласить друзей» в зоне; вход, начатый самим клиентом (приглашение), — «Подключение…».
func test_steam_friends_and_invite() -> void:
	var raw: Variant = _backup()
	var fake := NetUiFakeBackend.new()
	fake.fake_steam = true
	fake.auto_resolve = false
	var s := _screen(fake)
	var empty_label: Label = s.get("_friends_empty")
	check(s.friend_lines().is_empty() and empty_label.visible, "друзей нет — подсказка")
	fake.set_friends(
		[
			{"lobby_id": 101, "friend_name": "Мама", "zone_code": "4721", "place": "Юца", "same_version": true},
			{"lobby_id": 202, "friend_name": "Оля", "zone_code": "1234", "place": "Таганай", "same_version": false},
		]
	)
	var lines := s.friend_lines()
	check(lines.size() == 2 and not empty_label.visible, "две строки: %s" % [lines])
	if lines.size() == 2:
		check(lines[0].contains("Мама") and lines[0].contains("Юца") and lines[0].contains("4721"), lines[0])
		check(lines[1].contains(tr("net_nearby_other_version")), "другая версия: %s" % lines[1])
	s.call("_on_friend_activated", 1)
	check(s.view == NetScreen.View.INPUT and fake.last_lobby == 0, "другая версия — не входим")
	s.call("_on_friend_activated", 0)
	check(s.view == NetScreen.View.CONNECTING and fake.last_lobby == 101, "вход в лобби друга")
	fake.resolve()
	check(s.view == NetScreen.View.ZONE and s.code_text() == "4721", "в зоне друга: %s" % s.code_text())
	check(s.has_invite_button(), "кнопка «Пригласить друзей»")
	var btn: Button = s.get("_invite_btn")
	btn.pressed.emit()
	check(fake.invite_calls == 1, "оверлей приглашения")
	s.call("_on_leave")
	# Приглашение приняли, пока экран открыт: клиент сам начал вход — экран показывает подключение.
	fake.connect_and_join_lobby(101, "Я")
	check(s.view == NetScreen.View.CONNECTING, "вход по приглашению — «Подключение…»")
	fake.resolve()
	check(s.view == NetScreen.View.ZONE, "в зоне")
	s.call("_on_leave")
	s.queue_free()
	_restore(raw)
