extends TestCase
## SPF-К4 v2: PendulumModel.trim_pitch() — тангаж киля на триме для камеры («голова по тангажу»).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]
const FOLLOW := 0.3


class Tgt:
	extends Node3D
	var model = null


func _theta(m: PendulumModel) -> float:
	return asin(clampf((-m.wing_basis().z).normalized().y, -1.0, 1.0))


func test_pure_and_stable() -> void:
	for w: String in WINGS:
		var m := S.make(w)
		S.reset(m)
		var nr: Vector3 = m.arms.neutral_rel
		var pos: Vector3 = m.position
		var vel: Vector3 = m.velocity
		var t1 := m.trim_pitch()
		var t2 := m.trim_pitch()
		check(t1 == t2, "%s: стабилен между вызовами" % w)
		check(m.arms.neutral_rel == nr and m.position == pos and m.velocity == vel,
			"%s: состояние не меняется" % w)
		# свежая модель без reset: ленивый расчёт даёт то же число
		var m2 := S.make(w)
		approx(m2.trim_pitch(), t1, 1.0e-9, "%s: до reset то же значение" % w)
		check(not m2._neutral_ok, "%s: ленивый расчёт не трогает нейтраль рук" % w)


func test_steady_flight_matches_trim() -> void:
	for w: String in WINGS:
		var m := S.make(w)
		S.reset(m)
		var inp := S.input()
		var s := 0.0
		var k := 0
		for i in int(round(35.0 / S.DT)):
			m.step(S.DT, inp, Callable(), Callable())
			if m.time_s > 20.0:
				s += _theta(m)
				k += 1
		var tr := m.trim_pitch()
		approx(rad_to_deg(s / k), rad_to_deg(tr), 1.0, "%s: средний тангаж киля в штиле = trim_pitch, °" % w)
		approx(rad_to_deg(_theta(m)), rad_to_deg(tr), 3.0, "%s: к 35 с тангаж около трима, °" % w)
		print("    %s: trim_pitch %.2f°, средний θ %.2f°" % [w, rad_to_deg(tr), rad_to_deg(s / k)])


func test_push_out_gives_negative_head_pitch() -> void:
	for w: String in WINGS:
		var m := S.make(w)
		S.reset(m)
		var v_trim := S.airspeed(m)
		var inp := S.input(-1.0)  # штанга от себя (pitch < 0 — разгон)
		var th := 0.0
		for i in int(round(60.0 / S.DT)):
			m.step(S.DT, inp, Callable(), Callable())
			if S.airspeed(m) >= 1.6 * v_trim:
				break
		th = _theta(m)
		var d := th - m.trim_pitch()
		var p := FOLLOW * d
		print("    %s: V/Vтрим %.2f, Δθ %.1f°, p %.2f°" % [w, S.airspeed(m) / v_trim, rad_to_deg(d), rad_to_deg(p)])
		check(S.airspeed(m) >= 1.3 * v_trim, "%s: разогнались (%.2f)" % [w, S.airspeed(m) / v_trim])
		check(d < deg_to_rad(-1.0), "%s: θ меньше трима (Δθ %.1f°)" % [w, rad_to_deg(d)])
		check(p < 0.0, "%s: p отрицательный" % w)
		approx(absf(p), FOLLOW * absf(d), deg_to_rad(0.2), "%s: |p| = 0,3·|Δθ|" % w)


func test_camera_with_pendulum_target() -> void:
	var m := S.make("training")
	S.reset(m)
	var root := (Engine.get_main_loop() as SceneTree).root
	var host := root.get_child(root.get_child_count() - 1)
	if not InputMap.has_action("look_instrument"):
		InputMap.add_action("look_instrument")
	var t := Tgt.new()
	t.model = m
	host.add_child(t)
	var cam := CameraRig.new()
	host.add_child(cam)
	cam.target = t
	cam.set_mode("cockpit")
	# на триме — p = 0
	t.global_transform = Transform3D(m.wing_basis(), Vector3.ZERO)
	cam.snap()
	cam._process(1.0 / 60.0)
	check(absf(cam._head_pitch) < deg_to_rad(0.3), "на триме p ≈ 0 (%.2f°)" % rad_to_deg(cam._head_pitch))
	# нос на 8° ниже трима → p ≈ −2,4°
	var b := Basis.from_euler(Vector3(m.trim_pitch() - deg_to_rad(8.0), 0.0, 0.0))
	t.global_transform = Transform3D(b, Vector3.ZERO)
	cam.snap()
	cam._process(1.0 / 60.0)
	check(cam._head_pitch < 0.0, "ниже трима → p < 0 (%.2f°)" % rad_to_deg(cam._head_pitch))
	approx(rad_to_deg(cam._head_pitch), -2.4, 0.2, "p = 0,3·Δθ, °")
	cam.queue_free()
	t.queue_free()
