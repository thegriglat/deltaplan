extends Node
## Режим «Маятник» в Game (PD-4): старт всегда в воздухе — 100 м вперёд по курсу старта, 150 м над
## рельефом, на триме; Game передаёт settings.apparatus; автопилот держит курс ПИД через положение
## пилота. Шаги физики — Game.tick() вручную.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_pendulum_start_in_air() -> void:
	var cfg := Config.get_config("controls")
	var old: Variant = cfg.get("roll_control_mode")
	cfg["roll_control_mode"] = "pendulum"
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	var game: Game = main.get_node("Game")
	add_child(main)
	for i in 600:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	cfg["roll_control_mode"] = old
	check(main.get("state") == 2, "автостарт — в полёте")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(game.glider.model is PendulumModel, "модель — PendulumModel")
	check(game.settings.apparatus.has("hang_shift_cm"), "settings.apparatus есть")
	approx(
		float(game.glider.model.apparatus.hang_length_m),
		float(game.settings.apparatus.hang_length_m), 1e-9, "apparatus дошёл до модели"
	)
	game.autopilot = Autopilot.new()
	for round_i in 2:
		var tel := game.glider.get_telemetry()
		var st := game.get_start()
		var d := Vector2(tel.position.x - st.position.x, tel.position.z - st.position.z)
		var h := deg_to_rad(float(st.heading_deg))
		check(game.glider.phase() == "flying", "сразу в воздухе")
		approx(d.length(), 100.0, 1.0, "в 100 м от старта")
		check(d.normalized().dot(Vector2(sin(h), -cos(h))) > 0.999, "по курсу старта")
		approx(tel.altitude_agl, 150.0, 1.0, "150 м над рельефом")
		var hdg0 := tel.heading_deg
		var max_bank := 0.0
		for i in 120 * 20:
			game.tick(DT)
			max_bank = maxf(max_bank, absf(game.glider.get_telemetry().bank_deg))
		tel = game.glider.get_telemetry()
		check(game.glider.phase() == "flying", "летит 20 с под автопилотом")
		check(max_bank < 25.0, "крен в пределах: %.1f°" % max_bank)
		approx(wrapf(tel.heading_deg - hdg0, -180.0, 180.0), 0.0, 25.0, "курс держится")
		game.restart()
	game.autopilot.release_all()
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])
