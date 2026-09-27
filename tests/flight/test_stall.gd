extends TestCase
## Сваливание (FR-6): на малой скорости нос опускается, высота теряется; в крене — на крыло.

const Sim := preload("res://tests/flight/flight_sim.gd")
const TP := preload("res://tests/flight/test_polar.gd")


func test_full_push_stalls_and_drops_nose() -> void:
	for w in TP.wings():
		var m := Sim.make(w)
		var trim: Vector2 = Sim.settle(m, 0.0, 20.0)
		var y0 := m.position.y
		var was_stalled := false
		var min_pitch := 90.0
		var pitch_at_stall := 0.0
		var t := 0.0
		while t < 10.0:
			m.step(Sim.DT, Sim.input(1.0), Callable(), Callable())
			t += Sim.DT
			if m.stalled and not was_stalled:
				was_stalled = true
				pitch_at_stall = m.telemetry.pitch_deg
			if was_stalled:
				min_pitch = minf(min_pitch, m.telemetry.pitch_deg)
		check(was_stalled, w + ": полное выжимание сваливает крыло")
		check(
			min_pitch < pitch_at_stall - 10.0,
			"%s: нос опускается (%.1f → %.1f°)" % [w, pitch_at_stall, min_pitch]
		)
		var sink := (y0 - m.position.y) / 10.0
		check(
			sink > trim.y * 1.5,
			"%s: при срыве теряется высота: %.2f м/с против %.2f на триме" % [w, sink, trim.y]
		)


func test_stall_speed_on_slow_push() -> void:
	for w in TP.wings():
		var m := Sim.make(w)
		Sim.settle(m, 0.0, 20.0)
		var t := 0.0
		var v_stall := -1.0
		while t < 60.0 and v_stall < 0.0:
			m.step(Sim.DT, Sim.input(minf(t / 40.0, 1.0)), Callable(), Callable())
			t += Sim.DT
			if m.stalled:
				v_stall = m.telemetry.airspeed
		approx(
			Units.to_kmh(v_stall),
			Units.to_kmh(m.stall_speed()),
			2.0,
			w + ": срыв на скорости сваливания, км/ч"
		)


func test_stall_in_bank_drops_wing() -> void:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	m.bank = deg_to_rad(30.0)
	Sim.run_for(m, 5.0, Sim.input())
	var max_bank := 0.0
	var t := 0.0
	while t < 6.0:
		m.step(Sim.DT, Sim.input(1.0), Callable(), Callable())
		max_bank = maxf(max_bank, m.telemetry.bank_deg)
		t += Sim.DT
	check(max_bank > 50.0, "сваливание на крыло: крен вырос до %.0f°" % max_bank)


func test_recovers_after_releasing_bar() -> void:
	var m := Sim.make("sport")
	Sim.settle(m, 0.0, 10.0)
	Sim.run_for(m, 4.0, Sim.input(1.0))
	Sim.run_for(m, 15.0, Sim.input(0.0))
	check(not m.stalled, "после отпускания трапеции крыло выходит из срыва")
	approx(m.telemetry.airspeed, m.trim_speed(), 0.5, "и возвращается на трим")
