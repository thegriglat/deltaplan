extends Node
## Контракт TP-К8 (docs/contracts/trike-pilot.md): вид, камера, приборы и звук дельталёта игрока в игре.

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


func test_contract_version() -> void:
	var txt := FileAccess.get_file_as_string("res://docs/contracts/trike-pilot.md")
	var m := RegEx.create_from_string("(?m)^## TP-К8 v(\\d+)\\.").search(txt)
	check(m != null and m.get_string(1) == "1", "версия раздела TP-К8 - v1")


func test_update_parts() -> void:
	var v := TowTrikeVisual.new()
	add_child(v)
	v.setup(Config.get_config("tow_tug").engine, false)
	var hp := Vector3(1.0, 2.0, 3.0)
	v.update_parts(hp, Basis.IDENTITY, Basis.IDENTITY, 1200.0, 0.5)
	check(v.cart != null and v.cart.position.is_equal_approx(hp), "тележка в hang_pos")
	check(v.prop_anim != null and absf(v.prop_anim.speed_scale - 20.0) < 0.2, "speed_scale = prop_rpm/60")
	v.update_parts(hp, Basis.IDENTITY, Basis.IDENTITY, 0.0, 0.0)
	check(v.prop_anim.speed_scale == 0.0, "заглушен - винт стоит")
	check(v.get_marker("InstrumentMount") == null and v.get_marker("VarioMount") == null, "маркеров крыла дельтаплана нет")
	v.queue_free()


func test_trike_in_game() -> void:
	var r := await _game("trike")
	var main: Node = r[0]
	var game: Game = r[1]
	var g := game.glider
	check(g.is_trike() and g.visual == null and g.trike_visual != null, "вид дельталёта вместо GliderVisual")
	var tv := g.trike_visual
	check(tv.cart != null and tv.cart.find_child("Propeller", true, false) != null, "тележка с винтом")
	check(tv.wing != null and tv.pilot != null, "крыло и пилот")
	# пилот сидит
	var playing := ""
	for ap: AnimationPlayer in tv.pilot.find_children("*", "AnimationPlayer", true, false):
		playing = ap.current_animation
	check(playing == "sit", "пилот в позе sit: %s" % playing)
	# винт от оборотов: запуск и холостые
	game.input_controller.hands_off = false
	g.engine.step(DT, 0.0, 0.0, true)  # нажатие «запуск» (ввод игры перезаписывает control каждый тик)
	for i in 120 * 6:
		game.tick(DT)
	check(g.engine.state == "running", "двигатель запущен: %s" % g.engine.state)
	g._process(0.0)
	var want: float = g.engine.prop_rpm / 60.0
	check(want > 1.0 and absf(tv.prop_anim.speed_scale / want - 1.0) <= 0.01, "speed_scale = prop_rpm/60 (%f против %f)" % [tv.prop_anim.speed_scale, want])
	check(tv.sound != null and tv.sound.playing, "звук двигателя играет")
	# приборы
	check(game.trike_gauges != null, "TrikeGauges3D создан")
	var panel := g.get_marker("InstrumentPanel")
	check(panel != null and game.trike_gauges != null and panel.is_ancestor_of(game.trike_gauges), "TrikeGauges3D - потомок InstrumentPanel")
	check(g.get_marker("InstrumentMount") == null and g.get_marker("VarioMount") == null, "маркеры крыла дельтаплана - null")
	if game.trike_gauges != null:
		var ang := game.trike_gauges.rpm_needle.rotation_degrees.z
		var sc: Dictionary = game.trike_gauges._sc
		var rr: Dictionary = sc["rpm"]
		var want_ang := GaugeDial.needle_angle_deg(g.engine.engine_rpm, 0.0, float(rr["max_rpm"]),
			float(rr.get("angle_min_deg", 135.0)), float(rr.get("angle_max_deg", -135.0)))
		check(g.engine.engine_rpm > 100.0 and absf(ang - want_ang) <= 0.5, "стрелка = engine_rpm по шкале: %f против %f" % [ang, want_ang])
		# каждый кадр: сбить стрелку - tick вернёт
		game.trike_gauges.rpm_needle.rotation_degrees.z = 1234.0
		game.tick(DT)
		check(absf(game.trike_gauges.rpm_needle.rotation_degrees.z - 1234.0) > 1.0, "update_readout доходит до прибора каждый кадр")
		# пауза гасит звук двигателя, снятие паузы возвращает
		game.set_paused(true)
		check(not tv.sound.playing, "пауза: звук двигателя молчит")
		g._process(0.0)
		check(not tv.sound.playing, "пауза: звук не оживает по кадрам")
		game.set_paused(false)
		g._process(0.0)
		check(tv.sound.playing, "снятие паузы: звук двигателя вернулся")
		check(sc.has("tank_l"), "шкалы прибора")
	# HUD: chase виден, cockpit скрыт
	game.camera.set_mode("chase")
	game._update_overlay()
	check(game.trike_hud.is_shown(), "HUD виден в chase")
	game.camera.set_mode("cockpit")
	game._update_overlay()
	check(not game.trike_hud.is_shown(), "HUD скрыт в cockpit")
	# камера: глаз в голове
	var head := g.get_marker("PilotHead")
	check(head != null, "PilotHead есть")
	check(game.camera.head == head, "камера смотрит из PilotHead")
	game.camera.snap()
	game.camera._update_cockpit(g.global_transform, 0.0)
	check(game.camera.global_position.distance_to(head.global_position) <= 0.15, "глаз <= 0,15 м от головы: %f" % game.camera.global_position.distance_to(head.global_position))
	# тело пилота скрыто от кабины
	var hidden := true
	var hid_bit := 1 << (int(Config.get_config("camera").cockpit.get("hidden_layer", 20)) - 1)
	for n in tv.pilot.find_children("*", "VisualInstance3D", true, false):
		hidden = hidden and ((n as VisualInstance3D).layers == hid_bit)
	check(hidden, "тело пилота на скрытом от кабины слое")
	# нормаль панели - к пилоту
	if panel != null and head != null:
		var to_head := (head.global_position - panel.global_position).normalized()
		check(panel.global_basis.z.dot(to_head) > 0.0, "нормаль панели (+Z) смотрит на пилота: %f" % panel.global_basis.z.dot(to_head))
	main.queue_free()


func test_glider_unchanged() -> void:
	var r := await _game("glider")
	var main: Node = r[0]
	var game: Game = r[1]
	var g := game.glider
	check(not g.is_trike() and g.visual != null and g.trike_visual == null, "дельтаплан - прежний вид")
	check(g.get_marker("InstrumentMount") != null, "маркер InstrumentMount есть")
	check(game.camera.eye_offset_enabled, "смещение сидячей позы применяется")
	check(not game.trike_hud.is_shown(), "HUD дельталёта скрыт")
	main.queue_free()
