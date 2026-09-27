extends Node
## Кадры для страницы itch.io (tools/shots/itch.sh): главная сцена с автостартом (аргументы игры
## — те же, что у main: --autostart --autopilot --bots= --hour= --location= ...), затем своя
## камера по сценарию --kind. Интерфейс скрыт. Запуск (окно нужно — настоящий рендер):
##   godot --path . --audio-driver Dummy --fullscreen --resolution 1920x1080 \
##     res://tools/shots/itch_shot.tscn -- --autostart --autopilot --bots=8 \
##     --kind=gaggle --times=150,220,300 --out=/tmp/itch --tag=hero
## Сценарии (--kind):
##   gaggle  — за ботом в группе, группа кружащих впереди (кадры в моменты --times, с симуляции)
##   launch  — боты стоят с крыльями на старте, палатки (взгляд со склона ниже старта назад)
##   run     — бот бежит / только что оторвался, вид со старта
##   high    — у кромки облаков: планер переносится на ~cloudbase−120 м, камера сзади снизу
##   glare   — кабина, взгляд на солнце (с каской --helmet=visor)
##   chase   — обычная камера сзади (camera.json), кадры в --times
## --big=<Ш>x<В> — дополнительно снять кадр того же вида в SubViewport этого размера (обложка).
## Пишет <out>/<tag>_<n>.png. Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 280.0

var _out := ""
var _tag := "shot"
var _kind := "chase"
var _times: PackedFloat64Array = [20.0]
var _scale := 4.0
var _big := Vector2i.ZERO
var _view := "under"  ## сценарий cloud: under | field | far
var _yaw := 0.0  ## поворот вида, ° (сценарии launch/run/high)
var _main: Node = null
var _game: Game = null
var _cam: Camera3D = null
var _n := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"--out":
				_out = v
			"--tag":
				_tag = v
			"--kind":
				_kind = v
			"--scale":
				_scale = float(v)
			"--view":
				_view = v
			"--yaw":
				_yaw = float(v)
			"--times":
				_times = PackedFloat64Array()
				for x in v.split(","):
					_times.append(float(x))
			"--big":
				var p := v.split("x")
				_big = Vector2i(int(p[0]), int(p[1]))
	if _out == "":
		push_error("itch_shot: нужен --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("itch_shot: FAIL (%s)" % why)
	Engine.time_scale = 1.0
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true, false, true).timeout
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
	_hide_ui()
	match _kind:
		"gaggle":
			await _run_gaggle()
		"launch":
			await _run_launch()
		"run":
			await _run_run()
		"high":
			await _run_high()
		"glare":
			await _run_glare()
		"cloud":
			await _run_cloud()
		_:
			await _run_chase()
	Engine.time_scale = 1.0
	print("itch_shot: OK %s" % _tag)
	await _quit(0)


func _hide_ui() -> void:
	for n in _main.get_node("UI").get_children():
		if n is CanvasItem:
			(n as CanvasItem).visible = false
	_game.overlay.visible = false


## Ждать время симуляции t (ускоренно).
func _wait_sim(t: float) -> void:
	Engine.time_scale = _scale
	var last := -100.0
	while _game.sim_time_s < t:
		await get_tree().physics_frame
		_keep_up()
		if _game.sim_time_s - last >= 20.0:
			last = _game.sim_time_s
			print("itch_shot: sim %.0f с, реальное %.0f с" % [last, Time.get_ticks_msec() / 1000.0])
	Engine.time_scale = 1.0


## Игрок не садится (посадка остановила бы симуляцию): низко над рельефом — поднять.
var keep_up := true


func _keep_up() -> void:
	if not keep_up or _game.glider.phase() != "flying":
		return
	var g := _game.glider.global_position
	var agl := g.y - _game.terrain.height_at(g.x, g.z)
	if agl < 120.0:
		_game.glider.reset_in_air(g + Vector3.UP * (350.0 - agl), _game.glider.get_telemetry().heading_deg)
		_game.camera.snap()
		var o: LaunchOptions = _main.get("opts")
		if o.look != Vector2.ZERO:  # snap() сбросил голову
			_game.camera.set_look(o.look.x, o.look.y)


func _own_cam() -> Camera3D:
	if _cam == null:
		_cam = Camera3D.new()
		add_child(_cam)
		SkyEnvironment.setup_camera(_cam)
		_cam.fov = 60.0
	_cam.current = true
	return _cam


func _bot_vis(i: int) -> Node3D:
	var vis: Array = _game.bots.get("_visuals")
	return vis[i] if i < vis.size() else null


func _flying() -> Array[int]:
	var out: Array[int] = []
	for i in _game.bots.agents.size():
		if _game.bots.agents[i].state == BotAgent.State.FLY:
			out.append(i)
	return out


# ---------------------------------------------------------------- сценарии


func _run_chase() -> void:
	for t in _times:
		await _wait_sim(t)
		await _shoot(null)


## Группа: бот B с наибольшим числом соседей в 300 м; камера сзади-сверху B, взгляд на группу.
func _run_gaggle() -> void:
	var cam := _own_cam()
	cam.fov = 55.0
	for t in _times:
		await _wait_sim(t)
		var fly := _flying()
		print("itch_shot: t=%.0f %s" % [_game.sim_time_s, _game.bots.state_counts()])
		if fly.size() < 2:
			continue
		var best := -1
		var best_n := -1
		for i in fly:
			var n := 0
			for j in fly:
				var d: float = _game.bots.agents[i].model.position.distance_to(
					_game.bots.agents[j].model.position
				)
				if j != i and d < 300.0:
					n += 1
			if n > best_n:
				best_n = n
				best = i
		var bp: Vector3 = _game.bots.agents[best].model.position
		var c := Vector3.ZERO
		var k := 0
		for j in fly:
			var p: Vector3 = _game.bots.agents[j].model.position
			if j != best and p.distance_to(bp) < 300.0:
				c += p
				k += 1
		c = c / k if k > 0 else bp + _game.bots.agents[best].model.velocity * 10.0
		var v := Vector3(c.x - bp.x, 0, c.z - bp.z)
		if v.length() < 20.0:
			v = _game.bots.agents[best].model.velocity
			v.y = 0.0
		v = v.normalized().rotated(Vector3.UP, deg_to_rad(_yaw))
		var vis := _bot_vis(best)
		print("itch_shot: группа %d рядом, до центра %.0f м, выс %.0f" % [best_n, bp.distance_to(c), bp.y])
		# два вида: близко за ботом (широкий) и дальше с длинным фокусом (группа «сжата»)
		for view in [[16.0, 4.0, 55.0], [60.0, 10.0, 30.0]]:
			cam.fov = view[2]
			var eye: Vector3 = bp - v * float(view[0]) + Vector3.UP * float(view[1])
			# взгляд к группе, но не вверх: рельеф внизу кадра, небо с облаками сверху
			var look := bp + v * 80.0
			look.y = bp.y - 5.0
			var off := eye - bp
			var cur := vis.global_position if vis != null else bp
			cam.look_at_from_position(cur + off, look + (cur - bp), Vector3.UP)
			await _shoot(cam)


## Старт: боты стоят на местах ожидания; камера ниже по склону, смотрит на старт и лагерь.
func _run_launch() -> void:
	await _wait_sim(_times[0])
	var cam := _own_cam()
	cam.fov = 55.0
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
	var w := Vector3.ZERO
	for a in _game.bots.agents:
		w += a.model.position
	w /= maxf(_game.bots.agents.size(), 1)
	var wo: WorldObjects = _game.world_link.objects as WorldObjects
	var camp := w
	if wo != null and not wo.camp.is_empty():
		camp = Vector3.ZERO
		for t in wo.camp:
			camp += t.position
		camp /= wo.camp.size()
	var focus := sp.lerp(w, 0.5).lerp(camp, 0.25)
	for yaw in [_yaw, _yaw + 40.0, _yaw - 40.0]:
		var d := fwd.rotated(Vector3.UP, deg_to_rad(yaw))
		var e := focus + d * 38.0
		e.y = maxf(e.y, _game.terrain.height_at(e.x, e.z)) + 6.0
		cam.look_at_from_position(e, focus + Vector3.UP * 1.0, Vector3.UP)
		await _shoot(cam)


## Разбег бота: ждать бота в RUN, снять со старта сбоку-сзади; затем после отрыва.
func _run_run() -> void:
	var cam := _own_cam()
	cam.fov = 50.0
	var start: Dictionary = _game.get_start()
	var sp: Vector3 = start.position
	var fwd := TerrainGeo.heading_vector(float(start.heading_deg))
	var right := fwd.cross(Vector3.UP).normalized()
	Engine.time_scale = _scale
	var who := -1
	while who < 0 and _game.sim_time_s < 400.0:
		await get_tree().physics_frame
		for i in _game.bots.agents.size():
			if _game.bots.agents[i].state == BotAgent.State.RUN:
				who = i
	Engine.time_scale = 1.0
	if who < 0:
		_fail("никто не побежал")
		return
	var a: BotAgent = _game.bots.agents[who]
	var side := right if _yaw >= 0.0 else -right
	var eye := sp - fwd * 12.0 + side * 9.0
	eye.y = _game.terrain.height_at(eye.x, eye.z) + 1.7
	var shots := 0
	var t_run := _game.sim_time_s
	for dt in _times:  # --times: с после начала разбега
		while _game.sim_time_s < t_run + dt:
			await get_tree().physics_frame
		var vis := _bot_vis(who)
		var p: Vector3 = vis.global_position if vis != null else a.model.position
		cam.look_at_from_position(eye, p + fwd * 6.0 + Vector3.UP * 1.0, Vector3.UP)
		print("itch_shot: бот %d %s, t=%.1f" % [who, a.state_name(), _game.sim_time_s - t_run])
		await _shoot(cam)
		shots += 1


## У кромки облаков: планер — на cloudbase − 120 м, камера сзади-сбоку чуть ниже, взгляд вверх.
func _run_high() -> void:
	await _wait_sim(2.0)
	var cb := float(_game.air.call("get_cloudbase_msl")) if _game.air.has_method("get_cloudbase_msl") else 2400.0
	var tel := _game.glider.get_telemetry()
	var g := _game.glider.global_position
	_game.glider.reset_in_air(Vector3(g.x, cb - 120.0, g.z), tel.heading_deg)
	_game.camera.snap()
	print("itch_shot: кромка %.0f м" % cb)
	var cam := _own_cam()
	cam.fov = 60.0
	for t in _times:
		await _wait_sim(2.0 + t)
		var tr := _game.glider.global_transform
		var f := -tr.basis.z
		f.y = 0.0
		f = f.normalized().rotated(Vector3.UP, deg_to_rad(_yaw))
		var r := f.cross(Vector3.UP).normalized()
		var p := tr.origin
		cam.look_at_from_position(p - f * 13.0 + r * 4.0 - Vector3.UP * 1.5, p + f * 30.0 + Vector3.UP * 9.0)
		print("itch_shot: высота %.0f м" % p.y)
		await _shoot(cam)


## Кабина, взгляд на солнце (glance_target — точка по направлению на солнце).
func _run_glare() -> void:
	var target := Node3D.new()
	_game.add_child(target)
	_game.camera.glance_target = target
	Input.action_press("look_instrument")
	for t in _times:
		Engine.time_scale = _scale
		while _game.sim_time_s < t:
			await get_tree().physics_frame
			var to_sun := _game.sky.sun.global_basis.z.normalized()
			var p := _game.camera.global_position
			target.global_position = p + to_sun.rotated(Vector3.UP, deg_to_rad(_yaw)) * 1000.0
		Engine.time_scale = 1.0
		await _shoot(null)


## Облака (--view): under — под растущим кучевым сбоку-снизу (тёмное плоское основание, светлый
## верх); field — поле облаков сверху-сбоку с тенями на земле; far — даль у горизонта (башни,
## наковальни на storm, линзы на wave). Кадры в --times (с симуляции), облако выбирается заново.
func _run_cloud() -> void:
	var cam := _own_cam()
	for t in _times:
		await _wait_sim(t)
		var cb := float(_game.air.call("get_cloudbase_msl"))
		var g := _game.glider.global_position
		var fwd := -_game.glider.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized().rotated(Vector3.UP, deg_to_rad(_yaw))
		var eye: Vector3
		var look: Vector3
		match _view:
			"under":
				# лучшее облако: большое, растущее, в 0.6–4 км
				var best := {}
				var score := -1.0
				for cl in BotPilots._visible_clouds(_game.air as Atmosphere):
					var cc: Variant = cl.center
					var c3 := Vector3(cc.x, cb, cc.y) if cc is Vector2 else Vector3(cc.x, cb, cc.z)
					var d := Vector2(c3.x - g.x, c3.z - g.z).length()
					if d < 500.0 or d > 5000.0:
						continue
					var sc := float(cl.radius) * (0.5 + float(cl.growth)) * (1.0 - float(cl.decay))
					if sc > score:
						score = sc
						best = cl
						best.c3 = c3
				if best.is_empty():
					print("itch_shot: облака рядом нет")
					continue
				var c: Vector3 = best.c3
				var r := float(best.radius)
				var dir := Vector3(g.x - c.x, 0, g.z - c.z).normalized().rotated(Vector3.UP, deg_to_rad(_yaw))
				eye = c + dir * maxf(r * 1.35, 400.0)
				eye.y = cb - 160.0
				look = c + Vector3.UP * r * 0.35
				cam.fov = 75.0
				print("itch_shot: облако r=%.0f рост %.2f, кромка %.0f" % [r, float(best.growth), cb])
			"field":
				eye = g + Vector3.UP * (cb + 700.0 - g.y)
				look = eye + fwd * 3000.0 + Vector3.DOWN * 1400.0
				cam.fov = 70.0
			_:
				eye = g
				look = eye + fwd * 3000.0 + Vector3.UP * 250.0
				cam.fov = 60.0
		eye.y = maxf(eye.y, _game.terrain.height_at(eye.x, eye.z) + 30.0)
		cam.look_at_from_position(eye, look, Vector3.UP)
		await _shoot(cam)


# ---------------------------------------------------------------- кадр


func _shoot(cam: Camera3D) -> void:
	# после прыжка камеры рельеф дальних тайлов догружается — подождать
	for i in 45:
		await RenderingServer.frame_post_draw
	var path := "%s/%s_%d.png" % [_out, _tag, _n]
	_n += 1
	var img := get_viewport().get_texture().get_image()
	print("itch_shot: %s (%s)" % [path, error_string(img.save_png(path))])
	if _big != Vector2i.ZERO:
		await _shoot_big(cam if cam != null else get_viewport().get_camera_3d(), path)


## Тот же вид в SubViewport большего размера (тот же мир).
func _shoot_big(src: Camera3D, path: String) -> void:
	var root := get_viewport()
	var sv := SubViewport.new()
	sv.size = _big
	sv.world_3d = root.world_3d
	sv.msaa_3d = root.msaa_3d
	sv.screen_space_aa = root.screen_space_aa
	sv.use_taa = root.use_taa
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var c := Camera3D.new()
	sv.add_child(c)
	SkyEnvironment.setup_camera(c)
	c.fov = src.fov
	c.near = src.near
	c.far = src.far
	c.global_transform = src.global_transform
	c.current = true
	for i in 12:
		await RenderingServer.frame_post_draw
	var img := sv.get_texture().get_image()
	var p := path.get_basename() + "_%dx%d.png" % [_big.x, _big.y]
	print("itch_shot: %s (%s)" % [p, error_string(img.save_png(p))])
	sv.queue_free()
