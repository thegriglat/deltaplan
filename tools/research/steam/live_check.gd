extends SceneTree
# Живая проверка на App ID 480 (Spacewar), нужен запущенный и залогиненный клиент Steam.
# Ничего необратимого: ачивки и статистика только читаются; лобби приватное, закрывается; Cloud — один временный файл, удаляется.
# Печатает строки LIVE key=value. Запуск: probe.sh --live (или вручную: godot --headless -s live_check.gd)
var S: Object
var t := 0.0
var step := 0
var lobby := 0
var got := {}
var me := 0
var t_step := 0.0
func L(k: String, v) -> void:
	print("LIVE %s=%s" % [k, str(v).replace("\n", " ")])
func _initialize() -> void:
	if not Engine.has_singleton("Steam"):
		L("steam", "no_singleton"); quit(1); return
	S = Engine.get_singleton("Steam")
	var r: Dictionary = S.call("steamInitEx", 480, false)
	L("init", "%s/%s" % [r.get("status"), r.get("verbal")])
	if int(r.get("status", 1)) != 0:
		quit(2); return
	me = S.call("getSteamID")
	L("launch_cmdline", "'%s'" % S.call("getLaunchCommandLine"))
	L("app_owner_is_me_subscribed", "%s/%s" % [S.call("getAppOwner") == me, S.call("isSubscribed")])
	L("build_id", S.call("getAppBuildId"))
	L("ui_lang", S.call("getSteamUILanguage") if S.has_method("getSteamUILanguage") else "?")
	S.connect("lobby_created", _on_lobby_created)
	S.connect("lobby_joined", func(l, perm, locked, resp): L("sig_lobby_joined", "lobby=%s resp=%s" % [l, resp]))
	S.connect("lobby_data_update", func(ok, l, m): L("sig_lobby_data_update", "ok=%s" % ok))
	S.connect("network_messages_session_request", func(rid): L("sig_nm_session_request", rid); S.call("acceptSessionWithUser", rid))
	S.connect("network_messages_session_failed", func(reason, rid, st, msg): L("sig_nm_session_failed", "reason=%s state=%s %s" % [reason, st, msg]))
	S.connect("relay_network_status", func(av, pm, ac, ar, msg): L("sig_relay_status", "avail=%s ping_meas=%s cfg=%s relay=%s %s" % [av, pm, ac, ar, msg]))
	# Rich Presence (ключ без токена локализации — другим не виден как текст)
	L("rp_set_key", S.call("setRichPresence", "st1probe", "1"))
	L("rp_set_steam_display_unknown_token", S.call("setRichPresence", "steam_display", "#ST1_not_in_cabinet"))
	L("rp_set_key_too_long", S.call("setRichPresence", "k".repeat(65), "v"))
	L("rp_set_value_too_long", S.call("setRichPresence", "st1long", "v".repeat(257)))
	L("rp_set_value_256", S.call("setRichPresence", "st1v256", "v".repeat(256)))
	# ключи: уже 3 (st1probe, steam_display, st1v256); добиваем до лимита
	var n_ok := 3
	for i in range(40):
		if S.call("setRichPresence", "st1k%d" % i, "x"):
			n_ok += 1
	L("rp_keys_accepted_total", n_ok)
	S.call("run_callbacks")
	L("rp_own_key_count", S.call("getFriendRichPresenceKeyCount", me))
	L("rp_own_read_st1probe", S.call("getFriendRichPresence", me, "st1probe"))
	S.call("clearRichPresence")
	L("rp_after_clear_count", S.call("getFriendRichPresenceKeyCount", me))
	# Ачивки/статистика (чтение)
	var ach := []
	var n: int = S.call("getNumAchievements") if S.has_method("getNumAchievements") else -1
	L("ach_count", n)
	for i in range(max(n, 0)):
		ach.append(S.call("getAchievementName", i))
	L("ach_names_480", ach)
	L("ach_win_one_game_state", S.call("getAchievement", "ACH_WIN_ONE_GAME"))
	L("stat_NumGames", S.call("getStatInt", "NumGames"))
	L("fake_ach_state", S.call("getAchievement", "ST1_NOT_IN_CABINET"))
	# Cloud (Remote Storage)
	L("cloud_enabled_account", S.call("isCloudEnabledForAccount"))
	L("cloud_enabled_app", S.call("isCloudEnabledForApp"))
	L("cloud_quota", S.call("getQuota"))
	L("cloud_file_count_before", S.call("getFileCount"))
	var data := PackedByteArray("st1 cloud probe".to_utf8_buffer())
	var w: bool = S.call("fileWrite", "st1_probe.txt", data, data.size())
	L("cloud_write", w)
	L("cloud_exists", S.call("fileExists", "st1_probe.txt"))
	var rd: Dictionary = S.call("fileRead", "st1_probe.txt", data.size())
	L("cloud_read", str(rd))
	L("cloud_delete", S.call("fileDelete", "st1_probe.txt"))
	L("cloud_file_count_after", S.call("getFileCount"))
	# Сеть: сеть реле + лобби
	S.call("initRelayNetworkAccess")
	S.call("createLobby", S.get("LOBBY_TYPE_PRIVATE"), 4)
	t_step = 0.0
func _on_lobby_created(connect_res: int, lobby_id: int) -> void:
	lobby = lobby_id
	L("lobby_created", "result=%s id=%s" % [connect_res, lobby_id])
	if connect_res != 1:
		step = 9; return
	L("lobby_set_data", S.call("setLobbyData", lobby, "name", "st1"))
	L("lobby_set_data_big_8192", S.call("setLobbyData", lobby, "big", "x".repeat(8192)))
	L("lobby_set_data_big_8193", S.call("setLobbyData", lobby, "big2", "x".repeat(8193)))
	L("lobby_get_data", S.call("getLobbyData", lobby, "name"))
	L("lobby_set_member_data", S.call("setLobbyMemberData", lobby, "role", "pilot"))
	L("lobby_get_member_data", S.call("getLobbyMemberData", lobby, me, "role"))
	L("lobby_members", S.call("getNumLobbyMembers", lobby))
	L("lobby_owner_is_me", S.call("getLobbyOwner", lobby) == me)
	L("lobby_member_limit", S.call("getLobbyMemberLimit", lobby))
	# Networking Messages «себе»: петля через клиента
	var frame := JSON.stringify({"t": "st1", "pad": "x".repeat(2000)}).to_utf8_buffer()
	L("nm_frame_bytes", frame.size())
	L("nm_send_to_self_result", S.call("sendMessageToUser", me, frame, S.get("NETWORKING_SEND_RELIABLE_NO_NAGLE"), 0))
	step = 1
	t_step = t
func _process(delta: float) -> bool:
	if S == null:
		return true
	t += delta
	S.call("run_callbacks")
	if step == 0 and t > 8.0:
		L("lobby_create", "timeout"); step = 9
	if step == 1:
		var msgs: Array = S.call("receiveMessagesOnChannel", 0, 10)
		for m in msgs:
			L("nm_received", "size=%s from_me=%s flags=%s channel=%s" % [m.get("size"), m.get("identity") == me, m.get("flags"), m.get("channel")])
			step = 2
		if t - t_step > 6.0 and step == 1:
			L("nm_received", "none_in_6s"); step = 2
	if step == 2:
		L("nm_session_info", S.call("getSessionConnectionInfo", me, false, true))
		S.call("leaveLobby", lobby)
		L("lobby_left", true)
		step = 9
	if step >= 9 or t > 25.0:
		S.call("clearRichPresence")
		return true
	return false
