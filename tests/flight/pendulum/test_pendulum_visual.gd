extends Node
## «Маятник», визуал (PD-6, PD-К5): тело пилота висит по pilot_rel модели, маркер PilotHead
## совпадает с model.head_position (±3 см) в прямом полёте и в вираже 30°; в других режимах
## управления поза прежняя (set_pose); камера «из глаз» в «Маятнике» не добавляет следование за телом.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const M := preload("res://tests/flight/pendulum/test_pendulum_mode.gd")
const DT := 1.0 / 120.0
const HEAD_TOL_M := 0.03

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _glider(mode: String, wing := "sport") -> Glider:
	var g: Glider = M.make_glider(mode, wing)
	g.set_ground_fn(func(_x: float, _z: float) -> float: return 0.0)
	g.set_air_fn(func(_p: Vector3) -> Vector3: return Vector3.ZERO)
	add_child(g)
	g.set_process(false)  # шагаем и ставим визуал сами
	g.set_physics_process(false)
	g.reset_on_ground(Vector3(0.0, 1000.0, 0.0), 0.0)
	# в игре prone играет аниматор, здесь — вручную
	var ap: AnimationPlayer = g.visual.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	ap.advance(0.3)
	ap.pause()
	return g


## Лететь seconds с, держа крен bank_rad (0 — прямо). На земле (PD-3: «Маятник» стартует с земли) —
## сначала старт в воздухе на 1000 м.
func _fly(g: Glider, seconds: float, bank_rad: float) -> void:
	if g.model.mode != FlightModel.Mode.AIR:
		g.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	var bh := S.BankHold.new(bank_rad, 1.5, 0.8, 0.3)
	for i in int(seconds / DT):
		g.control.roll = bh.roll(g.model)
		g.step(DT)


## Поставить визуал на текущее состояние и дать скелету обновиться.
func _settle(g: Glider) -> void:
	g.global_transform = g._cur_xform
	for i in 3:
		g._update_pilot(DT)
		await get_tree().process_frame


func test_head_marker_matches_model() -> void:
	for w: String in ["training", "sport", "laminar"]:
		for bank_deg in [0.0, 30.0]:
			var g := _glider("pendulum", w)
			_fly(g, 25.0, deg_to_rad(bank_deg))
			await _settle(g)
			var m: PendulumModel = g.model
			var v := g.visual
			check(v.hang_pose_active, "%s %.0f°: поза задана маятником" % [w, bank_deg])
			var head := v.head_marker.global_position
			var d := head.distance_to(m.head_position)
			check(d < HEAD_TOL_M, "%s %.0f°: PilotHead от head_position %.1f см (≤ 3)" % [w, bank_deg, d * 100.0])
			# таз (ЦМ) — в pilot_rel от HangPoint
			var hang := v.get_marker("HangPoint").global_position
			var cm := hang + g.global_basis * m.pilot_rel
			check(hang.distance_to(m.hang_position) < 0.02, "%s: HangPoint визуала = подвеска модели" % w)
			var hips := v.global_transform * v._hips_local_world()
			check(hips.distance_to(cm) < 0.02, "%s %.0f°: таз в pilot_rel (%.1f см)" % [
				w, bank_deg, hips.distance_to(cm) * 100.0])
			# тело вдоль HangPoint → пилот
			var down := v.pilot.transform.basis * Vector3.DOWN
			check(down.angle_to(m.pilot_rel.normalized()) < 0.01, "%s %.0f°: тело вдоль стропы" % [w, bank_deg])
			print("    %s %.0f°: голова от модели %.1f см, pilot_rel %s" % [w, bank_deg, d * 100.0, m.pilot_rel])
			g.queue_free()


func test_other_modes_pose_unchanged() -> void:
	for mode in ["rate", "weight_shift"]:
		var g := _glider(mode)
		g.control.roll = 0.6
		g.control.pitch = -0.4
		g.model.mode = FlightModel.Mode.AIR
		g._update_pilot(1.0e6)
		var ref := GliderVisual.new()
		add_child(ref)
		ref.build(g.model.wing, g.model.pilot, Config.get_config("flight").visual)
		ref.set_pose(0.6, -0.4, true, 1.0e6)
		check(not g.visual.hang_pose_active, "%s: поза не от маятника" % mode)
		check(g.visual.pilot.transform.is_equal_approx(ref.pilot.transform), "%s: тело как при set_pose" % mode)
		check(g.visual.body_shift.is_equal_approx(ref.body_shift), "%s: body_shift как при set_pose" % mode)
		ref.free()
		g.queue_free()


func test_ground_stands() -> void:
	var g := _glider("pendulum")
	var a := GliderVisual.new()
	add_child(a)
	a.build(g.model.wing, g.model.pilot, Config.get_config("flight").visual)
	var b := GliderVisual.new()
	add_child(b)
	b.build(g.model.wing, g.model.pilot, Config.get_config("flight").visual)
	var rel := Vector3(0.1, -1.2, 0.3)
	a.set_hang_pose(rel, true, 1.0e6)
	b.set_pose(0.0, 0.0, false, 1.0e6)
	check(not a.hang_pose_active, "на земле поза не от маятника")
	check(a.pilot.transform.basis.is_equal_approx(b.pilot.transform.basis), "на земле — стоит, как set_pose")
	var want := a._hang + rel + rel.normalized() * 1.0
	var feet := a.ground_feet()
	check(feet.distance_to(want) < 0.001, "PD-К5 v2: ступни в ЦМ − 1 м по оси пилота (%.3f м)" % feet.distance_to(want))
	a.free()
	b.free()
	g.queue_free()


## PD-К5 v2: стоящий пилот «Маятника» рисуется ступнями на земле (±5 см), а не на 0,2–0,3 м выше.
func test_ground_feet_on_ground() -> void:
	for w: String in ["training", "laminar", "sport"]:
		var g := _glider("pendulum", w)
		for i in 120:
			g.step(DT)
		await _settle(g)
		var m: PendulumModel = g.model
		var v := g.visual
		var feet := v.global_transform * v.ground_feet()
		var model_feet := m.pilot_position - m.pilot_basis.y * 1.0
		var gh := float(g.ground_fn.call(feet.x, feet.z))
		print("    %s: ступни визуала %.3f м над землёй (модель %.3f), узел Glider %.3f" % [
			w, feet.y - gh, model_feet.y - gh, g.global_position.y - gh])
		check(m.phase() == "standing", "%s: стоит (%s)" % [w, m.phase()])
		check(absf(feet.y - gh) < 0.05, "%s: ступни у земли ±5 см (%.3f)" % [w, feet.y - gh])
		check(Vector2(feet.x - model_feet.x, feet.z - model_feet.z).length() < 0.05,
			"%s: ступни там же, где у модели" % w)
		g.queue_free()


## Камера «из глаз»: при позе от маятника следование за телом не добавляется.
func test_camera_no_body_follow_in_pendulum() -> void:
	var g := _glider("pendulum")
	_fly(g, 5.0, 0.0)
	await _settle(g)
	var cam := CameraRig.new()
	add_child(cam)
	cam.head = g.visual.head_marker
	cam.body_shift_fn = func() -> Vector3: return Vector3(0.3, 0.0, 0.1)
	var c: Dictionary = {"head_follow_body": 0.2, "head_follow_smoothing_s": 0.5}
	check(cam._follow_body(0.1, c) == Vector3.ZERO, "маятник: нет добавки head_follow_body")
	g.visual.set_pose(0.0, 0.0, true, 0.1)
	check(cam._follow_body(0.1, c) != Vector3.ZERO, "другие режимы: добавка прежняя")
	cam.free()
	g.queue_free()
