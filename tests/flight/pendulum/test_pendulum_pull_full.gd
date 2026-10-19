extends TestCase
## Добор «на себя» до бёдер (docs/contracts/pullin-speed.md VM-К3 v2, PD-К2 v8, PH-К1 v2): инварианты модели.
## Без модификатора цель хода прежняя (shift_x_pull) и pull_over = 0; с модификатором и pitch −1 — shift_x_pull_full;
## pitch ≥ 0 и земля — модификатор ничего не меняет; отпускание на pitch −1 — предел убывает монотонно с
## постоянной скоростью до shift_x_pull за (full − pull)/rate ± 1 шаг, pull_over → 0 не позже ещё 3·tau.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WING := "laminar"


static func _inp(pitch: float, full: bool) -> ControlInput:
	var c := S.input(pitch)
	c.pull_full = full
	return c


## Цель хода к носу от нейтрали, м (оси B: x вперёд).
static func _tgt_fwd(m: PendulumModel) -> float:
	return m.arms.target_b.x - m.arms.neutral_rel.x


func test_without_modifier_as_before() -> void:
	var m := S.make(WING)
	S.reset(m)
	var pull := float(m.pendulum.arms.shift_x_pull_m)
	var inp := _inp(-1.0, false)
	var over_max := 0.0
	for i in int(round(25.0 / S.DT)):
		m.step(S.DT, inp, Callable(), Callable())
		over_max = maxf(over_max, m.telemetry.pull_over)
	approx(_tgt_fwd(m), pull, 1.0e-6, "без добора: цель к носу = shift_x_pull_m")
	check(over_max == 0.0, "без добора pull_over = 0 всегда (%.4f)" % over_max)
	check(S.finite(m), "конечные числа")


func test_full_pull_target_and_over() -> void:
	var m := S.make(WING)
	S.reset(m)
	var full := float(m.pendulum.arms.shift_x_pull_full_m)
	var inp := _inp(-1.0, true)
	var v0 := S.airspeed(m)
	for i in int(round(20.0 / S.DT)):
		m.step(S.DT, inp, Callable(), Callable())
	approx(_tgt_fwd(m), full, 1.0e-6, "с добором и pitch −1: цель = shift_x_pull_full_m")
	var po := m.telemetry.pull_over
	print("    %s: V %.1f → %.1f км/ч, pull_over %.2f, |bar_force| %.0f Н" % [
		WING, v0 * 3.6, S.airspeed(m) * 3.6, po, m.telemetry.bar_force.length()])
	check(po > 0.5 and po <= 1.0, "за обычным пределом pull_over > 0,5 (%.2f)" % po)
	check(m.telemetry.bar_force.length() <= float(m.pendulum.arms.force_max_n) + 1.0e-6, "|bar_force| ≤ force_max_n")
	check(m.pilot_shift.y > 1.0, "pilot_shift за пределом шкалы (%.2f)" % m.pilot_shift.y)


func test_pitch_nonneg_and_ground_unchanged() -> void:
	for p: float in [0.0, 0.6, 1.0]:
		var a := S.make(WING)
		var b := S.make(WING)
		S.reset(a)
		S.reset(b)
		for i in int(round(6.0 / S.DT)):
			a.step(S.DT, _inp(p, false), Callable(), Callable())
			b.step(S.DT, _inp(p, true), Callable(), Callable())
		check(a.pilot_position == b.pilot_position and a.velocity == b.velocity,
				"pitch %.1f: модификатор ничего не меняет" % p)
		check(b.telemetry.pull_over == 0.0, "pitch %.1f: pull_over = 0" % p)
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var g1 := S.make(WING)
	var g2 := S.make(WING)
	g1.reset_on_ground(Vector3.ZERO, 0.0)
	g2.reset_on_ground(Vector3.ZERO, 0.0)
	for i in int(round(3.0 / S.DT)):
		g1.step(S.DT, _inp(-1.0, false), Callable(), flat)
		g2.step(S.DT, _inp(-1.0, true), Callable(), flat)
	check(g1.mode == FlightModel.Mode.GROUND and g2.mode == FlightModel.Mode.GROUND, "на земле")
	check(g1.pilot_position == g2.pilot_position and g1.position == g2.position, "на земле модификатор ничего не меняет")
	check(g2.telemetry.pull_over == 0.0, "на земле pull_over = 0")


func test_release_smooth() -> void:
	var m := S.make(WING)
	S.reset(m)
	var arms: Dictionary = m.pendulum.arms
	var pull := float(arms.shift_x_pull_m)
	var full := float(arms.shift_x_pull_full_m)
	var rate := float(arms.pull_full_release_m_s)
	var tau := float(arms.tau_s)
	for i in int(round(15.0 / S.DT)):
		m.step(S.DT, _inp(-1.0, true), Callable(), Callable())
	check(m.telemetry.pull_over > 0.0, "перед отпусканием за пределом")
	var t_ramp := (full - pull) / rate
	var prev := _tgt_fwd(m)
	var mono := true
	var max_drop := 0.0
	var t_normal := -1.0
	var t_over0 := -1.0
	var t := 0.0
	var inp := _inp(-1.0, false)
	while t < t_ramp + 3.0 * tau + 1.0:
		m.step(S.DT, inp, Callable(), Callable())
		t += S.DT
		var g := _tgt_fwd(m)
		if g > prev + 1.0e-9:
			mono = false
		max_drop = maxf(max_drop, prev - g)
		prev = g
		if t_normal < 0.0 and g <= pull + 1.0e-6:
			t_normal = t
		if t_over0 < 0.0 and m.telemetry.pull_over == 0.0:
			t_over0 = t
	print("    отпускание: предел к shift_x_pull за %.3f с (расчёт %.3f), pull_over → 0 за %.3f с" % [t_normal, t_ramp, t_over0])
	check(mono, "цель убывает монотонно")
	check(max_drop <= rate * S.DT + 1.0e-6, "без скачка: шаг ≤ rate·dt (%.4f м)" % max_drop)
	check(t_normal > 0.0 and absf(t_normal - t_ramp) <= S.DT + 1.0e-6, "предел = shift_x_pull через %.3f ± 1 шаг (%.3f)" % [t_ramp, t_normal])
	check(t_over0 > 0.0 and t_over0 <= t_normal + 3.0 * tau + S.DT, "pull_over → 0 не позже 3·tau после (%.3f)" % t_over0)
	approx(_tgt_fwd(m), pull, 1.0e-6, "после — обычный предел")
	# снова зажал — предел сразу полный, без рампы
	m.step(S.DT, _inp(-1.0, true), Callable(), Callable())
	approx(_tgt_fwd(m), full, 1.0e-6, "снова зажал — сразу shift_x_pull_full")
	check(S.finite(m), "конечные числа")
