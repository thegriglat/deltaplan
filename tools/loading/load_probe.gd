extends Node
## Замер загрузки полёта с точки на карте (фризы главного потока, этапы, экран загрузки).
## Меню (мир за меню — встроенная локация) → «Лететь» с точки --latlon → ждём полёт или
## возврат в меню. Печатает этапы (LoadProgress.trace), самые длинные интервалы между кадрами
## и итог. Запуск:
##   godot --path . --audio-driver Dummy --resolution 1280x720 res://tools/loading/load_probe.tscn \
##     -- --latlon=50.60,86.40 [--cache=<папка>] [--out=<папка> --shots=0.5,3,8] [--timeout=120]
## --cache — свой кеш рельефа (пустая папка — «холодная» загрузка из сети); --url=<шаблон> —
## другой адрес тайлов (проверка ошибок сети).
## Код выхода: 0 — полёт начался, 2 — вернулись в меню (ошибка показана), 1 — таймаут.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _lat := NAN
var _lon := NAN
var _out := ""
var _shots: Array[float] = []
var _timeout := 120.0
var _main: Node
var _t0 := 0
var _last := 0
var _measuring := false
var _gaps: Array[Vector2] = []  ## (t от старта, длительность), с
var _frames := 0
var _max_gap := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"latlon":
				var p := v.split(",")
				_lat = float(p[0])
				_lon = float(p[1])
			"cache":
				var world: Dictionary = Config.get_config("world")
				world.runtime_terrain.cache_dir = v
				world.surface.runtime.cache_dir = v.path_join("worldcover")
			"url":  # подменить адрес тайлов (проверка ошибок сети: несуществующий хост, 404)
				Config.get_config("world").runtime_terrain.url_template = v
			"out":
				_out = v
			"shots":
				for s in v.split(","):
					_shots.append(float(s))
			"timeout":
				_timeout = float(v)
	if is_nan(_lat):
		push_error("load_probe: нужен --latlon=<lat>,<lon>")
		get_tree().quit(1)
		return
	if _out != "":
		DirAccess.make_dir_recursive_absolute(_out)
	_run()


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if _measuring:
		_frames += 1
		var gap := (now - _last) / 1e6
		_max_gap = maxf(_max_gap, gap)
		if gap > 0.1:
			_gaps.append(Vector2((_last - _t0) / 1e6, gap))
			print("[gap] %.2f с: %.0f мс" % [(_last - _t0) / 1e6, gap * 1000.0])
	_last = now


func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", LaunchOptions.parse(PackedStringArray()))
	add_child(_main)
	var game: Game = _main.get_node("Game")
	for i in 1200:
		if game.settings != null and int(_main.get("state")) == 0:
			break
		await get_tree().process_frame
	for i in 10:
		await get_tree().process_frame
	var terrain: Terrain = game.terrain
	terrain.progress.trace = true
	var s: FlightSettings = (_main.get("flight") as FlightSettings).duplicate()
	s.pick_lat = _lat
	s.pick_lon = _lon
	print("load_probe: старт с %.4f, %.4f" % [_lat, _lon])
	_t0 = Time.get_ticks_usec()
	_last = _t0
	_measuring = true
	for t in _shots:
		get_tree().create_timer(t, true, false, true).timeout.connect(_shot.bind(t))
	var start_menu: StartMenu = _main.get_node("UI/StartMenu")
	start_menu.fly_requested.emit(s)
	var code := 1
	while (Time.get_ticks_usec() - _t0) / 1e6 < _timeout:
		await get_tree().process_frame
		var st := int(_main.get("state"))
		if st == 2:  # FLYING
			code = 0
			break
		if st == 0:  # MENU — ошибка
			code = 2
			break
	_measuring = false
	var total := (Time.get_ticks_usec() - _t0) / 1e6
	_gaps.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y > b.y)
	var top := _gaps.slice(0, 8).map(
		func(g: Vector2) -> String: return "%.0f@%.1f" % [g.y * 1000, g.x]
	)
	var how: String = ["полёт", "таймаут", "меню"][code]
	print("load_probe: итог %s за %.2f с, кадров %d" % [how, total, _frames])
	print("load_probe: макс. интервал %.0f мс; >100 мс: %s" % [_max_gap * 1000.0, top])
	if code == 2:
		print("load_probe: сообщение: %s" % _status_text(start_menu))
	for d in terrain.progress.timings:
		print("load_probe: этап %-10s %6.2f с" % [d.key, d.s])
	await _quit(code)


func _status_text(menu: StartMenu) -> String:
	var l: Variant = menu.get("_status")
	return (l as Label).text if l is Label else ""


func _shot(t: float) -> void:
	if not _measuring or _out == "":
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _out.path_join("load_%04.1fs.png" % t)
	img.save_png(path)
	print("load_probe: кадр %s" % path)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)
