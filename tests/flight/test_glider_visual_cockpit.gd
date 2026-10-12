extends Node
## PH-9 / PH-К5: GliderVisual.set_cockpit_body("hands") рисует в кабине только материалы из
## cockpit_visible_materials; в prone в кадре нет поверхностей головы, шеи, груди и кокона.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_glider_visual_cockpit_materials() -> void:
	var v := _build("sport")
	_pose(v, "prone")
	v.cockpit_visible_materials = ["Glove", "JacketSleeve", "Trousers", "Boot", "Sole"]
	v.set_cockpit_body("hands")
	var hands := v.find_child("PilotHands", true, false) as MeshInstance3D
	check(hands != null, "есть PilotHands")
	if hands != null:
		var shown: PackedStringArray = []
		for i in hands.mesh.get_surface_count():
			var mn := hands.mesh.surface_get_material(i).resource_name if hands.mesh.surface_get_material(i) != null else ""
			var ov := hands.get_surface_override_material(i) as ShaderMaterial
			var vis := ov == null or ov.shader == null or not ov.shader.code.contains("discard")
			print("         поверхность %d %s: %s" % [i, mn, "видна" if vis else "скрыта"])
			if vis:
				shown.append(mn)
		for mn in shown:
			var ok := false
			for pre in ["Glove", "JacketSleeve", "Trousers", "Boot", "Sole"]:
				ok = ok or mn.begins_with(pre)
			check(ok, "в кабине не рисуется " + mn)
		check(shown.has("Glove") and shown.has("Boot"), "перчатки и ботинки видны")
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
