extends Node
## Драйвер скриншотов карточки 12-02 (tools/shots/e2e.sh): та же цепочка, что в
## tests/game/test_e2e.gd (меню → «Полёт…» → «Готово» → «Лететь» → разбег → полёт → посадка), но с
## настоящим рендером (для кадров) вместо ручного Game.tick(). Запуск:
##   godot --path . --audio-driver Dummy --resolution 1920x1080 \
##     res://tools/shots/e2e_shot.tscn -- --location=altai --site=sinyukha_west --out=/tmp/e2e
## Пишет <out>/<location>_flight.png (кабина, взгляд вперёд) и <out>/<location>_result.png
## (экран итога). Код выхода 0/1.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const HOLD_COURSE_S := 60.0
const FLIGHT_SHOT_AFTER_S := 6.0  ## в воздухе столько с — кадр полёта (реальное время)
const FAST_FORWARD := 8.0  ## ускорение между кадром полёта и посадкой
const FALLBACK_LANDING_DIST_M := 3000.0
const TIMEOUT_S := 100.0

var _out := ""
var _location := ""
var _site := ""
var _main: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--location="):
			_location = a.substr(11)
		elif a.begins_with("--site="):
			_site = a.substr(7)
		elif a.begins_with("--out="):
			_out = a.substr(6)
	if _location == "" or _out == "":
		push_error("e2e_shot: нужны --location= и --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_fail.bind("таймаут"))
	_run()


func _fail(why: String) -> void:
	print("e2e_shot: FAIL (%s)" % why)
	await _quit(_main, 1)


## Убрать игровой мир перед выходом (как main.gd::_quit) — иначе аудиосервер оставляет
## висящие генераторы и движок ругается на утечки объектов при выходе.
func _quit(main: Node, code: int) -> void:
	if is_instance_valid(main):
		main.queue_free()
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
	game.autopilot = Autopilot.new()

	var start_menu: StartMenu = main.get_node("UI/StartMenu")
	var fss: FlightSetupScreen = main.get_node("UI/FlightSetupScreen")
	start_menu.setup_requested.emit()
	var site_idx := _pick_site(fss)
	if site_idx < 0:
		_fail("нет старта для локации %s" % _location)
		return
	fss.get("_site_opt").select(site_idx)
	# как щелчок пилота: выбор площадки снимает точку с карты (её мог помнить user://)
	fss.get("_site_opt").item_selected.emit(site_idx)
	(fss.get("_done_btn") as Button).emit_signal("pressed")  # «Готово»
	(start_menu.get("_fly_btn") as Button).emit_signal("pressed")  # «Лететь»

	for i in 1200:
		if int(main.get("state")) == 2:  # State.FLYING
			break
		await get_tree().process_frame
	if int(main.get("state")) != 2:
		_fail("не долетели до FLYING")
		return

	game.camera.set_mode("cockpit")
	var ended: Array = []
	game.flight_ended.connect(func(k: String, info: Dictionary) -> void: ended.append([k, info]))

	# --- кадр 1: в воздухе, кабина, взгляд вперёд ---
	var t_air := 0.0
	while t_air < FLIGHT_SHOT_AFTER_S and ended.is_empty():
		await get_tree().physics_frame
		if game.glider.phase() == "flying":
			t_air += get_physics_process_delta_time()
	if not ended.is_empty():
		_fail("сел раньше кадра полёта")
		return
	await _shoot("%s/%s_flight.png" % [_out, _location])

	# --- снижение и посадка у точки посадки (быстрее реального времени) ---
	Engine.time_scale = FAST_FORWARD
	var target := _landing_target(game)
	var repositioned := false
	while ended.is_empty():
		await get_tree().physics_frame
		if game.glider.phase() == "flying":
			# time_scale ускоряет частоту физ. кадров в реальном времени, не сам шаг dt.
			t_air += get_physics_process_delta_time()
			if t_air >= HOLD_COURSE_S and not repositioned:
				var tel := game.glider.get_telemetry()
				var y := game.terrain.height_at(target.x, target.y) + 5.0
				game.glider.reset_in_air(Vector3(target.x, y, target.y), tel.heading_deg)
				repositioned = true
	Engine.time_scale = 1.0

	# --- кадр 2: экран итога (main.gd показывает его сам после result_delay_s) ---
	var result_screen: Control = main.get_node("UI/ResultScreen")
	for i in 1200:
		if result_screen.visible:
			break
		await get_tree().process_frame
	if not result_screen.visible:
		_fail("ResultScreen не показан")
		return
	await _shoot("%s/%s_result.png" % [_out, _location])
	print("e2e_shot: OK %s" % _location)
	await _quit(main, 0)


func _pick_site(fss: FlightSetupScreen) -> int:
	var site_opt: OptionButton = fss.get("_site_opt")
	var sites: Array = fss.get("_sites")
	var first := -1
	for i in site_opt.item_count:
		var k: Variant = site_opt.get_item_metadata(i)
		if k == null:
			continue
		var e: Dictionary = sites[int(k)]
		if String(e.get("location", "")) != _location:
			continue
		if first < 0:
			first = i
		if _site != "" and String(e.get("site", "")) == _site:
			return i
	return first


func _landing_target(game: Game) -> Vector2:
	var sites := game.terrain.get_landing_sites()
	if not sites.is_empty():
		var p: Vector3 = sites[0].position
		return Vector2(p.x, p.z)
	var start: Dictionary = game.get_start()
	var sp: Vector3 = start.position
	var h := deg_to_rad(float(start.heading_deg))
	var dirv := Vector2(sin(h), -cos(h))
	return Vector2(sp.x, sp.z) + dirv * FALLBACK_LANDING_DIST_M


func _shoot(path: String) -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("e2e_shot: %s (%s)" % [path, error_string(err)])
