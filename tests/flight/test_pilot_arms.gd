extends Node
## Руки пилота держат трапецию (PilotArmIK, flight.json → visual.arms): в полёте (prone) пустышки
## хвата HandL/HandR на базовой штанге (BaseBar ± полуширина хвата) при любом крене/тангаже,
## на земле (stand) — на стойках; локоть смотрит наружу-вниз. Тряска крыла (visual.buzz): в
## спокойном воздухе нет, в болтанке — миллиметры–сантиметры на 2–8 Гц.

const WINGS: Array[String] = ["training", "sport", "laminar"]
const MAX_GRIP_ERR_M := 0.03

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
					_check_elbows(v, wing + " лёжа")
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
			if anim == "stand":
				_check_elbows(v, wing + " стоя")
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


## Локоть наружу-вниз: снаружи и ниже середины отрезка «плечо → хват».
func _check_elbows(v: GliderVisual, what: String) -> void:
	var sk: Skeleton3D = v.find_children("*", "Skeleton3D", true, false)[0]
	for side in [-1, 1]:
		var bone := sk.find_bone("Forearm.L" if side < 0 else "Forearm.R")
		var elbow := v.to_local(sk.to_global(sk.get_bone_global_pose(bone).origin))
		var mid := (v.shoulder(side) + _grip(v, side)) * 0.5
		check(elbow.x * side > mid.x * side, "%s рука %d: локоть наружу" % [what, side])
		check(elbow.y < mid.y, "%s рука %d: локоть вниз" % [what, side])
