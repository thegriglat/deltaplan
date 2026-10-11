extends RefCounted
## Пики удельной силы пилота на касании земли (PD-К6 v1, PD-38): посадка на ровную землю с заданной
## вертикальной и горизонтальной скоростью, оба режима («Смещение веса» — FlightModel, «Маятник» —
## PendulumModel). f = a − g_vec, a — разность Telemetry.pilot_velocity за интервал / интервал (как
## MotionSource, MR-К1); |f| в g на шаге физики (120 Гц) и на интервалах 1/60 с.
## Общий для tests/flight/test_landing_peaks.gd и tools/research/pendulum/pd38/peaks.gd.

const Sim := preload("res://tests/flight/flight_sim.gd")
const PSim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const GROUND_Y := 100.0
const FEET_CLEAR := 0.005  ## ступни над землёй в начале, м: касание на первом шаге


static func flat(_x: float, _z: float) -> float:
	return GROUND_Y


## mode "ws" | "pend"; v_down, v_fwd — м/с; secs — сколько шагать. → {phys_g, g60, grade, vtd, t_peak,
## t_td, last_g (|f| в конце, г), nan, model}.
## dt — шаг физики (по умолчанию 120 Гц; пик на интервалах 1/60 с — только при dt = 1/120).
static func run(
	mode: String, v_down: float, v_fwd: float = 2.0, secs: float = 2.0, wing := "sport", dt := DT
) -> Dictionary:
	var m: Variant
	# касание на первом шаге: за него свободное падение добавит g·dt — на касании ровно v_down
	var vel := Vector3(0.0, -(v_down - Units.G * dt), -v_fwd)
	if mode == "ws":
		m = Sim.make(wing)
		m.reset_in_air(Vector3(0.0, GROUND_Y + FEET_CLEAR, 0.0), 0.0)
		m.velocity = vel
		m._update_telemetry(Callable(), Callable())
	else:
		m = PSim.make(wing)
		m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
		var th: float = m.theta
		m.set_kinematic(Vector3(0.0, 1000.0, 0.0), vel, 0.0, 0.0, th)
		var feet: float = m.pilot_position.y - m._leg_len
		m.set_kinematic(Vector3(0.0, 1000.0 - (feet - GROUND_Y) + FEET_CLEAR, 0.0), vel, 0.0, 0.0, th)
	var inp := Sim.input()
	var g_vec := Vector3(0.0, -Units.G, 0.0)
	var v_prev: Vector3 = m.telemetry.pilot_velocity
	var v_prev2 := v_prev
	var phys := 0.0
	var g60 := 0.0
	var t_peak := 0.0
	var t_td := -1.0
	var last := 0.0
	var bad := false
	var n := int(round(secs / dt))
	for i in n:
		m.step(dt, inp, Callable(), flat)
		var v: Vector3 = m.telemetry.pilot_velocity
		if not v.is_finite():
			bad = true
			break
		if t_td < 0.0 and m.mode != FlightModel.Mode.AIR:
			t_td = (i + 1) * dt
		var f := ((v - v_prev) / dt - g_vec).length() / Units.G
		if f > phys:
			phys = f
			t_peak = (i + 1) * dt
		if i % 2 == 1:
			g60 = maxf(g60, ((v - v_prev2) / (2.0 * dt) - g_vec).length() / Units.G)
			v_prev2 = v
		last = f
		v_prev = v
	var r: Dictionary = m.landing_result
	return {
		"phys_g": phys, "g60": g60, "grade": String(r.get("grade", "none")),
		"vtd": float(r.get("vertical_speed_ms", NAN)), "t_peak": t_peak, "t_td": t_td, "last_g": last,
		"nan": bad, "model": m,
	}


## Строка «PEAK mode=… v=… phys_g=… g60=… grade=…» (+ скорость касания, времена).
static func line(mode: String, label: String, r: Dictionary) -> String:
	return "PEAK mode=%s v=%s phys_g=%.2f g60=%.2f grade=%s vtd=%.2f t_td=%.3f t_peak=%.3f end_g=%.2f nan=%s" % [
		mode, label, r.phys_g, r.g60, r.grade, r.vtd, r.t_td, r.t_peak, r.last_g, r.nan]
