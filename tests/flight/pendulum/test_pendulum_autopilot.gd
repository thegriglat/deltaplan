extends TestCase
## Автопилот в режиме «Маятник» (PD-4, R7): ПИД крена задаёт положение пилота (roll_command),
## в болтанке σ 1 м/с (поле из reference.json, как в тестах PD-2) СКО крена ≤ 1,5× прототипа.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const M := preload("res://tests/flight/pendulum/test_pendulum_mode.gd")
const WINGS := ["training", "laminar", "sport"]
static var MAXB := 0.0
const T_S := 40.0
const SETTLE_S := 10.0


## → {std_phi_deg, max_roll_cmd, ok}
func _fly(wing: String) -> Dictionary:
	var g := M.make_glider("pendulum", wing, {})
	var m: PendulumModel = g.model
	g.reset_in_air(S.START_CG, 0.0)
	var off := S.cg(m) - S.START_CG
	var tb := S.Turbulence.new(S.ref().turbulence, off)
	g.set_air_fn(tb.air)
	g.reset_in_air(S.START_CG - off, 0.0)
	var ap := Autopilot.new()
	ap.pendulum = true
	ap.max_bank_deg = MAXB
	ap.reset()
	var phi: PackedFloat64Array = []
	var max_cmd := 0.0
	var ok := true
	for i in int(round(T_S / S.DT)):
		ap.drive(g.get_telemetry(), S.DT)
		var c := ControlInput.new()
		c.roll = ap.roll_command
		g.set_input(c)
		g.step(S.DT)
		max_cmd = maxf(max_cmd, absf(ap.roll_command))
		if not S.finite(m):
			ok = false
			break
		if m.time_s > SETTLE_S:
			phi.append(rad_to_deg(m.bank))
	ap.release_all()
	g.free()
	var mean := 0.0
	for v in phi:
		mean += v
	mean /= maxf(phi.size(), 1)
	var q := 0.0
	for v in phi:
		q += (v - mean) * (v - mean)
	return {"std_phi_deg": sqrt(q / maxf(phi.size(), 1)), "max_roll_cmd": max_cmd, "ok": ok}


func test_autopilot_holds_horizon_in_turbulence() -> void:
	for w: String in WINGS:
		var r := S.scenario("turbulence", w)
		var o := _fly(w)
		check(o.ok, "%s: без NaN" % w)
		var lim := 1.5 * float(r.std_phi_deg)
		check(
			o.std_phi_deg <= lim,
			"%s: СКО крена %.2f° ≤ 1,5 × прототип (%.2f° → %.2f°)" % [w, o.std_phi_deg, r.std_phi_deg, lim]
		)
		check(o.max_roll_cmd > 0.05, "%s: автопилот двигает пилота (|roll| до %.2f)" % [w, o.max_roll_cmd])
		print("    %s: СКО крена %.2f° (прототип %.2f°), |roll| до %.2f" % [
			w, o.std_phi_deg, r.std_phi_deg, o.max_roll_cmd])


func test_roll_command_bounded_and_resets() -> void:
	var ap := Autopilot.new()
	ap.pendulum = true
	var t := Telemetry.new()
	t.phase = "flying"
	t.heading_deg = 0.0
	t.bank_deg = 40.0
	t.altitude_agl = 500.0
	for i in 100:
		ap.drive(t, 1.0 / 120.0)
	check(ap.roll_command < -0.5 and ap.roll_command >= -1.0, "крен вправо 40° → пилот влево (%.2f)" % ap.roll_command)
	t.phase = "landed"
	ap.drive(t, 1.0 / 120.0)
	approx(ap.roll_command, 0.0, 1e-9, "после посадки команда 0")
	ap.reset()
	approx(ap.roll_command, 0.0, 1e-9, "reset обнуляет")
	ap.release_all()
