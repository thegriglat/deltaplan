extends TestCase
## Экранный эффект полос «Маятника» (PD-14, configs/pendulum.json → ground_effect): σ Wieselsberger,
## у земли подъёмная сила на том же угле атаки больше, сопротивление меньше; выше h/b ≈ 0,76 и без
## земли — ничего не меняется (сценарии полёта PD-2).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")


func test_sigma() -> void:
	# Wieselsberger: σ = (1 − 1,32·h/b)/(1,05 + 7,4·h/b)
	approx(PendulumWingStrips.ground_sigma(1.0, 10.0), 0.868 / 1.79, 1e-6, "h/b = 0,1")
	approx(PendulumWingStrips.ground_sigma(2.5, 10.0), 0.67 / 2.9, 1e-6, "h/b = 0,25")
	check(PendulumWingStrips.ground_sigma(7.6, 10.0) == 0.0, "h/b ≥ 0,76 — нуля")
	check(PendulumWingStrips.ground_sigma(100.0, 10.0) == 0.0, "высоко — нуль")
	approx(PendulumWingStrips.ground_sigma(-1.0, 10.0), PendulumWingStrips.ground_sigma(0.33, 10.0), 1e-6,
		"ниже земли — как h/b = 0,033")


## Те же состояние и поток: у земли (σ полос по h/b ≈ 0,25) C_L больше, C_D меньше.
func test_lift_up_drag_down() -> void:
	for w: String in ["training", "laminar", "sport"]:
		var m := S.make(w)
		var st := m.solve_trim()
		var R := PendulumModel.basis_from_euler(0.0, float(st.theta), 0.0)
		var g: float = st.gamma
		var vel := Vector3(cos(g), 0.0, sin(g)) * float(st.V)
		m.strips.aero(vel, R, Vector3.ZERO, m._zero_air, Vector3.ZERO, 0.0, 1.225)
		var f0 := m.strips.force
		var ge := PackedFloat64Array()
		ge.resize(m.strips.n)
		ge.fill(PendulumWingStrips.ground_sigma(0.25 * m.span, m.span))
		m.strips.aero(vel, R, Vector3.ZERO, m._zero_air, Vector3.ZERO, 0.0, 1.225, ge)
		var f1 := m.strips.force
		var u := vel.normalized()
		var l0 := -(f0 - u * f0.dot(u)).z
		var l1 := -(f1 - u * f1.dot(u)).z
		var d0 := -f0.dot(u)
		var d1 := -f1.dot(u)
		print("    %s, h/b = 0,25: подъёмная +%.1f %%, сопротивление %.1f %%" % [
			w, (l1 / l0 - 1.0) * 100.0, (d1 / d0 - 1.0) * 100.0])
		check(l1 > l0 * 1.02 and l1 < l0 * 1.15, "%s: подъёмная у земли больше на 2–15 %%" % w)
		check(d1 < d0, "%s: сопротивление у земли меньше" % w)


## Высоко над землёй (ЦМ выше размаха) — шаг тот же, что без земли.
func test_high_no_change() -> void:
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var a := S.make("sport")
	var b := S.make("sport")
	a.reset_in_air(Vector3(0.0, 30.0, 0.0), 0.0)
	b.reset_in_air(Vector3(0.0, 30.0, 0.0), 0.0)
	var inp := S.input(0.3)
	for i in 240:
		a.step(S.DT, inp, Callable(), flat)
		b.step(S.DT, inp, Callable(), Callable())
	check(a.position.is_equal_approx(b.position), "30 м над землёй: как без земли")
	check(a.velocity.is_equal_approx(b.velocity), "30 м: скорость как без земли")
