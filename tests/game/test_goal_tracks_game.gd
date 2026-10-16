extends Node
## Треки в игре (GL-7b, GL-К5/К6): запись с отрыва, сохранение следа прошлой попытки места по
## концу полёта, показ при show_last_track, ничего — в сети. Главная сцена, шаги физики вручную.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []
var _old_dir := ""


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


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


func _fly(game: Game, seconds: float) -> void:
	for i in int(seconds / DT):
		game.tick(DT)


func _ribbons(game: Game) -> int:
	var n := 0
	for c in game.get_children():
		if c is TrackRibbon:
			n += 1
	return n


func test_record_save_and_show() -> void:
	_old_dir = LastTrackStore.base_dir
	LastTrackStore.base_dir = "user://tracks_test_gl7b"
	var pair := await _launch()
	var main: Node = pair[0]
	var game: Game = pair[1]
	var key := LastTrackStore.place_key(game.settings)
	DirAccess.remove_absolute(LastTrackStore.path_for(key))
	game.settings.show_last_track = true
	game.restart()
	check(game.goal_tracks.is_empty(), "следа ещё нет")
	check(_ribbons(game) == 0, "полос нет")
	_fly(game, 20.0)
	check(game.stats.took_off, "взлёт засчитан")
	game.restart()  # конец попытки: запись сохранена
	var saved := LastTrackStore.load(key)
	check(saved != null, "след сохранён")
	if saved != null:
		check(saved.size() >= 15 and saved.size() <= 25, "около 1 Гц: %d точек" % saved.size())
	check(game.goal_tracks.size() == 1 and (game.goal_tracks[0] as FlightTrack).source == "last",
			"след прошлой попытки в goal_tracks")
	check(_ribbons(game) == 1, "полоса нарисована")
	# без show_last_track — не показываем, но запись идёт
	game.settings.show_last_track = false
	game.restart()
	check(game.goal_tracks.is_empty() and _ribbons(game) == 0, "без флага — пусто")
	# сеть — ничего не пишем и не показываем
	game.settings.show_last_track = true
	game.net = NetFlight.new()
	_fly(game, 10.0)
	game.restart()
	check(game.goal_tracks.is_empty() and _ribbons(game) == 0, "в сети треков нет")
	game.net = null
	DirAccess.remove_absolute(LastTrackStore.path_for(key))
	main.queue_free()
	await get_tree().process_frame
	LastTrackStore.base_dir = _old_dir
