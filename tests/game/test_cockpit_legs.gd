extends Node
## PH-9 / PH-К5: тело пилота в кабинной камере. В позе flare носки ботинок в поле зрения камеры
## по умолчанию (оба eye_mode); в prone в кадре нет поверхностей головы, шеи и груди.
## Считается по геометрии (без рендера): вершины поверхностей PilotBody со скинингом.

const WINGS: Array[String] = ["sport"]
var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_legs_in_view_in_flare() -> void:
	var cam_cfg: Dictionary = Config.get_config("camera")
	var ck: Dictionary = cam_cfg.cockpit
	var half_fov := float(cam_cfg.fov_deg) * 0.5
	for wing in WINGS:
		var v := _build(wing)
		for anim in ["flare", "climb_out"]:
			_pose(v, anim)
			for mode in ["back_hidden", "eyes"]:
				var off := Vector3(ck.back_offset_m[0], ck.back_offset_m[1], ck.back_offset_m[2]) if mode == "back_hidden" else Vector3.ZERO
				var eye := v.head_marker.position + off
				var down := deg_to_rad(float(ck.look_down_deg))
				var axis := Vector3(0, -sin(down), -cos(down))
				var toes := _surface_points(v, ["Boot", "Sole"])
				check(not toes.is_empty(), "есть точки Boot/Sole")
				# носок — самая передняя (−Z) точка ботинка; также мин. угол любой точки ботинка
				var best := 180.0
				var tip := Vector3.ZERO
				var tz := 1e9
				for p in toes:
					best = minf(best, rad_to_deg((p - eye).angle_to(axis)))
					if p.z < tz:
						tz = p.z
						tip = p
				var tip_ang := rad_to_deg((tip - eye).angle_to(axis))
				print("         %s %s %s: носок %.1f° от оси взгляда (полполя %.0f°), ближайшая точка ботинка %.1f°, eye=%s tip=%s" % [wing, anim, mode, tip_ang, half_fov, best, eye, tip])
				if anim == "flare":
					check(tip_ang < half_fov, "%s flare %s: носок в поле зрения (%.1f°)" % [wing, mode, tip_ang])
		v.queue_free()


func _build(wing: String) -> GliderVisual:
	var vis_cfg: Dictionary = Config.get_config("flight").visual
	var v := GliderVisual.new()
	add_child(v)
	v.build(Config.get_config("wings/" + wing), Config.get_config("pilot"), vis_cfg)
	return v


func _pose(v: GliderVisual, anim: String) -> void:
	var ap: AnimationPlayer = v.find_children("*", "AnimationPlayer", true, false)[0]
	ap.play(anim, 0.0)
	ap.advance(3.0)
	for sk: Skeleton3D in v.find_children("*", "Skeleton3D", true, false):
		sk.force_update_all_bone_transforms()
	for ba: BoneAttachment3D in v.find_children("*", "BoneAttachment3D", true, false):
		ba.on_skeleton_update()
	v.set_pose(0.0, 0.0, anim == "prone", 1.0e6)


## Вершины поверхностей PilotBody с материалом на данный префикс, в координатах визуала (скининг).
func _surface_points(v: GliderVisual, prefixes: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var mi := v.find_child("PilotBody", true, false) as MeshInstance3D
	var sk := mi.get_node(mi.skeleton) as Skeleton3D
	var skin := mi.skin
	var to_v := Transform3D.IDENTITY
	var n: Node = mi
	while n != null and n != v:
		if n is Node3D:
			to_v = (n as Node3D).transform * to_v
		n = n.get_parent()
	for s in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(s)
		var ok := false
		for pre in prefixes:
			if m != null and m.resource_name.begins_with(pre):
				ok = true
		if not ok:
			continue
		var arr := mi.mesh.surface_get_arrays(s)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / maxi(vs.size(), 1)
		var skel_to_v := _rel(v, sk)
		for i in vs.size():
			var p := Vector3.ZERO
			for k in per:
				var wt := w[i * per + k]
				if wt <= 0.0:
					continue
				var b := bones[i * per + k]
				var bi := skin.get_bind_bone(b) if skin.get_bind_bone(b) >= 0 else b
				p += wt * ((sk.get_bone_global_pose(bi) * skin.get_bind_pose(b)) * vs[i])
			out.append(skel_to_v * p)
	return out


func _rel(root: Node, node: Node3D) -> Transform3D:
	var x := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			x = (n as Node3D).transform * x
		n = n.get_parent()
	return x
