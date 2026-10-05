extends Node
## ST-8: главная сцена и приглашения Steam (S5) на подставном Steam — запуск с «+connect_lobby»
## (ждущее лобби) и принятое приглашение в меню сами открывают «Сетевая игра» и входят в зону
## хозяина. Хозяин — свои NetClient/NetZone/SteamLobby; гость — автозагрузки NetClient/NetZone
## и свой SteamLobby, отданный главной сцене (main.steam_lobby).

const FakeNet := preload("res://tests/steam/fake_steam_net.gd")
const LOBBY := preload("res://scripts/steam/steam_lobby.gd")
const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const NET_ZONE := preload("res://scripts/net/net_zone.gd")
const MAIN_SCENE := "res://scenes/main.tscn"
const A_ID := 76561198000000011
const B_ID := 76561198000000012

var failures: PackedStringArray = []


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

	func start_listening() -> bool:
		return false

	func stop_listening() -> void:
		pass


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _wait(cond: Callable, timeout_s: float = 8.0) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func test_launch_lobby_and_invite_open_net_screen() -> void:
	var net := FakeNet.new()
	var ua := net.user(A_ID, "Хозяин")
	var ub := net.user(B_ID, "Гость")
	# хозяин
	var ca: Node = NET_CLIENT.new()
	ca.reconnect_delays_s = []
	add_child(ca)
	var za: Node = NET_ZONE.new()
	za.setup(ca)
	var lan := StubLan.new()
	add_child(lan)
	za.lan_discovery = lan
	add_child(za)
	var la: Node = LOBBY.new()
	la.presence = Node.new()
	add_child(la.presence)
	add_child(la)
	la.setup(ua, A_ID, za, ca)
	za.host_local(FlightSettings.defaults(), 7, 0, "Хозяин", 0)
	await _wait(func() -> bool: return la.role == "host")
	var lid: int = la.lobby_id
	check(lid > 0, "лобби хозяина")
	# гость: автозагрузки сети, свой SteamLobby
	var zone: Node = get_node("/root/NetZone")
	var client: Node = get_node("/root/NetClient")
	var lb: Node = LOBBY.new()
	lb.presence = Node.new()
	add_child(lb.presence)
	add_child(lb)
	lb.setup(ub, B_ID, zone, client)
	lb.register_transport()
	lb.pending_lobby = lid  # как SteamService.launch_lobby_id() при запуске «+connect_lobby»
	var main: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	main.set("steam_lobby", lb)
	add_child(main)
	await _wait(func() -> bool: return zone.in_zone)
	var ns: NetScreen = main.get("net_screen")
	check(zone.in_zone and zone.code == za.code, "запуск с лобби — вошёл в зону: %s / %s" % [zone.code, za.code])
	check(ns != null and ns.visible and ns.view == NetScreen.View.ZONE, "экран «Сетевая игра» открыт, в зоне")
	check(String(client.address) == "steam:%d" % A_ID and lb.pending_lobby == 0, "через Steam: %s" % client.address)
	# выйти в меню и принять приглашение (оверлей Steam) — экран открывается сам и входит
	if ns != null:
		ns.go_back()
	await _wait(func() -> bool: return not zone.in_zone and main.get("net_screen") == null)
	check(main.get("net_screen") == null and (main.get_node("UI/StartMenu") as Control).visible, "в меню")
	await _wait(func() -> bool: return za.peers.size() == 1)
	ub.join_requested.emit(lid, A_ID)
	await _wait(func() -> bool: return zone.in_zone)
	ns = main.get("net_screen")
	check(zone.in_zone and ns != null and ns.visible and ns.view == NetScreen.View.ZONE, "приглашение — экран и зона")
	check(not (main.get_node("UI/StartMenu") as Control).visible, "меню спрятано под экраном")
	# уборка
	if ns != null:
		ns.go_back()
	lb.unregister_transport()
	zone.leave_zone()
	client.disconnect_from_server()
	za.leave_zone()
	ca.disconnect_from_server()
	main.queue_free()
	for n: Node in [lb, lb.presence, la, la.presence, za, ca, lan]:
		n.queue_free()
	await get_tree().process_frame
	net.free_all()
