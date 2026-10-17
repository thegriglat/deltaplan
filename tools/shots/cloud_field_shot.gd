extends Node
## Кадры слоя поля облачности (CLF-5): главная сцена с автостартом (место, час, прогноз — флагами
## игры: --location= / --latlon=, --hour=, --temp=, --wind=, --sky=), мир переводится на
## --world-t секунд от часа старта (Game.set_world_time: поле облачности разгоняется до этого
## момента), затем виды своей камерой. Интерфейс скрыт. Нужно окно (настоящий рендер):
##   XDG_DATA_HOME=~/.cache/dp-xdg/<копия> DISPLAY=:0 godot --path . --audio-driver Dummy \
##     --resolution 1920x1080 res://tools/shots/cloud_field_shot.tscn -- --autostart --bots=0 \
##     --location=ongudai --hour=12 --temp=30 --wind=3 --world-t=5400 --views=high \
##     --out=/tmp/cf --tag=ongudai
## --views — через запятую:
##   high   — 2,5 км над стартом, взгляд вдаль чуть вниз (по курсу старта);
##   ground — 80 м над землёй (крыши) в 60 м к северу от старта, взгляд на юг на 5° вверх
##            (хребет из города);
##   low    — 300 м над стартом, взгляд по курсу старта на 5° вверх.
## Пишет <out>/<tag>_<вид>.jpg (JPEG q88) и строку поля (покрытие, мощность, основание). Код 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 600.0

var _out := ""
var _tag := "field"
var _wait := 8.0
var _world_t := -1.0
var _views: PackedStringArray = ["high"]
var _gpu_frames := 0
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
			"--views":
				_views = v.split(",", false)
			"--gpu":
				_gpu_frames = int(v)
	if _out == "":
		push_error("cloud_field_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("cloud_field_shot: FAIL (%s)" % why)
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
	# Точка с карты грузит рельеф из сети — ждать по времени, а не по кадрам.
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
	# Подсказки клавиш, прицел и прочие слои интерфейса — тоже.
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_game.set("_crashed", true)
	if _world_t >= 0.0:
		_game.set_world_time(_world_t)
	await get_tree().create_timer(_wait, true, false, true).timeout
	# Поле облачности считается в рабочем потоке: ждать, пока оно догонит время мира.
	var cp: CloudPhysics = _game.air.get("cloud_phys")
	for k in 120:
		var at := float(_game.air.get("time_s"))
		if cp == null or cp.field.time >= at - 60.0:
			break
		if k % 10 == 0:
			print("cloud_field_shot: ждём поле: поле %.0f, атмосфера %.0f" % [cp.field.time, at])
		await get_tree().create_timer(1.0, true, false, true).timeout
	_print_field()
	var cam := Camera3D.new()
	cam.far = 120000.0
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	cam.fov = 70.0
	var g: Variant = _game.get("glider")
	if g is Node3D:
		(g as Node3D).visible = false
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
	for view in _views:
		var eye := sp
		var dir := fwd
		match view:
			"high":
				eye = sp + Vector3.UP * 2500.0 - fwd * 1500.0
				dir = (fwd + Vector3.DOWN * 0.12).normalized()
			"ground":
				# 60 м к северу от старта, на высоте крыш (80 м над землёй: в городе дома
				# закрывают хребет).
				eye = sp + Vector3(0.0, 80.0, -60.0)
				var ter: Variant = _game.get("terrain")
				if ter != null and (ter as Object).has_method("height_at"):
					eye.y = maxf(eye.y, float(ter.call("height_at", eye.x, eye.z)) + 80.0)
				dir = Vector3(0.0, tan(deg_to_rad(5.0)), 1.0).normalized()
			"low":
				eye = sp + Vector3.UP * 300.0
				dir = (fwd + Vector3.UP * tan(deg_to_rad(5.0))).normalized()
		cam.look_at_from_position(eye, eye + dir * 1000.0, Vector3.UP)
		await _shoot(view)
	print("cloud_field_shot: OK %s" % _tag)
	await _quit(0)


func _print_field() -> void:
	var air: Object = _game.air
	var cp: CloudPhysics = air.get("cloud_phys")
	if cp == null or cp.field == null or cp.field.nx == 0:
		print("cloud_field_shot: поля нет")
		return
	var f := cp.field
	var layer := get_tree().root.find_children("*", "Node3D", true, false).filter(
		func(n: Node) -> bool: return n is CloudLayer
	)
	if not layer.is_empty():
		var l: CloudLayer = layer[0]
		print("cloud_field_shot: время атмосферы %.0f, слой cf_on %s, загрузок %d" % [
			float(air.get("time_s")), l.field_params.get("cf_on"), l.field_uploads])
	var n := 0
	var cs := 0.0
	var dmax := 0.0
	for c in f.cover.size():
		if f.cover[c] > 0.01:
			n += 1
		cs += f.cover[c]
		dmax = maxf(dmax, f.depth[c])
	print(
		(
			"cloud_field_shot: поле t=%.0f основание %.0f м, покрытие ср. %.3f, столбцов с облаком %d из %d, мощность макс %.0f м, фон %.2f/%.0f"
			% [f.time, f.base_msl, cs / f.cover.size(), n, f.cover.size(), dmax, f.bg_cover, f.bg_depth]
		)
	)


func _shoot(view: String) -> void:
	for i in 90:
		await RenderingServer.frame_post_draw
	var path := "%s/%s_%s.jpg" % [_out, _tag, view]
	var img := get_viewport().get_texture().get_image()
	print("cloud_field_shot: %s (%s)" % [path, error_string(img.save_jpg(path, 0.88))])
	if _gpu_frames > 0:
		await _measure(view)


## GPU кадра со слоем и без него (cf_on = 0 до следующей загрузки поля): разница — цена слоя.
func _measure(view: String) -> void:
	var layers := get_tree().root.find_children("*", "Node3D", true, false).filter(
		func(n: Node) -> bool: return n is CloudLayer
	)
	if layers.is_empty():
		return
	var l: CloudLayer = layers[0]
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var res := []
	for on in [true, false, true]:
		var keep: float = float(l.field_params.get("cf_on", 0.0))
		if not on:
			l.field_params["cf_on"] = 0.0
		for i in 20:
			await RenderingServer.frame_post_draw
		var g := 0.0
		for i in _gpu_frames:
			await RenderingServer.frame_post_draw
			g += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		res.append(g / _gpu_frames)
		l.field_params["cf_on"] = keep if on else 1.0
	print("cloud_field_shot: GPU %s: кадр со слоем %.2f / без слоя %.2f / со слоем %.2f мс" % [
		view, res[0], res[1], res[2]])
