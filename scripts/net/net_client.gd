extends Node
## NetClient (автозагрузка) — одно WebSocket-соединение с сервером сетевой игры.
##
## Протокол: docs/net_protocol.md, контракт — server/proto/deltaplan/v1/net.proto,
## кодирование — NetMessages (там же формат данных: ключи lowerCamelCase, умолчания подставлены).
##
## Адрес: "IP:порт" или "имя:порт" ("192.168.1.5:8080", "fly.example.org:9000"); без порта —
## DEFAULT_PORT (8080); "[::1]:8080" для IPv6; полный "ws://…" берётся как есть (без пути —
## добавляется /v1/ws). Итоговый URL — ws://<адрес>/v1/ws.
##
## Методы:
##   connect_to_server(address, pilot_name) -> bool — false, если адрес не разобран (тогда
##       ещё error("BAD_ADDRESS") и disconnected(false)). Идёт подключение, затем Hello
##       (версия игры — application/config/version, имя ≤ 20 символов); Welcome → connected.
##       Уже подключён — старое соединение закрывается (disconnected(false)).
##   disconnect_from_server() — закрыть соединение; без переподключения.
##   send(type, data) -> bool — отправить сообщение (type — ключ NetMessages.ENVELOPE:
##       "joinZone", "pilotState", …). Только когда is_online, иначе false. Hello и Ping
##       NetClient шлёт сам.
##   server_time() -> float — оценка текущего времени сервера, секунды Unix.
##   now() -> float — монотонные часы клиента, с (те же, что для server_time_offset_s).
##
## Свойства (только чтение):
##   my_id — id этого пилота от сервера (Welcome.yourId), "" без соединения;
##   is_online — соединение принято (после Welcome);
##   latency_ms — задержка туда-обратно (RTT), мс, сглаженная (EMA); −1 — ещё не замерена;
##   server_time_offset_s — server_time() − now(), сглаженное; has_server_time — был Pong;
##   server_version, address, pilot_name, state.
##
## Сигналы:
##   connected(reconnect: bool) — пришёл Welcome. reconnect = true после переподключения:
##       это новое соединение с НОВЫМ my_id; зону сервер уже забыл — вход обратно по коду
##       (JoinZone) делает NetZone (NET-31) по этому сигналу.
##   disconnected(will_reconnect: bool) — соединение потеряно или закрыто.
##       will_reconnect = true: оборвалось, идут повторы (затем connected(true) или
##       error("CONNECT_FAILED") + disconnected(false)); false — окончательно.
##   reconnecting(attempt: int) — запланирован повтор attempt (1..N) после паузы.
##   error(code: String, text: String) — ошибка сервера (Error.code без префикса
##       ERROR_CODE_: "ZONE_NOT_FOUND", "VERSION_MISMATCH", "ZONE_FULL", "BAD_MESSAGE")
##       или своя: "CONNECT_FAILED" (не подключиться / повторы кончились), "BAD_ADDRESS".
##       Ошибка сервера до Welcome (например VERSION_MISMATCH) закрывает соединение без
##       повторов: error, затем disconnected(false). После Welcome соединение остаётся.
##   message(type: String, data: Dictionary, from_id: String) — каждое разобранное
##       сообщение сервера, включая welcome/pong/error и пересылаемые pilotState/zoneState;
##       from_id — Envelope.fromId (id отправителя для пересылаемых, иначе "").
##
## Ping раз в ping_interval_s (2 с): RTT и смещение часов сервера, сглаживание EMA.
## Обрыв → повторы через reconnect_delays_s (1, 2, 4 с), затем error("CONNECT_FAILED") и
## disconnected(false). Первое подключение (до первого Welcome) тоже повторяется — сервер
## ведущего может быть занят: отказ в соединении или нет Welcome за connect_timeout_s (15 с) →
## reconnecting(1..N) по тем же паузам, но не дольше first_connect_budget_s с начала
## (недоступный адрес не держит пилота минуту), затем CONNECT_FAILED. Без повторов: плохой
## адрес (BAD_ADDRESS) и ошибка сервера до Welcome (VERSION_MISMATCH и т. п.).
## Работает и на паузе дерева (process_mode ALWAYS). Можно создавать отдельные экземпляры
## (load(...).new() + add_child) — тесты так поднимают несколько клиентов.

signal connected(reconnect: bool)
signal disconnected(will_reconnect: bool)
signal reconnecting(attempt: int)
signal error(code: String, text: String)
signal message(type: String, data: Dictionary, from_id: String)

enum State { IDLE, CONNECTING, HANDSHAKE, ONLINE, WAIT_RETRY }

const DEFAULT_PORT := 8080
const WS_PATH := "/v1/ws"
const NAME_MAX_LEN := 20
## Pong дольше этого (RTT, с) не учитывается в задержке и часах сервера.
const MAX_PONG_RTT_S := 3.0

## Настройки (тесты меняют их для скорости).
var ping_interval_s := 2.0
## Паузы перед повторами после обрыва, с; число элементов — число повторов.
var reconnect_delays_s: Array = [1.0, 2.0, 4.0]
## Сколько ждать Welcome от начала одной попытки подключения.
var connect_timeout_s := 15.0
## Первое подключение: новую попытку не начинать позже этого срока от connect_to_server, с.
var first_connect_budget_s := 30.0
## Вес нового замера в EMA задержки и смещения часов.
var smoothing := 0.3

var my_id := ""
var is_online: bool:
	get:
		return state == State.ONLINE
var latency_ms := -1.0
var server_time_offset_s := 0.0
var has_server_time := false
var server_version := ""
var address := ""
var pilot_name := ""
var state := State.IDLE

var _url := ""
var _ws: WebSocketPeer
## Закрываемые сокеты: опрашиваются, пока не закроются вежливо.
var _closing: Array[WebSocketPeer] = []
var _timer := 0.0
var _ping_timer := 0.0
## Номер текущего повтора: 0 — первое подключение, 1..N — повторы после обрыва.
var _attempt := 0
## Был ли Welcome в этой сессии (connect_to_server) — следующий connected будет reconnect.
var _had_welcome := false
## Начало первого подключения (now()), для first_connect_budget_s.
var _first_connect_at := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func connect_to_server(p_address: String, p_pilot_name: String) -> bool:
	if state != State.IDLE:
		disconnect_from_server()
	address = p_address
	pilot_name = p_pilot_name.strip_edges().left(NAME_MAX_LEN)
	_url = make_url(p_address)
	if _url == "":
		error.emit("BAD_ADDRESS", "cannot parse address '%s'" % p_address)
		disconnected.emit(false)
		return false
	_attempt = 0
	_had_welcome = false
	_first_connect_at = now()
	_open()
	return true


func disconnect_from_server() -> void:
	if state == State.IDLE:
		return
	_close_socket()
	_reset_session()
	disconnected.emit(false)


func send(type: String, data: Dictionary = {}) -> bool:
	if state != State.ONLINE:
		return false
	return _send_raw(type, data)


func now() -> float:
	return Time.get_ticks_usec() / 1e6


func server_time() -> float:
	return now() + server_time_offset_s


## Адрес пилота → ws://…/v1/ws; "" — не разобран.
static func make_url(p_address: String) -> String:
	var a := p_address.strip_edges()
	if a == "":
		return ""
	if a.begins_with("ws://") or a.begins_with("wss://"):
		var rest := a.substr(a.find("//") + 2)
		return a if rest.contains("/") else a + WS_PATH
	var host := a
	var port := DEFAULT_PORT
	if a.begins_with("["):
		var close := a.find("]")
		if close < 0:
			return ""
		host = a.substr(0, close + 1)
		var tail := a.substr(close + 1)
		if tail.begins_with(":"):
			if not tail.substr(1).is_valid_int():
				return ""
			port = tail.substr(1).to_int()
		elif tail != "":
			return ""
	elif a.count(":") == 1:
		host = a.get_slice(":", 0)
		var p := a.get_slice(":", 1)
		if not p.is_valid_int():
			return ""
		port = p.to_int()
	elif a.count(":") > 1:
		return ""
	if host == "" or host.contains("/") or host.contains(" ") or port < 1 or port > 65535:
		return ""
	return "ws://%s:%d%s" % [host, port, WS_PATH]


func _process(delta: float) -> void:
	_poll_closing()
	match state:
		State.IDLE:
			return
		State.WAIT_RETRY:
			_timer -= delta
			if _timer <= 0.0:
				_open()
			return
	_ws.poll()
	var ws_state := _ws.get_ready_state()
	if ws_state == WebSocketPeer.STATE_OPEN and state == State.CONNECTING:
		state = State.HANDSHAKE
		_send_raw("hello", {"gameVersion": _game_version(), "name": pilot_name})
	while state != State.IDLE and _ws != null and _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		if _ws.was_string_packet():
			_on_text(pkt.get_string_from_utf8())
	if state == State.IDLE or state == State.WAIT_RETRY or _ws == null:
		return
	if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_on_socket_closed(
			"closed: code %d %s" % [_ws.get_close_code(), _ws.get_close_reason()]
		)
		return
	if state == State.ONLINE:
		_ping_timer -= delta
		if _ping_timer <= 0.0:
			_send_ping()
	else:
		_timer -= delta
		if _timer <= 0.0:
			_close_socket()
			_on_attempt_failed("timeout %.1f s" % connect_timeout_s)


func _open() -> void:
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(_url)
	if err != OK:
		_ws = null
		state = State.CONNECTING  # чтобы _on_attempt_failed считал это попыткой
		_on_attempt_failed("connect_to_url %s: error %d" % [_url, err])
		return
	state = State.CONNECTING
	_timer = connect_timeout_s


func _on_text(text: String) -> void:
	var m := NetMessages.decode(text)
	if m.is_empty():
		return
	var type: String = m.type
	var data: Dictionary = m.data
	match type:
		"welcome":
			if state == State.HANDSHAKE:
				my_id = data.yourId
				server_version = data.serverVersion
				state = State.ONLINE
				var was_reconnect := _had_welcome
				_had_welcome = true
				_attempt = 0
				_send_ping()
				connected.emit(was_reconnect)
		"pong":
			_on_pong(data)
		"error":
			var code := NetMessages.short_enum(data.code)
			error.emit(code, data.text)
			if state == State.HANDSHAKE:
				# до Welcome повтор не поможет (например, другая версия игры)
				_close_socket()
				_reset_session()
				message.emit(type, data, m.from_id)
				disconnected.emit(false)
				return
	message.emit(type, data, m.from_id)


func _on_pong(data: Dictionary) -> void:
	var t_now := now()
	var sent: float = data.clientTime
	var rtt := t_now - sent
	# долгий ответ — чаще всего стоял свой главный поток (загрузка мира): замер испорчен
	# (смещение часов ушло бы на половину простоя) — выбросить
	if rtt < 0.0 or rtt > MAX_PONG_RTT_S:
		return
	var offset: float = data.serverTime - (sent + t_now) * 0.5
	if latency_ms < 0.0:
		latency_ms = rtt * 1000.0
	else:
		latency_ms = lerpf(latency_ms, rtt * 1000.0, smoothing)
	if not has_server_time:
		server_time_offset_s = offset
		has_server_time = true
	else:
		server_time_offset_s = lerpf(server_time_offset_s, offset, smoothing)


func _send_ping() -> void:
	_ping_timer = ping_interval_s
	_send_raw("ping", {"clientTime": now()})


func _send_raw(type: String, data: Dictionary) -> bool:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var text := NetMessages.encode(type, data)
	if text == "":
		return false
	return _ws.send_text(text) == OK


## Сокет закрылся сам (сервер, сеть).
func _on_socket_closed(reason: String) -> void:
	_ws = null
	if state == State.ONLINE:
		my_id = ""
		if reconnect_delays_s.is_empty():
			_fail("connection lost (%s)" % reason)
			return
		disconnected.emit(true)
		_attempt = 1
		_schedule_retry()
	else:
		_on_attempt_failed(reason)


## Попытка подключения (до Welcome) не удалась.
func _on_attempt_failed(reason: String) -> void:
	if _attempt >= reconnect_delays_s.size():
		_fail(reason)
	elif (
		not _had_welcome
		and now() - _first_connect_at + reconnect_delays_s[_attempt] > first_connect_budget_s
	):
		_fail(reason)
	else:
		_attempt += 1
		_schedule_retry()


func _schedule_retry() -> void:
	state = State.WAIT_RETRY
	_timer = reconnect_delays_s[_attempt - 1]
	reconnecting.emit(_attempt)


func _fail(reason: String) -> void:
	var attempts := _attempt
	_close_socket()
	_reset_session()
	var text := "cannot connect to %s: %s" % [_url, reason]
	if attempts > 0:
		text += " (after %d retries)" % attempts
	error.emit("CONNECT_FAILED", text)
	disconnected.emit(false)


func _close_socket() -> void:
	if _ws != null:
		if _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
			_ws.close(1000, "bye")
			_closing.append(_ws)
		_ws = null


func _reset_session() -> void:
	state = State.IDLE
	my_id = ""
	_attempt = 0


func _poll_closing() -> void:
	for i in range(_closing.size() - 1, -1, -1):
		var ws := _closing[i]
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_closing.remove_at(i)


static func _game_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))
