extends TestCase
## «Маятник» (PD-18): после «на себя» до упора (100 % и 50 %) 3 с и рук в нейтраль крыло выходит из
## срыва к триму сама. Раньше (ЦД сорванной полосы в четверти хорды, без пикирующего момента) laminar
## и sport оставались на α 79–93°, 26–27 км/ч, снижение ≈ 7 м/с навсегда.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]
const HOLD_S := 3.0
const AFTER_S := 20.0
const LONG_S := 60.0
## Самая долгая непрерывная пора выше срывного угла после отпускания, с (раньше — до конца прогона)
const STALL_STREAK_MAX_S := 10.0


## После отпускания крыло входит в слабозатухающую фугоиду (без пилотской работы весом): проверяем
## не «в какой-то момент в конце», а что за AFTER_S скорость хоть раз вошла в 10 % трима при α ниже
## срывного (вышло из срыва к триму), а за LONG_S срыв не держится дольше STALL_STREAK_MAX_S.
func _run(w: String, pull: float) -> void:
	var m := S.make(w)
	S.reset(m)
	var v_trim := S.airspeed(m) * 3.6
	var inp := S.input(-pull)
	var a_stall: float = m.strips.alpha0_root + m.strips.cl_max / m.strips.lift_slope
	var t_trim := NAN
	var streak := 0.0
	var streak_max := 0.0
	var a_max := 0.0
	for i in int(round((HOLD_S + LONG_S) / S.DT)):
		if m.time_s >= HOLD_S - 1.0e-9:
			inp.pitch = 0.0
		m.step(S.DT, inp, Callable(), Callable())
		a_max = maxf(a_max, m.alpha)
		if m.time_s < HOLD_S:
			continue
		if m.alpha > a_stall:
			streak += S.DT
			streak_max = maxf(streak_max, streak)
		else:
			streak = 0.0
			if is_nan(t_trim) and absf(S.airspeed(m) * 3.6 - v_trim) <= 0.10 * v_trim:
				t_trim = m.time_s - HOLD_S
	var tag := "%s %d %%" % [w, roundi(pull * 100.0)]
	check(S.finite(m), "%s: без NaN" % tag)
	check(t_trim <= AFTER_S, "%s: скорость в пределах 10 %% трима при α ниже срывного за %.1f с (≤ %.0f)" % [
		tag, t_trim, AFTER_S])
	check(streak_max < STALL_STREAK_MAX_S, "%s: срыв подряд не дольше %.1f с (< %.0f)" % [
		tag, streak_max, STALL_STREAK_MAX_S])
	print("    %s: α макс %.0f°, срывной %.1f°, выход к триму %.1f с, самый долгий срыв %.1f с" % [
		tag, rad_to_deg(a_max), rad_to_deg(a_stall), t_trim, streak_max])


func test_full_pull_recovers() -> void:
	for w: String in WINGS:
		_run(w, 1.0)


func test_half_pull_recovers() -> void:
	for w: String in WINGS:
		_run(w, 0.5)
