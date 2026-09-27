extends Node
## Нода FlightAudio: загружает все файлы из конфига, события не падают.
## Тест — Node (раннер добавляет его в дерево), FlightAudio вешается к себе.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_events_do_not_crash() -> void:
	var fa := FlightAudio.new()
	add_child(fa)
	check(fa._loops.size() == 13, "все 13 лупов загружены (%d)" % fa._loops.size())
	for list_name in ["snaps", "creaks", "steps_grass", "steps_gravel", "landing_crash"]:
		check(not fa._lists[list_name].is_empty(), "список %s загружен" % list_name)
	var t := Telemetry.new()
	t.airspeed = 15.0
	t.altitude_agl = 5.0
	t.on_ground = false
	for phase in ["standing", "walking", "running", "flying", "landed"]:
		fa.update(t, {"phase": phase, "stall_amount": 0.5, "turbulence": 0.5, "sideslip_deg": 5.0})
		fa._process(0.1)
	fa.play_landing({"grade": "soft", "vertical_speed_ms": 1.0})
	fa.play_landing({"grade": "hard", "vertical_speed_ms": 3.0})
	fa.play_landing({"grade": "crash", "vertical_speed_ms": 7.0})
	fa.play_landing({})
	fa.play_step()
	fa.play_step("gravel")
	fa.play_carabiner()
	check(fa.get_loop_db("rush") > -80.0, "поток звучит на 54 км/ч")
	check(AudioServer.get_bus_index("Wind") >= 0, "шина Wind есть")
	fa.free()
