extends Node
## Поза пилота (карточка docs/plan/models/01-poza-stoya-i-variometr.md, docs/models.md → «Пилот»):
## на земле (фаза standing, анимация stand) тело вертикально: ось тела «середина ступней → глаза»
## и ноги отклонены от вертикали меньше 20°, корпус — вперёд не больше 40° (по фото ~30°), подошвы
## на земле; в полёте (prone) корпус «таз → шея» горизонтален (±20°), голова впереди, ноги сзади.
## GliderVisual больше не поворачивает модель на 90° поверх анимации stand.

const WINGS: Array[String] = ["training", "sport", "kingpost"]
const MAX_STAND_TILT_DEG := 20.0
const MAX_TORSO_LEAN_DEG := 40.0
const MAX_PRONE_TILT_DEG := 20.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_standing_upright_and_flying_prone() -> void:
	var vis_cfg: Dictionary = Config.get_config("flight").visual
	var pilot_cfg: Dictionary = Config.get_config("pilot")
	for wing in WINGS:
		var v := GliderVisual.new()
		add_child(v)  # AnimationPlayer работает только в дереве
		v.build(Config.get_config("wings/" + wing), pilot_cfg, vis_cfg)
		var ap: AnimationPlayer = null
		for n: AnimationPlayer in v.find_children("*", "AnimationPlayer", true, false):
			ap = n
		check(ap != null and ap.has_animation("stand"), "%s: у пилота есть анимация stand" % wing)
		if ap == null:
			v.free()
			continue
		var st := _pose(v, ap, "stand", false)
		var legs := _tilt(st.hips - st.feet)
		var torso := _tilt(st.neck - st.hips)
		var whole := _tilt(st.eyes - st.feet)
		print(
			(
				"         %s стоя: от вертикали ноги %.1f°, корпус %.1f°, ступни→глаза %.1f°; подошвы y=%.2f"
				% [wing, legs, torso, whole, st.sole]
			)
		)
		check(whole < MAX_STAND_TILT_DEG, "%s: стоя тело вертикально (%.1f°)" % [wing, whole])
		check(legs < MAX_STAND_TILT_DEG, "%s: стоя ноги вертикально (%.1f°)" % [wing, legs])
		check(torso < MAX_TORSO_LEAN_DEG, "%s: стоя корпус вперёд ≤ 40° (%.1f°)" % [wing, torso])
		check(st.neck.z < st.hips.z, "%s: стоя корпус наклонён вперёд, а не назад" % wing)
		var eyes_min := float(pilot_cfg.visual.height_m) * 0.7
		check(st.eyes.y > eyes_min, "%s: стоя глаза высоко (%.2f м)" % [wing, st.eyes.y])
		check(absf(st.sole) < 0.15, "%s: стоя подошвы на земле (y=%.2f)" % [wing, st.sole])
		var pr := _pose(v, ap, "prone", true)
		var lie := 90.0 - _tilt(pr.neck - pr.hips)
		print("         %s лёжа: корпус от горизонта %.1f°" % [wing, lie])
		check(
			absf(lie) < MAX_PRONE_TILT_DEG, "%s: в полёте тело горизонтально (%.1f°)" % [wing, lie]
		)
		check(pr.neck.z < pr.hips.z, "%s: лёжа голова впереди (−Z)" % wing)
		check(pr.feet.z > pr.hips.z, "%s: лёжа ноги сзади (в коконе)" % wing)
		v.free()  # не в очереди: следующее крыло строится сразу


## Пилот в полёте качается маятником вокруг HangPoint (карабин на месте), а не едет вбок/вперёд
## по рельсе: при полном крене/тангаже центр масс смещается на pilot_shift_m/pilot_bar_m, угол
## поворота тела = asin(смещение / L), L — расстояние HangPoint → центр масс пилота.
func test_flight_pose_swings_around_hang_point() -> void:
	var vis_cfg: Dictionary = Config.get_config("flight").visual
	var pilot_cfg: Dictionary = Config.get_config("pilot")
	var pv: Dictionary = pilot_cfg.visual
	var c := Vector3(0, -float(pv.body_below_hang_m), float(pv.body_back_m))
	var l := c.length()
	var v := GliderVisual.new()
	add_child(v)
	v.build(Config.get_config("wings/" + WINGS[0]), pilot_cfg, vis_cfg)

	v.set_pose(0.0, 0.0, true, 1.0e6)
	var hang := v.pilot.transform.origin
	var com0 := v.pilot.transform * c

	v.set_pose(1.0, 0.0, true, 1.0e6)
	check(
		v.pilot.transform.origin.is_equal_approx(hang),
		"крен: карабин остаётся в HangPoint (%s vs %s)" % [v.pilot.transform.origin, hang]
	)
	var x_axis := v.pilot.transform.basis * Vector3.RIGHT
	var roll_ang := rad_to_deg(atan2(x_axis.y, x_axis.x))
	var expect_roll := rad_to_deg(asin(clampf(float(vis_cfg.pilot_shift_m) / l, -1.0, 1.0)))
	check(
		absf(roll_ang - expect_roll) < 1.0,
		"крен: угол тела %.2f° ≈ ожидаемый %.2f°" % [roll_ang, expect_roll]
	)
	var com1 := v.pilot.transform * c
	var com_shift := com1 - com0
	check(
		absf(com_shift.x - float(vis_cfg.pilot_shift_m)) < 0.02,
		"крен: центр масс смещён на pilot_shift_m (%.3f vs %.3f)" % [
			com_shift.x, float(vis_cfg.pilot_shift_m)
		]
	)

	v.set_pose(0.0, 1.0, true, 1.0e6)
	check(
		v.pilot.transform.origin.is_equal_approx(hang),
		"тангаж: карабин остаётся в HangPoint (%s vs %s)" % [v.pilot.transform.origin, hang]
	)
	var com2 := v.pilot.transform * c
	var pitch_shift := com2 - com0
	check(
		absf(pitch_shift.z - float(vis_cfg.pilot_bar_m)) < 0.02,
		"тангаж: центр масс смещён на pilot_bar_m (%.3f vs %.3f)" % [
			pitch_shift.z, float(vis_cfg.pilot_bar_m)
		]
	)
	v.free()


## Угол вектора от вертикали, °.
static func _tilt(d: Vector3) -> float:
	return rad_to_deg(d.angle_to(Vector3.UP))


## Проиграть позу, выставить тело (без сглаживания) и снять точки тела в координатах визуала
## (начало — ноги пилота на земле, вверх +Y, вперёд −Z).
func _pose(v: GliderVisual, ap: AnimationPlayer, anim: String, flying: bool) -> Dictionary:
	ap.play(anim, 0.0)
	ap.advance(0.5)
	var sk: Skeleton3D = v.find_children("*", "Skeleton3D", true, false)[0]
	sk.force_update_all_bone_transforms()
	for ba: BoneAttachment3D in v.find_children("*", "BoneAttachment3D", true, false):
		ba.on_skeleton_update()
	v.set_pose(0.0, 0.0, flying, 1.0e6)
	var fl := _bone(v, sk, "Foot.L")
	var fr := _bone(v, sk, "Foot.R")
	return {
		"feet": (fl + fr) * 0.5,
		"hips": _bone(v, sk, "Hips"),
		"neck": _bone(v, sk, "Head"),
		"eyes": v.head_marker.position,  # пустышка Head — глаза
		"sole": minf(fl.y, fr.y),
	}


## Начало кости в координатах визуала. В Godot точка в имени кости становится «_», а кость
## Head при импорте — Head_2 (имя занято пустышкой глаз).
func _bone(v: GliderVisual, sk: Skeleton3D, bone_name: String) -> Vector3:
	var i := -1
	for n in [bone_name, bone_name.replace(".", "_"), bone_name + "_2"]:
		if i < 0:
			i = sk.find_bone(n)
	check(i >= 0, "у скелета есть кость %s" % bone_name)
	if i < 0:
		return Vector3.ZERO
	var x := Transform3D.IDENTITY
	var n: Node = sk
	while n != null and n != v:
		if n is Node3D:
			x = (n as Node3D).transform * x
		n = n.get_parent()
	return x * sk.get_bone_global_pose(i).origin
