extends Node
## RW-P5: игровой путь входа на место (Main._fly → Game.start) доводит воздух до READY с полем Пикара:
## условия Game._air_conditions принимает крейт (раньше без quantum_h — BAD_INPUT, молча: поле не
## считалось, этапа «Рассчитываем ветер» не было, ветер 0), стадия подготовки видна экрану загрузки,
## у старта ветер ≠ 0. Режим поля «on» — в headless «auto» поле не включает (как и раньше).
## godot --headless --path . res://tests/run_tests.tscn -- --filter=place_air_stage

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []
var _stage_seen := false
var _iters_seen := false
var _fly_done := false
var _failed := ""


func needs_gpu() -> bool:
	return false


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _skip() -> bool:
	return not ClassDB.class_exists("DpAir")


func _watch(air: Node) -> void:
	while not _fly_done:
		var st: Dictionary = air.call("status")
		if String(st.get("stage", "")) != "":
			_stage_seen = true
			_iters_seen = _iters_seen or int(st.get("iters", 0)) > 0
		if int(st.state) == Atmosphere.STATE_FAILED:
			_failed = String(st.reason)
		await get_tree().process_frame


## Игровой путь: условия приняты крейтом, поле считается — экран загрузки видит этап «Рассчитываем ветер».
## Ждём этап (а не READY: полный счёт Пикара — минуты), затем обрываем загрузку.
func test_game_path_shows_wind_stage() -> void:
	if _skip():
		return
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in 1200:
		if menu.visible:
			break
		await get_tree().process_frame
	check(menu.visible, "меню открыто")
	var game: Game = main.get_node("Game")
	var air: Node = game.air
	check(air is Atmosphere, "воздух — Atmosphere")
	air.call("set_air_mode", "on")
	(main.get("opts") as LaunchOptions).autostart = true
	_watch(air)
	main.call("_fly", FlightSettings.defaults())
	var t0 := Time.get_ticks_msec()
	while not _stage_seen and _failed == "" and Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
	_fly_done = true
	check(_failed == "", "воздух не FAILED: " + _failed)
	check(String(air.call("last_error")) == "", "нет ошибки воздуха: " + String(air.call("last_error")))
	check(_stage_seen, "этап подготовки ветра виден экрану загрузки")
	check(bool(game.terrain.progress.text != ""), "экран загрузки с текстом")
	main.queue_free()
	await get_tree().process_frame


## Малое не запечённое место 25 м (9,6 км, как в debug_layers), условия того же вида, что у игры: подготовка
## идёт этапами, потом READY, поле включено, ветер у земли ≠ 0; отказ условий на READY состояние не ломает.
func test_small_place_ready_with_wind() -> void:
	if _skip():
		return
	const N := 385
	const HALF := 4800.0
	var n := N * N
	var heights := PackedFloat32Array()
	heights.resize(n)
	for j in N:
		for i in N:
			var dx := (-HALF + 25.0 * i) - 1200.0
			var dz := (-HALF + 25.0 * j) + 1500.0
			var r2 := (dx * dx + dz * dz) / (1500.0 * 1500.0)
			heights[j * N + i] = 600.0 + (400.0 * exp(-r2) if r2 < 9.0 else 0.0)
	var water := PackedByteArray()
	water.resize(n)
	var cls := PackedByteArray()
	cls.resize(n)
	cls.fill(SurfaceLayer.GRASS)
	var moist := PackedFloat32Array()
	moist.resize(n)
	moist.fill(0.4)
	var loc := {
		"id": "place_air_stage", "center_lat": 51.5, "center_lon": 86.5,
		"utc_offset_h": 6.0, "month": 7, "day": 15,
	}
	var grid := {"origin_x": -HALF, "origin_z": -HALF, "spacing": 25.0, "width": N, "height": N}
	var place := AirPlaceData.from_arrays(AirPlaceData.make_header(loc, grid, []), heights, water, cls, moist)
	place.fill_climate()
	place.fill_crate_inputs()
	var a := Atmosphere.new()
	a.visuals_enabled = false
	var cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	cfg.air.domain_l_m = 7200.0
	cfg.air.tol_scale = 5.0
	cfg.air_model.edge_blend_cells = 1.0
	cfg.air_model.window_levels_m = []
	a.cfg_override = cfg
	add_child(a)
	a.configure(cfg)
	a.configure(7)
	a.set_air_mode("on")
	var cond := {
		"forecast": {"temperature_c": 26.0, "wind_speed_kmh": 14.4, "wind_from_deg": 270.0, "sky": "clear"},
		"start_hour": 13.0,
		"speed": 1.0,
		"quantum_h": AtmoDay.new().quantum_h,
		"inflow_mode": "start",
	}
	check(a.set_conditions(cond) == 0, "условия приняты")
	check(a.load_place(place) == 0, "load_place " + a.last_error())
	a.set_focuses(PackedVector3Array([Vector3(0.0, 900.0, 0.0)]), PackedFloat32Array([1.0]))
	a.start_at(0.0)
	var stage := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 120000:
		a.pump(8000)
		var st: Dictionary = a.status()
		stage = stage or String(st.stage) != ""
		if int(st.state) != Atmosphere.STATE_LOADING:
			break
		await get_tree().process_frame
	var st2: Dictionary = a.status()
	check(stage, "этап подготовки ветра был")
	check(int(st2.state) == Atmosphere.STATE_READY, "READY: %s (%s)" % [st2.state, st2.reason])
	check(bool(st2.field_on), "поле включено")
	var v: Vector3 = a.air_velocity_at(Vector3(0.0, 640.0, 0.0))
	check(v.length() > 0.1, "ветер ≠ 0: %s" % v)
	# отказ крейта на READY: BAD_INPUT, состояние и прежние условия остаются
	var bad := cond.duplicate(true)
	bad.erase("quantum_h")
	check(a.set_conditions(bad) != 0, "условия без quantum_h отвергнуты")
	check(int(a.status().state) == Atmosphere.STATE_READY, "READY сохранён после отказа условий")
	a.queue_free()
