extends Node
## NET-31. NetZone: Zone ↔ FlightSettings; три клиента и сервер (NetTestServer: Go-сервер и
## встроенный LocalServer, NET-22):
## создание и вход по коду, единый список пилотов и ведущий, часы зоны у всех вместе, источники
## термиков из поля от ведущего (ZoneState.thermalSources, AM-07), уход
## ведущего → ведущий второй, часы без скачка > 0,2 с, очередь сохранилась; неверный код →
## ZONE_NOT_FOUND. Нет go или исходников сервера — вид "go" SKIP (тест проходит).

const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const NET_ZONE := preload("res://scripts/net/net_zone.gd")

var failures: PackedStringArray = []
## Вид сервера текущего прогона ("go" | "local") — в сообщениях о падении.
var _kind := ""


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + ("[%s] " % _kind if _kind != "" else "") + msg)


func test_zone_round_trip() -> void:
	var s := FlightSettings.new()
	s.wing = "wings/laminar"
	s.pilot_mass_kg = 90.0
	s.location_id = "altai"
	s.site_id = "north"
	s.month = 5
	s.day = 9
	s.start_hour = 12.5
	s.temperature_c = 22.0
	s.wind_speed_kmh = 14.4
	s.wind_into_launch = false
	s.wind_from_deg = 135.0
	s.sky = "partly"
	# через провод: encode → decode, как у настоящего клиента
	var m := NetMessages.decode(NetMessages.encode("createZone", {"zone": s.to_zone(4242, 3)}))
	var z: Dictionary = m.data.zone
	check(z.seed == 4242 and z.botsCount == 3, "сид и боты: %s" % [z])
	check(is_nan(z.pickLat) and is_nan(z.pickLon), "точка не задана → NAN")
	var own := FlightSettings.new()
	own.wing = "wings/sport"
	own.pilot_mass_kg = 70.0
	var r := FlightSettings.from_zone(z, own)
	var a := s.to_dict()
	var b := r.to_dict()
	for k in a:
		if k in ["wing", "pilot_mass_kg"]:
			continue
		var same: bool = (
			is_equal_approx(float(a[k]), float(b[k])) if a[k] is float else a[k] == b[k]
		)
		check(same, "%s: %s → %s" % [k, a[k], b[k]])
	check(r.wing == "wings/sport" and r.pilot_mass_kg == 70.0, "крыло и масса — свои")
	# точка с карты
	s.pick_lat = 50.123456
	s.pick_lon = 86.654321
	var m2 := NetMessages.decode(NetMessages.encode("createZone", {"zone": s.to_zone(1, 0)}))
	var r2 := FlightSettings.from_zone(m2.data.zone)
	check(r2.has_pick(), "точка задана")
	check(absf(r2.pick_lat - 50.123456) < 1e-9 and absf(r2.pick_lon - 86.654321) < 1e-9, "точка")


func test_world_key_and_check() -> void:
	var s := FlightSettings.new()
	s.site_id = "north"
	var key: String = NET_ZONE.world_key_for(s, 4711, 4)
	check(key.begins_with("deltaplan://world?"), "ключ: %s" % key)
	check(key == NET_ZONE.world_key_for(s, 4711, 4), "ключ детерминирован")
	check(key != NET_ZONE.world_key_for(s, 4712, 4), "сид в ключе")
	if not s.has_method("world_key"):
		check(key.contains("v=0-stub") and key.contains("bots=4"), "заглушка: %s" % key)
		s.pick_lat = 50.7512
		s.pick_lon = 86.1203
		var kp: String = NET_ZONE.stub_world_key(s, 1, 0)
		check(kp.contains("lat=50.75120&lon=86.12030"), "точка с карты: %s" % kp)
		var q := kp.get_slice("?", 1).split("&")
		var sorted_q := Array(q)
		sorted_q.sort()
		check(Array(q) == sorted_q, "ключи по алфавиту: %s" % kp)
	# хэш — первые 16 hex SHA-256
	var h: String = NET_ZONE.world_hash_of("abc")
	check(h == "ba7816bf8f01cfea", "sha256(abc)[:16]: %s" % h)
	# сверка у вошедшего
	var z: Node = NET_ZONE.new()
	var got := []
	z.world_mismatch.connect(func(e: String, a: String) -> void: got.append([e, a]))
	z.zone = {"worldKey": key, "worldHash": NET_ZONE.world_hash_of(key)}
	check(z.check_world(key), "тот же ключ → true")
	check(got.is_empty(), "без сигнала при совпадении")
	check(not z.check_world(key + "x"), "другой ключ → false")
	check(
		got == [[NET_ZONE.world_hash_of(key), NET_ZONE.world_hash_of(key + "x")]],
		"world_mismatch(expected, actual): %s" % [got]
	)
	z.zone = {"worldKey": "", "worldHash": ""}
	check(z.check_world("что угодно"), "старый создатель без хэша → проверки нет")
	check(got.size() == 1, "пустой хэш — без сигнала")
	z.free()


func test_three_pilots_leader_leaves() -> void:
	for kind: String in NetTestServer.KINDS:
		var srv := _server(kind)
		if srv != null:
			await _three_pilots_leader_leaves(srv)
	_kind = ""


func _three_pilots_leader_leaves(srv: NetTestServer) -> void:
	var a := await _pilot(srv, "Папа")
	var b := await _pilot(srv, "Мама")
	var c := await _pilot(srv, "Друг")
	if not (a.client.is_online and b.client.is_online and c.client.is_online):
		check(false, "не подключились")
		_free([a, b, c])
		srv.stop()
		return
	var za: Node = a.zone
	var zb: Node = b.zone
	var zc: Node = c.zone
	var settings := FlightSettings.new()
	settings.site_id = "north"
	settings.start_hour = 14.0
	za.create_zone(settings, 777, 2)
	await _wait(func() -> bool: return za.in_zone, 3.0)
	check(za.in_zone and za.code.length() == 4 and za.code.is_valid_int(), "код: '%s'" % za.code)
	check(za.is_leader(), "создатель — ведущий")
	zb.join_zone(za.code)
	await _wait(func() -> bool: return zb.in_zone, 3.0)
	zc.join_zone(za.code)
	await _wait(func() -> bool: return zc.in_zone and za.peers.size() == 3, 3.0)
	await _wait(func() -> bool: return zb.peers.size() == 3 and zc.has_clock, 3.0)
	var ids: Array[String] = [a.client.my_id, b.client.my_id, c.client.my_id]
	for z: Node in [za, zb, zc]:
		check(z.peer_ids() == ids, "пилоты по порядку: %s, ждали %s" % [z.peer_ids(), ids])
		check(z.leader_id == ids[0], "ведущий A: %s" % z.leader_id)
		check(z.world_seed == 777 and z.bots_count == 2, "сид и боты из зоны")
		check(z.zone_settings.site_id == "north" and z.zone_settings.start_hour == 14.0, "мир")
	# ключ мира от создателя дошёл до вошедших как есть; своя сверка
	var key: String = NET_ZONE.world_key_for(settings, 777, 2)
	check(key != "" and zb.zone.worldKey == key, "worldKey у B: %s" % zb.zone.worldKey)
	check(zc.zone.worldHash == NET_ZONE.world_hash_of(key), "worldHash у C: %s" % zc.zone.worldHash)
	check(zb.check_world(key), "свой мир совпал")
	check(not zb.is_leader() and not zc.is_leader(), "B и C не ведущие")
	check(za.queue == ids, "очередь у ведущего — живые по порядку: %s" % [za.queue])
	# часы: ZoneState 1 Гц доходит, B и C идут вместе с A
	await _wait(func() -> bool: return false, 1.3)
	check(zb.has_clock and zc.has_clock, "ZoneState дошёл")
	for z: Node in [zb, zc]:
		var d: float = absf(z.zone_time() - za.zone_time())
		check(d < 0.2, "часы у %s отстают от A на %.3f с" % [z.my_id, d])
	check(zb.queue == za.queue and zc.queue == za.queue, "очередь у всех: %s" % [zb.queue])
	# источники термиков из поля (AM-07): ведущий ставит — у всех те же, маска байт в байт
	var mask := PackedByteArray([0x02, 0x04, 0x00, 0x80])
	za.set_thermal_sources("400.000,-19200.000,-19200.000,4,8", mask)
	await _wait(func() -> bool: return not zb.thermal_sources.is_empty(), 2.0)
	await _wait(func() -> bool: return not zc.thermal_sources.is_empty(), 1.0)
	for z: Node in [zb, zc]:
		check(z.thermal_sources == za.thermal_sources, "источники термиков: %s" % [z.thermal_sources])
		var got := Marshalls.base64_to_raw(String(z.thermal_sources.get("mask", "")))
		check(got == mask, "маска источников байт в байт: %s" % [got])
	# очередь с ботами, затем ведущий уходит
	za.set_queue([ids[0], ids[1], ids[2], "bot-1", "bot-2"])
	await _wait(func() -> bool: return zb.queue.size() == 5 and zc.queue.size() == 5, 2.0)
	check(zb.queue.size() == 5, "set_queue дошёл до B: %s" % [zb.queue])
	var leaders := {}
	var track := func(lid: String, me: bool, who: String) -> void: leaders[who] = [lid, me]
	zb.leader_changed.connect(track.bind("b"))
	zc.leader_changed.connect(track.bind("c"))
	var t_before: float = zb.zone_time()
	var t0 := Time.get_ticks_usec() / 1e6
	za.leave_zone()
	check(not za.in_zone, "A вне зоны")
	await _wait(func() -> bool: return leaders.size() == 2, 3.0)
	var elapsed := Time.get_ticks_usec() / 1e6 - t0
	var t_after: float = zb.zone_time()
	var jump := t_after - t_before - elapsed
	check(absf(jump) < 0.2, "часы B при смене ведущего: скачок %.3f с" % jump)
	check(leaders.get("b", []) == [ids[1], true], "B узнал, что он ведущий: %s" % [leaders])
	check(leaders.get("c", []) == [ids[1], false], "C узнал ведущего B: %s" % [leaders])
	check(zb.is_leader() and zc.leader_id == ids[1], "ведущий — B")
	var expect_q: Array[String] = [ids[1], ids[2], "bot-1", "bot-2"]
	check(zb.queue == expect_q, "очередь у B без A: %s" % [zb.queue])
	check(zb.peer_ids() == [ids[1], ids[2]] and zc.peer_ids() == [ids[1], ids[2]], "пилоты B, C")
	# новый ведущий ведёт часы: C идёт за ним, без рывков назад
	var tc_prev: float = zc.zone_time()
	var max_back := [0.0]
	var deadline := Time.get_ticks_msec() + 1300
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var tc: float = zc.zone_time()
		max_back[0] = maxf(max_back[0], tc_prev - tc)
		tc_prev = tc
	check(max_back[0] <= 0.0, "часы C не идут назад: %.4f" % max_back[0])
	check(absf(zc.zone_time() - zb.zone_time()) < 0.2, "C идёт за B")
	check(zc.queue == expect_q, "очередь у C от B: %s" % [zc.queue])
	_free([a, b, c])
	srv.stop()


func test_wrong_code_and_rejoin() -> void:
	for kind: String in NetTestServer.KINDS:
		var srv := _server(kind)
		if srv != null:
			await _wrong_code_and_rejoin(srv)
	_kind = ""


func _wrong_code_and_rejoin(srv: NetTestServer) -> void:
	var a := await _pilot(srv, "Папа")
	var za: Node = a.zone
	var errors := []
	za.zone_error.connect(func(c: String, _t: String) -> void: errors.append(c))
	# коды 4 цифры; зон нет — любой не найден
	za.join_zone("0000")
	await _wait(func() -> bool: return not errors.is_empty(), 3.0)
	check(errors == ["ZONE_NOT_FOUND"], "неверный код: %s" % [errors])
	check(not za.in_zone, "не в зоне")
	# обрыв и возврат в ту же зону с новым id
	za.create_zone(FlightSettings.new(), 1, 0)
	await _wait(func() -> bool: return za.in_zone, 3.0)
	var zone_code: String = za.code
	var entered := []
	za.zone_entered.connect(func(c: String) -> void: entered.append(c))
	await _wait(func() -> bool: return false, 0.5)
	var t_before: float = za.zone_time()
	srv.stop()
	check(srv.start(srv.port), "сервер снова поднят: %s" % srv.last_error)
	await _wait(func() -> bool: return not errors.is_empty() and errors.size() > 1, 5.0)
	# перезапущенный сервер зону забыл → ZONE_NOT_FOUND и выход из зоны
	check(errors.back() == "ZONE_NOT_FOUND", "после перезапуска: %s" % [errors])
	check(not za.in_zone, "вне зоны после пропажи зоны")
	check(entered.is_empty(), "не вошёл обратно в '%s'" % zone_code)
	check(t_before > 0.4, "часы ведущего шли: %.2f" % t_before)
	_free([a])
	srv.stop()


func _server(kind: String) -> NetTestServer:
	_kind = kind
	var srv := NetTestServer.new(kind, self)
	if not srv.is_available():
		check(NetTestServer.build_error == "", NetTestServer.build_error)
		if NetTestServer.build_error == "":
			print("  SKIP test_zone [%s]: %s" % [kind, NetTestServer.skip_reason])
		return null
	if not srv.start():
		check(false, "сервер не запустился: %s" % srv.last_error)
		return null
	return srv


## Клиент + зона, подключённые к серверу: {"client", "zone"}.
func _pilot(srv: NetTestServer, pilot_name: String) -> Dictionary:
	var c: Node = NET_CLIENT.new()
	c.reconnect_delays_s = [0.3, 0.3, 0.3]
	add_child(c)
	var z: Node = NET_ZONE.new()
	z.state_interval_s = 0.5
	z.setup(c)
	add_child(z)
	c.connect_to_server(srv.address, pilot_name)
	await _wait(func() -> bool: return c.is_online, 5.0)
	return {"client": c, "zone": z}


func _free(pilots: Array) -> void:
	for p: Dictionary in pilots:
		p.client.disconnect_from_server()
		p.zone.queue_free()
		p.client.queue_free()


func _wait(cond: Callable, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
