extends RefCounted
## LoopbackPeer — пара пиров сети в памяти (контракт S4.1, docs/contracts/steam.md) для тестов:
## что один отправил send_text, другой получит pop_text, по порядку. Пары создаются сразу
## OPEN. close(code) на любой стороне: своя — сразу CLOSED, другая — CLOSED на своём следующем
## poll() (кадры, отправленные до закрытия, ещё читаются). Стороны можно опрашивать из разных
## потоков (общая очередь под мьютексом) — так встроенный сервер в своём потоке держит одну
## сторону, клиент в главном — другую.

const CONNECTING := 0
const OPEN := 1
const CLOSING := 2
const CLOSED := 3


## Общее состояние пары.
class Link:
	extends RefCounted
	var mutex := Mutex.new()
	## Очереди принятых кадров по сторонам: inbox[0] читает сторона 0.
	var inbox: Array = [[], []]
	var closed := false
	var close_code := -1


var _link: Link
var _side := 0
var _state := OPEN
var _close_code := -1


## [a, b] — два конца одного соединения.
static func pair() -> Array:
	var script: GDScript = load("res://scripts/net/loopback_peer.gd")
	var link := Link.new()
	var a: RefCounted = script.new()
	var b: RefCounted = script.new()
	a._link = link
	a._side = 0
	b._link = link
	b._side = 1
	return [a, b]


func poll() -> void:
	if _state == CLOSED:
		return
	_link.mutex.lock()
	if _link.closed:
		_state = CLOSED
		_close_code = _link.close_code
	_link.mutex.unlock()


func get_state() -> int:
	return _state


func pop_text() -> Variant:
	_link.mutex.lock()
	var q: Array = _link.inbox[_side]
	var out: Variant = null if q.is_empty() else q.pop_front()
	_link.mutex.unlock()
	return out


func send_text(text: String) -> Error:
	if _state != OPEN:
		return ERR_UNAVAILABLE
	_link.mutex.lock()
	var ok := not _link.closed
	if ok:
		_link.inbox[1 - _side].append(text)
	_link.mutex.unlock()
	return OK if ok else ERR_UNAVAILABLE


func close(code: int = 1000) -> void:
	if _state == CLOSED:
		return
	_link.mutex.lock()
	if not _link.closed:
		_link.closed = true
		_link.close_code = code
	_close_code = _link.close_code
	_link.mutex.unlock()
	_state = CLOSED


func get_close_code() -> int:
	return _close_code
