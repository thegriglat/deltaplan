extends Node
## «Осмотр карты»: мир без полёта (крыло скрыто и стоит, камера свободная и заперта на режиме,
## выход возвращает всё) и сетка стрелок ветра вокруг активной камеры (в любом режиме).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


static func _flat(_x: float, _z: float) -> float:
	return 100.0


static func _mean(pts: Array[Vector3]) -> Vector3:
	var m := Vector3.ZERO
	for p in pts:
		m += p
	return m / maxf(pts.size(), 1)


func test_wind_grid_centered_on_camera() -> void:
	var pilot := Node3D.new()
	var cam := Node3D.new()
	add_child(pilot)
	add_child(cam)
	pilot.global_position = Vector3(0, 300, 0)
	cam.global_position = Vector3(5000, 300, -3000)
	var dbg := DebugOverlays.new()
	add_child(dbg)
	dbg.setup(Node.new(), pilot, _flat)
	dbg.camera = cam
	var pts := dbg._wind_grid()
	check(not pts.is_empty(), "сетка не пуста")
	var m := _mean(pts)
	check(absf(m.x - 5000.0) < 200.0 and absf(m.z + 3000.0) < 200.0, "центр у камеры %s" % m)
	cam.global_position = Vector3(-800, 300, 900)
	m = _mean(dbg._wind_grid())
	check(absf(m.x + 800.0) < 200.0 and absf(m.z - 900.0) < 200.0, "следует за камерой %s" % m)
	dbg.free()


func test_inspect_flow() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	if game.settings == null:
		main.queue_free()
		failures.append("мир не загрузился")
		return
	game.process_mode = Node.PROCESS_MODE_DISABLED
	(main.get("opts") as LaunchOptions).autostart = true
	await main.call("_fly", FlightSettings.defaults(), true)
	check(game.inspect_mode, "режим осмотра включён")
	check(main.get("state") == 2, "состояние FLYING (меню паузы работает как обычно)")
	check(game.camera.mode == "free", "камера свободная")
	check(not game.glider.visible, "крыла не видно")
	check(game.debug_overlays.wind_on, "стрелки ветра включены")
	check(game.debug_overlays.camera == game.camera, "стрелки — вокруг камеры")
	game.camera.next_mode()
	check(game.camera.mode == "free", "режим камеры заперт")
	var p0 := game.glider.get_telemetry().position
	var t0 := game.sim_time_s
	for i in 240:
		game.tick(DT)
	check(game.sim_time_s > t0, "воздух идёт")
	check(game.glider.get_telemetry().position.is_equal_approx(p0), "крыло стоит на месте")
	main.call("_show_menu")
	check(not game.inspect_mode and game.glider.visible, "после выхода крыло на месте")
	check(not game.debug_overlays.wind_on, "стрелки выключены")
	check(not game.camera.locked_free, "камеры снова переключаются")
	main.queue_free()
