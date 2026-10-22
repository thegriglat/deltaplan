extends TestCase
## TT-8: тангаж крыла trike_ixess15 в «Маятнике» с тележкой TT-К1 (configs/tow_tug.json cart):
## trim_pitch(), установившиеся θ и скорость без ввода и на упорах pitch = ±1 (ход shift_x_push/pull).
## Запуск: cp tools/research/tow-trike/measure_trim.gd tests/game/test_tt8_trim.gd;
##   godot --headless --path . res://tests/run_tests.tscn -- --filter=test_tt8_trim | grep TT8 ; rm tests/game/test_tt8_trim.gd*
const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")


func _theta(m: PendulumModel) -> float:
	return asin(clampf((-m.wing_basis().z).normalized().y, -1.0, 1.0))


func _run(pitch: float) -> Dictionary:
	var tug: Dictionary = Config.get_config("tow_tug")
	var cart: Dictionary = tug.cart
	var app := {"hang_length_m": cart.cg_below_hang_m, "pilot_cda_m2": cart.cda_m2,
		"arms_force_max_n": cart.arms_force_max_n}
	var m := S.make("trike_ixess15", float(cart.mass_kg), app)
	S.reset(m)
	var inp := S.input(pitch)
	var th := 0.0
	var v := 0.0
	var ph := 0.0
	var k := 0
	var sink := 0.0
	for i in int(round(60.0 / S.DT)):
		m.step(S.DT, inp, Callable(), Callable())
		if m.time_s > 40.0:
			th += _theta(m)
			v += S.airspeed(m)
			ph += m.arms.phi
			sink += m.velocity.y
			k += 1
	return {"trim_pitch_deg": rad_to_deg(m.trim_pitch()), "theta_deg": rad_to_deg(th / k),
		"airspeed_ms": v / k, "vy": sink / k, "neutral_rel": [m.arms.neutral_rel.x, m.arms.neutral_rel.y, m.arms.neutral_rel.z], "phi_deg": rad_to_deg(ph / k), "hang_len": app.hang_length_m,
		"shift_push": m.arms.shift_x_push, "shift_pull": m.arms.shift_x_pull}


func test_tt8() -> void:
	for p: float in [0.0, 1.0, -1.0, 0.25, 0.5, 0.6, 0.75, -0.25, -0.5, -0.75]:
		print("TT8 pitch=%+.0f %s" % [p, JSON.stringify(_run(p))])
	check(true)
