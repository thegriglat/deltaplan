extends RefCounted
## SteamPeer — пир сети (контракт S4.1, docs/contracts/steam.md) поверх Steam Networking Messages:
## одно соединение с пользователем Steam, кадры — строки UTF-8 (одна строка = один Envelope).
## Сам пир Steam не трогает: кадры кладёт в очередь и берёт из очереди своего SteamTransport
## (scripts/steam/steam_transport.gd), который один говорит со Steam — в главном потоке.
## Поэтому методы пира можно звать из любого потока (встроенный сервер опрашивает своих пиров
## в своём потоке) — всё под мьютексом транспорта.
##
## Состояния: создаётся сразу OPEN (у Messages нет рукопожатия: сессию Steam открывает первый
## кадр); CLOSED — close() своей стороной, кадр «закрыть» с той стороны, обрыв сессии Steam
## (network_messages_session_failed, код 1006). Кадры, пришедшие до закрытия, ещё читаются.

const CONNECTING := 0
const OPEN := 1
const CLOSING := 2
const CLOSED := 3
## Код закрытия при обрыве сессии Steam (как «соединение потеряно» у WebSocket).
const CODE_LOST := 1006

## Транспорт (Node — не считается ссылкой, цикла нет).
var transport: Object
## Steam ID той стороны.
var remote := 0
## Номер соединения (случайный, выбирает клиент): отличает новое подключение того же
## пользователя от старого.
var conn_id := 0
## true — пир хозяина (принятый встроенным сервером), false — клиент к хозяину.
var server_side := false

var _state := OPEN
var _close_code := -1
var _inbox: Array[String] = []


func poll() -> void:
	pass


func get_state() -> int:
	transport.mutex.lock()
	var s := _state
	transport.mutex.unlock()
	return s


func pop_text() -> Variant:
	transport.mutex.lock()
	var out: Variant = null if _inbox.is_empty() else _inbox.pop_front()
	transport.mutex.unlock()
	return out


func send_text(text: String) -> Error:
	transport.mutex.lock()
	var ok := _state == OPEN
	if ok:
		transport.enqueue_locked(self, text.to_utf8_buffer(), false, 0)
	transport.mutex.unlock()
	return OK if ok else ERR_UNAVAILABLE


func close(code: int = 1000) -> void:
	transport.mutex.lock()
	if _state != CLOSED:
		_state = CLOSED
		_close_code = code
		transport.enqueue_locked(self, PackedByteArray(), true, code)
		transport.forget_locked(self)
	transport.mutex.unlock()


func get_close_code() -> int:
	transport.mutex.lock()
	var c := _close_code
	transport.mutex.unlock()
	return c


# ---------------------------------------------------------------- для транспорта (под мьютексом)


func push_locked(text: String) -> void:
	if _state != CLOSED:
		_inbox.append(text)


func close_remote_locked(code: int) -> void:
	if _state != CLOSED:
		_state = CLOSED
		_close_code = code
