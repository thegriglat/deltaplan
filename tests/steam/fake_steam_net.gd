extends RefCounted
## Подставная «сеть Steam» для тестов ST-8 (S4.1 Steam-пир, S5 лобби): несколько пользователей
## в одном процессе. user(id, name) — подставной синглтон GodotSteam этого пользователя (Object,
## методы и сигналы под именами GodotSteam 4.22.1, tools/research/steam/api_dump.json). Сигналы,
## как у настоящего Steam, приходят позже вызова (call_deferred — вместо run_callbacks).
##
## Networking Messages: sendMessageToUser кладёт кадр в очередь получателя; первый кадр от
## незнакомого отправителя — network_messages_session_request у получателя, кадры ждут
## acceptSessionWithUser. Лобби: createLobby/joinLobby/leaveLobby/данные лобби — общие на сеть.
## Друзья: befriend(a, b); getFriendGamePlayed(id) → {id: app_id, lobby} — лобби, где друг.

const APP_ID := 480

var users: Dictionary = {}  ## steam id → User
## Лобби: id → {owner, members: Array[int], data: Dictionary}.
var lobbies: Dictionary = {}
var next_lobby := 109775241000000001
## createLobby отвечает отказом (lobby_created(2, 0)).
var fail_create := false


class User:
	extends Object

	signal lobby_created(connect: int, lobby_id: int)
	signal lobby_joined(lobby: int, permissions: int, locked: bool, response: int)
	signal lobby_data_update(success: int, lobby_id: int, member_id: int)
	signal lobby_kicked(lobby_id: int, admin_id: int, due_to_disconnect: int)
	signal join_requested(lobby_id: int, steam_id: int)
	signal join_game_requested(user: int, connect: String)
	signal persona_state_change(steam_id: int, flags: int)
	signal network_messages_session_request(remote_steam_id: int)
	signal network_messages_session_failed(reason: int, remote_steam_id: int, connection_state: int, debug_message: String)

	var net  ## сеть (RefCounted, слабо не держим: тест держит сеть сам)
	var id := 0
	var persona := ""
	var friends: Array[int] = []
	## Принятые сессии (от кого кадры доставляются).
	var accepted: Dictionary = {}
	## Входящие кадры: [{identity, payload, channel}], и ждущие принятия сессии.
	var inbox: Array = []
	var pending: Array = []
	var sent := 0
	var invites := 0
	var relay_inits := 0
	var launch_cmd_calls := 0
	## Mutex: кадры кладут и читают из главного потока, но на всякий случай.
	var mutex := Mutex.new()

	func getSteamID() -> int:
		return id

	func getPersonaName() -> String:
		return persona

	func initRelayNetworkAccess() -> void:
		relay_inits += 1

	func getLaunchCommandLine() -> String:
		launch_cmd_calls += 1
		return ""

	# ------------------------------------------------ Networking Messages

	func sendMessageToUser(remote: int, data: PackedByteArray, _flags: int, channel: int) -> int:
		var to: User = net.users.get(remote)
		if to == null:
			return 3  # RESULT_NO_CONNECTION
		sent += 1
		# как у Steam: отправивший сам принимает сессию с получателем (его ответы не ждут accept)
		mutex.lock()
		accepted[remote] = true
		mutex.unlock()
		to.mutex.lock()
		var msg := {"identity": id, "payload": data, "channel": channel, "size": data.size()}
		var first := false
		if to.accepted.has(id) or to.id == id:
			to.inbox.append(msg)
		else:
			first = to.pending.is_empty() or not to.pending.any(func(m: Dictionary) -> bool: return m.identity == id)
			to.pending.append(msg)
		to.mutex.unlock()
		if first:
			to.network_messages_session_request.emit.call_deferred(id)
		return 1  # RESULT_OK

	func receiveMessagesOnChannel(channel: int, max_messages: int) -> Array:
		mutex.lock()
		var out: Array = []
		var rest: Array = []
		for m: Dictionary in inbox:
			if m.channel == channel and out.size() < max_messages:
				out.append(m)
			else:
				rest.append(m)
		inbox = rest
		mutex.unlock()
		return out

	func acceptSessionWithUser(remote: int) -> bool:
		mutex.lock()
		accepted[remote] = true
		var rest: Array = []
		for m: Dictionary in pending:
			if m.identity == remote:
				inbox.append(m)
			else:
				rest.append(m)
		pending = rest
		mutex.unlock()
		return true

	func closeSessionWithUser(remote: int) -> bool:
		mutex.lock()
		accepted.erase(remote)
		mutex.unlock()
		return true

	# ------------------------------------------------ лобби

	func createLobby(lobby_type: int, max_members: int) -> void:
		if net.fail_create:
			lobby_created.emit.call_deferred(2, 0)
			return
		var lid: int = net.next_lobby
		net.next_lobby += 1
		net.lobbies[lid] = {"owner": id, "members": [id], "data": {}, "type": lobby_type, "max": max_members}
		lobby_created.emit.call_deferred(1, lid)
		lobby_joined.emit.call_deferred(lid, 0, false, 1)

	func joinLobby(lobby_id: int) -> void:
		var l: Variant = net.lobbies.get(lobby_id)
		if l == null:
			lobby_joined.emit.call_deferred(lobby_id, 0, false, 2)  # DOESNT_EXIST
			return
		if not l.members.has(id):
			l.members.append(id)
		lobby_joined.emit.call_deferred(lobby_id, 0, false, 1)

	func leaveLobby(lobby_id: int) -> void:
		var l: Variant = net.lobbies.get(lobby_id)
		if l == null:
			return
		l.members.erase(id)
		if l.members.is_empty():
			net.lobbies.erase(lobby_id)
		elif l.owner == id:
			l.owner = l.members[0]

	func setLobbyData(lobby_id: int, key: String, value: String) -> bool:
		var l: Variant = net.lobbies.get(lobby_id)
		if l == null or l.owner != id:
			return false
		l.data[key] = value
		return true

	func getLobbyData(lobby_id: int, key: String) -> String:
		var l: Variant = net.lobbies.get(lobby_id)
		return String(l.data.get(key, "")) if l != null else ""

	func requestLobbyData(lobby_id: int) -> bool:
		lobby_data_update.emit.call_deferred(1, lobby_id, lobby_id)
		return net.lobbies.has(lobby_id)

	func getLobbyOwner(lobby_id: int) -> int:
		var l: Variant = net.lobbies.get(lobby_id)
		return int(l.owner) if l != null else 0

	func getNumLobbyMembers(lobby_id: int) -> int:
		var l: Variant = net.lobbies.get(lobby_id)
		return l.members.size() if l != null else 0

	func setLobbyJoinable(lobby_id: int, joinable: bool) -> bool:
		var l: Variant = net.lobbies.get(lobby_id)
		if l != null:
			l["joinable"] = joinable
		return l != null

	func activateGameOverlayInviteDialog(_lobby_id: int) -> void:
		invites += 1

	# ------------------------------------------------ друзья

	func getFriendCount(_flags: int = 4) -> int:
		return friends.size()

	func getFriendByIndex(i: int, _flags: int) -> int:
		return friends[i] if i >= 0 and i < friends.size() else 0

	func getFriendPersonaName(fid: int) -> String:
		var u: User = net.users.get(fid)
		return u.persona if u != null else ""

	func getFriendGamePlayed(fid: int) -> Dictionary:
		var u: User = net.users.get(fid)
		if u == null:
			return {}
		var lobby := 0
		for lid: int in net.lobbies:
			if net.lobbies[lid].members.has(fid):
				lobby = lid
		return {"id": APP_ID, "ip": "0.0.0.0", "game_port": 0, "query_port": 0, "lobby": lobby}


func user(id: int, persona: String) -> User:
	var u := User.new()
	u.net = self
	u.id = id
	u.persona = persona
	users[id] = u
	return u


func befriend(a: User, b: User) -> void:
	a.friends.append(b.id)
	b.friends.append(a.id)


## Обрыв сессии (как network_messages_session_failed у настоящего Steam): обоим сторонам.
func break_session(a: User, b: User) -> void:
	a.network_messages_session_failed.emit(4, b.id, 4, "fake: closed")
	b.network_messages_session_failed.emit(4, a.id, 4, "fake: closed")


func free_all() -> void:
	for u: User in users.values():
		u.net = null
		u.free()
	users.clear()
