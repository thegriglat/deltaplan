extends Node
## Режим «Маятник» в Game (PD-4, земля — PD-3): старт со склона — пилот стоит с крылом на руках,
## разбег под `run` → отрыв из сил → полёт под автопилотом (ПИД крена через положение пилота);
## Game передаёт settings.apparatus. Шаги физики — Game.tick() вручную.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const MAX_RUN_S := 25.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_pendulum_start_on_slope() -> void:
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
	for round_i in 2:
		var m: PendulumModel = game.glider.model
		var st := game.get_start()
		check(m.mode == FlightModel.Mode.GROUND, "старт на земле (режим %d)" % m.mode)
		check(game.glider.phase() == "standing", "стоит на старте (%s)" % game.glider.phase())
		var p := m.pilot_position
		var gh := game.terrain.height_at(p.x, p.z)
		approx(p.y - 1.0, gh, 0.15, "ступни на рельефе")
		var d := Vector2(p.x - float(st.position.x), p.z - float(st.position.z))
		check(d.length() < 3.0, "у точки старта (%.1f м)" % d.length())
		for i in 60:
			game.tick(DT)
		check(game.glider.phase() == "standing", "стоит 0,5 с")
		# разбег: run, пока не оторвался
		var t := 0.0
		Input.action_press("run")
		while t < MAX_RUN_S and m.mode == FlightModel.Mode.GROUND:
			game.tick(DT)
			t += DT
		Input.action_release("run")
		check(m.mode == FlightModel.Mode.AIR, "разбег → отрыв (режим %d, срыв «%s», %.1f с)" % [m.mode, m.takeoff_failure, t])
		var pl := m.pilot_position
		print("    раунд %d: отрыв за %.1f с бега, %.1f м от старта" % [
			round_i, t, Vector2(pl.x - float(st.position.x), pl.z - float(st.position.z)).length()])
		game.autopilot = Autopilot.new()
		var max_bank := 0.0
		var h0 := m.telemetry.altitude_agl
		for i in 120 * 10:
			game.tick(DT)
			max_bank = maxf(max_bank, absf(game.glider.get_telemetry().bank_deg))
		var tel := game.glider.get_telemetry()
		check(game.glider.phase() == "flying", "летит 10 с после отрыва (%s)" % game.glider.phase())
		check(max_bank < 30.0, "крен в пределах: %.1f°" % max_bank)
		check(tel.altitude_agl > h0, "отлетел от склона: %.1f м над рельефом" % tel.altitude_agl)
		game.autopilot.release_all()
		game.autopilot = null
		game.restart()
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


func approx(actual: float, expected: float, tol: float, msg: String = "") -> void:
	if absf(actual - expected) > tol:
		failures.append("%s: ожидалось %.4f ± %.4f, получено %.4f" % [msg, expected, tol, actual])
