extends Node
## SteamTransport — транспорт сети через Steam Networking Messages (Steam-пир S4.1 и мост
## хозяина S4.3, docs/contracts/steam.md). Один на процесс (дочерний узел SteamLobby); тесты
## поднимают по одному на каждого подставного пользователя Steam.
##
## Почему Networking Messages, а не Networking Sockets: ST-1 проверил именно Messages (кадр
## 2 КБ надёжным на канале 0 проходит, сигналы сессий есть); нашей модели «одна строка — один
## кадр» хватает сообщений без своих соединений и их состояний; сессию Steam открывает первый
## кадр (у хозяина — network_messages_session_request → acceptSessionWithUser), обрыв приходит
## сигналом network_messages_session_failed. Свои «соединения» поверх сессии — номер соединения
## в каждом кадре (ниже), этого достаточно, чтобы отличить переподключение от старых кадров.
##
## Steam трогает только главный поток (pump() в _process): пиры кладут исходящие кадры в
## очередь и читают входящие из своих очередей под общим мьютексом — встроенный сервер опрашивает
## их из своего потока. Цена — пока главный поток хозяина занят (загрузка мира), кадры Steam ждут
## в очереди Steam; сессия при этом живёт (у Steam свой поток).
##
## Кадр Steam (канал 0, надёжный, по порядку — как TCP у WebSocket):
##   байт 0 — вид: 1 данные клиент→хозяин, 2 «закрыть» клиент→хозяин, 3 данные хозяин→клиент,
##            4 «закрыть» хозяин→клиент;
##   байты 1–4 — номер соединения (u32, выбирает клиент);
##   дальше — данные: текст Envelope в UTF-8 (как есть, NetMessages) или код закрытия (s32).
## Это рамка транспорта, протокол (net.proto, docs/guide/net-protocol.md) не меняется.
##
## Клиент: open_peer(steam_id хозяина) → пир (NetClient берёт его через фабрику схемы steam).
## Хозяин: accepting = true — кадр данных от нового соединения создаёт пир хозяина и сигнал
## peer_accepted(peer) (SteamLobby отдаёт его LocalServer.attach_peer). accepting = false —
## новому соединению сразу «закрыть» (клиент не ждёт таймаута).

## Новое входящее соединение (только при accepting): пир хозяина, уже с первым кадром.
signal peer_accepted(peer: RefCounted)

const PEER := preload("res://scripts/steam/steam_peer.gd")
const DATA_C2S := 1
const BYE_C2S := 2
const DATA_S2C := 3
const BYE_S2C := 4
const HEADER := 5
const CHANNEL := 0
## NETWORKING_SEND_RELIABLE_NO_NAGLE (9) | NETWORKING_SEND_AUTORESTART_BROKEN_SESSION (32).
const SEND_FLAGS := 41
## Сколько сообщений забирать за один вызов receiveMessagesOnChannel и за кадр всего.
const RECEIVE_BATCH := 64
const RECEIVE_MAX := 1024
## Код закрытия для отказа новому соединению (хозяин не принимает).
const CODE_NOT_HOSTING := 1001

## Синглтон Steam (или подставной в тестах); null — транспорт молчит.
var api: Object
var mutex := Mutex.new()
## Принимать новые соединения (хозяин встроенного сервера с лобби).
var accepting := false

## Клиентские пиры: steam id хозяина → пир.
var _clients: Dictionary = {}
## Пиры хозяина: steam id клиента → пир.
var _servers: Dictionary = {}
## Исходящие кадры: [steam id, PackedByteArray] (под мьютексом).
var _outbox: Array = []
## Счётчики для отладки/тестов.
var frames_sent := 0
var frames_received := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(p_api: Object) -> void:
	if api != null and is_instance_valid(api):
		for s: Array in _signal_map():
			if api.is_connected(s[0], s[1]):
				api.disconnect(s[0], s[1])
	api = p_api
	if api == null:
		return
	for s: Array in _signal_map():
		if api.has_signal(s[0]):
			api.connect(s[0], s[1])


func _signal_map() -> Array:
	return [
		["network_messages_session_request", _on_session_request],
		["network_messages_session_failed", _on_session_failed],
	]


func _process(_delta: float) -> void:
	pump()


## Клиент: новое соединение с хозяином remote (старое к нему же закрывается).
func open_peer(remote: int) -> RefCounted:
	if api == null or remote <= 0:
		return null
	var p: RefCounted = PEER.new()
	p.transport = self
	p.remote = remote
	p.conn_id = (randi() & 0x7fffffff) | 1
	p.server_side = false
	mutex.lock()
	var old: RefCounted = _clients.get(remote)
	_clients[remote] = p
	mutex.unlock()
	if old != null:
		old.close(1000)
	return p


## Закрыть все пиры хозяина (хозяин закрыл зону; сервер обычно закрывает их сам).
func close_server_peers(code: int = CODE_NOT_HOSTING) -> void:
	mutex.lock()
	var list := _servers.values()
	mutex.unlock()
	for p: RefCounted in list:
		p.close(code)


## Живых соединений (клиентских, хозяина).
func peer_counts() -> Vector2i:
	mutex.lock()
	var v := Vector2i(_clients.size(), _servers.size())
	mutex.unlock()
	return v


## Один шаг: отправить очередь, принять всё пришедшее (главный поток).
func pump() -> void:
	if api == null:
		return
	mutex.lock()
	var out := _outbox
	_outbox = []
	mutex.unlock()
	for item: Array in out:
		api.call("sendMessageToUser", item[0], item[1], SEND_FLAGS, CHANNEL)
		frames_sent += 1
	var got := 0
	while got < RECEIVE_MAX:
		var msgs: Variant = api.call("receiveMessagesOnChannel", CHANNEL, RECEIVE_BATCH)
		if not (msgs is Array) or msgs.is_empty():
			break
		for m: Variant in msgs:
			if m is Dictionary:
				_on_frame(int(m.get("identity", 0)), m.get("payload", PackedByteArray()))
		got += msgs.size()


func _on_frame(from: int, raw: Variant) -> void:
	if not (raw is PackedByteArray) or raw.size() < HEADER or from <= 0:
		return
	var bytes: PackedByteArray = raw
	frames_received += 1
	var kind: int = bytes[0]
	var cid := bytes.decode_u32(1)
	var accepted: RefCounted = null
	mutex.lock()
	match kind:
		DATA_S2C, BYE_S2C:
			var p: RefCounted = _clients.get(from)
			if p != null and p.conn_id == cid:
				if kind == DATA_S2C:
					p.push_locked(bytes.slice(HEADER).get_string_from_utf8())
				else:
					p.close_remote_locked(_code_of(bytes))
					_clients.erase(from)
		DATA_C2S:
			var p: RefCounted = _servers.get(from)
			if p == null or p.conn_id != cid:
				if accepting:
					if p != null:  # тот же пилот подключился заново — старое соединение мертво
						p.close_remote_locked(PEER.CODE_LOST)
					p = PEER.new()
					p.transport = self
					p.remote = from
					p.conn_id = cid
					p.server_side = true
					_servers[from] = p
					accepted = p
				else:
					_enqueue_raw_locked(from, _header(BYE_S2C, cid) + _code_bytes(CODE_NOT_HOSTING))
					p = null
			if p != null:
				p.push_locked(bytes.slice(HEADER).get_string_from_utf8())
		BYE_C2S:
			var p: RefCounted = _servers.get(from)
			if p != null and p.conn_id == cid:
				p.close_remote_locked(_code_of(bytes))
				_servers.erase(from)
	mutex.unlock()
	if accepted != null:
		peer_accepted.emit(accepted)


## Сессию принимаем всегда: не хозяин — первый же кадр получит «закрыть», клиент не ждёт
## таймаута (сессия Steam сама по себе ничего не открывает — игру ведёт только accepting).
func _on_session_request(remote: int) -> void:
	if api != null:
		api.call("acceptSessionWithUser", remote)


func _on_session_failed(_reason: int, remote: int, _state: int, debug_message: String) -> void:
	mutex.lock()
	var hit := false
	for d: Dictionary in [_clients, _servers]:
		var p: RefCounted = d.get(remote)
		if p != null:
			p.close_remote_locked(PEER.CODE_LOST)
			d.erase(remote)
			hit = true
	mutex.unlock()
	if hit:
		print("steam: session with %d failed (%s)" % [remote, debug_message])


# ---------------------------------------------------------------- для пиров (под мьютексом)


func enqueue_locked(peer: RefCounted, data: PackedByteArray, bye: bool, code: int) -> void:
	var kind: int
	if peer.server_side:
		kind = BYE_S2C if bye else DATA_S2C
	else:
		kind = BYE_C2S if bye else DATA_C2S
	var payload := _code_bytes(code) if bye else data
	_enqueue_raw_locked(peer.remote, _header(kind, peer.conn_id) + payload)


func forget_locked(peer: RefCounted) -> void:
	var d: Dictionary = _servers if peer.server_side else _clients
	if d.get(peer.remote) == peer:
		d.erase(peer.remote)


func _enqueue_raw_locked(remote: int, bytes: PackedByteArray) -> void:
	_outbox.append([remote, bytes])


static func _header(kind: int, cid: int) -> PackedByteArray:
	var h := PackedByteArray()
	h.resize(HEADER)
	h[0] = kind
	h.encode_u32(1, cid)
	return h


static func _code_bytes(code: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, code)
	return b


static func _code_of(bytes: PackedByteArray) -> int:
	return bytes.decode_s32(HEADER) if bytes.size() >= HEADER + 4 else 1000
