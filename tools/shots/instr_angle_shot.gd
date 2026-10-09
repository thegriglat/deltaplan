extends Node3D
## Числа: угол лицевой плоскости приборов к горизонту и угол нормали экрана к лучу камера→прибор.
## godot --headless --path . res://tools/shots/instr_angle_shot.tscn -- [--wing=training]


func _ready() -> void:
	var wing := "training"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--wing="):
			wing = a.substr(7)
	var v := GliderVisual.new()
	add_child(v)
	v.build(
		Config.get_config("wings/" + wing),
		Config.get_config("pilot"),
		Config.get_config("flight").visual
	)
	var aps := v.find_children("*", "AnimationPlayer", true, false)
	if not aps.is_empty():
		(aps[0] as AnimationPlayer).play("prone", 0.0)
		(aps[0] as AnimationPlayer).advance(0.3)
		(aps[0] as AnimationPlayer).pause()
	for i in 4:
		v.set_pose(0.0, 0.0, true, 1.0e6)
		await get_tree().process_frame
	var head := v.get_marker("PilotHead") as Node3D
	print("instr_angle: PilotHead=", head.global_position)
	for mn: String in ["HangPoint", "BaseBar", "UprightTopL", "UprightBottomL", "BarGripL"]:
		print("instr_angle: ", mn, " ", (v.get_marker(mn) as Node3D).global_position)
	for mn: String in ["InstrumentMount", "VarioMount"]:
		var m := v.get_marker(mn) as Node3D
		# экран (после rotate_y 180° сцены прибора) смотрит в −Z маркера
		var n := -m.global_transform.basis.z
		var to_eye := (head.global_position - m.global_position).normalized()
		print(
			"instr_angle: %s pos=%s normal=%s plane_to_horizon=%.1f deg normal_vs_eye_ray=%.1f deg"
			% [mn, m.global_position, n, 90.0 - rad_to_deg(asin(clampf(n.y, -1, 1))),
				rad_to_deg(n.angle_to(to_eye))]
		)
	get_tree().quit(0)
