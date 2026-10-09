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
	print("hang_drop=", v.hang_drop_m, " pilot_xform=", v.pilot.transform)
	get_tree().quit(0)
