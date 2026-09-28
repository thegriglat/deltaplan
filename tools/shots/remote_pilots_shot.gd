extends Node
## Кадры чужих пилотов (RemotePilots, NET-41) на поддельных состояниях — без сети.
## Запуск (окно нужно — настоящий рендер; под timeout 150):
##   godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
##     res://tools/shots/remote_pilots_shot.tscn -- --autostart --bots=0 --out=/tmp/net41
##   … -- --autostart --bots=0 --perf --out=/tmp/net41   (замер: 0 и 10 чужих пилотов)
## Пишет <out>/{1_standing,2_running,3_circling,4_gaggle,5_landing,6_landed}.png.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 140.0
const NAMES := ["Оля", "Григорий", "Саша", "Марина", "Костя", "Лена", "Дима", "Ира", "Юра", "Вера"]

var _out := ""
var _perf := false
var _main: Node = null
var _game: Game
var _rp: RemotePilots
var _cam: Camera3D
## Поддельные пилоты: id -> Callable(t) -> {pos, rot, vel, phase}.
var _feeds: Dictionary = {}
var _t := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a == "--perf":
			_perf = true
	if _out == "":
		push_error("remote_pilots_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S * (3.0 if _perf else 1.0)).timeout.connect(
		_fail.bind("таймаут")
	)
	_run()


func _fail(why: String) -> void:
	print("remote_pilots_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)


## Поддельные состояния каждый кадр (как пакеты сети; позу продлевает сам RemotePilots).
func _process(dt: float) -> void:
	_t += dt
	if _rp == null:
		return
	for id: String in _feeds:
		var s: Dictionary = (_feeds[id] as Callable).call(_t)
		s.pilot_id = id
		_rp.upsert(s)


func _run() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	add_child(main)
	for i in 3000:
		if int(main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(main.get("state")) != 2:
		_fail("не долетели до FLYING (нужен --autostart)")
		return
	_game = main.get_node("Game")
	for n in main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	_game.glider.visible = false  # свой пилот не мешает на старте
	_rp = RemotePilots.new()
	_rp.name = "RemotePilots"
	_game.add_child(_rp)
	_rp.setup_in_world(_game.terrain)
	_cam = Camera3D.new()
	add_child(_cam)
	SkyEnvironment.setup_camera(_cam)
	_cam.fov = 55.0
	_cam.current = true
	if _perf:
		await _run_perf()
	else:
		await _run_shots()
	await _quit(0)


func _ground(p: Vector3) -> Vector3:
	return Vector3(p.x, _game.terrain.height_at(p.x, p.z), p.z)


static func pose(heading_deg: float, bank_deg: float = 0.0, pitch_deg: float = 0.0) -> Basis:
	return Basis.from_euler(
		Vector3(deg_to_rad(pitch_deg), -deg_to_rad(heading_deg), -deg_to_rad(bank_deg))
	)


func _add(id: String, nm: String, colors: Variant, wing: String, feed: Callable) -> void:
	_feeds[id] = func(t: float) -> Dictionary:
		var s: Dictionary = feed.call(t)
		s.name = nm
		s.colors = colors
		s.wing = wing
		s.is_bot = false
		return s


## Кружит в термике: центр c, радиус r, скорость v, со сдвигом фазы.
func _circler(c: Vector3, r: float, v: float, phase0: float, dir: float = 1.0) -> Callable:
	var w := v / r * dir
	var bank := rad_to_deg(atan(v * v / (r * 9.81))) * dir
	return func(t: float) -> Dictionary:
		var a := phase0 + w * t
		var p := c + Vector3(cos(a), 0.0, sin(a)) * r + Vector3.UP * 0.8 * t
		var vel := Vector3(-sin(a), 0.0, cos(a)) * v * dir + Vector3.UP * 0.8
		var hdg := rad_to_deg(atan2(vel.x, -vel.z))
		return {"pos": p, "rot": pose(hdg, bank, 4.0), "vel": vel, "phase": "flying"}


func _run_shots() -> void:
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var hdg := float(start.heading_deg)
	var fwd := TerrainGeo.heading_vector(hdg)
	var right := fwd.cross(Vector3.UP).normalized()
	var lc: Dictionary = Config.get_config("bots").get("launch", {})
	var r := float(lc.get("behind_max_m", 70.0)) + float(lc.get("lateral_max_m", 40.0))
	var spots := BotPilots.find_spots(
		_game.terrain.height_at,
		sp,
		hdg,
		3,
		lc,
		BotPilots.obstacles_near(_game.terrain, Vector2(sp.x, sp.z), r)
	)
	# 1. Стоят в очереди на старте (места ожидания, как у ботов).
	for i in spots.size():
		var s: Dictionary = spots[i]
		var st := {
			"pos": s.position,
			"rot": pose(float(s.heading_deg), 0.0, 8.0),
			"vel": Vector3.ZERO,
			"phase": "standing"
		}
		_add("q%d" % i, NAMES[i], i + 3, "", func(_t: float) -> Dictionary: return st.duplicate())
	# Кадр — на первых двух в очереди, со стороны старта.
	var qc: Vector3 = spots[0].position
	if spots.size() > 1:
		qc = (qc + spots[1].position) * 0.5
	var eye := _ground(qc + (sp - qc).normalized() * 16.0 + right * 5.0) + Vector3.UP * 1.8
	await _shot(eye, qc + Vector3.UP * 1.2, "1_standing")
	# 2. Разбег по склону: 5 м/с к старту и дальше.
	var t0 := _t
	_add(
		"run",
		"Оля",
		5,
		"atlas",
		func(t: float) -> Dictionary:
			var d := (t - t0) * 5.0 - 12.0
			return {
				"pos": _ground(sp + fwd * d),
				"rot": pose(hdg, 0.0, 12.0),
				"vel": fwd * 5.0,
				"phase": "running"
			}
	)
	await _wait(2.2)
	var rp: Vector3 = _rp.get_pilot("run").position
	await _shot(_ground(rp + right * 11.0) + Vector3.UP * 1.6, rp + Vector3.UP * 1.3, "2_running")
	_rp.remove("run")
	_feeds.erase("run")
	# 3. Кружит над склоном; 4. кучка в одном термике.
	var tc := sp + fwd * 250.0
	tc.y = maxf(sp.y, _game.terrain.height_at(tc.x, tc.z)) + 120.0
	_add("c0", "Оля", 5, "atlas", _circler(tc, 55.0, 12.0, 0.0))
	await _wait(9.0)
	var p0: Vector3 = _rp.get_pilot("c0").position
	var out := (Vector3(p0.x - tc.x, 0.0, p0.z - tc.z)).normalized()
	await _shot(p0 + out * 28.0 + Vector3.UP * 6.0, p0 + Vector3.UP * 1.5, "3_circling")
	for i in 4:
		_add(
			"g%d" % i,
			NAMES[i + 3],
			i * 2 + 1,
			["sport", "laminar", "target", "training"][i],
			_circler(tc + Vector3.UP * (i + 1) * 18.0, 55.0, 12.0, (i + 1) * TAU / 5.0)
		)
	await _wait(1.0)
	await _shot(tc + (sp - tc).normalized() * 180.0 + Vector3.UP * 30.0, tc, "4_gaggle")
	for id: String in _feeds.keys():
		_rp.remove(id)
	_feeds.clear()
	# 5. Заход на посадку и 6. сел — на самом ровном низком месте впереди.
	var lp := _landing_point(sp, fwd)
	var approach := 14.0
	t0 = _t
	_add(
		"land",
		"Оля",
		5,
		"atlas",
		func(t: float) -> Dictionary:
			var k := clampf((t - t0) / approach, 0.0, 1.0)
			var p := lp - fwd * (1.0 - k) * approach * 10.0
			if k >= 1.0:
				return {
					"pos": lp, "rot": pose(hdg, 0.0, 10.0), "vel": Vector3.ZERO, "phase": "landed"
				}
			p.y = _game.terrain.height_at(p.x, p.z) + lerpf(60.0, 1.5, k)
			return {
				"pos": p,
				"rot": pose(hdg, 0.0, 6.0 + 14.0 * k),
				"vel": fwd * 10.0 + Vector3.DOWN * 4.0,
				"phase": "flying"
			}
	)
	await _wait(approach - 1.0)
	var pl: Vector3 = _rp.get_pilot("land").position
	var cam_p := _ground(lp + right * 30.0 + fwd * 8.0) + Vector3.UP * 2.0
	await _shot(cam_p, pl + Vector3.UP * 1.0, "5_landing")
	await _wait(3.0)
	await _shot(
		_ground(lp + right * 12.0 + fwd * 6.0) + Vector3.UP * 4.0, lp + Vector3.UP, "6_landed"
	)
	print("remote_pilots_shot: OK")


## Низкое ровное место впереди старта (для посадки).
func _landing_point(sp: Vector3, fwd: Vector3) -> Vector3:
	var best := sp + fwd * 600.0
	var best_s := INF
	for d in range(500, 4000, 100):
		var p := sp + fwd * float(d)
		var h: float = _game.terrain.height_at(p.x, p.z)
		var slope := absf(_game.terrain.height_at(p.x + 5.0, p.z) - h)
		slope += absf(_game.terrain.height_at(p.x, p.z + 5.0) - h)
		var score := h + slope * 40.0 + _game.terrain.forest_at(p.x, p.z) * 500.0
		if score < best_s:
			best_s = score
			best = Vector3(p.x, h, p.z)
	return best


func _wait(seconds: float) -> void:
	var end := _t + seconds
	while _t < end:
		await get_tree().process_frame


func _shot(eye: Vector3, target: Vector3, file: String) -> void:
	_cam.look_at_from_position(eye, target)
	for i in 20:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_out, file]
	print("remote_pilots_shot: %s (%s)" % [path, error_string(img.save_png(path))])


## Замер: средний кадр без чужих пилотов и с 10 (кружат перед камерой, полная модель):
## время кадра, GPU и CPU отрисовки вьюпорта, _process всех узлов, вызовы отрисовки.
func _run_perf() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
	var tc := sp + fwd * 250.0
	tc.y = maxf(sp.y, _game.terrain.height_at(tc.x, tc.z)) + 100.0
	_cam.look_at_from_position(sp + Vector3.UP * 30.0 - fwd * 20.0, tc)
	await _wait(3.0)
	var sums := [{}, {}]
	for rnd in 3:
		for with_pilots in [false, true]:
			if with_pilots:
				for i in 10:
					var c := tc + Vector3.UP * i * 12.0
					_add("p%d" % i, NAMES[i], i, "", _circler(c, 60.0, 12.0, i * 0.63))
				for k in 5:
					var tq := Time.get_ticks_usec()
					await get_tree().process_frame
					print(
						"remote_pilots_shot: кадр %.1f мс" % ((Time.get_ticks_usec() - tq) / 1000.0)
					)
				await _wait(2.0)
			var m := await _measure(150)
			print("remote_pilots_shot: %d пилотов — %s" % [_rp.count(), str(m)])
			var acc: Dictionary = sums[1 if with_pilots else 0]
			for k: String in m:
				acc[k] = float(acc.get(k, 0.0)) + float(m[k]) / 3.0
			if with_pilots:
				for id: String in _feeds.keys():
					_rp.remove(id)
				_feeds.clear()
				await _wait(1.0)
	var a: Dictionary = sums[0]
	var b: Dictionary = sums[1]
	print(
		(
			"remote_pilots_shot: PERF 0 пилотов %s | 10 пилотов %s | падение FPS %.1f %%"
			% [str(a), str(b), (1.0 - a.frame_ms / b.frame_ms) * 100.0]
		)
	)


func _measure(frames: int) -> Dictionary:
	var vp := get_viewport().get_viewport_rid()
	await get_tree().process_frame
	var gpu := 0.0
	var cpu := 0.0
	var proc := 0.0
	var calls := 0.0
	var t0 := Time.get_ticks_usec()
	for i in frames:
		await get_tree().process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var n := float(frames)
	return {
		"frame_ms": snappedf((Time.get_ticks_usec() - t0) / 1000.0 / n, 0.01),
		"gpu_ms": snappedf(gpu / n, 0.01),
		"render_cpu_ms": snappedf(cpu / n, 0.01),
		"process_ms": snappedf(proc / n, 0.01),
		"draw_calls": roundf(calls / n),
	}
