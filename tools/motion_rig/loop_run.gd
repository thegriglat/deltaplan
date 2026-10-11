extends Node
## Петля MR-2/MR-5/MR-6: MotionOutput шлёт UDP всегда, пока вывод включён: меню (neutral, MENU_S с), земля (GROUND_S с),
## полёт (secs с), пауза (hold, PAUSE_S с), снова меню (neutral). generic, затем srs; плавный вход выключен (ramp_s = 0).
## godot --headless --path . res://tools/motion_rig/loop_run.tscn -- <port_generic> <port_srs> [секунд на формат]

const Sim := preload("res://tests/flight/flight_sim.gd")
const GROUND_S := 1.5  ## сколько секунд стоять на земле перед полётом
const MENU_S := 1.0  ## меню до полёта и после него
const PAUSE_S := 1.0  ## пауза посреди полёта


static func flat(_x: float, _z: float) -> float:
	return 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port_generic := int(args[0])
	var port_srs := int(args[1])
	var seconds := float(args[2]) if args.size() > 2 else 3.0
	var inp := Sim.input()
	for fmt_port: Array in [["generic", port_generic], ["srs", port_srs]]:
		var out := MotionOutput.new()
		out.enabled = true
		out.host = "127.0.0.1"
		out.port = int(fmt_port[1])
		out.format = String(fmt_port[0])
		out.every_n = 2  # 120 Гц физики / 2 = 60 Гц
		out.rate_hz = 60
		out.ramp_s = 0.0
		out.place = "Loop"
		# 0) меню: сцены полёта нет — нейтраль
		_idle(out, MENU_S)
		# 1) на земле: поток идёт (флаг on_ground в generic)
		var m := Sim.make("sport")
		m.reset_on_ground(Vector3.ZERO, 0.0)
		out.attach()
		out.reset()
		_fly(m, out, GROUND_S, inp, flat)
		# 2) в воздухе: постановка крыла — разрыв, reset(); выйти на установившийся режим без вывода
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		Sim.run_for(m, 20.0, inp)
		out.reset()
		_fly(m, out, seconds, inp, Callable())
		# 3) пауза: живых шагов нет, сцена присоединена — hold; затем выход в меню — нейтраль
		_idle(out, PAUSE_S)
		out.detach()
		_idle(out, MENU_S)
		out.shutdown()
		print("loop_run %s: отправлено %d" % [fmt_port[0], out.packets_sent])
	get_tree().quit(0)


func _fly(m: FlightModel, out: MotionOutput, secs: float, inp: ControlInput, ground_fn: Callable) -> void:
	var steps := int(secs / Sim.DT)
	var t0 := Time.get_ticks_usec()
	for i in steps:
		m.step(Sim.DT, inp, Callable(), ground_fn)
		out.step(m.telemetry, Sim.DT)
		out.tick(Sim.DT)
		var due := t0 + int((i + 1) * Sim.DT * 1e6)  # темп реального времени
		var now := Time.get_ticks_usec()
		if due > now:
			OS.delay_usec(due - now)


## Секунды без живых шагов (меню / пауза): только тики, темп реального времени.
func _idle(out: MotionOutput, secs: float) -> void:
	var t0 := Time.get_ticks_usec()
	for i in int(secs / Sim.DT):
		out.tick(Sim.DT)
		var due := t0 + int((i + 1) * Sim.DT * 1e6)
		var now := Time.get_ticks_usec()
		if due > now:
			OS.delay_usec(due - now)
