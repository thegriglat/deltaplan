extends Node
## Контракт S4 модуля steam (docs/contracts/steam.md): транспорт сети через подключаемые пиры.
## S4.1 — форма пиров ws_peer.gd и loopback_peer.gd; S4.2 — реестр схем NetClient;
## S4.3/S4.4 — клиенты ↔ LocalServer (threaded) через loopback_peer и attach_peer:
## Hello → CreateZone → JoinZone вторым клиентом → PilotState пересылается с fromId.

const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const WS_PEER := preload("res://scripts/net/ws_peer.gd")
const LOOPBACK := preload("res://scripts/net/loopback_peer.gd")
const SCHEME := "s4loop"
const PEER_METHODS := ["poll", "get_state", "pop_text", "send_text", "close", "get_close_code"]

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_s4_1_peer_shape() -> void:
	for script: GDScript in [WS_PEER, LOOPBACK]:
		var consts := script.get_script_constant_map()
		for k: String in ["CONNECTING", "OPEN", "CLOSING", "CLOSED"]:
			check(consts.has(k), "%s.%s" % [script.resource_path, k])
		check(
			[consts.CONNECTING, consts.OPEN, consts.CLOSING, consts.CLOSED]
			== [
				WebSocketPeer.STATE_CONNECTING,
				WebSocketPeer.STATE_OPEN,
				WebSocketPeer.STATE_CLOSING,
				WebSocketPeer.STATE_CLOSED
			],
			"состояния как WebSocketPeer.State: %s" % script.resource_path
		)
		var names := script.get_script_method_list().map(func(m: Dictionary) -> String: return m.name)
		for m: String in PEER_METHODS:
			check(names.has(m), "%s: нет %s" % [script.resource_path, m])
	var ab: Array = LOOPBACK.pair()
	check(ab.size() == 2, "pair() — два конца")
	var a: RefCounted = ab[0]
	var b: RefCounted = ab[1]
	check(a.get_state() == LOOPBACK.OPEN and b.get_state() == LOOPBACK.OPEN, "пара OPEN")
	check(a.get_close_code() == -1, "код закрытия -1 до закрытия")
	check(a.send_text("раз") == OK and a.send_text("два") == OK, "send_text OK")
	b.poll()
	check(b.pop_text() == "раз" and b.pop_text() == "два" and b.pop_text() == null, "порядок кадров")
	a.send_text("последний")
	a.close(4000)
	check(a.get_state() == LOOPBACK.CLOSED and a.get_close_code() == 4000, "своя сторона закрыта")
	b.poll()
	check(b.get_state() == LOOPBACK.CLOSED and b.get_close_code() == 4000, "другая — на poll")
	check(b.pop_text() == "последний", "кадр до закрытия читается")
	check(b.send_text("x") != OK, "в закрытый не отправить")


func test_s4_2_unknown_scheme() -> void:
	var c: Node = NET_CLIENT.new()
	add_child(c)
	var log := []
	c.error.connect(func(code: String, _t: String) -> void: log.append("error:" + code))
	c.disconnected.connect(func(w: bool) -> void: log.append("disconnected:%s" % w))
	check(not c.connect_to_server("nosuch://x", "Пилот"), "нет фабрики — false")
	check(not c.connect_to_server("steam:76561197960287930", "Пилот"), "steam без ST-8 — false")
	check(
		log == ["error:CONNECT_FAILED", "disconnected:false", "error:CONNECT_FAILED", "disconnected:false"],
		"CONNECT_FAILED: %s" % [log]
	)
	check(c.state == c.State.IDLE, "IDLE")
	# фабрика вернула null — попытка не удалась, повторы, затем CONNECT_FAILED
	NET_CLIENT.register_transport(SCHEME, func(_a: String) -> Variant: return null)
	c.reconnect_delays_s = [0.05]
	log.clear()
	check(c.connect_to_server(SCHEME + ":x", "Пилот"), "схема зарегистрирована")
	await _wait(func() -> bool: return c.state == c.State.IDLE, 3.0)
	check(log == ["error:CONNECT_FAILED", "disconnected:false"], "null-пир: %s" % [log])
	NET_CLIENT.register_transport(SCHEME, Callable())
	c.queue_free()


func test_s4_4_loopback_zone() -> void:
	var srv: LocalServer = LocalServer.new()
	check(srv.threaded, "сервер в своём потоке по умолчанию")
	var a_pair: Array = LOOPBACK.pair()
	check(srv.attach_peer(a_pair[1], "до start") == -1, "не запущен — -1")
	add_child(srv)
	check(srv.start(0, "127.0.0.1") == OK, "start")
	var nums := []
	NET_CLIENT.register_transport(
		SCHEME,
		func(address: String) -> Variant:
			var ab: Array = LOOPBACK.pair()
			nums.append(srv.attach_peer(ab[1], address))
			return ab[0]
	)
	var a := _client()
	var b := _client()
	check(a.node.connect_to_server(SCHEME + ":a", "Коля"), "connect a")
	check(b.node.connect_to_server(SCHEME + ":b", "Мама"), "connect b")
	await _wait(func() -> bool: return a.node.is_online and b.node.is_online, 5.0)
	check(a.node.is_online and b.node.is_online, "Welcome обоим: %s %s" % [a.log, b.log])
	check(nums.size() == 2 and nums[0] > 0 and nums[1] > nums[0], "номера соединений %s" % [nums])
	a.node.send("createZone", {"zone": {"seed": 7}})
	await _wait(func() -> bool: return _has(a.log, "zoneJoined"), 5.0)
	var code: String = _first(a.log, "zoneCreated").get("code", "")
	check(code != "", "ZoneCreated: %s" % [a.log])
	check(srv.zones_info().size() == 1 and srv.zones_info()[0].code == code, "zones_info")
	b.node.send("joinZone", {"code": code})
	await _wait(func() -> bool: return _has(b.log, "zoneJoined") and _has(a.log, "peerJoined"), 5.0)
	check(_first(b.log, "zoneJoined").get("peers", []).size() == 2, "двое в зоне: %s" % [b.log])
	a.node.send("pilotState", {"pilotId": a.node.my_id, "name": "Коля", "t": 1.5})
	await _wait(func() -> bool: return _has(b.log, "pilotState"), 5.0)
	var ps: Array = b.log.filter(func(m: Array) -> bool: return m[0] == "pilotState")
	check(ps.size() == 1, "PilotState дошёл: %s" % [b.log])
	if ps.size() == 1:
		check(ps[0][2] == a.node.my_id and ps[0][1].t == 1.5, "fromId и данные: %s" % [ps[0]])
	check(not _has(a.log, "pilotState"), "себе не пересылается")
	# обрыв со стороны клиента → сервер выкидывает соединение, второй видит PeerLeft
	a.node.disconnect_from_server()
	await _wait(func() -> bool: return _has(b.log, "peerLeft"), 5.0)
	check(_has(b.log, "peerLeft") and _has(b.log, "leaderChanged"), "PeerLeft/LeaderChanged: %s" % [b.log])
	srv.stop()
	await _wait(func() -> bool: return b.node.state != b.node.State.ONLINE, 3.0)
	check(not b.node.is_online, "остановка сервера рвёт loopback")
	NET_CLIENT.register_transport(SCHEME, Callable())
	for x: Dictionary in [a, b]:
		x.node.disconnect_from_server()
		x.node.queue_free()
	srv.queue_free()


func _client() -> Dictionary:
	var c: Node = NET_CLIENT.new()
	c.reconnect_delays_s = []
	add_child(c)
	var log := []
	c.message.connect(func(t: String, d: Dictionary, f: String) -> void: log.append([t, d, f]))
	return {"node": c, "log": log}


static func _has(log: Array, type: String) -> bool:
	return log.any(func(m: Array) -> bool: return m[0] == type)


static func _first(log: Array, type: String) -> Dictionary:
	for m: Array in log:
		if m[0] == type:
			return m[1]
	return {}


func _wait(cond: Callable, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
