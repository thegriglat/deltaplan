extends TestCase
## SPF-К4: тангаж головы в кабине = доля (0,3) отклонения тангажа крыла от трима, медленно.

const DT := 1.0 / 60.0


class FakeModel:
	extends RefCounted
	var trim := 0.05

	func trim_pitch() -> float:
		return trim


class FakeGlider:
	extends Node3D
	var model = FakeModel.new()


class Bare:
	extends Node3D


func _rig(tgt: Node3D) -> CameraRig:
	var root := (Engine.get_main_loop() as SceneTree).root
	var host := root.get_child(root.get_child_count() - 1)
	if not InputMap.has_action("look_instrument"):
		InputMap.add_action("look_instrument")
	host.add_child(tgt)
	var cam := CameraRig.new()
	host.add_child(cam)
	cam.target = tgt
	cam.set_mode("cockpit")
	return cam


func _pitch(tgt: Node3D, theta: float) -> void:
	tgt.global_transform = Transform3D(Basis.from_euler(Vector3(theta, 0.7, 0.0)), Vector3.ZERO)


func _free(cam: CameraRig) -> void:
	var t := cam.target
	cam.queue_free()
	t.queue_free()


func _run(cam: CameraRig, seconds: float) -> void:
	for i in int(round(seconds / DT)):
		cam._process(DT)


func test_trim_zero() -> void:
	var g := FakeGlider.new()
	var cam := _rig(g)
	_pitch(g, g.model.trim)
	_run(cam, 1.0)
	check(absf(cam._head_pitch) < 1e-6, "на триме p = 0 (%f)" % cam._head_pitch)
	_free(cam)


func test_steady_and_slow() -> void:
	var g := FakeGlider.new()
	var cam := _rig(g)
	_pitch(g, g.model.trim)
	_run(cam, 0.5)
	_pitch(g, g.model.trim - deg_to_rad(15.0))
	_run(cam, 0.5)
	var goal := deg_to_rad(-4.5)
	check(absf(cam._head_pitch) < 0.4 * absf(goal), "через 0,5 с p < 40%% цели (%.2f°)" % rad_to_deg(cam._head_pitch))
	_run(cam, 10.0)
	check(absf(rad_to_deg(cam._head_pitch) + 4.5) < 0.2, "p → -4,5° (%.2f°)" % rad_to_deg(cam._head_pitch))
	_free(cam)


func test_follow_zero_and_no_model() -> void:
	var g := FakeGlider.new()
	var cam := _rig(g)
	var saved: float = cam._cfg.cockpit.head_pitch_follow
	cam._cfg.cockpit.head_pitch_follow = 0.0
	_pitch(g, -0.3)
	_run(cam, 3.0)
	cam._cfg.cockpit.head_pitch_follow = saved
	check(cam._head_pitch == 0.0, "follow 0 → p = 0")
	_free(cam)
	var b := Bare.new()
	var cam2 := _rig(b)
	_pitch(b, -0.3)
	_run(cam2, 3.0)
	check(cam2._head_pitch == 0.0, "нет модели → p = 0")
	_free(cam2)


func test_snap_and_roll_yaw() -> void:
	var g := FakeGlider.new()
	var cam := _rig(g)
	_pitch(g, g.model.trim - deg_to_rad(15.0))
	cam.snap()
	cam._process(DT)
	check(absf(rad_to_deg(cam._head_pitch) + 4.5) < 0.2, "snap: p сразу на цели (%.2f°)" % rad_to_deg(cam._head_pitch))
	# курс и крен как раньше: p = 0 даёт тот же базис
	var b := Basis.from_euler(Vector3(0.2, 0.7, 0.3))
	var c: Dictionary = cam._cfg.cockpit
	var a0 := CameraRig._level_head(b, c)
	var a1 := CameraRig._level_head(b, c, 0.0)
	check(a0.is_equal_approx(a1), "p = 0 — базис прежний")
	var a2 := CameraRig._level_head(b, c, -0.08)
	check((a0.inverse() * a2).get_euler().length() > 0.07, "p ≠ 0 — голова наклонена")
	_free(cam)


func test_trim_pitch_model() -> void:
	var m := FlightModel.new()
	var wing: Dictionary = Config.get_config("wings/sport")
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	m.setup(wing, pilot)
	m.reset_in_air(Vector3(0, 500, 0), 0.0, 0.0, Vector3.ZERO)
	check(absf(m.theta - m.trim_pitch()) < deg_to_rad(0.1), "theta ≈ trim_pitch (%.3f vs %.3f)" % [m.theta, m.trim_pitch()])
