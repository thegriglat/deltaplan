extends TestCase
## CF-1: предел скорости бега — предел ног, а не пилота (docs/guide/flight.md → «Земля»). Под крутую
## горку в штиль склон и крыло разгоняют выше предела ног — крыло с высокой Vmin взлетает; на
## ровном предел ног держит.

const Sim := preload("res://tests/flight/flight_sim.gd")


static func slope_fn(k: float) -> Callable:
	return func(_x: float, z: float) -> float: return 1000.0 + k * z


## Разбег в штиль по склону с уклоном k (север вниз): {took_off, failure, v_max, run_m}.
static func run(w: String, k: float, pitch: float = 0.0) -> Dictionary:
	var m := Sim.make(w)
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var g: GroundRun = m.get("_ground")
	var inp := Sim.input(pitch, 0.0, true)
	var gf := slope_fn(k)
	var res := {"took_off": false, "failure": "", "v_max": 0.0, "run_m": 0.0}
	var t := 0.0
	while t < 15.0:
		m.step(Sim.DT, inp, Callable(), gf)
		t += Sim.DT
		if m.mode == FlightModel.Mode.GROUND:
			res.v_max = maxf(res.v_max, float(g.get("_speed")))
			res.run_m = Vector2(m.position.x, m.position.z).length()
		elif m.mode == FlightModel.Mode.AIR:
			res.took_off = true
			break
		else:
			res.failure = m.takeoff_failure
			break
	return res


func test_steep_calm_launch_beyond_leg_speed() -> void:
	var v_legs := float(Config.get_config("pilot").run.speed_max_ms)
	for w: String in ["sport", "combat", "training"]:
		var r := run(w, 0.3)
		check(r.took_off, "%s: штиль, склон 17° — взлёт (%s)" % [w, r])
	# «спорт» без потолка ног: склон разгоняет выше предела ног без разгрузки
	var s := run("sport", 0.3)
	check(s.v_max > v_legs, "склон 17°: скорость выше предела ног %.1f (%s)" % [v_legs, s])


func test_flat_calm_leg_limit_holds() -> void:
	var run_cfg: Dictionary = Config.get_config("pilot").run
	var cap := float(run_cfg.speed_max_ms) * (1.0 + float(run_cfg.unload_speed_bonus))
	var r := run("sport", 0.0)
	check(r.v_max <= cap + 0.05, "ровно, штиль: не быстрее предела ног %.2f (%s)" % [cap, r])
