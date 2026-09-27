extends Node
## Кадры «погода из прогноза» (docs/plan/weather_by_temperature.md, карточка 6): главная сцена с
## автостартом и прогнозом из аргументов игры (--temp= --wind= --from= --sky= --hour= --location=
## --site=), затем два вида своей камерой: со старта на долину (по курсу старта) и сверху — на
## 1 км выше старта, взгляд вдаль вниз (облака и тени). Рядом с кадрами — лог «_derived» погоды.
## Интерфейс скрыт. Запуск (нужно окно — настоящий рендер):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/forecast_shot.tscn -- --autostart --bots=0 --temp=26 --wind=3 \
##     --hour=13 --out=/tmp/fc --tag=p26_w3 [--wait=20]
## Пишет <out>/<tag>_launch.png, <out>/<tag>_above.png, <out>/<tag>.txt. Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 200.0

var _out := ""
var _tag := "forecast"
var _wait := 20.0
var _main: Node = null
var _game: Game = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"--out":
				_out = v
			"--tag":
				_tag = v
			"--wait":
				_wait = float(v)
	if _out == "":
		push_error("forecast_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("forecast_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(code)


func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	for i in 4000:
		if int(_main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		_fail("не долетели до FLYING (нужен --autostart)")
		return
	_game = _main.get_node("Game")
	for n in _main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	_game.overlay.visible = false
	# Планер не мешает: не шагает (как после столкновения — Game.tick его пропускает), воздух и
	# облака живут; в сильный ветер его иначе сдувает со старта и открывается итог полёта.
	_game.set("_crashed", true)
	# Реальное время (в сильный ветер пилота может сдуть — симуляция встанет, облака останутся).
	await get_tree().create_timer(_wait, true, false, true).timeout
	_log()
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
	cam.fov = 70.0
	var eye := sp - fwd * 20.0 + Vector3.UP * 6.0
	cam.look_at_from_position(eye, eye + fwd * 1000.0 + Vector3.UP * 120.0, Vector3.UP)
	await _shoot("launch")
	cam.fov = 75.0
	eye = sp - fwd * 600.0 + Vector3.UP * 1000.0
	cam.look_at_from_position(eye, eye + fwd * 3000.0 + Vector3.DOWN * 900.0, Vector3.UP)
	await _shoot("above")
	print("forecast_shot: OK %s" % _tag)
	await _quit(0)


func _log() -> void:
	var w: Dictionary = _game.air.get("weather")
	var d: Dictionary = w.get("_derived", {})
	var lines: PackedStringArray = [
		"кромка над средней землёй %.0f м, над морем %.0f м" % [
			float(w.get("cloudbase_agl_m", 0.0)), float(_game.air.call("get_cloudbase_msl"))],
		"термики %s м/с, шаг %.0f м, доля %.2f, сухих %.2f, Cb %.2f, пыль %.2f, пелена %.2f" % [
			str(w.get("thermal_strength_ms")), float(w.get("thermal_spacing_m", 0.0)),
			float(w.get("thermal_duty", 0.0)), float(w.get("dry_thermal_fraction", 0.0)),
			float(w.get("cb_chance", 0.0)), float(w.get("dust_devil_chance", 0.0)),
			float(w.get("cirrus_cover", 0.0))],
		"ветер %.0f км/ч с %.0f°, волна %.2f" % [
			float(w.get("wind_speed_kmh", 0.0)), float(w.get("wind_from_deg", 0.0)),
			float(w.get("wave_strength", 0.0))],
		"_derived: " + JSON.stringify(d),
	]
	var f := FileAccess.open("%s/%s.txt" % [_out, _tag], FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
	print("forecast_shot: " + " | ".join(lines))


func _shoot(view: String) -> void:
	for i in 60:
		await RenderingServer.frame_post_draw
	var path := "%s/%s_%s.png" % [_out, _tag, view]
	var img := get_viewport().get_texture().get_image()
	print("forecast_shot: %s (%s)" % [path, error_string(img.save_png(path))])
