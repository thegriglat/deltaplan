extends Node
## Кадры грозового облака (Cb) для проверки вида: полёт над стартом запускается как из меню,
## атмосфера прокручивается до зрелого Cb и замораживается (облака не меняются между кадрами
## и запусками), камера ставится относительно самого развитого Cb (ближнего к старту).
## Запуск:
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/storm_shot.tscn -- --out=/tmp/st [--loc=altai] [--temp=34] [--wind=3.9] \
##     [--hour=14] [--air_s=2400] [--views=far,mid,under,rain,high] [--bench=1]
## Виды: far — Cb за ~25 км сбоку от ветра (башня, наковальня); mid — ~9 км; under — у края
## основания, взгляд на ливень; rain — под основанием у ливня, взгляд наружу; high — высоко
## над стартом, взгляд на дальний рельеф в сторону Cb (серые прямоугольники над рельефом).
## --bench=1 — ещё и среднее GPU-время кадра на каждом виде (120 кадров).
## Пишет <out>/<view>.png. Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 400.0

var _out := ""
var _location := "altai"
## Прогноз: температура днём, °C, и ветер у земли, км/ч (--wind — в м/с, как у игры).
var _temp_c := 34.0
var _wind_kmh := 14.0
var _hour := 14.0
var _air_s := 2400.0
var _views: PackedStringArray = ["far", "mid", "under", "rain", "high", "high_ns", "high2"]
var _bench := false
## --ab=<плотность> — в замере чередовать старую плотность ливня (например 0,35 — непрозрачная
## стена) с текущей: одна и та же сцена и процесс, чужая нагрузка на GPU делится поровну.
var _ab := 0.0
var _layer: CloudLayer = null
var _main: Node = null
var _vp: SubViewport = null
var _root_cam: Camera3D = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"out":
				_out = kv[1]
			"loc":
				_location = kv[1]
			"temp":
				_temp_c = float(kv[1])
			"wind":
				_wind_kmh = float(kv[1]) * 3.6
			"hour":
				_hour = float(kv[1])
			"air_s":
				_air_s = float(kv[1])
			"views":
				_views = kv[1].split(",")
			"bench":
				_bench = kv[1] == "1"
			"ab":
				_ab = float(kv[1])
	if _out == "":
		push_error("storm_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("storm_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


func _run() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 600:
		if game.settings != null:
			break
		await get_tree().process_frame
	if game.settings == null:
		_fail("мир за меню не загрузился")
		return
	var s := FlightSettings.defaults()
	s.location_id = _location
	s.site_id = ""
	s.temperature_c = _temp_c
	s.wind_speed_kmh = _wind_kmh
	s.start_hour = _hour
	if not await game.start(s):
		_fail("полёт не запустился")
		return
	game.set_physics_process(false)
	game.set_process(false)
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	var air: Node = game.air
	air.set_physics_process(false)
	air.set("time_s", 0.0)
	var t := 0.0
	while t < _air_s:
		air.call("step", 0.5)
		t += 0.5
	var start: Dictionary = game.get_start()
	var sp: Vector3 = start.position
	_vp = SubViewport.new()
	_vp.size = Vector2i(1920, 1080)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var cam := Camera3D.new()
	_vp.add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.make_current()
	_root_cam = Camera3D.new()
	add_child(_root_cam)
	SkyEnvironment.setup_camera(_root_cam)
	_root_cam.make_current()
	get_viewport().disable_3d = true
	var layer := air.get_node_or_null("Clouds") as CloudLayer
	_layer = layer
	# Облака выбираются у камеры: сначала постоять над стартом.
	_place(cam, sp + Vector3.UP * 1500.0, sp + Vector3(0, 1500, -1000))
	_reselect(layer)
	for i in 90:
		await RenderingServer.frame_post_draw
	var cb := _pick_cb(layer, sp)
	if cb.is_empty():
		_fail("нет Cb (увеличить --air_s)")
		return
	var c: Vector3 = cb.c
	var ax: Vector3 = cb.ax
	var base: float = cb.base
	var hgt: float = cb.h
	var rx: float = cb.rx
	var side := Vector3(-ax.z, 0.0, ax.x)
	print(
		(
			(
				"storm_shot: Cb центр (%.0f, %.0f), до старта %.0f м, кромка %.0f, "
				+ "мощность %.0f, rx %.0f, наковальня %.2f, ливень %.2f"
			)
			% [c.x, c.z, Vector2(c.x - sp.x, c.z - sp.z).length(), base, hgt, rx, cb.anvil, cb.rain]
		)
	)
	for v in _views:
		var eye: Vector3
		var look: Vector3
		match v:
			"far":
				eye = c + side * 25000.0
				eye.y = base - 200.0
				look = c + Vector3.UP * (base + hgt * 0.4 - c.y)
			"mid":
				eye = c + side * 9000.0 - ax * 3000.0
				eye.y = base - 400.0
				look = c + Vector3.UP * (base + 1200.0 - c.y)
			"under":
				eye = c + side * rx * 1.6
				eye.y = base - 350.0
				look = Vector3(c.x, base - 700.0, c.z)
			"rain":
				eye = c + ax * rx * 0.25 + side * rx * 0.5
				eye.y = base - 150.0
				look = eye + side * 3000.0 - Vector3.UP * 500.0
			_:
				# high, high_ns (без теней-декалей), high2 / high2_ns — взгляд в другую сторону.
				eye = Vector3(sp.x, base - 250.0, sp.z)
				var d := Vector3(c.x - sp.x, 0.0, c.z - sp.z).normalized()
				d = d.rotated(Vector3.UP, deg_to_rad(40.0 if v.begins_with("high2") == false else 160.0))
				look = eye + d * 3000.0 - Vector3.UP * 350.0
		var gh := float(game.terrain.height_at(eye.x, eye.z))
		eye.y = maxf(eye.y, gh + 60.0)
		_place(cam, eye, look)
		_reselect(layer)
		# _ns — без теней-декалей (сравнение).
		for dc in layer.get_children():
			if dc is Decal:
				if v.ends_with("_ns"):
					dc.cull_mask = 0
		for i in 90:
			await RenderingServer.frame_post_draw
			_place(cam, eye, look)
		await _shoot("%s/%s.png" % [_out, v])
		if _bench:
			await _measure(v)
	print("storm_shot: OK")
	await _quit(0)


## Время атмосферы заморожено — облака, выбранные у новой камеры, не проявились бы
## (fade_in_s идёт по времени атмосферы): выбрать заново сразу видимыми.
func _reselect(layer: CloudLayer) -> void:
	layer.set("_instant", true)
	layer.set("_acc", 1.0e9)


## Самый развитый Cb (мощность × наковальня) поближе к старту.
func _pick_cb(layer: CloudLayer, sp: Vector3) -> Dictionary:
	var best := {}
	var score := -1.0
	for g in layer.records():
		if int(g[19] + 0.5) != 3:
			continue
		var c := Vector3(g[0], g[1], g[2])
		var d := Vector2(c.x - sp.x, c.z - sp.z).length()
		var sc := g[9] * (0.3 + g[17]) * g[20] / (1.0 + d / 20000.0)
		if sc > score:
			score = sc
			best = {
				"c": c, "ax": Vector3(g[4], 0.0, g[5]), "base": g[8], "h": g[9], "rx": g[10],
				"anvil": g[17], "rain": g[18],
			}
	return best


func _measure(view: String) -> void:
	var vp := _vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	if _ab <= 0.0:
		print("storm_shot: BENCH %s — GPU кадр %.3f мс" % [view, await _avg_gpu(vp, 120)])
		return
	var mat: ShaderMaterial = _layer.get("_material")
	var cur: float = mat.get_shader_parameter("virga_density")
	var sums := [0.0, 0.0]
	for r in 4:
		for k in 2:
			mat.set_shader_parameter("virga_density", _ab if k == 0 else cur)
			sums[k] += await _avg_gpu(vp, 40)
	mat.set_shader_parameter("virga_density", cur)
	print(
		"storm_shot: BENCH %s — GPU кадр: ливень %.3f — %.3f мс, ливень %.3f — %.3f мс"
		% [view, _ab, sums[0] / 4.0, cur, sums[1] / 4.0]
	)


func _avg_gpu(vp: RID, n: int) -> float:
	for i in 10:
		await RenderingServer.frame_post_draw
	var sum := 0.0
	for i in n:
		await RenderingServer.frame_post_draw
		sum += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return sum / n


func _place(cam: Camera3D, p: Vector3, look: Vector3) -> void:
	cam.look_at_from_position(p, look)
	_root_cam.global_transform = cam.global_transform
	if _root_cam.compositor != null:
		cam.compositor = _root_cam.compositor


func _shoot(path: String, frames: int = 12) -> void:
	for i in frames:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var err := img.save_png(path)
	print("storm_shot: %s (%s)" % [path, error_string(err)])
