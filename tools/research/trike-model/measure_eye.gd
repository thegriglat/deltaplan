extends Node
## TK-1: замер точки глаз «Сидячей позы» (eye_mode back_hidden: PilotHead + back_offset_m) относительно HangPoint.
## Запуск: cp в tests/game/test_tk1_eye.gd, godot --headless --path . res://tests/run_tests.tscn -- --filter=test_tk1_eye (файл не коммитить).
## Печать: строки "EYE wing ..." (оси Blender: x вправо, y вперёд, z вверх; в осях планера и в осях горизонта).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _step(game: Game) -> void:
	game.tick(DT)
	var ap: AnimationPlayer = game.get("_animator").player
	if ap != null:
		ap.advance(DT)
	for sk: Skeleton3D in game.glider.visual.find_children("*", "Skeleton3D", true, false):
		sk.force_update_all_bone_transforms()
	for ba: BoneAttachment3D in game.glider.visual.find_children("*", "BoneAttachment3D", true, false):
		ba.on_skeleton_update()
	game.glider.call("_process", DT)
	game.camera.call("_process", DT)


func _bl(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(-v.z, 0.001), snappedf(v.y, 0.001)]


func test_tk1_eye() -> void:
	for wing in ["training", "apogee"]:
		var main: Node = MAIN_SCENE.instantiate()
		main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--autopilot", "--wing=" + wing])))
		add_child(main)
		var game: Game = main.get_node("Game")
		for i in 600:
			if main.get("state") == 2:
				break
			await get_tree().process_frame
		game.process_mode = Node.PROCESS_MODE_DISABLED
		game.camera.set_mode("cockpit")
		Config.get_config("camera").cockpit.eye_mode = "back_hidden"
		var air := 0.0
		for i in int(80.0 / DT):
			_step(game)
			if game.glider.phase() == "flying":
				air += DT
			if air >= 14.0 and game.get("_animator").current() == "prone":
				break
		check(game.glider.phase() == "flying", "в полёте")
		game.camera.set_look(0.0, 0.0)
		for i in 240:
			_step(game)
		var acc := Vector3.ZERO
		var n := 0
		for k in 16:
			for i in 120:
				_step(game)
			var hp := game.glider.get_marker("HangPoint")
			var cam := game.camera
			var head := game.glider.get_marker("PilotHead")
			var d := cam.global_position - hp.global_position
			var dh := head.global_position - hp.global_position
			var vis_b := game.glider.visual.global_basis
			# оси горизонта: рыскание — по носу планера (−Z визуала), без тангажа и крена
			var fwd := -vis_b.z
			var yaw := atan2(-fwd.x, -fwd.z)
			var hb := Basis(Vector3.UP, yaw)
			var pitch := rad_to_deg(asin(clampf(fwd.y, -1, 1)))
			var roll_up := vis_b.y
			var g := vis_b.inverse() * d
			acc += Vector3(g.x, -g.z, g.y)
			n += 1
			print("EYE %s k=%d cam_glider=%s head_glider=%s cam_level=%s hangpoint_basis_pitch=%.2f visual_pitch=%.2f speed=%.1f" % [
				wing, k, _bl(vis_b.inverse() * d), _bl(vis_b.inverse() * dh), _bl(hb.inverse() * d),
				rad_to_deg(asin(clampf((-hp.global_basis.z).y, -1, 1))), pitch, game.glider.get("velocity").length() if game.glider.get("velocity") != null else -1.0])
		print("EYEMEAN %s n=%d cam_glider_blender=%s" % [wing, n, acc / n])
		main.queue_free()
		for i in 2:
			await get_tree().process_frame
