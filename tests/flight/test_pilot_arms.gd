extends Node
## Руки пилота держат трапецию (PilotArmIK, flight.json → visual.arms): в полёте (prone) пустышки
## хвата HandL/HandR на базовой штанге (BaseBar ± полуширина хвата) при любом крене/тангаже,
## на земле (stand) — на стойках; локоть смотрит наружу-вниз. Тряска крыла (visual.buzz): в
## спокойном воздухе нет, в болтанке — миллиметры–сантиметры на 2–8 Гц.

const WC := preload("res://tools/flight/wing_clearance.gd")
const WINGS: Array[String] = ["training", "sport", "laminar"]
const MAX_GRIP_ERR_M := 0.03
## Лёжа на штанге локоть выше плечевого сустава не больше чем на столько, м. База под плечами
## (плечо–хват 0,32–0,37 м), ось руки почти вертикальна, и локоть, торчащий наружу, лежит на
## окружности в почти горизонтальной плоскости: «наружу и ниже середины» невозможно, остаётся
## «наружу и не выше плеча» (запас на ±10 см — рука согнута, локоть на уровне плеча).
const ELBOW_ABOVE_SHOULDER_M := 0.1
## Нижняя граница угла в локте на стойках, ° (контракт A3.2 — 90°). Кости pilot.glb: плечо 0,26 м,
## предплечье с кистью 0,38 м, угол 90° — расстояние плечо–хват 0,46 м, а при «выше плеча ≤ 0,15 м,
## впереди ≤ 0,35 м» оно ≤ 0,39 м (≈ 72°). Контракт и кости не сходятся — вопрос координатору.
const MIN_ELBOW_DEG := 60.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_hands_on_base_bar_in_flight() -> void:
	for wing in WINGS:
		var v := _visual(wing)
		var ap := _player(v)
		check(v.arm_ik != null, "%s: у пилота есть IK рук" % wing)
		if v.arm_ik == null or ap == null:
			v.free()
			continue
		ap.play("prone", 0.0)
		ap.advance(0.5)
		var half := float(Config.get_config("flight").visual.arms.bar_grip_half_width_m)
		var bb := v.to_local(v.get_marker("BaseBar").global_position)
		check(
			v.bar_grip(-1).distance_to(bb + Vector3(-half, 0, 0)) < 1e-3,
			"%s: точка хвата = BaseBar − полуширина хвата" % wing
		)
		var worst := 0.0
		for roll in [-1.0, 0.0, 1.0]:
			for pitch in [-1.0, 0.0, 1.0]:
				v.set_pose(roll, pitch, true, 1.0e6)
				await _frames(2)
				for side in [-1, 1]:
					var err := _grip(v, side).distance_to(v.bar_grip(side))
					worst = maxf(worst, err)
					check(
						err < MAX_GRIP_ERR_M,
						(
							"%s: крен %+.0f, тангаж %+.0f, рука %d: кисть↔хват %.3f м"
							% [wing, roll, pitch, side, err]
						)
					)
				if roll == 0.0 and pitch == 0.0:
					_check_elbows(v, wing + " лёжа", true)
		print("         %s лёжа: худшее кисть↔штанга %.4f м" % [wing, worst])
		v.free()


func test_hands_on_uprights_standing() -> void:
	for wing in WINGS:
		var v := _visual(wing)
		var ap := _player(v)
		if v.arm_ik == null or ap == null:
			v.free()
			continue
		for anim in ["stand", "walk", "run"]:
			ap.play(anim, 0.0)
			ap.advance(0.3)
			ap.pause()  # цель на стойке — от плеча прошлого кадра; бег не должен её сбивать
			for roll in [-1.0, 0.0, 1.0]:
				v.set_pose(roll, 0.0, false, 1.0e6)
				await _frames(2)
				if anim == "stand" and roll == 0.0:
					_check_elbows(v, wing + " стоя", false)
				for side in [-1, 1]:
					var want := v.upright_grip(side)
					var err := _grip(v, side).distance_to(want)
					check(
						err < MAX_GRIP_ERR_M,
						(
							"%s %s крен %+.0f рука %d: кисть↔стойка %.3f м"
							% [wing, anim, roll, side, err]
						)
					)
					var shoulder_y := v.shoulder(side).y
					check(
						absf(want.y - shoulder_y) < 0.3,
						(
							"%s %s: хват на стойке на уровне плеч (%.2f vs %.2f)"
							% [wing, anim, want.y, shoulder_y]
						)
					)
		v.free()


## A3.2 (docs/contracts/aframe-geometry.md): крыло apogee стоит на старте (штиль, ровно, ввода нет),
## пилот в позе stand держит стойки: хват выше плечевого сустава на 0…0,15 м, впереди 0,05…0,35 м
## (по горизонтали, вперёд — вдоль курса крыла), угол в локте 90…165°. Плечо и локоть — решение IK.
func test_apogee_arms_on_uprights_at_start() -> void:
	var g := WC.make_glider(self, "apogee")
	g.model.reset_on_ground(Vector3(0, 100, 0), 0.0)
	var zero := func(_p: Vector3) -> Vector3: return Vector3.ZERO
	var flat := func(_x: float, _z: float) -> float: return 100.0
	for i in 360:
		g.model.step(1.0 / 120.0, ControlInput.new(), zero, flat)
	g.step(1.0 / 120.0)
	g.global_transform = Transform3D(g.model.telemetry.basis, g.model.position)
	var v := g.visual
	var ap := _player(v)
	check(ap != null and v.arm_ik != null, "apogee: пилот со скелетом и IK рук")
	if ap == null or v.arm_ik == null:
		g.free()
		return
	ap.play("stand", 0.0)
	ap.advance(0.3)
	ap.pause()
	for i in 4:
		v.set_pose(0.0, 0.0, false, 1.0e6)
		await _frames(2)
	var sk: Skeleton3D = v.find_children("*", "Skeleton3D", true, false)[0]
	var fwd := -g.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var theta := rad_to_deg(g.model.theta)
	var strop := v.to_global(v.pilot.position).distance_to(
		v.get_marker("HangPoint").global_position
	)
	print("         apogee стоя: карабин пилота от HangPoint %.2f м" % strop)
	for side in [-1, 1]:
		var j := v.arm_ik.solved_joints(0 if side < 0 else 1)
		var sh := sk.to_global(j[0])
		var el := sk.to_global(j[1])
		var hand := (
			(v.find_child("HandL" if side < 0 else "HandR", true, false) as Node3D).global_position
		)
		var up := hand.y - sh.y
		var ahead := (hand - sh).dot(fwd)
		var elbow := rad_to_deg((sh - el).angle_to(hand - el))
		print(
			(
				"         apogee стоя, рука %d: хват над плечом %.3f, впереди %.3f м, локоть %.0f°, киль %.1f°"
				% [side, up, ahead, elbow, theta]
			)
		)
		check(up >= 0.0 and up <= 0.15, "apogee: хват выше плеча на 0…0,15 м (%.3f)" % up)
		check(
			ahead >= 0.05 and ahead <= 0.35, "apogee: хват впереди плеча 0,05…0,35 м (%.3f)" % ahead
		)
		check(
			elbow >= MIN_ELBOW_DEG and elbow <= 165.0,
			"apogee: угол в локте %.0f…165° (%.0f°)" % [MIN_ELBOW_DEG, elbow]
		)
	g.free()


## Стоя на земле крен мышью (control.roll) не сдвигает пилота вбок: ноги на месте, крыло качается
## у него в руках. Печатает смещение ступней при полном крене и расстояние карабина от HangPoint.
func test_ground_roll_keeps_legs_in_place() -> void:
	var v := _visual("sport")
	var ap := _player(v)
	if ap == null:
		v.free()
		return
	ap.play("stand", 0.0)
	ap.advance(0.3)
	ap.pause()
	var sk: Skeleton3D = v.find_children("*", "Skeleton3D", true, false)[0]
	var foot := sk.find_bone("Foot.L")
	var feet: Array[Vector3] = []
	for roll in [-1.0, 0.0, 1.0]:
		v.set_pose(roll, 0.0, false, 1.0e6)
		await _frames(2)
		feet.append(v.to_local(sk.to_global(sk.get_bone_global_pose(foot).origin)))
	var move := maxf(feet[0].distance_to(feet[1]), feet[2].distance_to(feet[1]))
	var carabiner := v.pilot.position.distance_to(
		v.to_local(v.get_marker("HangPoint").global_position)
	)
	print(
		(
			"         стоя, полный крен: ступни сместились на %.3f м; карабин от HangPoint %.2f м"
			% [move, carabiner]
		)
	)
	check(move < 0.01, "крен стоя не сдвигает ноги пилота (%.3f м)" % move)
	v.free()


func test_trapeze_buzz() -> void:
	var v := _visual("sport")
	var base := v.wing.position
	var dt := 1.0 / 60.0
	for i in 120:
		v.set_flight(12.0, 0.0, 0.0)
		v.set_pose(0.0, 0.0, true, dt)
	check(v.buzz.is_zero_approx(), "спокойный воздух: трапеция неподвижна (%s)" % v.buzz)
	check(v.wing.position.is_equal_approx(base), "спокойный воздух: крыло на месте")
	var peak := 0.0
	var crossings := 0
	var prev := 0.0
	var n := 600
	for i in n:
		v.set_flight(12.0, 0.0, 1.0)
		v.set_pose(0.0, 0.0, true, dt)
		if i < 60:
			continue  # амплитуда разгоняется
		peak = maxf(peak, v.buzz.length())
		if prev != 0.0 and signf(v.buzz.y) != signf(prev):
			crossings += 1
		prev = v.buzz.y
	var freq := crossings * 0.5 / ((n - 60) * dt)
	print("         болтанка: тряска до %.1f мм, ~%.1f Гц" % [peak * 1000.0, freq])
	check(peak > 0.002 and peak <= 0.03, "болтанка: тряска мм–см (%.4f м)" % peak)
	check(freq > 2.0 and freq < 8.0, "болтанка: частота 2–8 Гц (%.1f)" % freq)
	var off := v.wing.position - base
	check(off.distance_to(v.buzz) < 1e-4, "крыло сдвинуто на buzz относительно пилота")
	v.free()


func _visual(wing: String) -> GliderVisual:
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/" + wing),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	return v


func _player(v: GliderVisual) -> AnimationPlayer:
	var found := v.find_children("*", "AnimationPlayer", true, false)
	return found[0] as AnimationPlayer if not found.is_empty() else null


## Скелет пилота обновляется (анимация + IK) в кадре — ждём кадры.
func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Пустышка хвата кисти в осях визуала.
func _grip(v: GliderVisual, side: int) -> Vector3:
	var node := v.find_child("HandL" if side < 0 else "HandR", true, false) as Node3D
	return v.to_local(node.global_position)


## Локоть и плечо по решению IK (не поза анимации), в осях визуала: [плечо, локоть].
func _joints(v: GliderVisual, side: int) -> Array[Vector3]:
	var sk: Skeleton3D = v.find_children("*", "Skeleton3D", true, false)[0]
	var j := v.arm_ik.solved_joints(0 if side < 0 else 1)
	return [v.to_local(sk.to_global(j[0])), v.to_local(sk.to_global(j[1]))]


## Локоть наружу; стоя — ниже середины отрезка «плечо → хват» (кисти выше плеч, локти вниз),
## лёжа — не выше плеча больше чем на ELBOW_ABOVE_SHOULDER_M.
func _check_elbows(v: GliderVisual, what: String, prone: bool) -> void:
	for side in [-1, 1]:
		var j := _joints(v, side)
		var elbow := j[1]
		var mid := (j[0] + _grip(v, side)) * 0.5
		check(elbow.x * side > mid.x * side, "%s рука %d: локоть наружу" % [what, side])
		if prone:
			check(
				elbow.y < j[0].y + ELBOW_ABOVE_SHOULDER_M,
				"%s рука %d: локоть не выше плеча (%.3f)" % [what, side, elbow.y - j[0].y]
			)
		else:
			check(elbow.y < mid.y, "%s рука %d: локоть вниз" % [what, side])
