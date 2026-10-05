extends Node
## ST-8: сеть через Steam на подставном Steam-API (tests/steam/fake_steam_net.gd) — двое
## «пользователей Steam» в одном процессе. Транспорт (S4.1 Steam-пир, кадры в обе стороны,
## закрытие, обрыв сессии, отказ без хозяина), лобби хозяина и вход участника (S5):
## лобби → пир → Hello/JoinZone/PilotState, другая версия, «Друзья в игре», приглашение.

const FakeNet := preload("res://tests/steam/fake_steam_net.gd")
const TRANSPORT := preload("res://scripts/steam/steam_transport.gd")
const PEER := preload("res://scripts/steam/steam_peer.gd")
const LOBBY := preload("res://scripts/steam/steam_lobby.gd")
const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const NET_ZONE := preload("res://scripts/net/net_zone.gd")
const A_ID := 76561198000000001
const B_ID := 76561198000000002

var failures: PackedStringArray = []


## LanDiscovery-заглушка: хозяин в тестах ничего не объявляет в локальной сети.
class StubLan:
	extends Node
	signal zones_changed
	var zones: Array = []

	func is_announcing() -> bool:
		return false

	func start_announcing(_source: Callable) -> void:
		pass

	func announce_now() -> void:
		pass

	func stop_announcing() -> void:
		pass


## SteamPresence-заглушка (S3 v2): запоминает set_lobby.
class StubPresence:
	extends Node
	var calls: Array = []

	func set_lobby(id: int) -> void:
		calls.append(id)


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _wait(cond: Callable, timeout_s: float = 5.0) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _transport(api: Object) -> Node:
	var t: Node = TRANSPORT.new()
	add_child(t)
	t.setup(api)
	return t


## Транспорт сам по себе: кадры в обе стороны, номер соединения, закрытие, обрыв, отказ.
func test_transport_frames() -> void:
	var net := FakeNet.new()
	var ua := net.user(A_ID, "Хозяин")
	var ub := net.user(B_ID, "Гость")
	var ta := _transport(ua)
	var tb := _transport(ub)
	var accepted: Array = []
	ta.peer_accepted.connect(func(p: RefCounted) -> void: accepted.append(p))
	# хозяин не принимает — новому соединению сразу «закрыть»
	var p0: RefCounted = tb.open_peer(A_ID)
	check(p0.get_state() == PEER.OPEN and p0.get_close_code() == -1, "клиентский пир сразу OPEN")
	check(p0.send_text("{\"hello\":{}}") == OK, "send_text OK")
	await _wait(func() -> bool: return p0.get_state() == PEER.CLOSED)
	check(p0.get_state() == PEER.CLOSED and p0.get_close_code() == TRANSPORT.CODE_NOT_HOSTING, "отказ без хозяина: %d" % p0.get_close_code())
	check(accepted.is_empty(), "не принят")
	# хозяин принимает
	ta.accepting = true
	var p1: RefCounted = tb.open_peer(A_ID)
	p1.send_text("раз")
	p1.send_text("два")
	await _wait(func() -> bool: return accepted.size() == 1)
	check(accepted.size() == 1, "peer_accepted")
	if accepted.size() != 1:
		net.free_all()
		return
	var h: RefCounted = accepted[0]
	check(h.server_side and h.remote == B_ID and h.conn_id == p1.conn_id, "пир хозяина: тот же номер соединения")
	await _wait(func() -> bool: return h._inbox.size() == 2)
	check(h.pop_text() == "раз" and h.pop_text() == "два" and h.pop_text() == null, "порядок кадров")
	check(h.send_text("ответ") == OK, "ответ хозяина")
	await _wait(func() -> bool: return p1._inbox.size() == 1)
	check(p1.pop_text() == "ответ", "ответ дошёл")
	# переподключение тем же пользователем: старое соединение хозяина закрывается
	var p2: RefCounted = tb.open_peer(A_ID)
	check(p1.get_state() == PEER.CLOSED, "старый клиентский пир закрыт")
	p2.send_text("снова")
	await _wait(func() -> bool: return accepted.size() == 2)
	check(h.get_state() == PEER.CLOSED, "старый пир хозяина закрыт (BYE или новое соединение)")
	var h2: RefCounted = accepted[accepted.size() - 1]
	await _wait(func() -> bool: return h2._inbox.size() == 1)
	check(h2.pop_text() == "снова" and h2.conn_id == p2.conn_id, "новое соединение")
	# закрытие хозяином: клиент видит CLOSED с кодом; кадры до закрытия читаются
	h2.send_text("последний")
	h2.close(4000)
	check(h2.send_text("x") != OK, "в закрытый не отправить")
	await _wait(func() -> bool: return p2.get_state() == PEER.CLOSED)
	check(p2.get_close_code() == 4000 and p2.pop_text() == "последний", "закрытие хозяином: %d" % p2.get_close_code())
	# обрыв сессии Steam — CLOSED 1006 у обоих
	var p3: RefCounted = tb.open_peer(A_ID)
	p3.send_text("x")
	await _wait(func() -> bool: return accepted.size() == 3)
	var h3: RefCounted = accepted[accepted.size() - 1]
	net.break_session(ua, ub)
	check(p3.get_state() == PEER.CLOSED and p3.get_close_code() == PEER.CODE_LOST, "обрыв у клиента")
	check(h3.get_state() == PEER.CLOSED and h3.get_close_code() == PEER.CODE_LOST, "обрыв у хозяина")
	check(ta.peer_counts() == Vector2i(0, 0) and tb.peer_counts() == Vector2i(0, 0), "пиры забыты")
	ta.queue_free()
	tb.queue_free()
	net.free_all()


## Хозяин и участник: лобби (данные S5, присутствие) → Steam-пир → Hello/JoinZone/PilotState
## в обе стороны → участник вышел (лобби, PeerLeft) → хозяин закрыл зону (вышел из лобби).
func test_two_users_lobby_zone_pilot_state() -> void:
	var net := FakeNet.new()
	var a := _side(net.user(A_ID, "Хозяин"), A_ID)
	var b := _side(net.user(B_ID, "Гость"), B_ID)
	b.lobby.register_transport()
	var lid := await _host(a)
	check(lid > 0, "лобби создано")
	if lid <= 0:
		_cleanup(net, [a, b])
		return
	var data: Dictionary = net.lobbies[lid].data
	check(net.lobbies[lid].type == LOBBY.LOBBY_TYPE_FRIENDS_ONLY and net.lobbies[lid].max == 16, "только друзья, 16")
	check(data.get("dp") == "1" and data.get("dp_zone") == a.zone.code and data.get("dp_host") == str(A_ID), "данные лобби: %s" % [data])
	check(data.get("dp_ver") == NET_CLIENT._game_version() and data.get("dp_name") == "Хозяин", "версия и имя: %s" % [data])
	check(String(data.get("dp_place", "")) != "", "место: %s" % [data])
	check(a.presence.calls == [lid], "присутствие хозяина: %s" % [a.presence.calls])

	var backend := NetUiClientBackend.new(b.client, b.zone, b.lan, b.lobby)
	var joined: Array = []
	var errors: Array = []
	backend.zone_joined.connect(func(c: String) -> void: joined.append(c))
	backend.failed.connect(func(k: String) -> void: errors.append(k))
	check(backend.steam_available(), "Steam у участника активен")
	backend.connect_and_join_lobby(lid, "Гость")
	check(backend.is_busy(), "подключение идёт")
	await _wait(func() -> bool: return not joined.is_empty() or not errors.is_empty(), 8.0)
	check(joined == [a.zone.code] and errors.is_empty(), "вошёл в зону хозяина: %s %s" % [joined, errors])
	check(String(b.client.address) == "steam:%d" % A_ID, "адрес NetClient: %s" % b.client.address)
	check(b.lobby.lobby_id == lid and b.lobby.role == "member" and b.presence.calls == [lid], "участник в лобби")
	check(net.lobbies[lid].members.has(B_ID), "в лобби Steam двое")
	await _wait(func() -> bool: return a.zone.peers.size() == 2)
	check(a.zone.peers.size() == 2 and b.zone.peers.size() == 2, "двое в зоне")
	check(a.lobby.transport.peer_counts().y == 1, "у хозяина одно Steam-соединение")

	var got_b: Array = []
	var got_a: Array = []
	b.zone.pilot_state_received.connect(func(f: String, d: Dictionary) -> void: got_b.append([f, d]))
	a.zone.pilot_state_received.connect(func(f: String, d: Dictionary) -> void: got_a.append([f, d]))
	a.zone.send_pilot_state({"pilotId": a.zone.my_id, "name": "Хозяин", "t": 1.5})
	b.zone.send_pilot_state({"pilotId": b.zone.my_id, "name": "Гость", "t": 2.5})
	await _wait(func() -> bool: return not got_a.is_empty() and not got_b.is_empty())
	check(got_b.size() >= 1 and got_b[0][0] == a.zone.my_id and got_b[0][1].t == 1.5, "PilotState хозяина у участника: %s" % [got_b])
	check(got_a.size() >= 1 and got_a[0][0] == b.zone.my_id and got_a[0][1].t == 2.5, "PilotState участника у хозяина: %s" % [got_a])

	# участник вышел: лобби покинуто, хозяин видит уход
	var b_id: String = b.zone.my_id
	backend.leave()
	check(b.lobby.lobby_id == 0 and not net.lobbies[lid].members.has(B_ID), "участник вышел из лобби")
	check(b.presence.calls == [lid, 0], "присутствие участника очищено: %s" % [b.presence.calls])
	await _wait(func() -> bool: return not a.zone.peers.has(b_id))
	check(not a.zone.peers.has(b_id), "хозяин видит уход")
	# хозяин закрыл зону: вышел из лобби, Steam-соединения не принимаются
	a.zone.leave_zone()
	await _wait(func() -> bool: return a.lobby.lobby_id == 0)
	check(a.lobby.lobby_id == 0 and not net.lobbies.has(lid), "лобби хозяина закрыто")
	check(not a.lobby.transport.accepting and a.presence.calls == [lid, 0], "не принимает; присутствие очищено")
	_cleanup(net, [a, b])


## Другая версия у хозяина — отказ version_mismatch без подключения NetClient; несуществующее
## лобби — zone_not_found.
func test_version_mismatch_and_missing_lobby() -> void:
	var net := FakeNet.new()
	var a := _side(net.user(A_ID, "Хозяин"), A_ID)
	var b := _side(net.user(B_ID, "Гость"), B_ID)
	b.lobby.register_transport()
	var lid := await _host(a)
	if lid <= 0:
		check(false, "лобби не создано")
		_cleanup(net, [a, b])
		return
	net.lobbies[lid].data["dp_ver"] = "0.0.1-old"
	var backend := NetUiClientBackend.new(b.client, b.zone, b.lan, b.lobby)
	var errors: Array = []
	backend.failed.connect(func(k: String) -> void: errors.append(k))
	var connects: Array = []
	b.client.reconnecting.connect(func(n: int) -> void: connects.append(n))
	backend.connect_and_join_lobby(lid, "Гость")
	await _wait(func() -> bool: return not errors.is_empty())
	check(errors == ["version_mismatch"], "другая версия: %s" % [errors])
	check(int(b.client.state) == 0 and String(b.client.address) == "", "NetClient не подключался")
	check(b.lobby.lobby_id == 0 and not net.lobbies[lid].members.has(B_ID), "из лобби вышел")
	check(a.lobby.transport.peer_counts().y == 0, "у хозяина нет соединений")
	errors.clear()
	backend.connect_and_join_lobby(4242, "Гость")
	await _wait(func() -> bool: return not errors.is_empty())
	check(errors == ["zone_not_found"], "нет лобби: %s" % [errors])
	_cleanup(net, [a, b])


## «Друзья в игре» и приглашения: друг-хозяин в лобби → строка в friends_zones; приглашение
## (join_requested), «Присоединиться» (join_game_requested «+connect_lobby <id>») —
## открытый экран (start_nearby) входит сам; «Пригласить друзей» — оверлей хозяина.
func test_friends_zones_and_invites() -> void:
	var net := FakeNet.new()
	var ua := net.user(A_ID, "Хозяин")
	var ub := net.user(B_ID, "Гость")
	net.befriend(ua, ub)
	var a := _side(ua, A_ID)
	var b := _side(ub, B_ID)
	b.lobby.register_transport()
	var host_backend := NetUiClientBackend.new(a.client, a.zone, a.lan, a.lobby)
	var lid := await _host(a)
	if lid <= 0:
		check(false, "лобби не создано")
		_cleanup(net, [a, b])
		return
	host_backend.invite_friends()
	check(ua.invites == 1, "оверлей приглашения хозяина")

	var backend := NetUiClientBackend.new(b.client, b.zone, b.lan, b.lobby)
	var changed := [0]
	backend.friends_changed.connect(func() -> void: changed[0] += 1)
	backend.start_nearby()
	await _wait(func() -> bool: return not backend.friends_zones().is_empty())
	var fz := backend.friends_zones()
	check(fz.size() == 1 and changed[0] >= 1, "друг в игре: %s" % [fz])
	if fz.size() == 1:
		var f: Dictionary = fz[0]
		check(f.lobby_id == lid and f.friend_name == "Хозяин" and f.zone_code == a.zone.code, "строка: %s" % [f])
		check(f.same_version and String(f.place) != "", "версия и место: %s" % [f])
	check(a.lobby.friends_zones().is_empty(), "своё лобби — не в списке у себя")

	# «Присоединиться» в списке друзей Steam при открытом экране — вход сам
	var joined: Array = []
	backend.zone_joined.connect(func(c: String) -> void: joined.append(c))
	ub.join_game_requested.emit(A_ID, "+connect_lobby %d" % lid)
	await _wait(func() -> bool: return not joined.is_empty(), 8.0)
	check(joined == [a.zone.code], "вход по «+connect_lobby»: %s" % [joined])
	backend.leave()
	await _wait(func() -> bool: return a.zone.peers.size() == 1)

	# приглашение при закрытом экране — ждёт, экран открылся — вошёл
	backend.stop_nearby()
	ub.join_requested.emit(lid, A_ID)
	await get_tree().process_frame
	check(not backend.is_busy() and b.lobby.pending_lobby == lid, "ждёт открытия экрана")
	joined.clear()
	backend.start_nearby()
	check(backend.is_busy() and b.lobby.pending_lobby == 0, "экран открылся — вход начат")
	await _wait(func() -> bool: return not joined.is_empty(), 8.0)
	check(joined == [a.zone.code], "вход по приглашению: %s" % [joined])
	backend.leave()
	a.zone.leave_zone()
	_cleanup(net, [a, b])


## Хозяин ушёл из лобби, Steam передал владение участнику (getLobbyOwner ≠ dp_host): у друга
## участника лобби в «Друзья в игре» не показывается, вход — zone_not_found.
func test_owner_changed_lobby_hidden() -> void:
	var net := FakeNet.new()
	var ua := net.user(A_ID, "Хозяин")
	var ub := net.user(B_ID, "Гость")
	var uc := net.user(76561198000000003, "Третий")
	net.befriend(ub, uc)
	var a := _side(ua, A_ID)
	var b := _side(ub, B_ID)
	var c := _side(uc, 76561198000000003)
	var lid := await _host(a)
	if lid <= 0:
		check(false, "лобби не создано")
		_cleanup(net, [a, b, c])
		return
	var ready: Array = []
	b.lobby.lobby_ready.connect(func(id: int, _ad: String, _z: String) -> void: ready.append(id))
	b.lobby.join_lobby(lid)
	await _wait(func() -> bool: return not ready.is_empty())
	check(ready == [lid] and b.lobby.role == "member", "участник в лобби")
	c.lobby.start_watching()
	check(c.lobby.friends_zones().size() == 1, "пока хозяин в лобби — видно: %s" % [c.lobby.friends_zones()])
	a.lobby.leave_lobby()
	check(ub.getLobbyOwner(lid) == B_ID, "владелец сменился")
	c.lobby.refresh_friends()
	check(c.lobby.friends_zones().is_empty(), "лобби без хозяина скрыто: %s" % [c.lobby.friends_zones()])
	var errs: Array = []
	c.lobby.lobby_failed.connect(func(_id: int, k: String) -> void: errs.append(k))
	c.lobby.join_lobby(lid)
	await _wait(func() -> bool: return not errs.is_empty())
	check(errs == ["zone_not_found"] and c.lobby.lobby_id == 0, "вход — zone_not_found: %s" % [errs])
	check(not net.lobbies.has(lid) or not net.lobbies[lid].members.has(uc.id), "из лобби вышел")
	c.lobby.stop_watching()
	_cleanup(net, [a, b, c])


## Steam неактивен (в тестах): автозагрузка SteamLobby молчит, схема steam не зарегистрирована.
func test_inactive_autoload() -> void:
	var l: Node = get_node_or_null("/root/SteamLobby")
	check(l != null, "автозагрузка SteamLobby")
	if l == null:
		return
	check(not l.available() and l.friends_zones().is_empty() and l.pending_lobby == 0, "пусто")
	var backend := NetUiClientBackend.new()
	check(not backend.steam_available() and backend.friends_zones().is_empty(), "бэкенд: Steam нет")
	var c: Node = NET_CLIENT.new()
	add_child(c)
	check(not c.connect_to_server("steam:%d" % A_ID, "Пилот"), "steam: без Steam — нет транспорта")
	c.queue_free()


# ---------------------------------------------------------------- стенд


## Один «пользователь Steam»: свои NetClient, NetZone, SteamLobby на подставном API.
func _side(api: Object, steam_id: int) -> Dictionary:
	var c: Node = NET_CLIENT.new()
	c.reconnect_delays_s = []
	add_child(c)
	var z: Node = NET_ZONE.new()
	z.setup(c)
	var lan := StubLan.new()
	add_child(lan)
	z.lan_discovery = lan
	add_child(z)
	var presence := StubPresence.new()
	add_child(presence)
	var l: Node = LOBBY.new()
	l.presence = presence
	add_child(l)
	l.setup(api, steam_id, z, c)
	return {"client": c, "zone": z, "lobby": l, "presence": presence, "lan": lan, "api": api}


## Хозяин: зона на встроенном сервере (случайный порт) → лобби; id лобби или 0.
func _host(a: Dictionary) -> int:
	a.zone.host_local(FlightSettings.defaults(), 7, 0, "Хозяин", 0)
	await _wait(func() -> bool: return a.lobby.role == "host", 8.0)
	return int(a.lobby.lobby_id)


func _cleanup(net: RefCounted, sides: Array) -> void:
	for s: Dictionary in sides:
		s.lobby.unregister_transport()
		s.zone.leave_zone()
		s.client.disconnect_from_server()
		for k: String in ["lobby", "zone", "client", "presence", "lan"]:
			s[k].queue_free()
	net.free_all()
