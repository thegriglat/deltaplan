extends TestCase
## Форма стыка S5 (docs/contracts/steam.md, версия 1): данные лобби, тип и размер лобби, методы
## и сигнал NetUiBackend (базовый, настоящий и фальшивый бэкенды; неактивный Steam — пусто/false),
## Steam-пир по S4.1. Поведение — tests/steam/test_steam_net.gd (подставной Steam).

const LOBBY := preload("res://scripts/steam/steam_lobby.gd")
const PEER := preload("res://scripts/steam/steam_peer.gd")
const BACKEND_METHODS := ["steam_available", "invite_friends", "friends_zones", "connect_and_join_lobby"]
const PEER_METHODS := ["poll", "get_state", "pop_text", "send_text", "close", "get_close_code"]


func test_s5_lobby_keys_and_type() -> void:
	var lobby_script: Script = LOBBY
	var c := lobby_script.get_script_constant_map()
	check(
		[c.KEY_GAME, c.KEY_VERSION, c.KEY_ZONE, c.KEY_HOST, c.KEY_NAME, c.KEY_PLACE]
		== ["dp", "dp_ver", "dp_zone", "dp_host", "dp_name", "dp_place"],
		"ключи данных лобби"
	)
	check(c.LOBBY_TYPE_FRIENDS_ONLY == 1 and c.MAX_MEMBERS == 16, "лобби «только друзья» на 16")
	check(c.MAX_MEMBERS == LocalServer.MAX_MEMBERS, "как предел зоны сервера")
	check(c.SCHEME == "steam" and preload("res://scripts/net/net_client.gd").TRANSPORT_SCHEMES.has("steam"), "адрес steam:<id>")


func test_s5_backend_interface() -> void:
	for script: Script in [NetUiBackend, NetUiClientBackend, NetUiFakeBackend]:
		var names: PackedStringArray = []
		for m in script.get_script_method_list():
			names.append(String(m.name))
		for n: String in BACKEND_METHODS:
			check(names.has(n), "%s.%s" % [script.resource_path.get_file(), n])
	var sigs: PackedStringArray = []
	for sg in NetUiBackend.new().get_signal_list():
		sigs.append(String(sg.name))
	check(sigs.has("friends_changed"), "сигнал friends_changed")
	for b: NetUiBackend in [NetUiBackend.new(), NetUiFakeBackend.new(), NetUiClientBackend.new()]:
		check(not b.steam_available() and b.friends_zones() == [], "неактивный Steam — пусто/false")


func test_s5_inactive_lobby_join_fails_unreachable() -> void:
	var b := NetUiClientBackend.new()
	var got: Array = []
	b.failed.connect(func(k: String) -> void: got.append(k))
	b.connect_and_join_lobby(109775241000000001, "Пилот")
	await Engine.get_main_loop().process_frame
	check(got == ["unreachable"], "без Steam — unreachable: %s" % [got])


func test_s4_1_steam_peer_shape() -> void:
	var peer_script: Script = PEER
	var consts := peer_script.get_script_constant_map()
	check(
		[consts.CONNECTING, consts.OPEN, consts.CLOSING, consts.CLOSED]
		== [
			WebSocketPeer.STATE_CONNECTING,
			WebSocketPeer.STATE_OPEN,
			WebSocketPeer.STATE_CLOSING,
			WebSocketPeer.STATE_CLOSED
		],
		"состояния как WebSocketPeer.State"
	)
	var names := peer_script.get_script_method_list().map(func(m: Dictionary) -> String: return m.name)
	for m: String in PEER_METHODS:
		check(names.has(m), "steam_peer: нет " + m)
