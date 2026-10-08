extends Node
## Кадры облаков для проверки обреза (облако срезано прямой вертикальной гранью): полёт над
## стартом локации запускается как из меню, время атмосферы замораживается (облака не
## меняются между кадрами и запусками), камера на заданных высотах AGL смотрит на солнце.
## Запуск:
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/cloud_cut_shot.tscn -- --out=/tmp/cc [--loc=ongudai] \
##     [--temp=31] [--wind=5] [--hour=13] [--agl=300,1500,2500] [--yaw=0] [--pitch=-3] \
##     [--air_s=600] [--series=8]
## --yaw — поворот от азимута солнца, град; --air_s — сколько секунд прокрутить атмосферу до
## заморозки (облака успевают вырасти); --series=N — ещё N кадров подряд с движением камеры
## (проверка мерцания), <out>/series_<agl>_NN.png; с --turn=<град/кадр> камера в серии не
## сдвигается, а поворачивается по рысканию каждый кадр (проверка шлейфа облаков при развороте),
## кадр серии — каждый 4-й.
## Для каждого ракурса печатает, сколько лучей (сетка 320×180) пересекают боксы облаков
## больше чем MAX_HITS раз — такие лучи теряли дальние облака до исправления.
## --bench=1 — ещё и среднее GPU-время кадра на каждом ракурсе (120 кадров).
## Пишет <out>/cloud_<agl>.png. Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 300.0
const OLD_MAX_HITS := 8

var _out := ""
var _location := "ongudai"
## Прогноз: температура днём, °C, и ветер у земли, км/ч (--wind — в м/с, как у игры).
var _temp_c := 31.0
var _wind_kmh := 18.0
var _hour := 13.0
var _agl: PackedFloat64Array = [300.0, 1500.0, 2500.0]
var _yaw := 0.0
var _pitch := -3.0
var _air_s := 600.0
var _series := 0
var _bench := false
var _turn := 0.0
var _main: Node = null
## Кадр рисуется в SubViewport постоянного размера: оконный менеджер может ужать окно
## (соседние окна), а кадры до/после должны совпадать. Корневое окно 3D не рисует.
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
			"agl":
				_agl = PackedFloat64Array()
				for x in kv[1].split(","):
					_agl.append(float(x))
			"yaw":
				_yaw = float(kv[1])
			"pitch":
				_pitch = float(kv[1])
			"air_s":
				_air_s = float(kv[1])
			"series":
				_series = int(kv[1])
			"bench":
				_bench = kv[1] == "1"
			"turn":
				_turn = float(kv[1])
	if _out == "":
		push_error("cloud_cut_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("cloud_cut_shot: FAIL (%s)" % why)
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
	# Мир за меню: Game.settings теперь появляется только в start() — просто дать меню подняться.
	for i in 60:
		await get_tree().process_frame
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
	# Атмосферу — вперёд до зрелых облаков, затем заморозить.
	var t := 0.0
	while t < _air_s:
		air.call("step", 0.5)
		t += 0.5
	var start: Dictionary = game.get_start()
	var sun: Vector3 = game.sky.clock.to_sun()
	var sun_yaw := rad_to_deg(atan2(sun.x, -sun.z))
	_vp = SubViewport.new()
	_vp.size = Vector2i(1920, 1080)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var cam := Camera3D.new()
	_vp.add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.make_current()
	# Облака (CloudLayer) вешают эффект на камеру корневого окна и выбирают облака у неё —
	# она ходит за камерой кадра и делит с ней Compositor.
	_root_cam = Camera3D.new()
	add_child(_root_cam)
	SkyEnvironment.setup_camera(_root_cam)
	_root_cam.make_current()
	get_viewport().disable_3d = true
	var dir := TerrainGeo.heading_vector(sun_yaw + _yaw)
	var look := dir * cos(deg_to_rad(_pitch)) + Vector3.UP * sin(deg_to_rad(_pitch))
	var layer := air.get_node_or_null("Clouds") as CloudLayer
	var h0 := (start.position as Vector3).y
	print("cloud_cut_shot: старт %.0f м MSL, солнце азимут %.0f°" % [h0, sun_yaw])
	for agl in _agl:
		var p: Vector3 = start.position + Vector3.UP * agl
		_place(cam, p, look)
		# Время атмосферы заморожено: облака, выбранные у новой камеры, не проявились бы
		# (fade_in_s) — выбрать заново сразу видимыми.
		if layer != null:
			layer.set("_instant", true)
			layer.set("_acc", 1.0e9)
		# Выбор облаков у камеры — раз в update_interval_s: дать ему пройти.
		for i in 90:
			await RenderingServer.frame_post_draw
			_place(cam, p, look)
		_report_hits(cam, layer, int(agl))
		await _shoot("%s/cloud_%d.png" % [_out, int(agl)])
		if _bench:
			await _measure(int(agl))
		if _turn != 0.0:
			for k in _series * 4:
				var a := deg_to_rad(_turn * (k + 1))
				_place(cam, p, look.rotated(Vector3.UP, a))
				await RenderingServer.frame_post_draw
				if k % 4 == 3:
					await _shoot("%s/turn_%d_%02d.png" % [_out, int(agl), k / 4], 0)
			continue
		for k in _series:
			var q := p + dir.cross(Vector3.UP) * 15.0 * (k + 1)
			_place(cam, q, look)
			await RenderingServer.frame_post_draw
			await _shoot("%s/series_%d_%02d.png" % [_out, int(agl), k], 1)
	print("cloud_cut_shot: OK")
	await _quit(0)


func _measure(agl: int) -> void:
	var vp := _vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for i in 10:
		await RenderingServer.frame_post_draw
	var sum := 0.0
	for i in 120:
		await RenderingServer.frame_post_draw
		sum += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	print("cloud_cut_shot: BENCH %d м AGL — GPU кадр %.3f мс" % [agl, sum / 120.0])


func _place(cam: Camera3D, p: Vector3, look: Vector3) -> void:
	cam.look_at_from_position(p, p + look * 1000.0)
	_root_cam.global_transform = cam.global_transform
	if _root_cam.compositor != null:
		cam.compositor = _root_cam.compositor


## Сколько лучей кадра пересекают больше OLD_MAX_HITS боксов облаков.
func _report_hits(cam: Camera3D, layer: CloudLayer, agl: int) -> void:
	if layer == null:
		return
	var recs := layer.records()
	var vp := Vector2(_vp.size)
	var over := 0
	var most := 0
	var total := 0
	for j in 180:
		for i in 320:
			var sp := Vector2((i + 0.5) / 320.0 * vp.x, (j + 0.5) / 180.0 * vp.y)
			var ro := cam.project_ray_origin(sp)
			var rd := cam.project_ray_normal(sp)
			var n := 0
			for g in recs:
				if _box_hit(g, ro, rd):
					n += 1
			most = maxi(most, n)
			if n > OLD_MAX_HITS:
				over += 1
			total += 1
	print(
		(
			"cloud_cut_shot: %d м AGL — облаков %d, лучей с > %d боксов: %d из %d (макс. %d)"
			% [agl, recs.size(), OLD_MAX_HITS, over, total, most]
		)
	)


static func _box_hit(g: PackedFloat32Array, ro: Vector3, rd: Vector3) -> bool:
	var ax := Vector3(g[4], 0.0, g[5])
	var az := Vector3(-g[5], 0.0, g[4])
	var dl := ro - Vector3(g[0], g[1], g[2])
	var lo := Vector3(dl.dot(ax), dl.y, dl.dot(az))
	var ld := Vector3(rd.dot(ax), rd.y, rd.dot(az))
	var he := Vector3(g[6], g[3], g[7])
	var tn := 0.0
	var tf := 1.0e30
	for k in 3:
		if absf(ld[k]) < 1e-9:
			if absf(lo[k]) > he[k]:
				return false
			continue
		var t0 := (-he[k] - lo[k]) / ld[k]
		var t1 := (he[k] - lo[k]) / ld[k]
		tn = maxf(tn, minf(t0, t1))
		tf = minf(tf, maxf(t0, t1))
	return tf > tn


func _shoot(path: String, frames: int = 12) -> void:
	for i in frames:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var err := img.save_png(path)
	print("cloud_cut_shot: %s (%s)" % [path, error_string(err)])
