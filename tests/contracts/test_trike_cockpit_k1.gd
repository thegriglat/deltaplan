extends Node
## Контракт TC-К1 (docs/contracts/trike-cockpit.md), инварианты 1-6: приборы дельталёта видны и показывают из кабины.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _game(vehicle: String) -> Array:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--location=wilotree_park", "--vehicle=" + vehicle])))
	add_child(main)
	for i in 3000:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	return [main, game]


## Кадры игрового цикла: tick + обновление кабинной камеры.
func _frames(game: Game, n: int) -> void:
	for i in n:
		game.tick(DT)
		game.camera._update_cockpit(game.glider.global_transform, DT)
	await get_tree().process_frame


func _dials(game: Game) -> Array:
	var tg := game.trike_gauges
	return [tg.get_node("RpmFace") as MeshInstance3D, tg.get_node("FuelFace") as MeshInstance3D]


## Ширина лица в мире, м (по AABB квада).
func _dial_info(mi: MeshInstance3D, cam: Camera3D) -> Dictionary:
	var bb := mi.global_transform * mi.get_aabb()
	var c := bb.get_center()
	var eye := cam.global_position
	var n: Vector3 = (mi.get_parent() as Node3D).global_basis.z.normalized()
	var d := (mi.mesh as QuadMesh).size.x
	var dist := eye.distance_to(c)
	return {
		"center": c,
		"front": n.dot(eye - c),
		"in_frustum": cam.is_position_in_frustum(c),
		"ahead": (-cam.global_basis.z).dot(c - eye) > 0.0,
		"ang_deg": rad_to_deg(2.0 * atan(d * 0.5 / maxf(dist, 1e-6))),
	}


func test_contract_version() -> void:
	var txt := FileAccess.get_file_as_string("res://docs/contracts/trike-cockpit.md")
	var m := RegEx.create_from_string("(?m)^## TC-К1 v(\\d+)\\.").search(txt)
	check(m != null and m.get_string(1) == "1", "версия раздела TC-К1 - v1")


func test_trike_cockpit_dials() -> void:
	var r := await _game("trike")
	var main: Node = r[0]
	var game: Game = r[1]
	var g := game.glider
	game.camera.set_mode("cockpit")
	game.camera.snap()
	await _frames(game, 6)
	var cam := game.camera
	check(cam.mode == "cockpit", "режим кабины")
	var tg := game.trike_gauges
	check(tg != null and tg.is_visible_in_tree(), "1: TrikeGauges3D в дереве и видим")
	var panel := g.get_marker("InstrumentPanel")
	check(tg != null and panel != null and panel.is_ancestor_of(tg), "1: потомок InstrumentPanel")
	if tg == null:
		main.queue_free()
		return
	for n in tg.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		check((vi.layers & cam.cull_mask) != 0, "1: %s рисуется кабинной камерой (layers %x, cull %x)" % [vi.name, vi.layers, cam.cull_mask])
		check(vi.is_visible_in_tree(), "1: %s видим в дереве" % vi.name)
	for mi: MeshInstance3D in _dials(game):
		var inf := _dial_info(mi, cam)
		print("TC-К1 ", mi.name, ": ", inf)
		check(inf.in_frustum and inf.ahead, "2: центр %s в пирамиде видимости перед камерой: %s" % [mi.name, inf])
		check(inf.front > 0.0, "3: лицо %s к глазу: dot=%f" % [mi.name, inf.front])
		check(inf.ang_deg >= 3.0, "4: угловой диаметр %s >= 3 град: %f" % [mi.name, inf.ang_deg])
	# 5: показания в игровом цикле
	game.input_controller.hands_off = false
	g.engine.step(DT, 0.0, 0.0, true)
	await _frames(game, 120 * 6)
	check(g.engine.state == "running", "двигатель запущен: %s" % g.engine.state)
	var sc: Dictionary = tg._sc
	var rr: Dictionary = sc["rpm"]
	var ff: Dictionary = sc["fuel"]
	for step in 2:
		if step == 1:
			g.engine.throttle = 0.8
			await _frames(game, 120 * 3)
		var want_r := GaugeDial.needle_angle_deg(g.engine.engine_rpm, 0.0, float(rr["max_rpm"]),
			float(rr.get("angle_min_deg", 135.0)), float(rr.get("angle_max_deg", -135.0)))
		var want_f := GaugeDial.needle_angle_deg(g.engine.fuel_l, 0.0, g.engine.tank_l,
			float(ff.get("angle_min_deg", 60.0)), float(ff.get("angle_max_deg", -60.0)))
		var got_r := tg.rpm_needle.rotation_degrees.z
		var got_f := tg.fuel_needle.rotation_degrees.z
		print("TC-К1 rpm=", g.engine.engine_rpm, " got/want=", got_r, "/", want_r, " fuel=", g.engine.fuel_l, " got/want=", got_f, "/", want_f)
		check(g.engine.engine_rpm > 100.0, "5: обороты > 100: %f" % g.engine.engine_rpm)
		check(absf(got_r - want_r) <= 0.5, "5: RpmNeedle %f против %f" % [got_r, want_r])
		check(absf(got_f - want_f) <= 0.5, "5: FuelNeedle %f против %f" % [got_f, want_f])
	main.queue_free()


func test_glider_cockpit_unchanged() -> void:
	var r := await _game("glider")
	var main: Node = r[0]
	var game: Game = r[1]
	check(not game.glider.is_trike() and game.trike_gauges == null, "6: glider без приборов дельталёта")
	check(game.glider.get_marker("InstrumentMount") != null, "6: маркер InstrumentMount есть")
	main.queue_free()

