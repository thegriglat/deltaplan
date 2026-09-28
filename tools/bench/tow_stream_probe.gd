extends Node
## Замер подгрузки мира на скорости буксира «догнать» (NET-42): выдержит ли подгрузка деревьев,
## кустов и камней полёт на v_max у земли без рывков кадра и «пустой» земли. Не игровой код.
## Запускает scenes/main.tscn (--autostart), после старта выключает физику игры и ведёт крыло
## настоящим CatchUpTow к синтетической цели в dist км у земли (цель на agl м над рельефом),
## камера «сзади». Каждый кадр пишет время кадра и отставание центра подгрузки
## (деревья-модели, кусты, камни) от камеры; в середине — скриншоты.
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --disable-vsync \
##     --resolution 1600x900 res://tools/bench/tow_stream_probe.tscn -- --location=ongudai \
##     --v_kmh=1000 --dist_km=8 --agl=60 [--out=<каталог скриншотов>] [--shots=6,12] [--dir_deg=]
##     [--off=rocks,shrubs]  — выключить слои (искать, кто мешает)
## Отставание: слой собирает новый центр (_pending_center), только применив прошлый, — значит,
## прошлый центр уже на экране; отставание = расстояние камеры до него. Рывки кадра сравнивать
## с прогоном на скорости крыла (--v_kmh=60 --dist_km=0.8): замер шумит, если GPU занят.
## Печатает:
##   TOW v=… км/ч: кадров N, средний X мс, макс Y мс, >50 мс: K (после разгона Z)
##   LAG <слой>: радиус R м, макс отставание A м, отставание > R/2: P % из N кадров
##   BUILD <слой>: сборок, средняя/макс длительность;  HITCH t=… — кадр > 50 мс
##   TREES_BUILD i: цена одной сборки деревьев вдоль пути без потока
##   SHOT <путь>

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 240.0

var _location := "ongudai"
var _v_kmh := 1000.0
var _dist_km := 8.0
var _agl := 60.0
var _out := ""
var _shots: Array[float] = [6.0, 12.0]
var _dir_deg := NAN
## Отключить слои подгрузки (через запятую: trees,shrubs,rocks) — искать, кто кому мешает.
var _off: PackedStringArray = []
var _main: Node
var _game: Game
var _tow: CatchUpTow
var _tgt_pos := Vector3.ZERO
var _tgt_vel := Vector3.ZERO
var _t := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--location="):
			_location = a.substr(11)
		elif a.begins_with("--v_kmh="):
			_v_kmh = float(a.substr(8))
		elif a.begins_with("--dist_km="):
			_dist_km = float(a.substr(10))
		elif a.begins_with("--agl="):
			_agl = float(a.substr(6))
		elif a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--off="):
			_off = a.substr(6).split(",")
		elif a.begins_with("--dir_deg="):
			_dir_deg = float(a.substr(10))
		elif a.begins_with("--shots="):
			_shots.clear()
			for s in a.substr(8).split(","):
				_shots.append(float(s))
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	var main: Node = MAIN_SCENE.instantiate()
	_main = main
	main.set("opts", LaunchOptions.parse(["--autostart", "--location=" + _location]))
	add_child(main)
	for i in 3600:
		if int(main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(main.get("state")) != 2:
		_fail("не дошли до FLYING")
		return
	_game = main.get_node("Game")
	# физика игры выключена (как у буксира); итог полёта не наступит
	_game.set_physics_process(false)
	_game.glider.set_physics_process(false)
	# дать миру вокруг старта догрузиться (как игрок, постоявший на старте)
	for i in 120:
		await get_tree().process_frame
	if get_tree().paused:
		print("tow_stream_probe: игра на паузе (состояние %s) — снимаю" % main.get("state"))
		get_tree().paused = false
		_game.set_paused(false)
		main.set("state", 2)
	_game.camera.set_mode("chase")

	var terrain: Terrain = _game.terrain
	var own: Vector3 = _game.glider.model.position
	var dir_rad := deg_to_rad(_dir_deg) if not is_nan(_dir_deg) else atan2(-own.x, own.z)
	if is_nan(_dir_deg) and Vector2(own.x, own.z).length() < 1000.0:
		dir_rad = 0.0
	var dir := Vector3(sin(dir_rad), 0.0, -cos(dir_rad))
	_tgt_pos = own + dir * _dist_km * 1000.0
	_tgt_pos.y = terrain.height_at(_tgt_pos.x, _tgt_pos.z) + _agl
	_tgt_vel = dir * 12.0
	var cfg: Dictionary = Config.value("net", "catch_up", {}).duplicate(true)
	cfg.v_max_kmh = _v_kmh
	_tow = CatchUpTow.new(cfg, terrain.height_at)
	_tow.start(own, Vector3.ZERO, _target, _game.glider.model.heading)
	var path_from := Vector2(own.x, own.z)
	await _fly()
	# собственная цена сборки деревьев вдоль пути (синхронно, без соседей по пулу потоков)
	var trees := terrain.trees as TerrainTreeModels
	if trees != null:
		var path_to := Vector2(_tow.last.position.x, _tow.last.position.z)
		for i in 5:
			var c := path_from.lerp(path_to, (i + 0.5) / 5.0)
			var t0 := Time.get_ticks_usec()
			trees.placer.build(c)
			print("TREES_BUILD %d: %.0f мс" % [i, (Time.get_ticks_usec() - t0) / 1000.0])
	await _quit(0)


func _target() -> Dictionary:
	return {"position": _tgt_pos, "velocity": _tgt_vel}


func _physics_process(dt: float) -> void:
	if _tow == null or not _tow.is_active():
		return
	_t += dt
	_tgt_pos += _tgt_vel * dt
	_tgt_pos.y = _game.terrain.height_at(_tgt_pos.x, _tgt_pos.z) + _agl
	var r := _tow.step(dt)
	var g := _game.glider
	g.model.position = r.position
	g.model.velocity = r.velocity
	g.model.heading = r.heading
	g.model.bank = r.bank
	g.model.telemetry.basis = r.basis
	g.set("_prev_xform", g.get("_cur_xform"))
	g.set("_cur_xform", Transform3D(r.basis, r.position))


func _fly() -> void:
	var terrain: Terrain = _game.terrain
	var layers := {
		"trees": [terrain.trees, float(Config.value("world", "trees.radius_m", 500.0))],
		"shrubs":
		[
			terrain.get_node_or_null("Shrubs"),
			float(Config.value("vegetation", "shrubs.radius_m", 650.0))
		],
		"rocks":
		[terrain.get_node_or_null("Rocks"), float(Config.value("world", "rocks.radius_m", 300.0))],
	}
	for k in _off:
		if layers.has(k) and layers[k][0] != null:
			(layers[k][0] as Node).set_process(false)
			layers.erase(k)
	var applied := {}
	var busy_since := {}
	var pend := {}
	var build_ms := {}
	var lag_max := {}
	var lag_bad := {}
	var lag_n := {}
	for k in layers:
		applied[k] = Vector2(INF, INF)
		busy_since[k] = -1
		pend[k] = Vector2(INF, INF)
		build_ms[k] = PackedFloat64Array()
		lag_max[k] = 0.0
		lag_bad[k] = 0
		lag_n[k] = 0
	var dts: PackedFloat64Array = []
	var dts_fast: PackedFloat64Array = []
	var shots := _shots.duplicate()
	var t_prev: int = Time.get_ticks_usec()
	var ramp := float(_tow.cfg.ramp_s)
	while _tow.is_active():
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		var dt_ms := (now - t_prev) / 1000.0
		t_prev = now
		dts.append(dt_ms)
		var fast: bool = _t > ramp and _tow.last.state == "cruising"
		if fast:
			dts_fast.append(dt_ms)
		var cam := _game.camera.get_viewport().get_camera_3d().global_position
		var c := Vector2(cam.x, cam.z)
		var agl := cam.y - terrain.height_at(cam.x, cam.z)
		var just_applied: PackedStringArray = []
		for k in layers:
			var node: Node = layers[k][0]
			if node == null:
				continue
			# сборка идёт в потоке; новый центр (_pending_center) ставится, только когда
			# прошлая сборка применена — значит, прошлый центр уже на экране
			var pc: Vector2 = node.get("_pending_center")
			if pc != pend[k]:
				if busy_since[k] >= 0:
					applied[k] = pend[k]
					build_ms[k].append((now - busy_since[k]) / 1000.0)
					just_applied.append(k)
				busy_since[k] = now
				pend[k] = pc
			elif int(node.get("_task")) < 0 and busy_since[k] >= 0:
				applied[k] = pc
				build_ms[k].append((now - busy_since[k]) / 1000.0)
				just_applied.append(k)
				busy_since[k] = -1
			if not node.visible or not fast:
				continue
			var lag: float = c.distance_to(applied[k])
			lag_max[k] = maxf(lag_max[k], lag)
			lag_n[k] += 1
			if lag > float(layers[k][1]) * 0.5:
				lag_bad[k] += 1
		if dt_ms > 50.0:
			print(
				(
					"HITCH t=%.1f %.0f мс, собрано в этом кадре: %s"
					% [_t, dt_ms, ",".join(just_applied)]
				)
			)
		if dts.size() % 60 == 0:
			print(
				(
					"… t=%.1f %s d=%.0f v=%.0f агл=%.0f кадр %.1f мс"
					% [_t, _tow.last.state, _tow.last.distance, _tow.last.speed * 3.6, agl, dt_ms]
				)
			)
		if not shots.is_empty() and _t >= shots[0] and _out != "":
			var s: float = shots.pop_front()
			var img := get_viewport().get_texture().get_image()
			DirAccess.make_dir_recursive_absolute(_out)
			var path := _out.path_join(
				"tow_%s_%dkmh_t%02d_agl%d.png" % [_location, int(_v_kmh), int(s), int(agl)]
			)
			img.save_png(path)
			t_prev = Time.get_ticks_usec()  # запись PNG — не рывок подгрузки
			print(
				(
					"SHOT %s (скорость %.0f км/ч, над землёй %.0f м)"
					% [path, _tow.last.speed * 3.6, agl]
				)
			)
	_report("всё", dts)
	_report("крейсер", dts_fast)
	for k in layers:
		if layers[k][0] == null:
			print("LAG %s: нет слоя" % k)
			continue
		var n: int = maxi(1, lag_n[k])
		var bm: PackedFloat64Array = build_ms[k]
		var bsum := 0.0
		var bmax := 0.0
		for b in bm:
			bsum += b
			bmax = maxf(bmax, b)
		print(
			(
				"BUILD %s: сборок %d, средняя %.0f мс, макс %.0f мс"
				% [k, bm.size(), bsum / maxi(1, bm.size()), bmax]
			)
		)
		print(
			(
				"LAG %s: радиус %.0f м, макс отставание %.0f м, отставание > R/2: %.1f %% из %d кадров"
				% [k, layers[k][1], lag_max[k], 100.0 * lag_bad[k] / n, lag_n[k]]
			)
		)
	print("TOW итог: %s за %.1f с" % [_tow.last.state, _t])


func _report(what: String, dts: PackedFloat64Array) -> void:
	if dts.is_empty():
		print("TOW %s: нет кадров" % what)
		return
	var sum := 0.0
	var mx := 0.0
	var over := 0
	for d in dts:
		sum += d
		mx = maxf(mx, d)
		if d > 50.0:
			over += 1
	print(
		(
			"TOW v=%.0f км/ч %s: кадров %d, средний %.1f мс, макс %.1f мс, >50 мс: %d"
			% [_v_kmh, what, dts.size(), sum / dts.size(), mx, over]
		)
	)


func _fail(why: String) -> void:
	print("tow_stream_probe: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1, true).timeout
	get_tree().quit(code)
