extends Node
## Петля MR-2: headless FlightModel летит горизонтально, MotionOutput шлёт UDP (generic, затем srs).
## godot --headless --path . res://tools/motion_rig/loop_run.tscn -- <port_generic> <port_srs> [секунд на формат]

const Sim := preload("res://tests/flight/flight_sim.gd")


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port_generic := int(args[0])
	var port_srs := int(args[1])
	var seconds := float(args[2]) if args.size() > 2 else 3.0
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var inp := Sim.input()
	Sim.run_for(m, 20.0, inp)  # выйти на установившийся режим, без вывода
	for fmt_port: Array in [["generic", port_generic], ["srs", port_srs]]:
		var out := MotionOutput.new()
		out.enabled = true
		out.host = "127.0.0.1"
		out.port = int(fmt_port[1])
		out.format = String(fmt_port[0])
		out.every_n = 2  # 120 Гц физики / 2 = 60 Гц
		out.place = "Loop"
		out.reset()
		var steps := int(seconds / Sim.DT)
		var t0 := Time.get_ticks_usec()
		for i in steps:
			m.step(Sim.DT, inp, Callable(), Callable())
			out.step(m.telemetry, Sim.DT)
			var due := t0 + int((i + 1) * Sim.DT * 1e6)  # темп реального времени
			var now := Time.get_ticks_usec()
			if due > now:
				OS.delay_usec(due - now)
		print("loop_run %s: отправлено %d" % [fmt_port[0], out.packets_sent])
	get_tree().quit(0)
