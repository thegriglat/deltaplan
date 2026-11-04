extends TestCase
## Темп руки игрока controls.hand.tau_s (PHD-К1 v3): итоговые roll и pitch игрока проходят фильтр первого порядка
## в InputController — (а) ступень мыши и X без рывка, (б) дрожь мыши 4 Гц гасится относительно 0,5 Гц на модели,
## (в) перекладка 45→45 укладывается в 5 с (DHV). Крылья training и sport, трим, штиль. Руки модели без фильтра.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "sport"]
const DT60 := 1.0 / 60.0


func _ic() -> InputController:
	var ic := InputController.new()
	ic.reload_config()
	ic.enabled = true
	ic.on_ground = false
	return ic


## Смещение мыши (доли хода), дающее roll = r после мёртвой зоны.
func _offset_for(r: float) -> float:
	var dz := float(Config.get_config("controls").mouse.bar_deadzone)
	return signf(r) * (absf(r) * (1.0 - dz) + dz) if r != 0.0 else 0.0


func test_mouse_step_and_x() -> void:
	var ic := _ic()
	ic._mouse_offset = Vector2(_offset_for(0.3), 0.0)
	var r1 := ic.update(DT60).roll
	check(r1 <= 0.15 * 0.3, "ступень мыши 0 → 0,3: через кадр roll %.4f ≤ %.4f" % [r1, 0.15 * 0.3])
	var r := r1
	for i in 29:
		r = ic.update(DT60).roll
	check(r >= 0.95 * 0.3, "через 0,5 с roll %.4f ≥ %.4f" % [r, 0.95 * 0.3])
	print("    ступень мыши 0,3: через 1/60 с %.4f, через 0,5 с %.4f" % [r1, r])
	# X: нажатие обнуляет смещение мыши (_update_centering), цель сразу 0; сырой ввод 0 → фильтр уходит к 0
	for i in 60:
		ic.update(DT60)
	ic._mouse_offset = Vector2.ZERO
	var x1 := ic.update(DT60).roll
	check(x1 >= 0.85 * 0.3, "X из 0,3: через кадр roll %.4f ≥ %.4f (без рывка)" % [x1, 0.85 * 0.3])
	var x := x1
	for i in 29:
		x = ic.update(DT60).roll
	check(x <= 0.05 * 0.3, "X: через 0,5 с roll %.4f ≤ %.4f" % [x, 0.05 * 0.3])
	for i in 300:
		x = ic.update(DT60).roll
	check(x == 0.0, "сырой ввод 0 → ровно 0 (события «ввод вернулся к 0»): %s" % x)
	print("    X из 0,3: через 1/60 с %.4f, через 0,5 с %.4f" % [x1, x])
	ic.free()


func _settled(w: String) -> PendulumModel:
	var m := S.make(w)
	S.reset(m)
	var c := S.input()
	for i in int(round(20.0 / S.DT)):
		m.step(S.DT, c, Callable(), Callable())
	return m


## Амплитуда скорости крена от синуса roll ±amp на частоте f через фильтр игрока: максимум |p| после 4 с.
func _amp(w: String, f: float, amp: float) -> float:
	var m := _settled(w)
	var ic := _ic()
	var c := S.input()
	var t_end := 4.0 + maxf(3.0 / f, 2.0)
	var mx := 0.0
	for i in int(round(t_end / S.DT)):
		var t := (i + 1) * S.DT
		ic.control.roll = amp * sin(TAU * f * t)
		ic._apply_hand(S.DT)
		c.roll = ic.control.roll
		m.step(S.DT, c, Callable(), Callable())
		if t > 4.0:
			mx = maxf(mx, absf(m.roll_rate))
	ic.free()
	return mx


func test_mouse_tremor_damped() -> void:
	for w: String in WINGS:
		var hi := _amp(w, 4.0, 0.126)
		var lo := _amp(w, 0.5, 0.126)
		var ratio := hi / maxf(lo, 1.0e-9)
		check(ratio <= 0.40, "%s: p(4 Гц)/p(0,5 Гц) = %.2f ≤ 0,40" % [w, ratio])
		print("    %s: дрожь roll ±0,126: p(4 Гц) %.4f, p(0,5 Гц) %.4f рад/с, отношение %.2f" % [w, hi, lo, ratio])


func test_reversal_45_within_5s() -> void:
	for w: String in WINGS:
		var m := _settled(w)
		var hold := S.BankHold.new(deg_to_rad(45.0), 1.5, 0.8, 0.15)
		var c := S.input()
		for i in int(round(25.0 / S.DT)):
			c.roll = hold.roll(m)
			m.step(S.DT, c, Callable(), Callable())
		var ic := _ic()
		ic._hand = Vector2(c.roll, 0.0)
		var t_rev := NAN
		for i in int(round(15.0 / S.DT)):
			ic.control.roll = -1.0
			ic._apply_hand(S.DT)
			c.roll = ic.control.roll
			m.step(S.DT, c, Callable(), Callable())
			if m.bank <= deg_to_rad(-45.0):
				t_rev = (i + 1) * S.DT
				break
		ic.free()
		check(not is_nan(t_rev) and t_rev <= 5.0, "%s: перекладка 45→45 за %.2f с ≤ 5,0 с" % [w, t_rev])
		print("    %s: перекладка 45→45 %.2f с" % [w, t_rev])
