extends Node
## Тень от неба видна из кабины и внешних камер (PH-8, PH-К7): в кабине рисуются только перчатки и
## мир, декаль — на слое 1, который рисует любой режим камеры.

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_sky_shade_cockpit_visible_to_every_camera() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--autopilot"])))
	add_child(main)
	for i in 6000:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	if main.get("state") == 2:
		var game: Game = main.get_node("Game")
		var ss := game.glider.visual.sky_shade
		check(ss != null, "у визуала есть SkyShade")
		if ss != null:
			var decal := ss.get_node("Decal") as Decal
			for mode in ["cockpit", "chase", "free"]:
				game.camera.set_mode(mode)
				check((decal.layers & game.camera.cull_mask) != 0, "декаль видна камерой %s" % mode)
			game.camera.set_mode("cockpit")
			var body_only := game.glider.visual.find_child("PilotHands", true, false)
			check(body_only == null or (body_only as VisualInstance3D).layers != decal.layers, "декаль не на слое перчаток")
	main.queue_free()
	await get_tree().process_frame
