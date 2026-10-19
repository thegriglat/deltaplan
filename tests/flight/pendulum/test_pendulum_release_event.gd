extends TestCase
## Отпускание рук по событию (docs/contracts/pullin-speed.md VM-К7 v2, PD-К2 v9, VM-К8): руки отпускают пилота вдоль киля
## только при возврате ввода к 0 после «на себя»; в остальное время держат. Мёртвая зона мыши и стика даёт ровно pitch = 0.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const H := 1.0 / 480.0
const LOAD := Vector3(-200.0, 0.0, 700.0)


func _arms(on: bool) -> PendulumPilotArms:
	var a := PendulumPilotArms.new()
	a.setup(Config.get_config("pendulum").arms)
	a.release_event = on
	a.neutral_rel = Vector3(0.0, 0.0, 1.2)
	return a


func _fx(a: PendulumPilotArms, rel: Vector3, pitch: float, v := Vector3.ZERO) -> float:
	return a.compute(rel, v, 0.0, pitch, 75.0, H, false, NAN, LOAD).x


func test_event_release_and_hold() -> void:
	var rel := Vector3(0.2, 0.0, 1.18)  # пилот сдвинут вперёд от нейтрали, кажущийся вес наклонён
	var a := _arms(true)
	check(absf(_fx(a, rel, 0.0)) > 10.0, "без «на себя» ввод 0 руки держат вдоль киля")
	check(absf(_fx(a, rel, -0.1)) > 10.0, "pitch −0,1 (< порога 0,25): держат, не взведено")
	check(absf(_fx(a, rel, 0.0)) > 10.0, "0 после −0,1: держат")
	check(absf(_fx(a, rel, -0.5)) > 10.0, "pitch −0,5: держат")
	check(_fx(a, rel, 0.0) == 0.0, "возврат к 0 после «на себя»: вдоль киля ровно 0")
	check(_fx(a, rel, 0.0) == 0.0, "и дальше, пока ввод 0")
	var f_y := a.compute(rel, Vector3.ZERO, 0.5, 0.0, 75.0, H, false, NAN, LOAD)
	check(f_y.x == 0.0 and absf(f_y.y) > 1.0, "поперёк держат по-прежнему (%.1f Н)" % f_y.y)
	check(absf(_fx(a, rel, -0.01)) > 10.0, "pitch −0,01: руки снова держат")
	check(absf(_fx(a, rel, 0.0)) > 10.0, "0 после мелкого ввода без «на себя»: держат")
	check(absf(_fx(_arms(false), rel, 0.0)) > 10.0, "release_event = false: держат всегда")
	var b := _arms(true)
	_fx(b, rel, -1.0)
	_fx(b, rel, 0.0)
	b.reset()
	check(absf(_fx(b, rel, 0.0)) > 10.0, "reset() снимает отпускание")


func test_event_settles() -> void:
	# при нейтрали держащие руки дают ≈ 200 Н (против кажущегося веса LOAD), отпущенные — 0
	var rest := Vector3(0.0, 0.0, 1.2)
	var T := TAU * sqrt(1.2 / Units.G)
	var n := int(T / H)
	var a := _arms(true)
	_fx(a, rest, -1.0)
	check(_fx(a, rest, 0.0) == 0.0, "отпущено")
	var released := true
	for i in n - 10:
		released = released and _fx(a, rest, 0.0) == 0.0
	check(released, "спокоен меньше периода (%.2f с): ещё отпущено" % T)
	for i in 20:
		_fx(a, rest, 0.0)
	check(absf(_fx(a, rest, 0.0)) > 10.0, "спокоен период: руки снова держат")
	# качание больше 5 см сбрасывает счётчик
	var b := _arms(true)
	_fx(b, rest, -1.0)
	_fx(b, rest, 0.0)
	var swing := Vector3(0.0, 0.0, 1.2)
	var still := true
	for i in 3 * n:
		swing.x = 0.1 * sin(float(i) * H * 3.0)
		still = still and _fx(b, swing, 0.0, Vector3(0.3 * cos(float(i) * H * 3.0), 0.0, 0.0)) == 0.0
	check(still, "качается > 5 см: отпущено сколько угодно")


func test_deadzones_give_exact_zero() -> void:
	var gp: Dictionary = Config.get_config("controls").gamepad
	var dz := float(gp.deadzone)
	for x in [0.0, 0.5 * dz, -0.99 * dz, dz * 0.999]:
		check(BarAxis.shape(x, gp) == 0.0, "стик %.3f в мёртвой зоне → 0" % x)
	# мышь: смещение внутри bar_deadzone даёт control.pitch = 0 (InputController._update_bar)
	var ic := InputController.new()
	ic.reload_config()
	ic.enabled = true
	var mdz := float(Config.get_config("controls").mouse.bar_deadzone)
	ic._mouse_offset = Vector2(0.9 * mdz, -0.99 * mdz)
	var c := ic.update(1.0e-4)
	check(c.pitch == 0.0 and c.roll == 0.0, "мышь внутри мёртвой зоны (%.3f): pitch = %s, roll = %s" % [mdz, c.pitch, c.roll])
	ic.free()


## Эталоны прототипа (release-tumble.md «Порт в игру»): плавный выход (pitch −1 → 0 за 0,5 с) с обычного «на себя»
## и с добором; мгновенное отпускание с 1,8·Vтрим — без переворота у обычного выхода (и 1,8), тангаж киля.
func _release(w: String, full: bool) -> Dictionary:
	var m := S.make(w)
	S.reset(m)
	var v_trim := S.airspeed(m)
	var inp := S.input(0.0)
	inp.pull_full = full
	for i in int(round(50.0 / S.DT)):
		inp.pitch = -clampf(m.time_s / 6.0, 0.0, 1.0)
		m.step(S.DT, inp, Callable(), Callable())
	var v0 := S.airspeed(m) / v_trim
	inp.pull_full = false
	var t0 := m.time_s
	var th_min := 0.0
	var a_max := 0.0
	var v_tail := 0.0
	var k := 0
	for i in int(round(30.0 / S.DT)):
		inp.pitch = -clampf(1.0 - (m.time_s - t0) / 0.5, 0.0, 1.0)
		m.step(S.DT, inp, Callable(), Callable())
		th_min = minf(th_min, rad_to_deg(m.theta))
		a_max = maxf(a_max, absf(rad_to_deg(m.alpha)))
		if m.time_s - t0 >= 25.0:
			v_tail += S.airspeed(m)
			k += 1
	var tuck := th_min < -60.0 or a_max > 90.0 or absf(v_tail / k / v_trim - 1.0) > 0.10
	return {"v0": v0, "tuck": tuck, "th_min": th_min}


func test_release_reference_wings() -> void:
	# прототип VM-6 (вариант h_relaxed_x): normal / full = в(ыход) / П(ереворот)
	var want := {"training": [false, false], "laminar": [false, true], "sport": [false, true],
			"ww_t2c": [false, true], "aeros_combat_c": [false, true]}
	var wrong := 0
	for w: String in want:
		for j in 2:
			var r := _release(w, j == 1)
			print("    %s %s: V0 %.2f·Vтрим, переворот %s, θmin %.0f°" % [w, "full" if j == 1 else "normal", r.v0, r.tuck, r.th_min])
			if bool(r.tuck) != bool(want[w][j]):
				wrong += 1
	check(wrong <= 1, "эталон VM-6: расхождений по флагам %d (допуск ±1)" % wrong)
