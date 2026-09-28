extends Node
## NET-30. NetClient против сервера (NetTestServer: Go-сервер и встроенный LocalServer, NET-22):
## подключение, Hello → Welcome, Ping/Pong (задержка, смещение часов сервера), обрыв →
## disconnected и 3 повтора → ошибка, перезапуск сервера во время повторов → переподключение
## с новым id. Нет go или исходников сервера — вид "go" SKIP (тест проходит).

const NET_CLIENT := preload("res://scripts/net/net_client.gd")

var failures: PackedStringArray = []
## Вид сервера текущего прогона ("go" | "local") — в сообщениях о падении.
var _kind := ""


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + ("[%s] " % _kind if _kind != "" else "") + msg)


func test_make_url() -> void:
	check(NET_CLIENT.make_url("192.168.1.5:9000") == "ws://192.168.1.5:9000/v1/ws", "IP:порт")
	var no_port := NET_CLIENT.make_url(" fly.example.org ")
	check(no_port == "ws://fly.example.org:8080/v1/ws", "без порта — 8080")
	check(NET_CLIENT.make_url("[::1]:7000") == "ws://[::1]:7000/v1/ws", "IPv6")
	check(NET_CLIENT.make_url("ws://h:1/v1/ws") == "ws://h:1/v1/ws", "полный URL")
	check(NET_CLIENT.make_url("ws://h:1") == "ws://h:1/v1/ws", "URL без пути")
	for bad in ["", "h:x", "h:0", "h:70000", "a:b:c", "h/x:1"]:
		check(NET_CLIENT.make_url(bad) == "", "плохой адрес '%s'" % bad)


func test_connect_failed_without_server() -> void:
	var c := _client()
	var log := _record(c)
	# порт 1 на localhost никто не слушает; первое подключение не повторяется
	c.connect_to_server("127.0.0.1:1", "Пилот")
	await _wait(func() -> bool: return c.state == c.State.IDLE, 5.0)
	check(log.has("error:CONNECT_FAILED"), "CONNECT_FAILED: %s" % [log])
	check(log.back() == "disconnected:false", "последним disconnected(false): %s" % [log])
	check(not log.any(func(e: String) -> bool: return e.begins_with("reconnecting")), "без повторов")
	c.queue_free()


func test_hello_ping() -> void:
	for kind: String in NetTestServer.KINDS:
		var srv := _server(kind)
		if srv != null:
			await _hello_ping(srv)
	_kind = ""


func _hello_ping(srv: NetTestServer) -> void:
	var c := _client()
	c.ping_interval_s = 0.1
	var log := _record(c)
	var pongs := [0]
	c.message.connect(
		func(type: String, _d: Dictionary, _f: String) -> void: pongs[0] += int(type == "pong")
	)
	check(c.connect_to_server(srv.address, "Пилот"), "адрес разобран")
	await _wait(func() -> bool: return c.is_online, 5.0)
	check(c.is_online and c.my_id != "", "Welcome: my_id = '%s'" % c.my_id)
	check(log.has("connected:false"), "connected(false): %s" % [log])
	check(log.has("message:welcome"), "welcome и в message")
	await _wait(func() -> bool: return pongs[0] >= 5, 5.0)
	check(pongs[0] >= 5, "Pong пришли: %d" % pongs[0])
	check(c.latency_ms >= 0.0 and c.latency_ms < 100.0, "RTT на localhost: %.2f мс" % c.latency_ms)
	var skew: float = c.server_time() - Time.get_unix_time_from_system()
	check(c.has_server_time and absf(skew) < 0.2, "часы сервера: расхождение %.3f с" % skew)
	# работает и на паузе дерева
	get_tree().paused = true
	var before: int = pongs[0]
	await _wait(func() -> bool: return pongs[0] >= before + 2, 3.0)
	get_tree().paused = false
	check(pongs[0] >= before + 2, "Ping/Pong идут на паузе")
	c.disconnect_from_server()
	check(log.back() == "disconnected:false" and not c.is_online, "явное отключение")
	await _wait(func() -> bool: return false, 0.3)
	check(c.state == c.State.IDLE and log.back() == "disconnected:false", "без переподключения")
	c.queue_free()
	srv.stop()


func test_drop_retries_then_error() -> void:
	for kind: String in NetTestServer.KINDS:
		var srv := _server(kind)
		if srv != null:
			await _drop_retries_then_error(srv)
	_kind = ""


func _drop_retries_then_error(srv: NetTestServer) -> void:
	var c := _client()
	c.reconnect_delays_s = [0.2, 0.2, 0.2]
	var log := _record(c)
	c.connect_to_server(srv.address, "Пилот")
	await _wait(func() -> bool: return c.is_online, 5.0)
	check(c.is_online, "подключился")
	srv.stop()
	await _wait(func() -> bool: return log.has("disconnected:true"), 5.0)
	check(log.has("disconnected:true"), "обрыв → disconnected(true): %s" % [log])
	check(c.my_id == "", "my_id сброшен")
	await _wait(func() -> bool: return log.has("disconnected:false"), 10.0)
	var tail := log.slice(log.find("disconnected:true"))
	var expect := [
		"disconnected:true",
		"reconnecting:1",
		"reconnecting:2",
		"reconnecting:3",
		"error:CONNECT_FAILED",
		"disconnected:false",
	]
	check(tail == expect, "последовательность %s" % [tail])
	check(c.state == c.State.IDLE, "IDLE после ошибки")
	c.queue_free()


func test_reconnect_after_restart() -> void:
	for kind: String in NetTestServer.KINDS:
		var srv := _server(kind)
		if srv != null:
			await _reconnect_after_restart(srv)
	_kind = ""


func _reconnect_after_restart(srv: NetTestServer) -> void:
	var c := _client()
	c.reconnect_delays_s = [0.5, 0.5, 0.5]
	var log := _record(c)
	c.connect_to_server(srv.address, "Пилот")
	await _wait(func() -> bool: return c.is_online, 5.0)
	var first_id: String = c.my_id
	srv.stop()
	await _wait(func() -> bool: return log.has("reconnecting:2"), 5.0)
	check(log.has("reconnecting:2"), "повторы идут: %s" % [log])
	check(srv.start(srv.port), "сервер снова поднят: %s" % srv.last_error)
	await _wait(func() -> bool: return c.is_online, 5.0)
	check(c.is_online, "переподключился: %s" % [log])
	check(log.has("connected:true"), "connected(true): %s" % [log])
	check(not log.has("error:CONNECT_FAILED"), "без CONNECT_FAILED")
	# новое соединение — новый Welcome; перезапущенный сервер считает id заново, так что id
	# может совпасть с прежним — важно лишь, что он выдан снова
	check(c.my_id != "", "id выдан снова (был %s, стал %s)" % [first_id, c.my_id])
	c.queue_free()
	srv.stop()


func _server(kind: String) -> NetTestServer:
	_kind = kind
	var srv := NetTestServer.new(kind, self)
	if not srv.is_available():
		check(NetTestServer.build_error == "", NetTestServer.build_error)
		if NetTestServer.build_error == "":
			print("  SKIP test_net_client [%s]: %s" % [kind, NetTestServer.skip_reason])
		return null
	if not srv.start():
		check(false, "сервер не запустился: %s" % srv.last_error)
		return null
	return srv


func _client() -> Node:
	var c: Node = NET_CLIENT.new()
	add_child(c)
	return c


## Журнал сигналов клиента строками "имя:аргумент".
func _record(c: Node) -> Array:
	var log := []
	c.connected.connect(func(r: bool) -> void: log.append("connected:%s" % r))
	c.disconnected.connect(func(w: bool) -> void: log.append("disconnected:%s" % w))
	c.reconnecting.connect(func(a: int) -> void: log.append("reconnecting:%d" % a))
	c.error.connect(func(code: String, _t: String) -> void: log.append("error:" + code))
	c.message.connect(
		func(type: String, _d: Dictionary, _f: String) -> void:
			if type == "welcome":
				log.append("message:welcome")
	)
	return log


func _wait(cond: Callable, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
