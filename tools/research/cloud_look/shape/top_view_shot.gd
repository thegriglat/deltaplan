extends Node
## CLK-2: вид сверху на слой кучевых — размеры отдельных облаков (size_p90_p10, README.md).
## Главная сцена с автостартом, мир переводится на --world-t секунд (поле облачности «сильного дня»
## догоняет время), камера висит над слоем (--alt м над основанием, взгляд вниз, FOV --fov) и снимает
## кадры в точках со сдвигом --offsets (x,z;x,z… в метрах от старта). Пишет <out>/<tag>_<i>.png и
## <out>/<tag>_field.json (основание, покрытие, размеры кадра в метрах на уровне верха слоя).
## Запуск — top_view.sh (окно xvfb, тот же профиль, что у tools/shots/menu_background.sh).
##   godot --path . --resolution 1920x1080 res://tools/research/cloud_look/shape/top_view_shot.tscn -- \
##     --autostart --bots=0 --location=ongudai --hour=12 --temp=30 --wind=3 --world-t=5400 \
##     --out=/tmp/tv --tag=after --alt=9000 --fov=90 --offsets=0,0;14000,0;-14000,0;0,14000;0,-14000

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 900.0

var _out := ""
var _tag := "top"
var _wait := 8.0
var _world_t := -1.0
var _alt := 9000.0
var _fov := 90.0
var _offsets: Array[Vector2] = [Vector2.ZERO]
var _warm := 60
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
			"--world-t":
				_world_t = float(v)
			"--alt":
				_alt = float(v)
			"--fov":
				_fov = float(v)
			"--warm":
				_warm = int(v)
			"--offsets":
				_offsets.clear()
				for p in v.split(";", false):
					var xy := p.split(",")
					_offsets.append(Vector2(float(xy[0]), float(xy[1])))
	if _out == "":
		push_error("top_view_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("top_view_shot: FAIL (%s)" % why)
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
	var t_end := Time.get_ticks_msec() + 300000
	while Time.get_ticks_msec() < t_end:
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
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_game.set("_crashed", true)
	if _world_t >= 0.0:
		_game.set_world_time(_world_t)
	await get_tree().create_timer(_wait, true, false, true).timeout
	var cp: CloudPhysics = _game.air.get("cloud_phys")
	for k in 120:
		var at := float(_game.air.get("time_s"))
		if cp == null or cp.field.time >= at - 60.0:
			break
		await get_tree().create_timer(1.0, true, false, true).timeout
	var f := cp.field
	var cs := 0.0
	var dmax := 0.0
	for c in f.cover.size():
		cs += f.cover[c]
		dmax = maxf(dmax, f.depth[c])
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var top_m := minf(dmax, 3000.0)
	var info := {
		"world_t": _world_t, "field_t": f.time, "base_msl": f.base_msl, "cover_mean": cs / f.cover.size(),
		"depth_max_m": dmax, "alt_above_base_m": _alt, "fov_deg": _fov, "frames": [],
		"viewport_px": [get_viewport().size.x, get_viewport().size.y],
		"start": [sp.x, sp.z],
		"field": {
			"nx": f.nx, "ny": f.ny, "dx": f.dx, "x0": f.x0, "y0": f.y0,
			"cover": Array(f.cover), "depth": Array(f.depth), "stage": Array(f.stage),
		},
	}
	var cam := Camera3D.new()
	cam.far = 120000.0
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	cam.fov = _fov
	var g: Variant = _game.get("glider")
	if g is Node3D:
		(g as Node3D).visible = false
	for i in _offsets.size():
		var eye := Vector3(sp.x + _offsets[i].x, f.base_msl + _alt, sp.z + _offsets[i].y)
		cam.look_at_from_position(eye, eye + Vector3.DOWN * 1000.0, Vector3.FORWARD)
		for k in _warm:
			await RenderingServer.frame_post_draw
		var path := "%s/%s_%d.png" % [_out, _tag, i]
		var img := get_viewport().get_texture().get_image()
		print("top_view_shot: %s (%s)" % [path, error_string(img.save_png(path))])
		# Масштаб на уровне середины слоя: полуширина кадра = (alt − top/2)·tan(fov/2) по горизонтали
		# (fov камеры Godot — вертикальный по умолчанию; keep_aspect = KEEP_HEIGHT).
		(info.frames as Array).append({
			"file": path.get_file(), "eye": [eye.x, eye.y, eye.z], "cam_height_above_mid_layer_m": _alt - top_m * 0.5,
			"keep_aspect": cam.keep_aspect,
		})
	var jf := FileAccess.open("%s/%s_field.json" % [_out, _tag], FileAccess.WRITE)
	jf.store_string(JSON.stringify(info, "  "))
	jf.close()
	print("top_view_shot: OK %s" % _tag)
	await _quit(0)
