extends Node
## Контракт TC-К1 (docs/contracts/trike-cockpit.md), инвариант 7 (tools/gpu_tests.sh): тахометр дельталёта
## нарисован кабинной камерой и стрелка двигает пиксели.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const SHOT_DIR := "res://build/screenshots/trike-cockpit/"

var failures: PackedStringArray = []


func needs_gpu() -> bool:
	return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _game() -> Array:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--location=wilotree_park", "--vehicle=trike"])))
	add_child(main)
	for i in 3000:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	return [main, game]


## Кадр кабины при заданных оборотах.
func _shot(game: Game, rpm: float) -> Image:
	var e := game.glider.engine
	e.engine_rpm = rpm
	e.running = rpm > 0.0
	game._update_trike_gauges()
	game.camera._update_cockpit(game.glider.global_transform, DT)
	for i in 6:
		await get_tree().process_frame
	return get_viewport().get_texture().get_image()


func _rect(mi: MeshInstance3D, cam: Camera3D, size: Vector2) -> Rect2i:
	var bb := mi.global_transform * mi.get_aabb()
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for i in 8:
		var p := cam.unproject_position(bb.get_endpoint(i))
		mn = mn.min(p)
		mx = mx.max(p)
	var win := get_viewport().get_visible_rect().size
	var k := size / win
	mn = (mn * k).max(Vector2.ZERO)
	mx = (mx * k).min(size - Vector2.ONE)
	return Rect2i(Vector2i(mn), Vector2i((mx - mn).max(Vector2.ONE)))


func test_tacho_drawn_and_moves_gpu() -> void:
	var r := await _game()
	var main: Node = r[0]
	var game: Game = r[1]
	var cam := game.camera
	cam.set_mode("cockpit")
	cam.snap()
	for i in 6:
		game.tick(DT)
		cam._update_cockpit(game.glider.global_transform, DT)
		await get_tree().process_frame
	var tg := game.trike_gauges
	check(tg != null, "TrikeGauges3D создан")
	if tg == null:
		main.queue_free()
		return
	var max_rpm := float((tg._sc["rpm"] as Dictionary)["max_rpm"])
	var a := await _shot(game, 0.0)
	var b := await _shot(game, 0.85 * max_rpm)
	var rect := _rect(tg.get_node("RpmFace") as MeshInstance3D, cam, Vector2(a.get_size()))
	var changed := 0
	var lum := 0.0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b))) > 10.0 / 255.0:
				changed += 1
			lum += (cb.r + cb.g + cb.b) / 3.0
	var area := float(rect.size.x * rect.size.y)
	var frac := changed / area
	var mean := lum / area
	print("TC-К1 GPU: rect=", rect, " changed=", changed, " доля=", frac, " яркость=", mean, " окно=", a.get_size())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var pad := Rect2i(rect.position - Vector2i(30, 30), rect.size + Vector2i(60, 60))
	for pair: Array in [["rpm0", a], ["rpm85", b]]:
		var crop: Image = (pair[1] as Image).get_region(pad)
		crop.resize(crop.get_width() * 3, crop.get_height() * 3, Image.INTERPOLATE_NEAREST)
		crop.save_png(ProjectSettings.globalize_path(SHOT_DIR + "tc1_%s_crop.png" % pair[0]))
	a.save_png(ProjectSettings.globalize_path(SHOT_DIR + "tc1_rpm0.png"))
	b.save_png(ProjectSettings.globalize_path(SHOT_DIR + "tc1_rpm85.png"))
	check(frac >= 0.02, "7: изменившихся пикселей >= 2 %%: %f" % frac)
	check(mean >= 0.05, "7: яркость тахометра >= 0,05: %f" % mean)
	main.queue_free()
