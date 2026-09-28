extends Node
## Кадр меню «Догнать» (CatchUpMenu, NET-42) поверх настоящего полёта — без сети: поддельные
## пилоты (RemotePilots.upsert) и источник меню из них (CatchUpMenu.remote_pilots_source).
## Запуск (окно нужно — настоящий рендер; под timeout 120):
##   godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
##     res://tools/shots/catch_up_menu_shot.tscn -- --autostart --air-start --bots=0 \
##     --camera=cockpit --lang=ru --out=/tmp/net42 --tag=ru_cockpit
## Пилоты: Оля — кружит впереди выше, Коля — стоит на старте, бот — кружит в стороне.
## Пишет <out>/<tag>.png.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 100.0

var _out := ""
var _tag := "menu"
var _lang := "ru"
var _main: Node = null
var _game: Game
var _rp: RemotePilots
var _feeds: Dictionary = {}
var _t := 0.0
var _layer: CanvasLayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--lang="):
			_lang = a.substr(7)
	if _out == "":
		push_error("catch_up_menu_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("catch_up_menu_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_layer):
		_layer.queue_free()
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


func _process(dt: float) -> void:
	get_tree().paused = false
	_t += dt
	if _rp == null:
		return
	for id: String in _feeds:
		var s: Dictionary = (_feeds[id] as Callable).call(_t)
		s.pilot_id = id
		_rp.upsert(s)


func _run() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	for i in 3000:
		if int(_main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		_fail("не долетели до FLYING (нужен --autostart)")
		return
	_game = _main.get_node("Game")
	Language.apply(_lang)
	_rp = RemotePilots.new()
	_rp.name = "RemotePilots"
	_game.add_child(_rp)
	_rp.setup_in_world(_game.terrain)
	var own: Vector3 = _game.glider.model.position
	var vel: Vector3 = _game.glider.model.velocity
	var fwd := Vector3(vel.x, 0.0, vel.z).normalized()
	if fwd.length() < 0.5:
		fwd = Vector3.FORWARD
	var right := fwd.cross(Vector3.UP).normalized()
	# Оля — впереди, кружит выше; бот — впереди справа; Коля — на старте.
	_add("7", "Оля", false, 5, _circler(own + fwd * 260.0 + Vector3.UP * 40.0, 45.0, 11.0, 0.0))
	_add(
		"bot-2",
		"Марина",
		true,
		2,
		_circler(own + fwd * 420.0 + right * 260.0 + Vector3.UP * 10.0, 50.0, 11.0, 1.5)
	)
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var hdg := float(start.heading_deg)
	var st := {
		"pos": sp, "rot": RemotePilotsShotPose.pose(hdg), "vel": Vector3.ZERO, "phase": "standing"
	}
	_add("5", "Коля", false, 7, func(_t2: float) -> Dictionary: return st.duplicate())
	await _wait(1.5)
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_layer = layer
	var menu: CatchUpMenu = (
		(load("res://scenes/ui/catch_up_menu.tscn") as PackedScene).instantiate()
	)
	layer.add_child(menu)
	menu.set_source(
		CatchUpMenu.remote_pilots_source(_rp), func() -> Vector3: return _game.glider.model.position
	)
	menu.open()
	_game.input_controller.hands_off = true  # как в game.gd: пока меню открыто — крыло само
	await _wait(1.0)
	for i in 10:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_out, _tag]
	print("catch_up_menu_shot: %s (%s)" % [path, error_string(img.save_png(path))])
	print("catch_up_menu_shot: rows %s, selected %s" % [menu.row_texts(), menu.selected_id()])
	print("catch_up_menu_shot: OK")
	await _quit(0)


func _add(id: String, nm: String, is_bot: bool, colors: Variant, feed: Callable) -> void:
	_feeds[id] = func(t: float) -> Dictionary:
		var s: Dictionary = feed.call(t)
		s.name = nm
		s.colors = colors
		s.wing = ""
		s.is_bot = is_bot
		return s


func _circler(c: Vector3, r: float, v: float, phase0: float) -> Callable:
	var w := v / r
	var bank := rad_to_deg(atan(v * v / (r * 9.81)))
	return func(t: float) -> Dictionary:
		var a := phase0 + w * t
		var p := c + Vector3(cos(a), 0.0, sin(a)) * r
		var vel := Vector3(-sin(a), 0.0, cos(a)) * v
		var hdg := rad_to_deg(atan2(vel.x, -vel.z))
		return {
			"pos": p,
			"rot": RemotePilotsShotPose.pose(hdg, bank, 4.0),
			"vel": vel,
			"phase": "flying"
		}


func _wait(seconds: float) -> void:
	var end := _t + seconds
	while _t < end:
		await get_tree().process_frame


## Поза по курсу/крену/тангажу, как в remote_pilots_shot.gd.
class RemotePilotsShotPose:
	static func pose(heading_deg: float, bank_deg: float = 0.0, pitch_deg: float = 0.0) -> Basis:
		return Basis.from_euler(
			Vector3(deg_to_rad(pitch_deg), -deg_to_rad(heading_deg), -deg_to_rad(bank_deg))
		)
