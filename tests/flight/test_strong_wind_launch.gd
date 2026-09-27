extends Node
## F01. Взлёт в сильный день (ветер в лоб старту): сочетания, срывавшиеся в матрице
## стабильности, с правильной техникой (Autopilot опускает нос в сильный ветер) взлетают
## на 5 сидах из 5. Сид — момент на часах атмосферы при старте (фаза порывов и термиков).
## Плюс детерминизм: одинаковый сид — одинаковый разбег; новый полёт — часы атмосферы с нуля.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const MAX_GROUND_S := 20.0
const COMBOS := [
	["altai", "wings/kingpost"],
	["aushkul", "wings/sport"],
	["ongudai", "wings/sport"],
]
## 2415 — момент, на котором altai × kingpost срывался в матрице (nose_high), 4110 — askarovo.
const SEEDS := [0.0, 600.0, 1500.0, 2415.0, 4110.0]
const Sim := preload("res://tests/flight/flight_sim.gd")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Физика без автопилота: сильный ветер в лоб (5 м/с, восходящий у склона 0,8 м/с) стихает
## на 4 м/с за секунду, пока пилот разгоняется. Поток поворачивается снизу, киль догоняет его
## с запаздыванием (tau_pitch) — угол атаки на 2–3° выше заданного. Нейтральный нос (0,3 —
## ~23°) почти на критическом (24°): крыло срывает, «нос высоко». Нос ниже — отрыв.
func test_strong_wind_lull_needs_lower_nose() -> void:
	var slope := func(_x: float, z: float) -> float: return 1000.0 + 0.3 * z
	for wing in ["kingpost", "sport"]:
		for pitch: float in [0.3, 0.0]:
			var clock := [0.0]
			var lull := func(_p: Vector3) -> Vector3:
				return Vector3(0.0, 0.8, clampf(5.0 - 4.0 * clock[0], 1.0, 5.0))
			var m := Sim.make(wing)
			m.reset_on_ground(Vector3.ZERO, 0.0)
			var inp := Sim.input(pitch, 0.0, true)
			var out := "none"
			for i in int(12.0 / DT):
				clock[0] += DT
				m.step(DT, inp, lull, slope)
				if m.mode == FlightModel.Mode.AIR:
					out = "air"
					break
				if m.mode == FlightModel.Mode.FAILED:
					out = m.takeoff_failure
					break
			var want := "nose_high" if pitch > 0.2 else "air"
			check(
				out == want,
				"%s, нос %.1f, затишье в сильный ветер: %s (ждали %s)" % [wing, pitch, out, want]
			)


func test_strong_day_launch_5_of_5() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 1200:
		if game.settings != null:
			break
		await get_tree().process_frame
	check(game.settings != null, "мир за меню загружен")
	if game.settings == null:
		main.queue_free()
		return
	game.autopilot = Autopilot.new()
	(main.get("opts") as LaunchOptions).autostart = true
	game.process_mode = Node.PROCESS_MODE_DISABLED
	for c in COMBOS:
		var s := FlightSettings.new()
		s.location_id = c[0]
		s.wing = c[1]
		s.weather = "weather/strong"
		s.wind_mode = "into_site"
		await main.call("_fly", s)
		var label := "%s × %s × strong" % [c[0], c[1]]
		check(
			float(game.air.get("time_s")) == 0.0, "%s: новый полёт — часы атмосферы с нуля" % label
		)
		var ok := 0
		for sd: float in SEEDS:
			await main.call("_fly", s)
			var r := _launch(game, sd)
			if r.result == "air":
				ok += 1
			else:
				failures.append("%s, сид %.0f: взлёт сорван (%s)" % [label, sd, r.result])
		check(ok == SEEDS.size(), "%s: взлёт %d/%d" % [label, ok, SEEDS.size()])
		# Детерминизм: новый полёт с тем же сидом — тот же разбег до шага.
		var runs := []
		for k in 2:
			await main.call("_fly", s)
			runs.append(_launch(game, SEEDS[3]))
		var a: Dictionary = runs[0]
		var b: Dictionary = runs[1]
		check(
			a.result == b.result and a.t == b.t and a.pos == b.pos,
			(
				"%s: одинаковый сид — одинаковый разбег (%s %.3f %s vs %s %.3f %s)"
				% [label, a.result, a.t, a.pos, b.result, b.t, b.pos]
			)
		)
	game.autopilot.release_all()
	main.queue_free()


## Разбег с того же старта при часах атмосферы sd: {result: "air"|причина|"none", t, pos}.
## Сразу после Game.start (новый полёт): атмосфера только что настроена, первый шаг обновит
## термики на момент sd.
func _launch(game: Game, sd: float) -> Dictionary:
	game.air.set("time_s", sd)
	var m: FlightModel = game.glider.model
	var t := 0.0
	var out := {"result": "none", "t": 0.0, "pos": Vector3.ZERO}
	while t < MAX_GROUND_S:
		game.tick(DT)
		t += DT
		if m.mode == FlightModel.Mode.AIR:
			out.result = "air"
			break
		if m.mode == FlightModel.Mode.FAILED:
			out.result = m.takeoff_failure
			break
	out.t = t
	out.pos = m.position
	game.autopilot.release_all()
	return out
