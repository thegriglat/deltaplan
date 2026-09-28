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
}

var client: Node
var zone: Node

var _mode := ""  ## "create" | "join" — что сделать после Welcome
var _params: FlightSettings  ## создание: параметры зоны; вход: свои крыло и масса
var _join_code := ""
var _busy := false
var _in_zone := false


## client/zone — экземпляры для тестов; по умолчанию — автозагрузки NetClient/NetZone.
func _init(p_client: Node = null, p_zone: Node = null) -> void:
	client = p_client
	zone = p_zone
	var tree := Engine.get_main_loop() as SceneTree
	if client == null and tree != null:
		client = tree.root.get_node_or_null("NetClient")
	if zone == null and tree != null:
		zone = tree.root.get_node_or_null("NetZone")
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


func connect_and_create(address: String, name: String, zone_params: FlightSettings) -> void:
	if client == null or zone == null:
		super.connect_and_create(address, name, zone_params)
		return
	_mode = "create"
	_params = zone_params.duplicate() if zone_params != null else FlightSettings.defaults()
	_start(address, name)


func connect_and_join(address: String, name: String, zone_code: String) -> void:
	if client == null or zone == null:
		super.connect_and_join(address, name, zone_code)
		return
	_mode = "join"
	_join_code = zone_code
	_params = UserSettings.load_last_flight()
	_start(address, name)


func leave() -> void:
	var was := _busy or _in_zone
	_busy = false
	_in_zone = false
	_mode = ""
	if zone != null:
		zone.leave_zone()
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
	if _busy and not reconnect:
		_send_request()


func _on_disconnected(will_reconnect: bool) -> void:
	if _busy and not will_reconnect:
		_fail("unreachable")


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
		NetUiClientBackend._drop_if_idle.bind(client, weakref(self)).call_deferred()


static func _drop_if_idle(c: Node, me: WeakRef) -> void:
	var b: NetUiClientBackend = me.get_ref()
	if not is_instance_valid(c):
		return
	if b == null or (not b._busy and not b._in_zone):
		c.disconnect_from_server()
