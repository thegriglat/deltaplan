extends Node
## TK-14: замер центра базовой штанги (маркер BaseBar) относительно HangPoint в осях тележки на триме и на крайних
## положениях трапеции по тангажу (полное «от себя» full_push / «на себя» full_pull), крыло training, режим «Маятник».
## Запуск: cp в tests/game/test_tk14_bar.gd, godot --headless --path . res://tests/run_tests.tscn -- --filter=test_tk14_bar
## (файл не коммитить). Печать "BAR ..." — оси Blender (x вправо, y вперёд, z вверх), от HangPoint.
## Оси тележки = оси визуала крыла при трима (как eye_measured); при отклонении — повёрнуты на поворот тела пилота
## (тело висит вдоль цепи маятника) относительно тримма: bar_T = Q · P⁻¹ · (BaseBar − HangPoint), Q = V0⁻¹ · P0.

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


func _sample(game: Game, tag: String, q: Basis, wing_cfg_note: String) -> Vector3:
	var hp := game.glider.get_marker("HangPoint")
	var bb := game.glider.get_marker("BaseBar")
	var vis := game.glider.visual
	var pb: Basis = vis.pilot.global_basis
	var vb: Basis = vis.global_basis
	var d := bb.global_position - hp.global_position
	var in_wing := vb.inverse() * d
	var in_trike := q * (pb.inverse() * d)
	var cam := game.camera.global_position - hp.global_position
	print("BAR %s pitch_in=%.2f wing_axes=%s trike_axes=%s eye_wing=%s eye_trike=%s" % [
		tag, game.glider.control.pitch, _bl(in_wing), _bl(in_trike), _bl(vb.inverse() * cam), _bl(q * (pb.inverse() * cam))])
	return in_trike


func test_tk14_bar() -> void:
	for dirn in ["pull", "push"]:
		await _one(dirn)


func _one(dirn: String) -> void:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--autopilot", "--wing=training"])))
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
	game.autopilot.release_all()
	game.autopilot = null
	var ic := game.input_controller
	ic.mouse_captured = true
	game.camera.set_look(0.0, 0.0)
	for i in 600:
		_step(game)
	print("BAR pendulum=%s" % game.glider.is_pendulum())
	var q := Basis.IDENTITY
	var vis := game.glider.visual
	q = vis.global_basis.inverse() * vis.pilot.global_basis  # Q = V0⁻¹·P0 (трим)
	for stage in [["trim", 0.0], [dirn, -1.0 if dirn == "push" else 1.0]]:
		for k in 8:
			for i in 60:
				ic._mouse_offset.y = float(stage[1])
				_step(game)
			_sample(game, "%s k=%d" % [stage[0], k], q, "")
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
