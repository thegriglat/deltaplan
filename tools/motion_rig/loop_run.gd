extends Node
## Петля MR-2/MR-5: headless FlightModel стоит на земле (GROUND_S с), затем летит горизонтально; MotionOutput
## шлёт UDP и на земле, и в полёте (generic, затем srs).
## godot --headless --path . res://tools/motion_rig/loop_run.tscn -- <port_generic> <port_srs> [секунд на формат]

const Sim := preload("res://tests/flight/flight_sim.gd")
const GROUND_S := 1.5  ## сколько секунд стоять на земле перед полётом


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
		out.place = "Loop"
		# 1) на земле: поток идёт (флаг on_ground в generic)
		var m := Sim.make("sport")
		m.reset_on_ground(Vector3.ZERO, 0.0)
		out.reset()
		_fly(m, out, GROUND_S, inp, flat)
		# 2) в воздухе: постановка крыла — разрыв, reset(); выйти на установившийся режим без вывода
		m.reset_in_air(Vector3(0, 3000, 0), 0.0)
		Sim.run_for(m, 20.0, inp)
		out.reset()
		_fly(m, out, seconds, inp, Callable())
		print("loop_run %s: отправлено %d" % [fmt_port[0], out.packets_sent])
	get_tree().quit(0)


func _fly(m: FlightModel, out: MotionOutput, secs: float, inp: ControlInput, ground_fn: Callable) -> void:
	var steps := int(secs / Sim.DT)
	var t0 := Time.get_ticks_usec()
	for i in steps:
		m.step(Sim.DT, inp, Callable(), ground_fn)
		out.step(m.telemetry, Sim.DT)
		var due := t0 + int((i + 1) * Sim.DT * 1e6)  # темп реального времени
		var now := Time.get_ticks_usec()
		if due > now:
			OS.delay_usec(due - now)
