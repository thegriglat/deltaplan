extends Node
## CR-14: смена места в одном сеансе (меню -> «Лететь» -> меню -> другое место), как в отчётах #20/#21.
## Места — JSON вне репозитория: {"метка": {"lat":..,"lon":..} | {"catalog":"<id записи каталога>"}}.
## Параметры: --places=<файл> --seq=K,Y,K --fly=<с игровых> --bots=<N> --skip-fly
## Печатает на загрузку: CR14 load <n> <метка>: ... rss/hwm/static/peak (МБ); стадии и дома — из [stage]/PlaceData лога.
const MAIN_SCENE := preload("res://scenes/main.tscn")
var _peak_rss := 0.0


func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return def


static func _status() -> Dictionary:
	var out := {}
	for l in FileAccess.get_file_as_string("/proc/self/status").split("\n"):
		for k in ["VmRSS", "VmHWM"]:
			if l.begins_with(k + ":"):
				out[k] = float(l.split(" ", false)[1]) / 1024.0
	return out


func _settings(spec: Dictionary) -> FlightSettings:
	var s := FlightSettings.defaults()
	s.clear_exact_start()
	if spec.has("catalog"):
		var cat := PopularPlaces.load_catalog(String(Config.value("ui", "popular_places_path", "")))
		for p: Dictionary in cat.takeoffs:
			if String(p.get("id", "")) == String(spec.catalog):
				s.pick_lat = float(p.lat)
				s.pick_lon = float(p.lon)
	else:
		s.pick_lat = float(spec.lat)
		s.pick_lon = float(spec.lon)
	s.wing = "wings/sport"
	s.wind_speed_kmh = 14.4
	s.wind_into_launch = true
	return s


func _ready() -> void:
	var places: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_arg("places", "")))
	var seq := _arg("seq", "K,Y").split(",", false)
	var fly_s := 0.0 if OS.get_cmdline_user_args().has("--skip-fly") else float(_arg("fly", "40"))
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	var poll := Timer.new()
	poll.wait_time = 0.5
	poll.timeout.connect(func() -> void: _peak_rss = maxf(_peak_rss, _status().get("VmRSS", 0.0)))
	add_child(poll)
	poll.start()
	for i in seq.size():
		var label: String = seq[i]
		main.opts.bots = int(_arg("bots", "2"))
		game.world_seed = int(main.call("_new_seed"))
		_peak_rss = 0.0
		var hwm0: float = _status().get("VmHWM", 0.0)
		var t0 := Time.get_ticks_msec()
		print("CR14 cycle %d place %s: start" % [i, label])
		await main.call("_fly", _settings(places[label]))
		var st := _status()
		print(
			(
				"CR14 load %d %s: total %.1f s state=%d rss %.0f hwm %.0f hwm_delta %.0f peak_rss %.0f static %.0f"
				% [i, label, (Time.get_ticks_msec() - t0) / 1000.0, int(main.get("state")), st.VmRSS, st.VmHWM, st.VmHWM - hwm0, _peak_rss, OS.get_static_memory_usage() / 1048576.0]
			)
		)
		var t := 0.0
		while t < fly_s:
			await get_tree().process_frame
			game.tick(1.0 / 60.0)
			t += 1.0 / 60.0
		main.call("_show_menu")
		await get_tree().create_timer(1.0).timeout
	print("CR14 done: %d cycles without crash" % seq.size())
	get_tree().quit(0)
