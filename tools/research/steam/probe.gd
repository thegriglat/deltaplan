extends SceneTree
# Прототип ST-1: безопасная проверка наличия GodotSteam и инициализации.
# Аргументы после "--": noinit (только загрузка), appid=<N> (вызвать steamInitEx(N)).
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var do_init := not ("noinit" in args)
	var app_id := 0
	for a in args:
		if a.begins_with("appid="):
			app_id = int(a.substr(6))
	# Единственный безопасный способ: никаких идентификаторов Steam.* в тексте скрипта —
	# иначе при отсутствии расширения разбор скрипта падает (Identifier "Steam" not declared).
	var loaded := Engine.has_singleton("Steam")
	var info := ""
	if loaded:
		var s: Object = Engine.get_singleton("Steam")
		info += " gs_version=%s" % s.call("get_godotsteam_version")
		info += " sdk=%s" % s.call("getSteamworksVersion") if s.has_method("getSteamworksVersion") else ""
		if do_init:
			var r: Dictionary = s.call("steamInitEx", app_id, false)
			info += " init=%s/%s" % [r.get("status"), str(r.get("verbal")).replace(" ", "_")]
			if int(r.get("status", 1)) == 0:
				info += " persona=%s steam_id=%s lang=%s logged_on=%s" % [s.call("getPersonaName"), s.call("getSteamID"), s.call("getCurrentGameLanguage"), s.call("loggedOn")]
				s.call("run_callbacks")
		else:
			info += " init=skipped"
	else:
		info += " init=none"
	print("STEAM_PROBE loaded=%s%s args=%s" % [str(loaded).to_lower(), info, args])
	quit(0)
