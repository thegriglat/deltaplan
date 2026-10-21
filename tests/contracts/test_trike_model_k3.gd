extends Node
## Контракт TK-K3 (docs/contracts/trike-model.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/trike-model.md"
const VERSION := 1

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (TK-K\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("TK-K3", 0) == VERSION, "TK-K3 (v%d) в заголовках: %s" % [VERSION, found])


const PILOT := "res://assets/models/pilot.glb"
const OLD_ANIMS := ["stand", "walk", "run", "run_air", "climb_in", "prone", "climb_out", "flare"]
const SIT_FOOT_DEG := 80.0   # направление стопы в sit от вертикали вниз (build_pilot.py: SIT_FOOT_DEG)
const ANKLE_H := 0.09        # голеностоп над подошвой (D.ANKLE_H из меша; допуск 3 см его покрывает)


## Blender (x вправо, y вперёд, z вверх) -> Godot.
func _g(a: Array) -> Vector3:
	return Vector3(a[0], a[2], -a[1])


## Мировое преобразование пустышки под BoneAttachment3D по текущей позе костей (сами вложения
## обновляются только на кадре отрисовки).
func _empty_xf(skel: Skeleton3D, n: Node3D) -> Transform3D:
	var att := n.get_parent() as BoneAttachment3D
	if att == null:
		return n.global_transform
	return skel.global_transform * skel.get_bone_global_pose(skel.find_bone(att.bone_name)) * n.transform


func test_pilot_sit_pose() -> void:
	var params: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://tools/blender/trike_params.json"))
	check(params is Dictionary and params.has("seat"), "trike_params.json: блок seat")
	if not (params is Dictionary and params.has("seat")):
		return
	var seat: Dictionary = params.seat
	var root := (load(PILOT) as PackedScene).instantiate()
	add_child(root)  # AnimationPlayer работает только в дереве
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var skel := root.find_child("Skeleton3D", true, false) as Skeleton3D
	check(ap != null and skel != null, "pilot.glb: AnimationPlayer и Skeleton3D")
	if ap == null or skel == null:
		root.free()
		return
	for a in OLD_ANIMS + ["sit"]:
		check(ap.has_animation(a), "анимация " + a)
	check(ap.get_animation("sit").loop_mode == Animation.LOOP_LINEAR, "sit зациклена")
	ap.play("sit")
	ap.seek(0.0, true)
	skel.force_update_all_bone_transforms()

	var head := root.find_child("Head", true, false) as Node3D
	check(head != null, "пустышка Head")
	if head != null:
		var hx := _empty_xf(skel, head)
		var eye := hx.origin
		check(eye.distance_to(_g(seat.eye)) <= 0.02,
			"Head в seat.eye ± 2 см: %s vs %s" % [eye, _g(seat.eye)])
		var gaze := -hx.basis.z   # пустышка Head смотрит по −Z (look_matrix)
		var pitch := rad_to_deg(asin(clampf(gaze.y, -1.0, 1.0)))
		check(absf(pitch) <= 10.0, "взгляд горизонтален ± 10°: %.1f°" % pitch)
	var th_l := skel.find_bone("Thigh.L")
	var th_r := skel.find_bone("Thigh.R")
	var hip_mid := (skel.global_transform * skel.get_bone_global_pose(th_l).origin
		+ skel.global_transform * skel.get_bone_global_pose(th_r).origin) * 0.5
	check(hip_mid.distance_to(_g(seat.hip)) <= 0.03,
		"середина голов Thigh.L/R в seat.hip ± 3 см: %s vs %s" % [hip_mid, _g(seat.hip)])
	# подошвы: голеностоп + нормаль стопы (вверх, носок чуть вниз) * ANKLE_H -> подошва
	var up_f := Vector3(0.0, sin(deg_to_rad(SIT_FOOT_DEG)), -cos(deg_to_rad(SIT_FOOT_DEG)))
	for side in ["L", "R"]:
		var ank: Vector3 = skel.global_transform * skel.get_bone_global_pose(skel.find_bone("Foot." + side)).origin
		var sole := ank - up_f * ANKLE_H
		var tgt := _g(seat.foot_l if side == "L" else seat.throttle_pedal)
		var tgt2 := _g(seat.foot_l if side == "L" else seat.foot_r)
		check(sole.distance_to(tgt) <= 0.03, "подошва %s у подножки ± 3 см: %s vs %s" % [side, sole, tgt])
		check(sole.distance_to(tgt2) <= 0.04, "подошва %s у foot_%s: %s vs %s" % [side, side.to_lower(), sole, tgt2])
	for side in ["L", "R"]:
		var hand := root.find_child("Hand" + side, true, false) as Node3D
		check(hand != null, "пустышка Hand" + side)
		if hand != null:
			var t := _g(seat.hand_l if side == "L" else seat.hand_r)
			check(_empty_xf(skel, hand).origin.distance_to(t) <= 0.05,
				"Hand%s у hand_%s ± 5 см: %s vs %s" % [side, side.to_lower(), _empty_xf(skel, hand).origin, t])
	# пропорции пилота не меняем: масштаб костей корпуса 1 ± 0,001; корпус вдоль спинки (≤ 5°)
	for b in ["Hips", "Spine", "Chest"]:
		var bi := skel.find_bone(b)
		check(bi >= 0, "кость " + b)
		if bi >= 0:
			var bs := skel.get_bone_pose_scale(bi)
			check(absf(bs.x - 1.0) <= 0.001 and absf(bs.y - 1.0) <= 0.001 and absf(bs.z - 1.0) <= 0.001,
				"%s: масштаб в sit = 1: %s" % [b, bs])
	var sp := skel.find_bone("Spine")
	var hd := skel.find_bone("Chest")   # голова Chest = конец Spine, вдоль корпуса
	if sp >= 0 and hd >= 0:
		var trunk: Vector3 = (skel.get_bone_global_pose(hd).origin - skel.get_bone_global_pose(sp).origin).normalized()
		var back := deg_to_rad(float(seat.backrest_angle_deg))
		var back_dir := Vector3(0.0, cos(back), sin(back))   # вдоль спинки вверх (Godot: назад = +Z)
		var ang := rad_to_deg(trunk.angle_to(back_dir))
		check(ang <= 5.0, "корпус вдоль спинки ≤ 5°: %.1f°" % ang)
	for b in ["PodTail", "PodMid", "PodEnd", "Strap"]:
		var i := skel.find_bone(b)
		check(i >= 0, "кость " + b)
		if i >= 0:
			var sc := skel.get_bone_pose_scale(i)
			check(sc.x <= 0.01 and sc.y <= 0.01 and sc.z <= 0.01, "%s схлопнута в sit: масштаб %s" % [b, sc])
	root.free()
