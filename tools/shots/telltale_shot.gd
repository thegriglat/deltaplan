extends Node
## Кадр ленточки на тросе трапеции (docs/telltale.md): главная сцена с аргументами игры
## (--autostart --autopilot --air-start ...), в момент --time камера — дочерняя планера (летит
## вместе с ним) в точке --eye (оси планера, м: X вправо, Y вверх от ног, −Z вперёд), смотрит
## на правую ленточку (--side=L — на левую).
##   godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
##     res://tools/shots/telltale_shot.tscn -- --autostart --autopilot --air-start \
##     --time=12 --eye=1.9,1.1,-2.2 --out=/tmp/yarn.png
## Без --eye — кадр из камеры игры (--camera=cockpit --look=...). --set-wind=<км/ч>,<откуда °>
## — сразу после старта задать ветер (Atmosphere.set_wind), например боковой на старте.
## Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 150.0

var _out := ""
var _time := 10.0
var _eye := Vector3(1.9, 1.1, -2.2)
var _side := "R"
var _fov := 50.0
var _own_eye := false
var _wind := Vector2(-1, 0)
var _target := Vector3(INF, 0, 0)  ## --target=x,y,z (оси планера): куда смотреть вместо ленточки
var _fwd_pitch := NAN  ## --forward=<тангаж °>: из глаз пилота прямо вперёд, а не на ленточку


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"--out":
				_out = v
			"--time":
				_time = float(v)
			"--side":
				_side = v
			"--fov":
				_fov = float(v)
			"--set-wind":
				var w := v.split(",")
				_wind = Vector2(float(w[0]), float(w[1]))
			"--target":
				var q := v.split(",")
				_target = Vector3(float(q[0]), float(q[1]), float(q[2]))
			"--forward":
				_fwd_pitch = float(v)
			"--eye":
				_own_eye = true
				var p := v.split(",")
				_eye = Vector3(float(p[0]), float(p[1]), float(p[2]))
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_done.bind(1))
	_run()


func _run() -> void:
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = null
	while game == null or game.sim_time_s < _time:
		await get_tree().process_frame
		if game == null and int(main.get("state")) == 2:  # State.FLYING
			game = main.get_node("Game")
			if _wind.x >= 0.0:
				game.air.call("set_wind", _wind.x, _wind.y)
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	game.overlay.visible = false
	var tt := game.glider.visual.find_child("Telltale" + _side, true, false) as Node3D
	if tt == null:
		print("telltale_shot: FAIL нет ленточки")
		_done(1)
		return
	if not is_nan(_fwd_pitch):
		var gc := get_viewport().get_camera_3d()
		var fc := Camera3D.new()
		game.glider.add_child(fc)
		SkyEnvironment.setup_camera(fc)
		fc.fov = _fov
		fc.near = 0.02
		fc.global_position = gc.global_position
		fc.rotation = Vector3(deg_to_rad(_fwd_pitch), 0, 0)
		fc.current = true
		for i in 40:
			await RenderingServer.frame_post_draw
		_save()
		return
	if not _own_eye:
		for i in 40:
			await RenderingServer.frame_post_draw
		_save()
		return
	var cam := Camera3D.new()
	game.glider.add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.fov = _fov
	cam.near = 0.02
	cam.position = _eye
	cam.current = true
	for i in 40:
		var knot := game.glider.to_local(tt.global_position) + Vector3(0, 0, 0.12)
		if _target.x != INF:
			knot = _target
		cam.look_at(game.glider.to_global(knot), game.glider.global_basis.y)
		await RenderingServer.frame_post_draw
	_save()


func _save() -> void:
	var img := get_viewport().get_texture().get_image()
	print("telltale_shot: %s (%s)" % [_out, error_string(img.save_png(_out))])
	_done(0)


func _done(code: int) -> void:
	get_tree().quit(code)
