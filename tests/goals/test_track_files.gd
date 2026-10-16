extends Node
## GL-10: GPX (TrackIO.read_gpx), проверка «из этого места», track_paths → список вкладки и goal_tracks.

const DATA := "res://tests/goals/data/"
const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("approx: %s: %f != %f" % [msg, actual, expected])


func _settings(loc: String) -> FlightSettings:
	var s := FlightSettings.defaults()
	s.location_id = loc
	return s


func test_gpx_with_time() -> void:
	var t := TrackIO.read(DATA + "time.gpx")
	check(t != null, "чтение: " + TrackIO.last_error())
	if t == null:
		return
	check(t.size() == 4, "две секции подряд: %d" % t.size())
	approx(t.t_s[0], 0.0, 1e-4, "t0")
	approx(t.t_s[1], 2.5, 1e-3, "дробные секунды")
	approx(t.t_s[2], 5.0, 1e-3, "смещение +02:00 (12:23:50+02:00 = 10:23:50Z)")
	approx(t.t_s[3], 10.25, 1e-3, "дробные секунды Z")
	approx(t.alt_m[3], 530.0, 1e-3, "ele")
	approx(t.lat[2], 50.002, 1e-9, "lat")
	check(t.name == "Тест", "имя трека")
	check(t.source == DATA + "time.gpx", "источник")


func test_gpx_without_time_one_second() -> void:
	var t := TrackIO.read_gpx(DATA + "notime.gpx")
	check(t != null, "чтение")
	if t != null:
		check(t.size() == 3, "точек")
		approx(t.t_s[2], 2.0, 1e-4, "по 1 с на точку")


func test_gpx_without_ele_rejected() -> void:
	check(TrackIO.read_gpx(DATA + "noele.gpx") == null, "без ele — null")
	check(TrackIO.last_error().contains("ele"), "причина: " + TrackIO.last_error())


func test_gpx_broken_and_missing() -> void:
	check(TrackIO.read_gpx(DATA + "broken.gpx") == null, "битый — null")
	check(TrackIO.last_error() != "", "есть причина")
	check(TrackIO.read(DATA + "nope.gpx") == null, "нет файла")
	check(TrackIO.read(DATA + "x.txt") == null, "неизвестное расширение")


func test_iso_time_parse() -> void:
	var a := TrackIO._parse_iso_time("2024-07-15T10:23:45Z")
	approx(TrackIO._parse_iso_time("2024-07-15T12:23:45+0200"), a, 1e-6, "+0200")
	approx(TrackIO._parse_iso_time("2024-07-15T05:53:45-04:30"), a, 1e-6, "-04:30")
	approx(TrackIO._parse_iso_time("2024-07-15T10:23:45.5"), a + 0.5, 1e-6, "без зоны")
	check(is_nan(TrackIO._parse_iso_time("вчера")), "мусор — NAN")


func test_place_check() -> void:
	var ong := _settings("ongudai")
	var mine := TrackIO.read(DATA + "ongudai.gpx")
	var far := TrackIO.read(DATA + "far.gpx")
	check(GoalsTab.track_in_place(mine, ong), "свой трек у Онгудая принят")
	check(not GoalsTab.track_in_place(far, ong), "трек за 200 км отвергнут")
	check(GoalsTab.check_track_file(DATA + "ongudai.gpx", ong) == "", "файл принят")
	check(GoalsTab.check_track_file(DATA + "far.gpx", ong) == "goals_track_foreign", "чужой")
	check(GoalsTab.check_track_file(DATA + "broken.gpx", ong) == "goals_track_unreadable", "нечитаемый")
	var pick := FlightSettings.defaults()
	pick.pick_lat = 50.8
	pick.pick_lon = 86.1
	check(GoalsTab.track_in_place(mine, pick), "точка с карты рядом — принят")
	pick.pick_lat = 60.0
	check(not GoalsTab.track_in_place(mine, pick), "точка с карты далеко — нет")


func test_tab_list_and_recheck() -> void:
	var tab := GoalsTab.new()
	var s := _settings("ongudai")
	tab.context_fn = func() -> FlightSettings: return s
	tab.add_track_files(PackedStringArray([DATA + "ongudai.gpx", DATA + "far.gpx", DATA + "broken.gpx"]))
	check(tab.collect_track_paths() == PackedStringArray([DATA + "ongudai.gpx"]), "принят один: %s" % [tab.collect_track_paths()])
	check((tab.get("_track_msg") as Label).visible, "сообщение о чужих")
	check((tab.get("_tracks_box") as Control).get_child_count() == 1, "в списке одна строка")
	tab.add_track_files(PackedStringArray([DATA + "ongudai.gpx"]))
	check(tab.collect_track_paths().size() == 1, "дубль не добавлен")
	# смена места: трек становится чужим
	s = _settings("altai")
	tab.recheck_tracks(s)
	check(tab.collect_track_paths().is_empty(), "при смене места чужой убран")
	check((tab.get("_track_msg") as Label).visible, "сообщение при смене места")
	# убрать вручную
	s = _settings("ongudai")
	tab.add_track_files(PackedStringArray([DATA + "ongudai.gpx"]))
	tab.call("_remove_track", DATA + "ongudai.gpx")
	check(tab.collect_track_paths().is_empty(), "убран кнопкой")
	tab.free()


func _launch() -> Array:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--air-start=600,150"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	game.process_mode = Node.PROCESS_MODE_DISABLED
	return [main, game]


func _circle_at(game: Game, dlat: float) -> FlightTrack:
	var c: Vector2 = game.terrain.local_to_latlon(0.0, 0.0)
	var t := FlightTrack.new()
	for i in 30:
		var a := TAU * i / 30.0
		t.append(c.x + dlat + 0.01 * sin(a), c.y + 0.015 * cos(a), 1000.0 + i, float(i))
	return t


func test_game_loads_track_paths() -> void:
	var pair := await _launch()
	var main: Node = pair[0]
	var game: Game = pair[1]
	var dir := "user://test_track_files_gl10"
	DirAccess.make_dir_recursive_absolute(dir)
	var ok_p := ProjectSettings.globalize_path(dir.path_join("here.igc"))
	var far_p := ProjectSettings.globalize_path(dir.path_join("far.igc"))
	var bad_p := ProjectSettings.globalize_path(dir.path_join("bad.gpx"))
	check(TrackIO.write_igc(_circle_at(game, 0.0), ok_p) == OK, "запись своего")
	check(TrackIO.write_igc(_circle_at(game, 2.0), far_p) == OK, "запись чужого (200 км)")
	var f := FileAccess.open(bad_p, FileAccess.WRITE)
	f.store_string("<gpx><trk>")
	f.close()
	game.settings.track_paths = PackedStringArray([ok_p, far_p, bad_p])
	game.restart()
	var from_files: Array = game.goal_tracks.filter(
		func(t: FlightTrack) -> bool: return t.source.is_absolute_path())
	check(from_files.size() == 1, "загружен один: %d" % from_files.size())
	if from_files.size() == 1:
		check((from_files[0] as FlightTrack).source == ok_p, "источник — путь файла")
	var ribbons := 0
	for c in game.get_children():
		if c is TrackRibbon:
			ribbons += 1
	check(ribbons == 1, "полоса нарисована: %d" % ribbons)
	# повторный старт не копит треки
	game.restart()
	check(game.goal_tracks.size() == 1, "после перезапуска всё ещё один: %d" % game.goal_tracks.size())
	# без путей — пусто
	game.settings.track_paths = PackedStringArray()
	game.restart()
	check(game.goal_tracks.is_empty(), "без track_paths пусто")
	for n in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)
	main.queue_free()
	await get_tree().process_frame
