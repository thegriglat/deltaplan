class_name LocalServer
extends Node
## LocalServer — встроенный сервер сетевой игры (NET-22): тот же контракт, что у Go-сервера
## (server/internal/ws, server/internal/zone), для игры в одной комнате без VPS.
##
## Транспорт: TCPServer + серверный WebSocketPeer (accept_stream), путь /v1/ws, порт по
## умолчанию 8080 (как у NetClient.DEFAULT_PORT и Go -addr :8080). Кадры — proto3 JSON
## Envelope, кодек — NetMessages. Работает на паузе дерева (process_mode ALWAYS); опрос
## сокетов — в _process, раз в кадр.
##
## Правила (как в Go):
##   - первым — Hello (до него всё, включая Ping, — Error BAD_MESSAGE; повторный Hello — тоже);
##     game_version не пусто — Hello другой версии получает VERSION_MISMATCH; имя ≤ 20 символов;
##   - Welcome{yourId} — id строкой по счётчику ("1", "2", …), новое соединение — новый id;
##   - CreateZone → ZoneCreated, затем ZoneJoined (создатель — ведущий); код — случайный
##     1000–9999, уникальный среди активных зон;
##   - JoinZone → ZoneJoined, остальным PeerJoined; ошибки ZONE_NOT_FOUND, VERSION_MISMATCH
##     (версия создателя зоны), ZONE_FULL (MAX_MEMBERS = 16); уже в зоне — BAD_MESSAGE;
##   - LeaveZone или обрыв → PeerLeft остальным, ушёл ведущий → LeaderChanged; ушёл последний —
##     зона удалена, код свободен (zone_closed);
##   - PilotState — всем остальным в зоне, ZoneState — только от ведущего (от остальных молча
##     отбрасывается); Envelope.fromId проставляет сервер;
##   - Ping → Pong{clientTime, serverTime — секунды Unix};
##   - мусор (не JSON, не объект, двоичный кадр, сообщение не к месту) — Error BAD_MESSAGE,
##     соединение остаётся; незнакомый вариант Envelope молча пропускается.
##
## Отличия от Go-сервера: нет HTTP /healthz и /v1/status (только WebSocket); неверный путь
## (не /v1/ws) закрывает соединение после рукопожатия кодом 4404, а не HTTP 404; живость —
## WebSocket heartbeat движка (HEARTBEAT_S); очередей с приоритетом нет: кадр, не влезший в
## исходящий буфер, отбрасывается; пересылаемое сообщение перекодируется NetMessages
## (незнакомые поля отбрасываются — как protojson DiscardUnknown у Go).
##
## API:
##   start(port := 8080, bind := "*") -> Error — слушать; занятый порт → ERR_ALREADY_IN_USE.
##   stop() — закрыть все соединения (клиенты видят обрыв) и зоны (zone_closed на каждую).
##   is_running() -> bool; port — порт, на котором слушает (0 — не запущен).
##   zones_info() -> Array — [{code, host_name, address, port, game_version, pilots_count}]
##       по коду — формат LanDiscovery.start_announcing (NET-23): host_name — имя создателя
##       зоны, address — "" (LanDiscovery подставит свой IPv4), port — порт WebSocket,
##       game_version — версия создателя зоны.
## Сигналы: zone_opened(code), zone_closed(code).

signal zone_opened(code: String)
signal zone_closed(code: String)

const DEFAULT_PORT := 8080
const WS_PATH := "/v1/ws"
const MAX_MEMBERS := 16
const NAME_MAX_LEN := 20
const CODE_MIN := 1000
const CODE_MAX := 9999
## Сколько ждать завершения WebSocket-рукопожатия, с.
const HANDSHAKE_TIMEOUT_S := 5.0
## Период WebSocket ping движка, с (как PingInterval у Go).
const HEARTBEAT_S := 15.0
const INBOUND_BUFFER := 64 * 1024
const OUTBOUND_BUFFER := 256 * 1024
const SERVER_VERSION := "embedded"
## Код закрытия при неверном пути.
const CLOSE_BAD_PATH := 4404

## Версия игры, обязательная для Hello; "" — любая (проверяется только при входе в зону).
var game_version := ""
var port := 0

var _tcp: TCPServer
## Соединения по порядку подключения.
var _conns: Array[Conn] = []
## Зоны: код → {code, params, version, creator_name, members: Array[Conn], next_order}.
var _zones: Dictionary = {}
var _next_id := 0


## Одно соединение (после Hello — живой пилот).
class Conn:
	extends RefCounted
	var ws: WebSocketPeer
	## Id после Hello; "" — Hello ещё не было.
	var id := ""
	var name := ""
	var version := ""
	## Код зоны или "".
	var zone := ""
	var join_order := 0
	## Рукопожатие завершено.
	var open := false
	## Срок рукопожатия, мс (Time.get_ticks_msec).
	var deadline := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	stop()


func start(p_port: int = DEFAULT_PORT, bind: String = "*") -> Error:
	stop()
	_tcp = TCPServer.new()
	var err := _tcp.listen(p_port, bind)
	if err != OK:
		_tcp = null
		return err
	port = _tcp.get_local_port()
	return OK


func stop() -> void:
	for c in _conns:
		var ws := c.ws
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.close(1001, "server stopped")
			ws.poll()
		# без вежливого ожидания: сокет рвётся сразу (как у Go при остановке процесса)
		ws.close(-1)
	_conns.clear()
	var codes := _zones.keys()
	_zones.clear()
	for c: String in codes:
		zone_closed.emit(c)
	if _tcp != null:
		_tcp.stop()
		_tcp = null
	port = 0


func is_running() -> bool:
	return _tcp != null and _tcp.is_listening()


func zones_info() -> Array:
	var codes := _zones.keys()
	codes.sort()
	var out := []
	for c: String in codes:
		var z: Dictionary = _zones[c]
		out.append(
			{
				"code": c,
				"host_name": z.creator_name,
				"address": "",
				"port": port,
				"game_version": z.version,
				"pilots_count": z.members.size(),
			}
		)
	return out


func _process(_delta: float) -> void:
	if _tcp == null:
		return
	while _tcp.is_connection_available():
		var stream := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = INBOUND_BUFFER
		ws.outbound_buffer_size = OUTBOUND_BUFFER
		ws.heartbeat_interval = HEARTBEAT_S
		if ws.accept_stream(stream) != OK:
			continue
		var c := Conn.new()
		c.ws = ws
		c.deadline = Time.get_ticks_msec() + int(HANDSHAKE_TIMEOUT_S * 1000.0)
		_conns.append(c)
	for i in range(_conns.size() - 1, -1, -1):
		if i < _conns.size():
			_poll_conn(_conns[i])


func _poll_conn(c: Conn) -> void:
	var ws := c.ws
	ws.poll()
	var st := ws.get_ready_state()
	if not c.open:
		if st == WebSocketPeer.STATE_OPEN:
			c.open = true
			if _path_of(ws.get_requested_url()) != WS_PATH:
				ws.close(CLOSE_BAD_PATH, "not found")
				_drop(c)
				return
		elif st == WebSocketPeer.STATE_CLOSED or Time.get_ticks_msec() > c.deadline:
			_drop(c)
			return
		else:
			return
	while ws.get_available_packet_count() > 0:
		var pkt := ws.get_packet()
		if not ws.was_string_packet():
			_send_error(c, "BAD_MESSAGE", "binary frames are not supported")
			continue
		_on_text(c, pkt.get_string_from_utf8())
		if not _conns.has(c):
			return
	if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_drop(c)


## Соединение закрыто: выйти из зоны, забыть.
func _drop(c: Conn) -> void:
	_leave(c)
	var ws := c.ws
	if ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		ws.close(-1)
	_conns.erase(c)


static func _path_of(url: String) -> String:
	var rest := url
	var scheme := rest.find("://")
	if scheme >= 0:
		rest = rest.substr(scheme + 3)
		var slash := rest.find("/")
		rest = rest.substr(slash) if slash >= 0 else "/"
	var q := rest.find("?")
	return rest.substr(0, q) if q >= 0 else rest


func _on_text(c: Conn, text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		_send_error(c, "BAD_MESSAGE", "cannot parse envelope")
		return
	var m := NetMessages.decode(text)
	if m.is_empty():
		for key: Variant in json.data:
			if key is String and NetMessages.ENVELOPE.has(key):
				_send_error(c, "BAD_MESSAGE", "cannot parse envelope: bad '%s'" % key)
				return
		return  # незнакомый вариант из более новой версии протокола
	var type: String = m.type
	var data: Dictionary = m.data
	if type == "hello":
		_on_hello(c, data)
		return
	if c.id == "":
		_send_error(c, "BAD_MESSAGE", "Hello expected first")
		return
	match type:
		"ping":
			_send(c, "pong", {"clientTime": data.clientTime, "serverTime": _unix_now()})
		"createZone":
			_create(c, data.zone)
		"joinZone":
			_join(c, String(data.code).strip_edges())
		"leaveZone":
			_leave(c)
		"pilotState", "zoneState":
			_relay(c, type, data)
		_:
			_send_error(c, "BAD_MESSAGE", "unexpected message from client")


func _on_hello(c: Conn, data: Dictionary) -> void:
	if c.id != "":
		_send_error(c, "BAD_MESSAGE", "duplicate Hello")
		return
	if game_version != "" and data.gameVersion != game_version:
		_send_error(
			c,
			"VERSION_MISMATCH",
			'server runs game version "%s", yours is "%s"' % [game_version, data.gameVersion]
		)
		return
	_next_id += 1
	c.id = str(_next_id)
	c.name = String(data.name).left(NAME_MAX_LEN)
	c.version = data.gameVersion
	_send(c, "welcome", {"yourId": c.id, "serverVersion": SERVER_VERSION})


func _create(c: Conn, params: Dictionary) -> void:
	if c.zone != "":
		_send_error(c, "BAD_MESSAGE", "already in zone %s" % c.zone)
		return
	var code := _free_code()
	if code == "":
		_send_error(c, "ZONE_FULL", "no free zone codes")
		return
	_zones[code] = {
		"code": code,
		"params": params,
		"version": c.version,
		"creator_name": c.name,
		"members": [],
		"next_order": 0,
	}
	_send(c, "zoneCreated", {"code": code})
	_add(_zones[code], c)
	zone_opened.emit(code)


func _join(c: Conn, code: String) -> void:
	if c.zone != "":
		_send_error(c, "BAD_MESSAGE", "already in zone %s" % c.zone)
		return
	if not _zones.has(code):
		_send_error(c, "ZONE_NOT_FOUND", "zone %s not found" % code)
		return
	var z: Dictionary = _zones[code]
	if c.version != z.version:
		_send_error(
			c,
			"VERSION_MISMATCH",
			'zone %s runs game version "%s", yours is "%s"' % [code, z.version, c.version]
		)
		return
	if z.members.size() >= MAX_MEMBERS:
		_send_error(c, "ZONE_FULL", "zone %s is full (%d pilots)" % [code, MAX_MEMBERS])
		return
	_add(z, c)


func _add(z: Dictionary, c: Conn) -> void:
	z.next_order += 1
	c.zone = z.code
	c.join_order = z.next_order
	z.members.append(c)
	var peers := []
	for p: Conn in z.members:
		peers.append(_peer(p))
	_send(
		c,
		"zoneJoined",
		{"code": z.code, "zone": z.params, "peers": peers, "leaderId": z.members[0].id}
	)
	var joined := NetMessages.encode("peerJoined", {"peer": _peer(c)})
	for p: Conn in z.members:
		if p != c:
			_send_text(p, joined)


func _leave(c: Conn) -> void:
	if c.zone == "" or not _zones.has(c.zone):
		c.zone = ""
		return
	var z: Dictionary = _zones[c.zone]
	var was_leader: bool = z.members[0] == c
	z.members.erase(c)
	c.zone = ""
	c.join_order = 0
	if z.members.is_empty():
		_zones.erase(z.code)
		zone_closed.emit(z.code)
		return
	var left := NetMessages.encode("peerLeft", {"id": c.id})
	for p: Conn in z.members:
		_send_text(p, left)
	if was_leader:
		var lc := NetMessages.encode("leaderChanged", {"leaderId": z.members[0].id})
		for p: Conn in z.members:
			_send_text(p, lc)


func _relay(c: Conn, type: String, data: Dictionary) -> void:
	if c.zone == "" or not _zones.has(c.zone):
		_send_error(c, "BAD_MESSAGE", "not in a zone")
		return
	var z: Dictionary = _zones[c.zone]
	if type == "zoneState" and z.members[0] != c:
		return
	var text := NetMessages.encode(type, data, c.id)
	for p: Conn in z.members:
		if p != c:
			_send_text(p, text)


static func _peer(c: Conn) -> Dictionary:
	return {"id": c.id, "name": c.name, "joinOrder": c.join_order}


func _free_code() -> String:
	var n := CODE_MAX - CODE_MIN + 1
	if _zones.size() >= n:
		return ""
	for i in 32:
		var cand := str(CODE_MIN + randi() % n)
		if not _zones.has(cand):
			return cand
	var start_at := randi() % n
	for i in n:
		var cand := str(CODE_MIN + (start_at + i) % n)
		if not _zones.has(cand):
			return cand
	return ""


func _send(c: Conn, type: String, data: Dictionary) -> void:
	_send_text(c, NetMessages.encode(type, data))


func _send_error(c: Conn, err_code: String, text: String) -> void:
	_send(c, "error", {"code": "ERROR_CODE_" + err_code, "text": text})


func _send_text(c: Conn, text: String) -> void:
	var ws := c.ws
	if text == "" or ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	# не влезло в исходящий буфер — кадр пропадает (клиент безнадёжно отстал)
	ws.send_text(text)


static func _unix_now() -> float:
	return Time.get_unix_time_from_system()
