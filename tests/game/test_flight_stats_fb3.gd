extends TestCase
## FB-3 / FB-К2: FlightStats — до начала перехода в лётное положение подскок и касание не
## заканчивают полёт («взлёт сорван» нет); после — прежние правила.


func _tick(st: FlightStats, pos: Vector3, on_ground: bool, dt: float) -> void:
	var t := Telemetry.new()
	t.phase = "standing" if on_ground else "flying"
	t.position = pos
	t.on_ground = on_ground
	t.altitude_msl = pos.y
	t.altitude_agl = pos.y - 1000.0 if pos.y > 1000.0 else 0.0
	st.update(t, dt)


## Подскок на 1 м без перехода в лётное положение, потом долго стоит — не конец, можно бежать снова.
func test_hop_before_flight_position_does_not_finish() -> void:
	var st := FlightStats.new()
	st.reset(Vector3(0, 1000, 0))
	st.flight_position_started = false
	var dt := 0.1
	for i in 3:
		_tick(st, Vector3(0, 1001.0, -float(i)), false, dt)
	for i in 40:
		_tick(st, Vector3(0, 1000.0, -3.0), true, dt)
	check(not st.is_finished(), "до перехода касание — не «взлёт сорван»")
	check(st.grounded_pending_s() == 0.0, "нет отсчёта посадки")
	check(not st.force_finish(), "нечего засчитывать")


## Тот же подскок после начала перехода — прежнее правило: не взвёлся, сел — взлёт сорван.
func test_hop_after_flight_position_is_takeoff_failed() -> void:
	var st := FlightStats.new()
	st.reset(Vector3(0, 1000, 0))
	st.flight_position_started = false
	var dt := 0.1
	for i in 3:
		_tick(st, Vector3(0, 1001.0, -float(i)), false, dt)
		st.flight_position_started = true
	for i in 20:
		_tick(st, Vector3(0, 1000.0, -3.0), true, dt)
	check(st.is_finished(), "после перехода долгое касание — конец")
	check(st.finish_reason() == "takeoff_failed", "не взвёлся — срыв взлёта")
