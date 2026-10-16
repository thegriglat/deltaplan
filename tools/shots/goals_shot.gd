extends Node
## GL-6: кадры целей (этапы A и B). Место — Онгудай, старт Каянча, июль, 13:00, ясно. Игру не меняет.
## Нужно окно (не headless), профиль — своей копии:
##   XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") godot --path . --audio-driver Dummy \
##     --resolution 1920x1080 res://tools/shots/goals_shot.tscn -- --stage=<стадия> \
##     --out=<каталог> [--igc=tools/shots/goals_track.igc]
## Стадии: gen — синтетический IGC у старта Каянча (по рельефу места) в --igc;
##   a1 — окно «Полёт…», вкладка «Цели»; a — полёт: a2 список целей и прибор, a3 цилиндры;
##   a4 — итог после настоящего полёта автопилота (с земли до посадки);
##   d — окно «Полёт…», вкладка «Цели», диалог выбора файла трека (a5_file_dialog) и выбор --igc;
##   b — полоса следа прошлой попытки: b1 с высоты, b2 издалека, b3 вблизи.
## Кадры JPEG q88.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const TIMEOUT_S := 400.0
const SITE_ID := "kayancha_south"
const LOCATION_ID := "ongudai"

var _stage := ""
var _out := ""
var _igc := "res://tools/shots/goals_track.igc"
var _main: Node = null
var _game: Game = null


## Настройки кадров: место, погода и (по стадии) цели / след прошлой попытки.
class ShotOpts:
	extends LaunchOptions
	var goals: Array = []
	var last_track := false

	func apply_to(s: FlightSettings) -> FlightSettings:
		var r := super.apply_to(s)
		r.goals = goals.duplicate(true)
		r.show_last_track = last_track
		r.month = 7
		r.day = 15
		return r


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"stage":
				_stage = v
			"out":
				_out = v
			"igc":
				_igc = v
	if _stage == "" or _out == "":
		push_error("goals_shot: нужны --stage= и --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S, true, false, true).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("goals_shot: FAIL (%s)" % why)
	await _quit(1)


func _quit(code: int) -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	for i in 2:
		await get_tree().process_frame
	get_tree().quit(code)


func _snap(name: String) -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	var path := _out.path_join(name + ".jpg")
	var img := get_viewport().get_texture().get_image()
	print("goals_shot: %s (%s)" % [path, error_string(img.save_jpg(path, 0.88))])


func _base_opts() -> ShotOpts:
	var o := ShotOpts.new()
	o.autostart = true
	o.bots = 0
	o.seed = 4711
	o.overrides = {
		"location": LOCATION_ID, "site": SITE_ID, "wind": "3", "from": "launch", "sky": "clear", "hour": "13"
	}
	return o


## Настройки с целями «средней» трудности по погоде места (GoalEstimator, без выдуманных чисел).
func _goal_specs(base: LaunchOptions) -> Array:
	var s := base.apply_to(FlightSettings.defaults())
	var wx := GoalEstimator.weather_for(s)
	var tri_m := GoalEstimator.suggest("triangle", "medium", wx)
	var specs: Array = []
	for kind in ["height", "distance", "triangle", "speed", "landing"]:
		var level := "easy" if kind in ["distance", "landing"] else "medium"
		var v := GoalEstimator.suggest(kind, level, wx, tri_m * 1.0)
		specs.append(GoalSpec.make(kind, level, v))
	print("goals_shot: wx=%s цели=%s" % [wx, specs])
	return specs


func _boot(o: LaunchOptions) -> bool:
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", o)
	add_child(_main)
	for i in 6000:
		if int(_main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(_main.get("state")) != 2:
		await _fail("не долетели до FLYING")
		return false
	_game = _main.get_node("Game")
	for i in 30:
		await get_tree().process_frame
	return true


func _run() -> void:
	match _stage:
		"gen":
			await _stage_gen()
		"a1":
			await _stage_a1()
		"a":
			await _stage_a()
		"a4":
			await _stage_a4()
		"b":
			await _stage_b()
		"d":
			await _stage_d()
		_:
			await _fail("неизвестная стадия " + _stage)
			return
	print("goals_shot: OK %s" % _stage)
	await _quit(0)


# ------------------------------------------------------------------ gen: синтетический трек


## Трек: старт, спираль в термике А (+2…+3,5 м/с), переход (−1…−2,5), термик B, переход, термик C,
## конечное скольжение. 1 Гц, ~25 мин. Высота не ниже рельефа + 80 м (рельеф под полётом выше —
## точки подтянуты вверх; это иллюстрация, не запись полёта).
func _stage_gen() -> void:
	var o := _base_opts()
	if not await _boot(o):
		return
	var terr := _game.terrain
	var start: Vector3 = _game.get_start().position
	var h0 := terr.height_at(start.x, start.z)
	var tr_ := FlightTrack.new()
	var p := Vector2(start.x, start.z)
	var alt := h0 + 15.0
	var t := 0.0
	var speed := 10.5  # м/с по земле, трим ~38 км/ч
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	var legs := [
		# [курс перехода, длина м, снижение м/с, радиус спирали м, набор м/с, высота набора м]
		[151.0, 350.0, 1.2, 70.0, 3.0, 650.0],
		[110.0, 1800.0, 1.6, 75.0, 2.4, 550.0],
		[95.0, 1500.0, 2.2, 65.0, 3.4, 600.0],
		[130.0, 2600.0, 1.4, 0.0, 0.0, 0.0],
	]
	var add := func(pt: Vector2, a: float, tt: float) -> void:
		var g := terr.height_at(pt.x, pt.y) + 80.0
		var ll: Vector2 = terr.local_to_latlon(pt.x, pt.y)
		tr_.append(ll.x, ll.y, maxf(a, g), tt)
	add.call(p, alt, t)
	for leg: Array in legs:
		var hdg := deg_to_rad(float(leg[0]))
		var dirv := Vector2(sin(hdg), -cos(hdg))
		var n := int(float(leg[1]) / speed)
		for i in n:
			t += 1.0
			p += dirv * speed
			alt -= float(leg[2]) + rng.randf_range(-0.4, 0.5)
			add.call(p, alt, t)
		var r := float(leg[3])
		if r > 0.0:
			var center := p + Vector2(-dirv.y, dirv.x) * r  # левая спираль
			var ang := atan2(p.y - center.y, p.x - center.x)
			var target_alt := alt + float(leg[5])
			var w := speed / r
			while alt < target_alt:
				t += 1.0
				ang -= w
				p = center + Vector2(cos(ang), sin(ang)) * r
				alt += maxf(float(leg[4]) + rng.randf_range(-0.7, 0.7), 0.3)
				add.call(p, alt, t)
	print("goals_shot: gen точек %d, %.1f мин, высота %.0f…%.0f" % [tr_.size(), t / 60.0, Array(tr_.alt_m).min(), Array(tr_.alt_m).max()])
	tr_.name = LOCATION_ID
	var err := TrackIO.write_igc(tr_, ProjectSettings.globalize_path(_igc), {"year": 2026, "month": 7, "day": 15, "start_s": 12 * 3600 + 20 * 60, "name": "Kayancha synthetic"})
	print("goals_shot: IGC %s (%s)" % [_igc, error_string(err)])


# ------------------------------------------------------------------ a1: окно «Цели»


func _stage_a1() -> void:
	var o := _base_opts()
	o.goals = _goal_specs(o)
	o.last_track = true
	o.autostart = false  # меню: настройки ниже
	o.screenshot = ""
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", o)
	add_child(_main)
	for i in 30:
		await get_tree().process_frame
	var s: FlightSettings = o.apply_to(FlightSettings.defaults())
	_main.set("flight", s)
	_main.call("_open_flight_setup")
	var screen: FlightSetupScreen = _main.get_node("UI/FlightSetupScreen")
	var tabs: TabContainer = screen.get("_tabs")
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == TranslationServer.translate("setup_tab_goals"):
			tabs.current_tab = i
	for i in 30:
		await get_tree().process_frame
	await _snap("a1_goals_tab")


# ------------------------------------------------------------------ a: полёт и итог


func _a_teleport(pos: Vector3, heading: float, agl: float) -> void:
	pos.y = _game.terrain.height_at(pos.x, pos.z) + agl
	_game.glider.reset_in_air(pos, heading)


func _tick(seconds: float) -> void:
	for i in int(seconds * 120.0):
		_game.tick(1.0 / 120.0)


func _cylinders(on: bool) -> void:
	UserSettings.save_patch("goals/world", {"cylinders": {"enabled": on}})
	Config.reload()


func _hide_hint() -> void:
	var h := _game.get_node_or_null("FKeyHint")
	if h != null:
		h.visible = false


func _stage_a() -> void:
	_cylinders(false)
	var o := _base_opts()
	o.goals = _goal_specs(o)
	if not await _boot(o):
		return
	var g := _game
	if g.goals == null:
		await _fail("цели не созданы")
		return
	_hide_hint()
	var start: Vector3 = g.get_start().position
	var hdg := float(g.get("_start_heading"))
	var pts := g.goals.world_points()
	print("goals_shot: start %s heading %.0f, точки %s" % [start, hdg, pts])
	# Набор высоты: над стартом на значение цели + запас, 12 с держим (hold_s 10).
	var hspec: Dictionary = o.goals[0]
	g.glider.reset_in_air(start + Vector3(0, float(hspec.value) + 60.0, 0), hdg)
	_tick(12.0)
	# Первый пункт пройден (над ним), потом — на полпути ко второму, курс мимо него (стрелка на приборе).
	var p1: Vector3 = pts[0].position
	var p2: Vector3 = pts[1].position
	_a_teleport(p1, hdg, 450.0)
	_tick(4.0)
	var leg := Vector3(p2.x - p1.x, 0, p2.z - p1.z)
	var bearing := rad_to_deg(atan2(leg.x, -leg.z))
	_a_teleport(p1 + leg.normalized() * 900.0, bearing + 55.0, 450.0)
	_tick(6.0)
	print("goals_shot: после пункта %s" % [g.goals.items()])
	g.instrument.set_page(2)
	g.camera.set_mode("cockpit")
	g.set_paused(false)
	_tick(1.0)
	for i in 20:
		await get_tree().process_frame
	await _snap("a2_flight_list")
	_cylinders(true)
	g.call("_goals_sync_cylinders")
	# Все три пункта впереди: сзади-снизу от середины стороны ТР1–ТР2, лицом к гоулу.
	var goal: Vector3 = pts[2].position
	var mid := (p1 + p2) * 0.5
	var away := Vector3(mid.x - goal.x, 0, mid.z - goal.z).normalized()
	var face := rad_to_deg(atan2(-away.x, away.z))
	_a_teleport(mid + away * 3600.0, face, 1100.0)
	_tick(2.0)
	for i in 20:
		await get_tree().process_frame
	await _snap("a3_cylinders")


## Итог: настоящий полёт автопилота с земли до посадки (цели — «своя» трудность, чтобы часть сошлась).
func _stage_a4() -> void:
	_cylinders(false)
	DirAccess.remove_absolute("user://records.json")
	var o := _base_opts()
	o.autopilot = true
	o.goals = [
		GoalSpec.make("height", "custom", 150.0),
		GoalSpec.make("duration", "custom", 120.0),
		GoalSpec.make("distance", "custom", 3000.0),
		GoalSpec.make("triangle", "medium", 11000.0),
		GoalSpec.make("landing", "easy", 50.0),
	]
	if not await _boot(o):
		return
	var g := _game
	_hide_hint()
	var ended := [false]
	g.flight_ended.connect(func(_k: String, _i: Dictionary) -> void: ended[0] = true)
	var left := 1200.0
	while not ended[0] and left > 0.0:
		_tick(0.5)
		left -= 0.5
		if int(left * 2.0) % 40 == 0:
			await get_tree().process_frame
	print("goals_shot: итог %s, сим. время %.0f с, цели %s" % [ended[0], g.sim_time_s, g.goals.items()])
	for i in 600:
		if int(_main.get("state")) == 4:  # RESULT (задержка result_delay_s)
			break
		await get_tree().process_frame
	await _snap("a4_result")


# ------------------------------------------------------------------ b: полоса следа


func _stage_b() -> void:
	var igc := ProjectSettings.globalize_path(_igc)
	var o := _base_opts()
	o.last_track = true
	var key := LastTrackStore.place_key(o.apply_to(FlightSettings.defaults()))
	var ft := TrackIO.read_igc(igc)
	if ft == null:
		await _fail("нет IGC " + igc)
		return
	ft.name = key
	print("goals_shot: след в профиль: %s" % error_string(LastTrackStore.save(key, ft)))
	if not await _boot(o):
		return
	var g := _game
	if g.goal_tracks.is_empty():
		await _fail("след прошлой попытки не загружен")
		return
	g.overlay.visible = false
	for n in g.get_children():
		if n is CanvasLayer:
			n.visible = false
	_main.get_node("UI").visible = false
	var tr_: FlightTrack = g.goal_tracks[0]
	# Первая спираль набора: середина (набрано 300 м от старта) ± 2 витка (≈ 42 с на виток).
	var im := 0
	while im < tr_.size() and tr_.alt_m[im] < tr_.alt_m[0] + 300.0:
		im += 1
	if im >= tr_.size():
		await _fail("нет спирали в треке")
		return
	var i0 := maxi(im - 42, 0)
	var i1 := mini(im + 42, tr_.size() - 1)
	var c := Vector3.ZERO
	for i in range(i0, i1 + 1):
		var q: Vector2 = g.terrain.latlon_to_local(tr_.lat[i], tr_.lon[i])
		c += Vector3(q.x, tr_.alt_m[i], q.y)
	c /= float(i1 - i0 + 1)
	print("goals_shot: спираль %d..%d, центр %s, w=%.2f, t=%.0f" % [i0, i1, c, tr_.vertical_speed_ms(im, 5.0), tr_.t_s[im]])
	# Конец набора А (первое снижение) — для кадра с высоты: спирали позади, переход впереди.
	var it := im
	while it < tr_.size() - 1 and tr_.vertical_speed_ms(it, 5.0) > -0.5:
		it += 1
	var pa := _track_point(tr_, it)
	var pb := _track_point(tr_, mini(it + 100, tr_.size() - 1))
	var back := Vector3(pa.x - pb.x, 0, pa.z - pb.z).normalized()
	var cam := Camera3D.new()
	add_child(cam)
	SkyEnvironment.setup_camera(cam)
	cam.current = true
	cam.fov = 70.0
	var views := {
		"b1_track_high": [pa + back * 420.0 + Vector3(0, 200, 0), pa + (pb - pa) * 0.4 - Vector3(0, 150, 0)],
		"b2_track_far": [c + Vector3(-3200, 450, -2600), c],
		"b3_track_close": [c + Vector3(55, 0, 20), c + Vector3(0, 30, 0)],
	}
	for name: String in views:
		var v: Array = views[name]
		var eye: Vector3 = v[0]
		eye.y = maxf(eye.y, g.terrain.height_at(eye.x, eye.z) + 40.0)
		cam.look_at_from_position(eye, v[1], Vector3.UP)
		print("goals_shot: %s eye %s" % [name, eye])
		for i in 20:
			await get_tree().process_frame
		await _snap(name)


func _track_point(tr_: FlightTrack, i: int) -> Vector3:
	var q: Vector2 = _game.terrain.latlon_to_local(tr_.lat[i], tr_.lon[i])
	return Vector3(q.x, tr_.alt_m[i], q.y)


# ------------------------------------------------------------------ d: диалог выбора файла трека


func _stage_d() -> void:
	var o := _base_opts()
	o.autostart = false
	_main = MAIN_SCENE.instantiate()
	_main.set("opts", o)
	add_child(_main)
	for i in 30:
		await get_tree().process_frame
	_main.set("flight", o.apply_to(FlightSettings.defaults()))
	_main.call("_open_flight_setup")
	var screen: FlightSetupScreen = _main.get_node("UI/FlightSetupScreen")
	var tabs: TabContainer = screen.get("_tabs")
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == TranslationServer.translate("setup_tab_goals"):
			tabs.current_tab = i
	for i in 30:
		await get_tree().process_frame
	var tab := _find_goals_tab(screen)
	if tab == null:
		await _fail("нет GoalsTab")
		return
	tab.call("_on_load_pressed")
	var dlg: FileDialog = tab.get("_dialog")
	print("goals_shot: диалог native=%s visible=%s" % [dlg.use_native_dialog, dlg.visible])
	dlg.current_dir = ProjectSettings.globalize_path(_igc).get_base_dir()
	for i in 30:
		await get_tree().process_frame
	await _snap("a5_file_dialog")
	dlg.files_selected.emit(PackedStringArray([ProjectSettings.globalize_path(_igc)]))
	for i in 10:
		await get_tree().process_frame
	var paths: PackedStringArray = tab.get("_track_paths")
	print("goals_shot: после выбора пути %s" % [paths])
	if paths.is_empty():
		await _fail("трек не попал в список")
		return
	dlg.hide()
	await _snap("a6_track_added")


func _find_goals_tab(n: Node) -> Node:
	if n is GoalsTab:
		return n
	for ch in n.get_children():
		var r := _find_goals_tab(ch)
		if r != null:
			return r
	return null
