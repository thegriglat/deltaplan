extends Node
## NetZone (автозагрузка) — зона сетевой игры поверх NetClient: создать/войти/выйти, пилоты
## зоны, ведущий, часы зоны и очередь на старт (NET-31).
##
## Протокол: docs/net_protocol.md («Роль ведущего», «Переподключение»); данные сообщений —
## словари NetMessages (ключи lowerCamelCase, умолчания подставлены).
##
## Методы:
##   create_zone(settings: FlightSettings, world_seed: int, bots_count: int) — CreateZone;
##       ответ — zone_entered(code) (создатель сразу ведущий) или zone_error.
##   join_zone(code: String) — JoinZone; ответ — zone_entered(code) или zone_error
##       ("ZONE_NOT_FOUND", "ZONE_FULL", "VERSION_MISMATCH").
##       Уже в зоне — сначала выходит из неё (zone_left).
##   leave_zone() — LeaveZone и сброс состояния; zone_left, если был в зоне.
##   is_leader() -> bool — этот клиент ведущий.
##   zone_time() -> float — часы зоны, с от создания зоны (ZoneState.clock), сейчас.
##       Идут ×1 по монотонным часам, пауза дерева их не останавливает. Время суток в зоне =
##       zone_settings.start_hour + zone_time() / 3600. До первого ZoneState у вошедшего — 0
##       (has_clock = false).
##   set_queue(ids: Array) — только ведущий: заменить очередь на старт и сразу разослать.
##   peer_ids() -> Array[String] — id живых пилотов по порядку подключения.
##   send_pilot_state(data: Dictionary) -> bool — отправить PilotState (данные NetMessages)
##       в зону; false — не в зоне или нет связи. Хук для NET-32.
##
## Свойства (только чтение):
##   in_zone — в зоне (после ZoneJoined, до выхода); code — код зоны ("4721"), "" вне зоны;
##   zone — Zone как пришла от сервера (словарь NetMessages);
##   zone_settings: FlightSettings — мир зоны (FlightSettings.from_zone; крыло и масса —
##       по умолчанию, свои подставляет вызывающий); world_seed, bots_count — из Zone;
##   peers — id → {"id", "name", "joinOrder"}, по порядку подключения (включая себя);
##   leader_id; my_id (NetClient.my_id);
##   queue: Array[String] — очередь на старт: сначала живые пилоты, потом боты ("bot-…");
##       у ведущего — своя (он её ведёт), у остальных — из последнего ZoneState;
##   has_clock — часы зоны известны (у ведущего всегда, у остальных — после ZoneState).
##
## Сигналы:
##   zone_entered(code) — вошёл в зону (создал, вошёл по коду, вернулся после переподключения);
##   zone_left() — вышел: leave_zone, связь потеряна окончательно, зона пропала при возврате;
##   peer_joined(peer: Dictionary) — вошёл другой пилот ({"id", "name", "joinOrder"});
##   peer_left(id) — пилот вышел;
##   leader_changed(leader_id, is_me) — сменился ведущий (и при входе в зону);
##   zone_state_changed() — у не-ведущего применён ZoneState (часы, очередь); у ведущего —
##       после set_queue и изменений очереди;
##   zone_error(code, text) — ошибка входа/создания ("ZONE_NOT_FOUND", "ZONE_FULL",
##       "VERSION_MISMATCH", "BAD_MESSAGE", "CONNECT_FAILED");
##   pilot_state_received(from_id, data) — пришёл PilotState другого пилота или бота
##       (from_id — отправитель, data.pilotId — чьё состояние). Хук для NET-32/NET-44.
##
## Часы. Ведущий ведёт часы сам и раз в state_interval_s (1 с) шлёт ZoneState {clock, queue};
## при входе нового пилота — сразу. Остальные берут clock + задержка/2 и идут дальше сами,
## расхождение убирают плавно — скоростью хода часов 0,8…1,2 (назад часы не прыгают; вперёд
## прыгают только при отставании > SNAP_S). Новый ведущий продолжает со своей оценки часов
## (последний ZoneState + прошедшее время) без скачка и с сохранённой очередью (без ушедших).
##
## Переподключение: NetClient.connected(true) в зоне → JoinZone с тем же кодом (сервер даёт
## новый id, встаём в конец порядка подключения). Зоны уже нет → zone_error + zone_left.
##
## Экземпляры для тестов: load("res://scripts/net/net_zone.gd").new(), setup(client),
## add_child. Автозагрузка без setup берёт автозагрузку NetClient.

signal zone_entered(code: String)
signal zone_left
signal peer_joined(peer: Dictionary)
signal peer_left(id: String)
signal leader_changed(leader_id: String, is_me: bool)
signal zone_state_changed
signal zone_error(code: String, text: String)
signal pilot_state_received(from_id: String, data: Dictionary)

## Отставание часов, после которого не догоняем плавно, а прыгаем вперёд, с.
const SNAP_S := 1.0
## Предел поправки скорости хода часов (±).
const MAX_SLEW := 0.2
## За сколько секунд убирать расхождение часов.
const SLEW_WINDOW_S := 2.0
const BOT_PREFIX := "bot-"
const ZONE_ERRORS := ["ZONE_NOT_FOUND", "ZONE_FULL", "VERSION_MISMATCH", "BAD_MESSAGE"]

## Период рассылки ZoneState ведущим, с (тесты меняют).
var state_interval_s := 1.0

var in_zone := false
var code := ""
var zone: Dictionary = {}
var zone_settings: FlightSettings
var world_seed := 0
var bots_count := 0
var peers: Dictionary = {}
var leader_id := ""
var queue: Array[String] = []
var has_clock := false
var my_id: String:
	get:
		return _client.my_id if _client != null else ""

var _client: Node
## Что ждём от сервера: "" | "create" | "join" | "rejoin".
var _pending := ""
## Часы зоны: _clock_base в момент _clock_at (монотонные с), ход — _clock_rate.
var _clock_base := 0.0
var _clock_at := 0.0
var _clock_rate := 1.0
var _state_timer := 0.0


func setup(client: Node) -> void:
	_client = client
	_client.connected.connect(_on_connected)
	_client.disconnected.connect(_on_disconnected)
	_client.error.connect(_on_error)
	_client.message.connect(_on_message)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _client == null:
		setup(get_node("/root/NetClient"))


func create_zone(settings: FlightSettings, p_world_seed: int, p_bots_count: int) -> void:
	_leave_if_in_zone()
	_pending = "create"
	if not _client.send("createZone", {"zone": settings.to_zone(p_world_seed, p_bots_count)}):
		_fail_pending("CONNECT_FAILED", "not connected")


func join_zone(p_code: String) -> void:
	_leave_if_in_zone()
	_pending = "join"
	if not _client.send("joinZone", {"code": p_code.strip_edges()}):
		_fail_pending("CONNECT_FAILED", "not connected")


func leave_zone() -> void:
	_pending = ""
	if not in_zone:
		return
	_client.send("leaveZone", {})
	_reset()
	zone_left.emit()


func is_leader() -> bool:
	return in_zone and leader_id != "" and leader_id == my_id


func zone_time() -> float:
	return _clock_now() if has_clock else 0.0


func set_queue(ids: Array) -> void:
	if not is_leader():
		push_warning("NetZone.set_queue: не ведущий")
		return
	queue.assign(ids)
	zone_state_changed.emit()
	_broadcast_state()


func peer_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(peers.keys())
	return ids


func send_pilot_state(data: Dictionary) -> bool:
	return in_zone and _client.send("pilotState", data)


func _process(delta: float) -> void:
	if not is_leader():
		return
	_state_timer -= delta
	if _state_timer <= 0.0:
		_broadcast_state()


func _broadcast_state() -> void:
	_state_timer = state_interval_s
	_client.send("zoneState", {"clock": zone_time(), "queue": queue})


func _on_message(type: String, data: Dictionary, from_id: String) -> void:
	match type:
		"zoneJoined":
			_on_zone_joined(data)
		"peerJoined":
			_on_peer_joined(data.peer)
		"peerLeft":
			_on_peer_left(data.id)
		"leaderChanged":
			_on_leader_changed(data.leaderId)
		"zoneState":
			if in_zone and from_id == leader_id and not is_leader():
				_apply_state(data)
		"pilotState":
			if in_zone:
				pilot_state_received.emit(from_id, data)


func _on_zone_joined(data: Dictionary) -> void:
	var was := _pending
	_pending = ""
	var rejoin := was == "rejoin"
	code = data.code
	zone = data.zone
	zone_settings = FlightSettings.from_zone(zone)
	world_seed = int(zone.seed)
	bots_count = int(zone.botsCount)
	peers.clear()
	for p: Dictionary in data.peers:
		peers[p.id] = p
	in_zone = true
	leader_id = data.leaderId
	if not rejoin:
		queue.clear()
		has_clock = false
		_set_clock(0.0, 1.0)
	else:
		_drop_absent_from_queue()
	if is_leader():
		# создатель: часы с нуля; вернувшийся единственным — продолжает свои
		has_clock = true
		if queue.is_empty() or not queue.has(my_id):
			_queue_add_live(my_id)
		_set_clock(_clock_now(), 1.0)
		_state_timer = 0.0
	zone_entered.emit(code)
	leader_changed.emit(leader_id, is_leader())


func _on_peer_joined(p: Dictionary) -> void:
	if not in_zone:
		return
	peers[p.id] = p
	peer_joined.emit(p)
	if is_leader():
		_queue_add_live(p.id)
		zone_state_changed.emit()
		_broadcast_state()


func _on_peer_left(id: String) -> void:
	if not in_zone or not peers.has(id):
		return
	peers.erase(id)
	queue.erase(id)
	peer_left.emit(id)
	if is_leader():
		zone_state_changed.emit()
		_broadcast_state()


func _on_leader_changed(new_leader: String) -> void:
	if not in_zone:
		return
	leader_id = new_leader
	var me := is_leader()
	if me:
		# продолжаем со своей оценки часов, ход ровно ×1, очередь — последняя известная
		_set_clock(_clock_now() if has_clock else 0.0, 1.0)
		has_clock = true
		_drop_absent_from_queue()
		_broadcast_state()
	leader_changed.emit(new_leader, me)


func _apply_state(data: Dictionary) -> void:
	var latency_s: float = maxf(_client.latency_ms, 0.0) / 2000.0
	var target: float = data.clock + latency_s
	var now_est := _clock_now()
	var err := target - now_est
	if not has_clock or err > SNAP_S:
		_set_clock(target, 1.0)
	else:
		_set_clock(now_est, 1.0 + clampf(err / SLEW_WINDOW_S, -MAX_SLEW, MAX_SLEW))
	has_clock = true
	queue.assign(data.queue)
	zone_state_changed.emit()


func _set_clock(value: float, rate: float) -> void:
	_clock_base = value
	_clock_at = _now()
	_clock_rate = rate


## Живой пилот — в очередь после живых, перед ботами.
func _queue_add_live(id: String) -> void:
	if queue.has(id):
		return
	var at := queue.size()
	for i in queue.size():
		if queue[i].begins_with(BOT_PREFIX):
			at = i
			break
	queue.insert(at, id)


## Убрать из очереди живых, которых уже нет в зоне (боты остаются).
func _drop_absent_from_queue() -> void:
	var kept: Array[String] = []
	for id in queue:
		if id.begins_with(BOT_PREFIX) or peers.has(id):
			kept.append(id)
	queue = kept


func _on_connected(reconnect: bool) -> void:
	if reconnect and in_zone:
		_pending = "rejoin"
		_client.send("joinZone", {"code": code})


func _on_disconnected(will_reconnect: bool) -> void:
	if will_reconnect:
		return
	if _pending != "" and not in_zone:
		_fail_pending("CONNECT_FAILED", "connection closed")
	elif in_zone:
		_pending = ""
		_reset()
		zone_left.emit()


func _on_error(err_code: String, text: String) -> void:
	if _pending == "" or not ZONE_ERRORS.has(err_code):
		return
	if _pending == "rejoin":
		_pending = ""
		zone_error.emit(err_code, text)
		_reset()
		zone_left.emit()
	else:
		_fail_pending(err_code, text)


func _fail_pending(err_code: String, text: String) -> void:
	_pending = ""
	zone_error.emit(err_code, text)


func _leave_if_in_zone() -> void:
	if in_zone:
		leave_zone()


func _reset() -> void:
	in_zone = false
	code = ""
	zone = {}
	peers.clear()
	leader_id = ""
	queue.clear()
	has_clock = false
	_set_clock(0.0, 1.0)


func _clock_now() -> float:
	return _clock_base + (_now() - _clock_at) * _clock_rate


static func _now() -> float:
	return Time.get_ticks_usec() / 1e6
