extends TestCase
## TW-17: SpeedHold — удержание воздушной скорости 12–16 м/с в «Маятнике» (крыло sport): свободный полёт
## и лебёдочный трос (звено link к якорю на земле впереди, как tools/research/tow/tow_sweep.gd), через Autopilot.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const ROPE_M := 300.0
const RAMP_S := 10.0


## Лебёдка: ведёт якорь так, чтобы натяжение шло к T_n (нарастает за RAMP_S); якорь на земле впереди, ε° ниже
## горизонта пилота. Регулятор — П + медленный И по натяжению поверх скорости пилота вдоль курса.
static func attach_winch(m: PendulumModel, t_n: float, eps_deg: float) -> void:
	var st := {"x": 0.0, "off": 0.0}
	var x0 := m.pilot_position.z
	m.set_external_force(func(s: Dictionary) -> Dictionary:
		var err: float = t_n * minf(s.t / RAMP_S, 1.0) - float(s.link_tension_n)
		st.off += 0.001 * err * s.h
		var va := clampf(-m.velocity.z + st.off + 0.004 * err, 5.0, 45.0)
		st.x += va * s.h
		var base: Vector3 = s.pilot_pos
		var anchor := Vector3(0.0, base.y - ROPE_M * sin(deg_to_rad(eps_deg)), 0.0)
		anchor.z = x0 - ROPE_M * cos(deg_to_rad(eps_deg)) - st.x
		return {"link": {"anchor": anchor, "anchor_vel": Vector3(0, 0, -va), "length_m": ROPE_M,
			"compliance_m_per_n": ROPE_M / 3.0e5, "damping_s": 0.02, "at": "pilot"}})


## → {err_end, v_min, v_max (за последние 10 с), shift_max (по модулю, м), ok}
func _fly(target: float, t_n: float, eps_deg: float, secs: float) -> Dictionary:
	var m := S.make("sport", 0.0)
	S.reset(m)
	if t_n > 0.0:
		attach_winch(m, t_n, eps_deg)
	var ap := Autopilot.new()
	ap.hold_airspeed_ms = target
	ap.reset()
	var r := {"err_end": 0.0, "v_min": 1e9, "v_max": -1e9, "shift_max": 0.0, "ok": true}
	var n := int(round(secs / S.DT))
	for i in n:
		ap.drive(m.telemetry, S.DT)
		m.step(S.DT, S.input(ap.pitch_command, 0.0), Callable(), Callable())
		if not S.finite(m):
			r.ok = false
			break
		if i >= n - int(round(10.0 / S.DT)):
			var v := S.airspeed(m)
			r.v_min = minf(r.v_min, v)
			r.v_max = maxf(r.v_max, v)
			r.shift_max = maxf(r.shift_max, absf(S.rel_b(m).x - m.arms.neutral_rel.x))
	r.err_end = S.airspeed(m) - target
	return r


func test_free_flight_holds_speed() -> void:
	for v: float in [12.0, 14.0, 16.0]:
		var r := _fly(v, 0.0, 0.0, 20.0)
		check(r.ok, "%.0f м/с: без NaN" % v)
		check(absf(r.err_end) < 0.5, "%.0f м/с: ошибка за 20 с %.2f < 0,5" % [v, r.err_end])
		check(r.v_min > v - 0.5 and r.v_max < v + 0.5, "%.0f м/с: V за последние 10 с %.2f…%.2f в ±0,5" % [v, r.v_min, r.v_max])
		print("    свободный %.0f м/с: ошибка %.2f, V %.2f…%.2f" % [v, r.err_end, r.v_min, r.v_max])


func test_on_winch_rope_holds_speed_without_stop() -> void:
	var lim := float(Config.get_config("pendulum").get("shift_x_pull_m", 0.45))
	for v: float in [12.0, 14.0, 16.0]:
		for t_n: float in [400.0, 600.0, 800.0]:
			for eps: float in [20.0, 45.0, 60.0]:
				var r := _fly(v, t_n, eps, 40.0)
				var tag := "V=%.0f T=%.0f ε=%.0f°" % [v, t_n, eps]
				check(r.ok, tag + ": без NaN")
				check(r.v_min > 12.0 - 0.5 and r.v_max < 16.0 + 0.5, tag + ": V %.2f…%.2f в 12–16 м/с" % [r.v_min, r.v_max])
				check(absf(r.err_end) < 0.5, tag + ": ошибка %.2f < 0,5" % r.err_end)
				check(r.shift_max < lim, tag + ": ход пилота %.2f м не в упоре (< %.2f)" % [r.shift_max, lim])
				print("    %s: ошибка %.2f, V %.2f…%.2f, ход %.2f м" % [tag, r.err_end, r.v_min, r.v_max, r.shift_max])


func test_autopilot_without_hold_keeps_trim() -> void:
	var ap := Autopilot.new()
	var t := Telemetry.new()
	t.phase = "flying"
	t.airspeed = 9.0
	t.altitude_agl = 500.0
	for i in 200:
		ap.drive(t, S.DT)
	approx(ap.pitch_command, 0.0, 1e-9, "hold_airspeed_ms = 0: тангаж трапеции — трим")
	ap.hold_airspeed_ms = 14.0
	for i in 200:
		ap.drive(t, S.DT)
	check(ap.pitch_command < -0.1, "медленнее цели → на себя (%.2f)" % ap.pitch_command)
	ap.hold_airspeed_ms = 0.0
	for i in 400:
		ap.drive(t, S.DT)
	approx(ap.pitch_command, 0.0, 1e-9, "выключили — трапеция возвращается к триму")
	ap.release_all()
