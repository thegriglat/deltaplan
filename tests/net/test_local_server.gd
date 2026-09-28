extends Node
## NET-22. Встроенный сервер LocalServer и NetZone.host_local: три клиента на одной машине
## (создатель — через host_local, двое входят по коду), пересылка PilotState и ZoneState с
## fromId, zones_info и сигналы зоны, объявление зоны в локальной сети (LanDiscovery); выход
## создателя → сервер остановлен, объявление прекращено, у остальных обрыв
## и zone_left. Отдельно — правила сервера: Hello первым, мусор → BAD_MESSAGE, неверный путь,
## ZONE_NOT_FOUND, VERSION_MISMATCH, занятый порт → PORT_BUSY.

const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const NET_ZONE := preload("res://scripts/net/net_zone.gd")
const LAN := preload("res://scripts/net/lan_discovery.gd")
const PORT_MIN := 20000
const PORT_MAX := 40000

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_three_clients_host_local() -> void:
	var a := _pilot()
	var za: Node = a.zone
	var errors := []
	za.zone_error.connect(func(c: String, _t: String) -> void: errors.append(c))
	var settings := FlightSettings.new()
	settings.site_id = "north"
	var port := _free_port()
	var lan_port := _free_port()
	var lan_tx: Node = LAN.new()
	var lan_rx: Node = LAN.new()
	for lan: Node in [lan_tx, lan_rx]:
		lan.port = lan_port
		lan.broadcast_address = "127.0.0.1"
		add_child(lan)
	check(lan_rx.start_listening(), "слушатель LAN")
	za.lan_discovery = lan_tx
	za.host_local(settings, 4711, 0, "Коля", port)
	check(za.is_hosting(), "сервер запущен: %s" % [errors])
	var opened := []
	var closed := []
	za.local_server.zone_opened.connect(func(c: String) -> void: opened.append(c))
	za.local_server.zone_closed.connect(func(c: String) -> void: closed.append(c))
	await _wait(func() -> bool: return za.in_zone, 5.0)
	check(za.in_zone and za.is_leader(), "создатель в зоне и ведущий: %s" % [errors])
	check(za.local_server.port == port, "порт %d" % za.local_server.port)
	check(opened == [za.code], "zone_opened: %s" % [opened])
	var b := _pilot()
	var c := _pilot()
	var addr := "127.0.0.1:%d" % port
	b.client.connect_to_server(addr, "Мама")
	c.client.connect_to_server(addr, "Друг")
	await _wait(func() -> bool: return b.client.is_online and c.client.is_online, 5.0)
	b.zone.join_zone(za.code)
	await _wait(func() -> bool: return b.zone.in_zone, 5.0)
	c.zone.join_zone(za.code)
	await _wait(
		func() -> bool: return b.zone.in_zone and c.zone.in_zone and za.peers.size() == 3, 5.0
	)
	var ids: Array[String] = [a.client.my_id, b.client.my_id, c.client.my_id]
	for p: Dictionary in [a, b, c]:
		check(p.zone.peer_ids() == ids, "пилоты: %s, ждали %s" % [p.zone.peer_ids(), ids])
		check(p.zone.leader_id == ids[0], "ведущий — создатель")
		check(p.zone.world_seed == 4711, "сид зоны")
	var info: Array = za.local_server.zones_info()
	check(info.size() == 1, "zones_info: %s" % [info])
	if info.size() == 1:
		check(info[0].code == za.code and info[0].pilots_count == 3, "код и число: %s" % [info])
		check(info[0].host_name == "Коля" and info[0].port == port, "имя и порт: %s" % [info])
	# зона объявлена в локальной сети (свой LanDiscovery на 127.0.0.1)
	# число пилотов обновляется с периодическим объявлением (раз в секунду)
	await _wait(
		func() -> bool: return lan_rx.zones.size() == 1 and lan_rx.zones[0].pilots_count == 3, 3.0
	)
	check(lan_rx.zones.size() == 1, "зона видна в LAN: %s" % [lan_rx.zones])
	if lan_rx.zones.size() == 1:
		var seen: Dictionary = lan_rx.zones[0]
		check(seen.code == za.code and seen.port == port, "объявление: %s" % [seen])
		check(seen.host_name == "Коля" and seen.pilots_count == 3, "объявление: %s" % [seen])
	# PilotState каждого доходит до двух других с fromId; ZoneState ведущего — до всех
	var got := {}
	for p: Dictionary in [a, b, c]:
		var me: String = p.client.my_id
		p.zone.pilot_state_received.connect(
			func(from_id: String, d: Dictionary) -> void:
				got["%s<-%s" % [me, from_id]] = d.pilotId
		)
	for p: Dictionary in [a, b, c]:
		var d := NetMessages.defaults("pilotState")
		d.pilotId = p.client.my_id
		d.pos = Vector3(1.0, 2.0, 3.0)
		check(p.zone.send_pilot_state(d), "отправка состояния")
	await _wait(func() -> bool: return got.size() == 6, 3.0)
	check(got.size() == 6, "состояния: %s" % [got])
	for k: String in got:
		check(got[k] == k.get_slice("<-", 1), "fromId = pilotId: %s" % k)
	await _wait(func() -> bool: return b.zone.has_clock and c.zone.has_clock, 3.0)
	check(b.zone.has_clock and c.zone.has_clock, "ZoneState дошёл")
	# создатель выходит → сервер остановлен, у остальных обрыв, повторы и выход из зоны
	var left := []
	b.zone.zone_left.connect(func() -> void: left.append("b"))
	c.zone.zone_left.connect(func() -> void: left.append("c"))
	var b_log := []
	b.client.disconnected.connect(func(w: bool) -> void: b_log.append("disconnected:%s" % w))
	b.client.error.connect(func(e: String, _t: String) -> void: b_log.append("error:" + e))
	var code: String = za.code
	za.leave_zone()
	check(not za.is_hosting(), "сервер остановлен")
	check(not a.client.is_online and a.client.state == a.client.State.IDLE, "создатель отключён")
	check(closed == [code], "zone_closed: %s" % [closed])
	check(za.local_server.zones_info().is_empty(), "зон нет")
	check(not lan_tx.is_announcing(), "объявление остановлено")
	await _wait(func() -> bool: return left.size() == 2, 5.0)
	check(left.size() == 2, "B и C вышли из зоны: %s" % [left])
	check(
		b_log == ["disconnected:true", "error:CONNECT_FAILED", "disconnected:false"],
		"B: обрыв, повторы, ошибка: %s" % [b_log]
	)
	_free([a, b, c])
	lan_tx.queue_free()
	lan_rx.queue_free()


func test_protocol_rules() -> void:
	var srv: LocalServer = LocalServer.new()
	add_child(srv)
	check(srv.start(0, "127.0.0.1") == OK and srv.port > 0, "start на свободном порту")
	var url := "ws://127.0.0.1:%d/v1/ws" % srv.port
	var ws := WebSocketPeer.new()
	ws.connect_to_url(url)
	await _wait(func() -> bool: return _poll(ws) == WebSocketPeer.STATE_OPEN, 3.0)
	# до Hello — BAD_MESSAGE; мусор — BAD_MESSAGE; незнакомый вариант — молча
	ws.send_text(NetMessages.encode("ping", {"clientTime": 1.0}))
	ws.send_text("not json")
	ws.send_text('{"someFutureMessage": {}}')
	ws.send_text(NetMessages.encode("hello", {"gameVersion": "1.0", "name": "Пилот"}))
	ws.send_text(NetMessages.encode("ping", {"clientTime": 5.5}))
	ws.send_text(NetMessages.encode("joinZone", {"code": "0000"}))
	ws.send_text(NetMessages.encode("welcome", {"yourId": "x"}))
	var msgs := []
	await _wait(func() -> bool: return _read(ws, msgs) >= 6, 3.0)
	var types := msgs.map(func(m: Dictionary) -> String: return _short(m))
	var expect := [
		"error:BAD_MESSAGE",
		"error:BAD_MESSAGE",
		"welcome",
		"pong",
		"error:ZONE_NOT_FOUND",
		"error:BAD_MESSAGE",
	]
	check(types == expect, "ответы: %s" % [types])
	if msgs.size() >= 4:
		var pong: Dictionary = msgs[3].data
		check(pong.clientTime == 5.5, "clientTime как был")
		var skew: float = pong.serverTime - Time.get_unix_time_from_system()
		check(absf(skew) < 1.0, "serverTime — секунды Unix: %.3f" % skew)
	# зона другой версии → VERSION_MISMATCH
	ws.send_text(NetMessages.encode("createZone", {"zone": {"seed": 1}}))
	msgs.clear()
	await _wait(func() -> bool: return _read(ws, msgs) >= 2, 3.0)
	var zone_code: String = msgs[0].data.code if not msgs.is_empty() else ""
	check(msgs.map(func(m: Dictionary) -> String: return _short(m)) == ["zoneCreated", "zoneJoined"])
	var ws2 := WebSocketPeer.new()
	ws2.connect_to_url(url)
	await _wait(func() -> bool: return _poll(ws2) == WebSocketPeer.STATE_OPEN, 3.0)
	ws2.send_text(NetMessages.encode("hello", {"gameVersion": "2.0", "name": "Другой"}))
	ws2.send_text(NetMessages.encode("joinZone", {"code": zone_code}))
	var msgs2 := []
	await _wait(func() -> bool: return _read(ws2, msgs2) >= 2, 3.0)
	check(
		msgs2.map(func(m: Dictionary) -> String: return _short(m))
		== ["welcome", "error:VERSION_MISMATCH"],
		"другая версия: %s" % [msgs2]
	)
	# неверный путь — соединение закрыто
	var ws3 := WebSocketPeer.new()
	ws3.connect_to_url("ws://127.0.0.1:%d/other" % srv.port)
	await _wait(func() -> bool: return _poll(ws3) == WebSocketPeer.STATE_CLOSED, 3.0)
	check(ws3.get_ready_state() == WebSocketPeer.STATE_CLOSED, "неверный путь закрыт")
	check(ws3.get_close_code() == LocalServer.CLOSE_BAD_PATH, "код %d" % ws3.get_close_code())
	# занятый порт → ERR_ALREADY_IN_USE; NetZone.host_local → PORT_BUSY
	var other: LocalServer = LocalServer.new()
	add_child(other)
	check(other.start(srv.port) == ERR_ALREADY_IN_USE, "порт занят")
	var p := _pilot()
	var errs := []
	p.zone.zone_error.connect(func(c: String, _t: String) -> void: errs.append(c))
	p.zone.host_local(FlightSettings.new(), 1, 0, "Коля", srv.port)
	check(errs == ["PORT_BUSY"] and not p.zone.is_hosting(), "PORT_BUSY: %s" % [errs])
	ws.close()
	ws2.close()
	srv.stop()
	check(not srv.is_running() and srv.port == 0, "остановлен")
	_free([p])
	other.queue_free()
	srv.queue_free()


func _pilot() -> Dictionary:
	var c: Node = NET_CLIENT.new()
	c.reconnect_delays_s = [0.2, 0.2, 0.2]
	add_child(c)
	var z: Node = NET_ZONE.new()
	z.state_interval_s = 0.3
	z.setup(c)
	add_child(z)
	return {"client": c, "zone": z}


func _free(pilots: Array) -> void:
	for p: Dictionary in pilots:
		p.zone.stop_hosting()
		p.client.disconnect_from_server()
		p.zone.queue_free()
		p.client.queue_free()


## Свободный порт на всех адресах (как слушает host_local).
func _free_port() -> int:
	for i in 20:
		var p := randi_range(PORT_MIN, PORT_MAX)
		var probe := TCPServer.new()
		if probe.listen(p) == OK:
			probe.stop()
			return p
	return PORT_MIN


func _poll(ws: WebSocketPeer) -> int:
	ws.poll()
	return ws.get_ready_state()


## Дочитать пришедшие кадры в msgs; вернуть их число.
func _read(ws: WebSocketPeer, msgs: Array) -> int:
	ws.poll()
	while ws.get_available_packet_count() > 0:
		msgs.append(NetMessages.decode(ws.get_packet().get_string_from_utf8()))
	return msgs.size()


static func _short(m: Dictionary) -> String:
	if m.is_empty():
		return "?"
	if m.type == "error":
		return "error:" + NetMessages.short_enum(m.data.code)
	return m.type


func _wait(cond: Callable, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
