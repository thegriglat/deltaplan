extends Node3D
## Замер сегментов модели пилота и геометрии позы в полёте (нейтраль) относительно трапеции.
##   godot --headless --path . res://tools/flight/pilot_pose_measure.tscn -- [--wing=sport] [--roll=0] [--pitch=0]
var _wing := "sport"
var _roll := 0.0
var _pitch := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--wing="):
			_wing = a.substr(7)
		elif a.begins_with("--roll="):
			_roll = float(a.substr(7))
		elif a.begins_with("--pitch="):
			_pitch = float(a.substr(8))
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/" + _wing),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play("prone", 0.0)
	ap.advance(0.3)
	ap.pause()
	for i in 6:
		v.set_pose(_roll, _pitch, true, 1.0e6)
		await get_tree().process_frame
	var sk := v.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	print("--- bones (rest, длина до первого ребёнка) ---")
	for i in sk.get_bone_count():
		var ch := sk.get_bone_children(i)
		var l := sk.get_bone_rest(ch[0]).origin.length() if ch.size() > 0 else 0.0
		print("%s len=%.3f" % [sk.get_bone_name(i), l])
	var ik := v.arm_ik
	print("max_reach=%.3f (плечо+предплечье+grip+reach); grip от запястья=%.3f" % [ik.max_reach(), ik.max_reach() - v._cfg.arms.shoulder_reach_m - sk.get_bone_rest(sk.find_bone("Forearm.L")).origin.length()])
	var mi := v.pilot.find_children("*", "MeshInstance3D", true, false)
	for m: MeshInstance3D in mi:
		var bb := m.get_aabb()
		print("mesh ", m.name, " aabb size=", bb.size, " pos=", bb.position)
	print("--- prone, оси визуала (x вправо, y вверх, -z вперёд) wing=", _wing)
	var to_v := v.global_transform.affine_inverse() * sk.global_transform
	for side in 2:
		var j := ik.solved_joints(side)
		var sh: Vector3 = to_v * j[0]
		var el: Vector3 = to_v * j[1]
		var gr: Vector3 = to_v * ik.grip_point(side)
		var bg := v.bar_grip(-1 if side == 0 else 1)
		print("side %d shoulder=%s elbow=%s grip=%s bargrip=%s" % [side, sh, el, gr, bg])
		print(
			(
				"  upper=%.3f fore+hand=%.3f elbow_below_shoulder=%.3f bar_below_shoulder=%.3f bar_ahead_of_shoulder=%.3f elbow_ahead=%.3f elbow_out=%.3f"
				% [
					sh.distance_to(el),
					el.distance_to(gr),
					sh.y - el.y,
					sh.y - bg.y,
					sh.z - bg.z,
					sh.z - el.z,
					absf(el.x - sh.x)
				]
			)
		)
		var u := (el - sh).normalized()
		var f := (gr - el).normalized()
		print(
			(
				"  upper_from_down=%.1f deg elbow_angle=%.1f deg"
				% [
					rad_to_deg(acos(clampf(-u.y, -1, 1))),
					rad_to_deg(acos(clampf(-u.dot(f), -1, 1)))
				]
			)
		)
	_print_cg(v, sk)
	var shl := v.pilot.transform.affine_inverse() * v.shoulder(-1)
	print("плечо в осях пилота от карабина: вниз %.4f вперёд %.4f; длины плечо %.4f, локоть-хват %.4f" % [-shl.y, -shl.z, ik.arm_lengths().x, ik.arm_lengths().y])
	print("hang_drop=", v.hang_drop_m, " pilot_xform=", v.pilot.transform)
	get_tree().quit(0)


## Центр масс тела (Winter: масса и положение центра сегмента) в осях пилота (начало — карабин),
## поза prone по анимации, без IK. Сегмент: [кость, кость-конец (или ""), доля массы, доля длины].
func _print_cg(v: GliderVisual, sk: Skeleton3D) -> void:
	var seg := [
		["Head_2", "", 0.081, 0.0], ["Chest", "", 0.497, 0.0],
		["UpperArm.L", "Forearm.L", 0.028, 0.436], ["UpperArm.R", "Forearm.R", 0.028, 0.436],
		["Forearm.L", "Hand.L", 0.022, 0.43], ["Forearm.R", "Hand.R", 0.022, 0.43],
		["Thigh.L", "Shin.L", 0.1, 0.433], ["Thigh.R", "Shin.R", 0.1, 0.433],
		["Shin.L", "Foot.L", 0.0465, 0.433], ["Shin.R", "Foot.R", 0.0465, 0.433],
		["Foot.L", "", 0.0145, 0.0], ["Foot.R", "", 0.0145, 0.0],
	]
	var to_p := v.pilot.global_transform.affine_inverse() * sk.global_transform
	var m := 0.0
	var c := Vector3.ZERO
	for sg in seg:
		var a: Vector3 = to_p * sk.get_bone_global_pose(sk.find_bone(sg[0])).origin
		var b := a
		if sg[1] != "":
			b = to_p * sk.get_bone_global_pose(sk.find_bone(sg[1])).origin
		elif sg[0] == "Chest":
			b = to_p * sk.get_bone_global_pose(sk.find_bone("Head_2")).origin
			a = to_p * sk.get_bone_global_pose(sk.find_bone("Hips")).origin
		var p := a.lerp(b, sg[3]) if sg[0] != "Chest" else a.lerp(b, 0.5)
		m += sg[2]
		c += p * sg[2]
	c /= m
	print("CG тела (скелет, Winter), оси пилота от карабина: y=%.3f z=%.3f (z>0 назад)  | body_below_hang_m=%.3f body_back_m=%.3f в конфиге" % [c.y, c.z, float(v._pcfg.body_below_hang_m), float(v._pcfg.body_back_m)])
