class_name NetUiClientBackend
extends NetUiBackend
## Настоящий клиент сети для экрана «Сетевая игра»: переходник NetClient + NetZone
## (автозагрузки, scripts/net/) → интерфейс NetUiBackend. Порядок: connect_to_server →
## Welcome (connected) → create_zone / join_zone → zone_entered. Коды ошибок сети → виды
## ошибок экрана (ERROR_MAP). Автозагрузок нет — ведёт себя как NetUiBackend («недоступен»).

## Код ошибки NetClient/NetZone → вид ошибки экрана.
const ERROR_MAP := {
	"CONNECT_FAILED": "unreachable",
	"BAD_ADDRESS": "unreachable",
	"ZONE_NOT_FOUND": "zone_not_found",
	"VERSION_MISMATCH": "version_mismatch",
	"ZONE_FULL": "zone_full",
	"BAD_MESSAGE": "bad_message",
	"PORT_BUSY": "port_busy",
	"SERVER_FAILED": "server_failed",
}

var client: Node
var zone: Node
var lan: Node  ## LanDiscovery (NET-23): автозагрузка или переданный экземпляр (тесты).

var _mode := ""  ## "create" | "join" — что сделать после Welcome
var _params: FlightSettings  ## создание: параметры зоны; вход: свои крыло и масса
var _join_code := ""
var _busy := false
var _in_zone := false
## «Создать» без адреса — зона на встроенном сервере (zone.host_local, NET-22): не звать
## _send_request() по client.connected — host_local сам подключает и создаёт зону.
var _using_embedded := false


## client/zone/p_lan — экземпляры для тестов; по умолчанию — автозагрузки NetClient/NetZone/
## LanDiscovery.
func _init(p_client: Node = null, p_zone: Node = null, p_lan: Node = null) -> void:
	client = p_client
	zone = p_zone
	lan = p_lan
	var tree := Engine.get_main_loop() as SceneTree
	if client == null and tree != null:
		client = tree.root.get_node_or_null("NetClient")
	if zone == null and tree != null:
		zone = tree.root.get_node_or_null("NetZone")
	if lan == null and tree != null:
		lan = tree.root.get_node_or_null("LanDiscovery")
	if lan != null:
		lan.zones_changed.connect(func() -> void: nearby_changed.emit())
	if client == null or zone == null:
		return
	client.connected.connect(_on_connected)
	client.disconnected.connect(_on_disconnected)
	client.error.connect(_on_error)
	zone.zone_entered.connect(_on_zone_entered)
	zone.zone_left.connect(_on_zone_left)
	zone.zone_error.connect(_on_error)
	zone.peer_joined.connect(func(_p: Dictionary) -> void: peers_changed.emit())
	zone.peer_left.connect(func(_id: String) -> void: peers_changed.emit())
	zone.leader_changed.connect(func(_id: String, _me: bool) -> void: peers_changed.emit())


## address == "" (NET-22): без адреса сервера — зона на встроенном сервере (zone.host_local);
## остальные подключаются по адресу этого компьютера в локальной сети. С адресом — как раньше.
func connect_and_create(address: String, name: String, zone_params: FlightSettings) -> void:
	if client == null or zone == null:
		super.connect_and_create(address, name, zone_params)
		return
	_mode = "create"
	_params = zone_params.duplicate() if zone_params != null else FlightSettings.defaults()
	if address == "":
		_using_embedded = true
		_in_zone = false
		if client.is_online or int(client.state) != 0:  # свежее подключение для host_local
			client.disconnect_from_server()
		_busy = true
		state_changed.emit()
		var bots := int(Config.value("bots", "count", 0))
		zone.host_local(_params, randi() & 0x7fffffff, maxi(bots, 0), name)
	else:
		_using_embedded = false
		_start(address, name)


func connect_and_join(address: String, name: String, zone_code: String) -> void:
	if client == null or zone == null:
		super.connect_and_join(address, name, zone_code)
		return
	_mode = "join"
	_join_code = zone_code
	_params = UserSettings.load_last_flight()
	_using_embedded = false
	_start(address, name)


func leave() -> void:
	var was := _busy or _in_zone
	_busy = false
	_in_zone = false
	_mode = ""
	_using_embedded = false
	if zone != null:
		zone.leave_zone()  # был встроенный сервер (host_local) — NetZone его тоже останавливает
	if client != null:
		client.disconnect_from_server()
	if was:
		state_changed.emit()


func code() -> String:
	return String(zone.code) if _in_zone and zone != null else ""


func peers() -> Array:
	if not _in_zone or zone == null:
		return []
	var out: Array = []
	for p: Dictionary in zone.peers.values():
		var id := String(p.get("id", ""))
		out.append(
			{
				"id": id,
				"name": String(p.get("name", "")),
				"join_order": int(p.get("joinOrder", 0)),
				"is_leader": id == String(zone.leader_id),
				"is_me": id == String(zone.my_id),
			}
		)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.join_order < b.join_order)
	return out


func is_busy() -> bool:
	return _busy


## Мир зоны (место, дата, время, погода) со своими крылом и массой.
func zone_settings() -> FlightSettings:
	if not _in_zone or zone == null or zone.zone_settings == null:
		return null
	var s: FlightSettings = zone.zone_settings.duplicate()
	if _params != null:
		s.wing = _params.wing
		s.pilot_mass_kg = _params.pilot_mass_kg
	return s


func _start(address: String, name: String) -> void:
	_in_zone = false
	var reuse: bool = client.is_online and String(client.address) == address
	if not reuse and int(client.state) != 0:  # не IDLE: старое соединение закрыть, пока не заняты
		client.disconnect_from_server()
	_busy = true
	state_changed.emit()
	if reuse:
		_send_request()
	else:
		client.connect_to_server(address, name)


func _send_request() -> void:
	if _mode == "create":
		var bots := int(Config.value("bots", "count", 0))
		zone.create_zone(_params, randi() & 0x7fffffff, maxi(bots, 0))
	elif _mode == "join":
		zone.join_zone(_join_code)


func _on_connected(reconnect: bool) -> void:
	# host_local (встроенный сервер) сам подключает и создаёт зону — не дублировать.
	if _busy and not reconnect and not _using_embedded:
		_send_request()


## NetClient повторяет и первое подключение (reconnect_delays_s): пока идут попытки, он шлёт
## только reconnecting(attempt), на который мы не подписаны — экран остаётся на «Подключение…».
## disconnected(true) NetClient шлёт только после Welcome (обрыв уже идущей сессии), не во время
## первых попыток; сюда попадает только will_reconnect=false — обрыв окончательный.
func _on_disconnected(will_reconnect: bool) -> void:
	if _busy and not will_reconnect:
		_fail("unreachable")


## error("CONNECT_FAILED") NetClient шлёт один раз — когда повторы кончились (перед
## disconnected(false)); _fail() сразу гасит _busy, так что следующий disconnected(false)
## по тому же обрыву уже не позовёт _fail() второй раз.
func _on_error(err_code: String, _text: String) -> void:
	if _busy:
		_fail(String(ERROR_MAP.get(err_code, "bad_message")))


func _on_zone_entered(zone_code: String) -> void:
	if not _busy and _in_zone:
		peers_changed.emit()  # вернулись в зону после переподключения
		return
	if not _busy:
		return
	_busy = false
	_in_zone = true
	zone_joined.emit(zone_code)
	peers_changed.emit()
	state_changed.emit()


func _on_zone_left() -> void:
	if not _in_zone:
		return
	_in_zone = false
	_disconnect_later()
	failed.emit("disconnected")
	state_changed.emit()


func _fail(kind: String) -> void:
	_busy = false
	_mode = ""
	_disconnect_later()
	failed.emit(kind)
	state_changed.emit()


## Отключиться после текущего сигнала сети (не рвать сокет посреди его же обработки);
## если к тому времени уже подключаемся заново — не трогать.
func _disconnect_later() -> void:
	if client != null:
		_drop_if_idle.bind(client, weakref(self)).call_deferred()


## Без ссылок класса на само себя по имени (NetUiClientBackend.… / тип переменной): у Godot они
## дают цикл скриптов — при выходе «ObjectDB instances were leaked», «resources still in use».
static func _drop_if_idle(c: Node, me: WeakRef) -> void:
	var b: Object = me.get_ref()
	if not is_instance_valid(c):
		return
	if b == null or (not b._busy and not b._in_zone):
		c.disconnect_from_server()


# ---------------------------------------------------------------- NET-23: зоны рядом (LanDiscovery)


## Зоны в локальной сети — LanDiscovery.zones (уже с полем same_version).
func nearby() -> Array:
	return lan.zones if lan != null else []


## Экран «Сетевая игра» открылся — начать слушать объявления (NET-23). Одновременно на этой
## машине слушать может только один процесс: start_listening() тогда вернёт false — список
## остаётся пустым, без ошибки (не наша забота).
func start_nearby() -> void:
	if lan != null and lan.has_method("start_listening"):
		lan.start_listening()


## Экран закрылся — перестать слушать (список внутри LanDiscovery очищается сам).
func stop_nearby() -> void:
	if lan != null and lan.has_method("stop_listening"):
		lan.stop_listening()
