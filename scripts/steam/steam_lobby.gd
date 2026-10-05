extends Node
## SteamLobby (автозагрузка) — лобби Steam и адресация (контракт S5, docs/contracts/steam.md)
## и Steam-транспорт сети (S4.1 через SteamTransport, мост хозяина S4.3). Steam неактивен
## (SteamService.is_active() == false) — ничего не делает: available() false, списки пусты.
##
## Хозяин: свой NetZone вошёл в зону на встроенном сервере (is_hosting) → лобби «только друзья»
## на MAX_MEMBERS, данные лобби (KEY_* ниже), SteamPresence.set_lobby(id) (S3 v2, если
## автозагрузка есть); входящие Steam-соединения → local_server.attach_peer. Зона закрыта
## (zone_left) → выход из лобби, новые соединения не принимаются.
## Участник: join_lobby(id) → joinLobby → данные лобби: не игра/нет хозяина — lobby_failed
## "zone_not_found", другая версия — "version_mismatch" (без подключения), иначе
## lobby_ready(id, "steam:<dp_host>", dp_zone) — дальше обычный вход NetClient/NetZone по адресу.
## Вышел из зоны (zone_left) или вход не удался (leave_lobby от экрана) — выход из лобби.
## Приглашение (join_requested), «Присоединиться» в списке друзей (join_game_requested,
## «+connect_lobby <id>») и аргумент запуска (SteamService.launch_lobby_id) → request_join:
## pending_lobby и сигнал join_lobby_requested — входит экран «Сетевая игра» (backend).
## «Друзья в игре»: пока экран открыт (start_watching) — раз в FRIENDS_REFRESH_S и по сигналам
## Steam: друзья в этой игре с лобби → данные лобби → friends_zones(), friends_changed.
##
## Тесты: setup(api, steam_id, zone, client, app_id) — подставной Steam и свои NetZone/NetClient.

signal friends_changed
## Пришло приглашение / вход к другу / аргумент запуска: войти в лобби lobby_id.
signal join_lobby_requested(lobby_id: int)
## Вступили в лобби lobby_id: адрес NetClient хозяина и код зоны.
signal lobby_ready(lobby_id: int, address: String, zone_code: String)
## Не вступили: вид ошибки экрана (NetUiBackend.ERROR_KINDS).
signal lobby_failed(lobby_id: int, kind: String)

const TRANSPORT := preload("res://scripts/steam/steam_transport.gd")
const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const SCHEME := "steam"
const LOBBY_TYPE_FRIENDS_ONLY := 1
const MAX_MEMBERS := 16
## lobby_created(connect, …): 1 — RESULT_OK.
const CREATE_OK := 1
## lobby_joined(…, response): CHAT_ROOM_ENTER_RESPONSE_SUCCESS / _FULL.
const ENTER_SUCCESS := 1
const ENTER_FULL := 4
const FRIEND_FLAG_IMMEDIATE := 4
const FRIENDS_REFRESH_S := 5.0
const KEY_GAME := "dp"
const KEY_VERSION := "dp_ver"
const KEY_ZONE := "dp_zone"
const KEY_HOST := "dp_host"
const KEY_NAME := "dp_name"
const KEY_PLACE := "dp_place"

## Синглтон Steam (SteamService.api() или подставной); null — Steam неактивен.
var api: Object
var my_id := 0
var app_id := 480
var game_version := ""
var zone: Node  ## NetZone
var client: Node  ## NetClient
## SteamPresence для set_lobby; null — автозагрузка /root/SteamPresence, если есть.
var presence: Node
var transport: Node

## Текущее лобби (0 — нет) и роль: "" | "creating" | "host" | "member".
var lobby_id := 0
var role := ""
## Ждём lobby_joined этого лобби (вход участником).
var _joining := 0
## Код зоны, для которой создаётся лобби.
var _host_code := ""
## Лобби, в которое просили войти (приглашение, запуск), пока экран не забрал.
var pending_lobby := 0
var _friends: Array = []
var _requested: Dictionary = {}
var _watching := false
var _refresh_timer := 0.0
var _registered := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_transport()
	if api != null:
		return
	var svc := get_node_or_null("/root/SteamService")
	if svc == null or not svc.is_active():
		return
	setup(
		svc.api(),
		svc.steam_id(),
		get_node_or_null("/root/NetZone"),
		get_node_or_null("/root/NetClient"),
		svc.app_id()
	)
	register_transport()
	api.call("initRelayNetworkAccess")
	api.call("getLaunchCommandLine")  # просьба Valve: игра читает командную строку запуска
	if svc.launch_lobby_id() > 0:
		request_join(svc.launch_lobby_id())


func _exit_tree() -> void:
	unregister_transport()


func setup(p_api: Object, p_my_id: int, p_zone: Node, p_client: Node, p_app_id: int = 480) -> void:
	_ensure_transport()
	api = p_api
	my_id = p_my_id
	zone = p_zone
	client = p_client
	app_id = p_app_id
	game_version = str(ProjectSettings.get_setting("application/config/version", ""))
	transport.setup(api)
	if api == null:
		return
	for s: Array in [
		["lobby_created", _on_lobby_created],
		["lobby_joined", _on_lobby_joined],
		["lobby_data_update", _on_lobby_data_update],
		["lobby_kicked", _on_lobby_kicked],
		["join_requested", _on_join_requested],
		["join_game_requested", _on_join_game_requested],
		["persona_state_change", _on_persona_state_change],
	]:
		if api.has_signal(s[0]) and not api.is_connected(s[0], s[1]):
			api.connect(s[0], s[1])
	if zone != null:
		zone.zone_entered.connect(_on_zone_entered)
		zone.zone_left.connect(_on_zone_left)


func _ensure_transport() -> void:
	if transport == null:
		transport = TRANSPORT.new()
		transport.name = "SteamTransport"
		transport.peer_accepted.connect(_on_peer_accepted)
		add_child(transport)


func available() -> bool:
	return api != null


## Схема steam в NetClient (S4.2): "steam:<steam_id64>" → Steam-пир к хозяину.
func register_transport() -> void:
	NET_CLIENT.register_transport(SCHEME, make_peer)
	_registered = true


func unregister_transport() -> void:
	if _registered:
		NET_CLIENT.register_transport(SCHEME, Callable())
		_registered = false


func make_peer(address: String) -> RefCounted:
	var s := address.strip_edges()
	s = s.substr(s.find(":") + 1)
	if not s.is_valid_int() or int(s) <= 0:
		return null
	return transport.open_peer(int(s))


func _process(delta: float) -> void:
	if not _watching or api == null:
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		refresh_friends()


# ---------------------------------------------------------------- хозяин


func _on_zone_entered(code: String) -> void:
	if api == null or zone == null:
		return
	if not (zone.has_method("is_hosting") and zone.is_hosting()):
		return
	transport.accepting = true
	_host_code = code
	if role == "host" and lobby_id != 0:
		_write_data()  # вернулись в зону после переподключения — код мог смениться
		return
	if role == "creating":
		return
	leave_lobby()
	role = "creating"
	api.call("createLobby", LOBBY_TYPE_FRIENDS_ONLY, MAX_MEMBERS)


func _on_lobby_created(result: int, id: int) -> void:
	if role != "creating":
		if result == CREATE_OK and id > 0:  # зону уже закрыли, пока лобби создавалось
			api.call("leaveLobby", id)
		return
	if result != CREATE_OK or id <= 0:
		role = ""
		print("steam: lobby not created (result %d)" % result)
		return
	lobby_id = id
	role = "host"
	_write_data()
	api.call("setLobbyJoinable", id, true)
	_set_presence(id)
	print("steam: lobby %d for zone %s" % [id, _host_code])


func _write_data() -> void:
	var d := {
		KEY_GAME: "1",
		KEY_VERSION: game_version,
		KEY_ZONE: _host_code,
		KEY_HOST: str(my_id),
		KEY_NAME: String(client.pilot_name) if client != null else "",
		KEY_PLACE: place_name(zone.zone_settings) if zone != null else "",
	}
	for k: String in d:
		api.call("setLobbyData", lobby_id, k, d[k])


func _on_peer_accepted(peer: RefCounted) -> void:
	var srv: Node = zone.get("local_server") if zone != null else null
	if srv == null or srv.attach_peer(peer, "steam:%d" % peer.remote) < 0:
		peer.close(TRANSPORT.CODE_NOT_HOSTING)


func _on_zone_left() -> void:
	transport.accepting = false
	leave_lobby()


# ---------------------------------------------------------------- участник


## Вступить в лобби друга; ответ — lobby_ready или lobby_failed.
func join_lobby(id: int) -> void:
	if api == null or id <= 0:
		lobby_failed.emit.call_deferred(id, "unreachable")
		return
	leave_lobby()
	_joining = id
	api.call("joinLobby", id)


func _on_lobby_joined(lobby: int, _permissions: int, _locked: bool, response: int) -> void:
	if lobby != _joining or lobby == 0:
		return
	_joining = 0
	if response != ENTER_SUCCESS:
		lobby_failed.emit(lobby, "zone_full" if response == ENTER_FULL else "zone_not_found")
		return
	var info := lobby_info(lobby)
	var kind := ""
	if (
		info.game != "1" or info.host <= 0 or info.code == "" or info.host == my_id
		or _owner_changed(info)
	):
		kind = "zone_not_found"
	elif info.version != game_version:
		kind = "version_mismatch"
	if kind != "":
		api.call("leaveLobby", lobby)
		lobby_failed.emit(lobby, kind)
		return
	lobby_id = lobby
	role = "member"
	_set_presence(lobby)
	lobby_ready.emit(lobby, "%s:%d" % [SCHEME, info.host], info.code)


func _on_lobby_kicked(lobby: int, _admin: int, _due_to_disconnect: int) -> void:
	if lobby == lobby_id:
		lobby_id = 0
		role = ""
		_set_presence(0)


## Выйти из лобби (если есть); ждущий вход/создание отменяется.
func leave_lobby() -> void:
	_joining = 0
	if role == "creating":
		role = ""  # придёт lobby_created — выйдем там
	if lobby_id != 0 and api != null:
		api.call("leaveLobby", lobby_id)
		lobby_id = 0
		_set_presence(0)
	role = ""


func invite() -> void:
	if api != null and lobby_id != 0:
		api.call("activateGameOverlayInviteDialog", lobby_id)


## Данные лобби: {game, version, code, host, name, place, owner} (owner — getLobbyOwner, 0 — неизвестен).
func lobby_info(lobby: int) -> Dictionary:
	var g := func(k: String) -> String: return String(api.call("getLobbyData", lobby, k))
	var host_s: String = g.call(KEY_HOST)
	return {
		"game": g.call(KEY_GAME),
		"version": g.call(KEY_VERSION),
		"code": g.call(KEY_ZONE),
		"host": int(host_s) if host_s.is_valid_int() else 0,
		"name": g.call(KEY_NAME),
		"place": g.call(KEY_PLACE),
		"owner": int(api.call("getLobbyOwner", lobby)),
	}


## Хозяин ушёл, Steam передал лобби другому (владелец ≠ dp_host): сервера зоны там нет.
## Владелец 0 — Steam его не сообщил (не участник лобби): не считаем сменой.
static func _owner_changed(info: Dictionary) -> bool:
	return int(info.owner) != 0 and int(info.owner) != int(info.host)


# ---------------------------------------------------------------- приглашения


func request_join(lobby: int) -> void:
	if lobby <= 0:
		return
	pending_lobby = lobby
	join_lobby_requested.emit(lobby)


## Забрать ждущее лобби (0 — нет).
func take_pending() -> int:
	var l := pending_lobby
	pending_lobby = 0
	return l


func _on_join_requested(lobby: int, _friend: int) -> void:
	request_join(lobby)


func _on_join_game_requested(_user: int, connect: String) -> void:
	var parts := connect.strip_edges().split(" ", false)
	var i := parts.find("+connect_lobby")
	if i >= 0 and i + 1 < parts.size() and parts[i + 1].is_valid_int():
		request_join(int(parts[i + 1]))


# ---------------------------------------------------------------- друзья в игре


func start_watching() -> void:
	_watching = true
	refresh_friends()


func stop_watching() -> void:
	_watching = false


func friends_zones() -> Array:
	return _friends.duplicate(true)


## Друзья в этой игре с лобби игры: [{lobby_id, friend_name, zone_code, place, same_version}].
func refresh_friends() -> void:
	_refresh_timer = FRIENDS_REFRESH_S
	if api == null:
		return
	var list: Array = []
	var seen: Dictionary = {}
	var n := int(api.call("getFriendCount", FRIEND_FLAG_IMMEDIATE))
	for i in n:
		var fid := int(api.call("getFriendByIndex", i, FRIEND_FLAG_IMMEDIATE))
		var g: Variant = api.call("getFriendGamePlayed", fid)
		if not (g is Dictionary) or int(g.get("id", 0)) != app_id:
			continue
		var lid := int(g.get("lobby", 0))
		if lid <= 0 or lid == lobby_id or seen.has(lid):
			continue
		var info := lobby_info(lid)
		if info.game == "":  # данных ещё нет — запросить, придёт lobby_data_update
			if not _requested.has(lid):
				_requested[lid] = true
				api.call("requestLobbyData", lid)
			continue
		if info.game != "1" or info.code == "" or _owner_changed(info):
			continue
		seen[lid] = true
		list.append(
			{
				"lobby_id": lid,
				"friend_name": String(api.call("getFriendPersonaName", fid)),
				"zone_code": info.code,
				"place": info.place,
				"same_version": info.version == game_version,
			}
		)
	if list != _friends:
		_friends = list
		friends_changed.emit()


func _on_lobby_data_update(_success: int, lobby: int, _member: int) -> void:
	if _watching and (_requested.has(lobby) or _friends.any(func(f: Dictionary) -> bool: return f.lobby_id == lobby)):
		_refresh_timer = 0.0  # перечитать в ближайшем кадре


func _on_persona_state_change(_steam_id: int, _flags: int) -> void:
	if _watching:
		_refresh_timer = minf(_refresh_timer, 0.5)


# ---------------------------------------------------------------- прочее


func _set_presence(id: int) -> void:
	var p := presence if presence != null else get_node_or_null("/root/SteamPresence")
	if p != null and p.has_method("set_lobby"):
		p.call("set_lobby", id)


## Отображаемое имя места зоны (язык игры хозяина): старт локации или точка с карты.
static func place_name(s: FlightSettings) -> String:
	if s == null:
		return ""
	if s.has_pick():
		return TranslationServer.translate("menu_point") % [s.pick_lat, s.pick_lon]
	for loc_name in Config.list_configs("locations"):
		if loc_name.get_file() != s.location_id:
			continue
		var loc: Dictionary = Config.get_config(loc_name)
		for st: Dictionary in loc.get("start_sites", []):
			if String(st.get("id", "")) == s.site_id:
				return String(TranslationServer.translate(String(st.get("name", s.site_id))))
		return String(TranslationServer.translate(String(loc.get("name", s.location_id))))
	return s.location_id
