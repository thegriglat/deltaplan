extends RefCounted
## WsPeer — пир сети (контракт S4.1, docs/contracts/steam.md) поверх WebSocketPeer: одно
## соединение, кадры — строки UTF-8 (одна строка = один Envelope). Клиент — connect_to(url),
## принятое сервером — accept(stream, …). Двоичные кадры pop_text пропускает и считает в
## binary_frames (встроенный сервер отвечает на них BAD_MESSAGE).
##
## Сверх S4.1 (только у WebSocket): get_requested_url() — путь запроса принятого соединения,
## get_close_reason(), binary_frames. Причину закрытия пир ставит по коду (REASONS).

const CONNECTING := 0
const OPEN := 1
const CLOSING := 2
const CLOSED := 3

## Причины закрытия по коду (уходят в кадр Close, как раньше передавались явно).
const REASONS := {1000: "bye", 1001: "server stopped", 4404: "not found"}

var ws: WebSocketPeer
## Сколько двоичных кадров пропущено (растёт; читатель сам помнит, сколько уже видел).
var binary_frames := 0


## Клиентское соединение; null — connect_to_url не начал подключение.
static func connect_to(url: String) -> RefCounted:
	var p: RefCounted = load("res://scripts/net/ws_peer.gd").new()
	p.ws = WebSocketPeer.new()
	if p.ws.connect_to_url(url) != OK:
		return null
	return p


## Соединение, принятое сервером по TCP; null — рукопожатие не начать.
static func accept(
	stream: StreamPeerTCP, inbound: int, outbound: int, heartbeat_s: float
) -> RefCounted:
	var p: RefCounted = load("res://scripts/net/ws_peer.gd").new()
	p.ws = WebSocketPeer.new()
	p.ws.inbound_buffer_size = inbound
	p.ws.outbound_buffer_size = outbound
	p.ws.heartbeat_interval = heartbeat_s
	if p.ws.accept_stream(stream) != OK:
		return null
	return p


func poll() -> void:
	ws.poll()


func get_state() -> int:
	return ws.get_ready_state()


func pop_text() -> Variant:
	while ws.get_available_packet_count() > 0:
		var pkt := ws.get_packet()
		if ws.was_string_packet():
			return pkt.get_string_from_utf8()
		binary_frames += 1
	return null


func send_text(text: String) -> Error:
	return ws.send_text(text)


func close(code: int = 1000) -> void:
	ws.close(code, REASONS.get(code, ""))


func get_close_code() -> int:
	return ws.get_close_code()


func get_close_reason() -> String:
	return ws.get_close_reason()


func get_requested_url() -> String:
	return ws.get_requested_url()
