extends TestCase
## Чужие пилоты (RemotePilots, NET-41) на поддельных состояниях, без сети: upsert создаёт узел
## вида с именем; фаза меняет позу; remove и «пропал» (нет состояний 5 с) убирают узел;
## 10 пилотов разом; разбор полей состояния (proto3 JSON: {x,y,z}, кватернион, PHASE_*).


func make() -> RemotePilots:
	var rp := RemotePilots.new()
	rp.ground_fn = func(_x: float, _z: float) -> float: return 100.0
	# Раннер тестов (корень занят его _ready — добавляем к нему).
	var tree_root := (Engine.get_main_loop() as SceneTree).root
	tree_root.get_child(tree_root.get_child_count() - 1).add_child(rp)
	return rp


func state(id: String, phase: String, pos: Vector3, extra: Dictionary = {}) -> Dictionary:
	var s := {
		"pilot_id": id,
		"is_bot": false,
		"name": "Пилот " + id,
		"t": 0.0,
		"pos": pos,
		"rot": Basis.from_euler(Vector3(0.0, -0.5, 0.0)),
		"vel": Vector3.ZERO,
		"phase": phase,
		"wing": "atlas",
		"colors": 2,
	}
	s.merge(extra, true)
	return s


func test_upsert_creates_node_with_name() -> void:
	var rp := make()
	var added: Array = []
	rp.pilot_added.connect(func(id: String) -> void: added.append(id))
	rp.upsert(state("7", "standing", Vector3(10, 100, 20)))
	check(rp.count() == 1, "один пилот")
	check(added == ["7"], "сигнал pilot_added")
	var p := rp.get_pilot(7)
	check(p != null and p.glider != null, "узел вида создан")
	check(p.glider.get_parent() == rp, "узел — ребёнок RemotePilots")
	check(p.glider.name_tag != null, "есть имя над крылом")
	check(p.agent.pilot_name == "Пилот 7", "имя из состояния")
	check(p.glider.global_position.distance_to(Vector3(10, 100, 20)) < 0.01, "стоит в pos")
	check(String(p.agent.wing_id) == "atlas", "крыло из состояния")
	check(float(p.agent.scheme.get("hue_deg", -1.0)) == 52.0, "расцветка №2 — жёлтый")
	rp.free()


func test_phase_changes_pose() -> void:
	var rp := make()
	rp.upsert(state("a", "standing", Vector3(0, 100, 0)))
	var p := rp.get_pilot("a")
	var anim := p.glider.animator
	var has_anim := anim.player != null
	check(p.agent.model.mode == FlightModel.Mode.GROUND, "стоит — на земле")
	if has_anim:
		check(anim.current() == "stand", "стоит: %s" % anim.current())
	rp.upsert(state("a", "PILOT_PHASE_WALK", Vector3(0, 100, 0), {"vel": Vector3(0, 0, -1.2)}))
	rp.tick(0.1)
	check(p.agent.state == BotAgent.State.WALK, "идёт")
	if has_anim:
		check(anim.current() == "walk", "идёт: %s" % anim.current())
	rp.upsert(state("a", "running", Vector3(0, 100, -5), {"vel": Vector3(0, 0, -5)}))
	rp.tick(0.1)
	if has_anim:
		check(anim.current() == "run", "бежит: %s" % anim.current())
	rp.upsert(state("a", "flying", Vector3(0, 130, -50), {"vel": Vector3(0, -1, -11)}))
	rp.tick(0.1)
	check(p.agent.model.mode == FlightModel.Mode.AIR, "летит — в воздухе")
	check(p.agent.state == BotAgent.State.FLY, "имя видно по-воздушному")
	if has_anim:
		check(anim.current() != "run" and anim.current() != "stand", "летит: %s" % anim.current())
	rp.upsert(state("a", "landed", Vector3(0, 100.5, -300)))
	rp.tick(0.1)
	check(p.agent.model.mode == FlightModel.Mode.LANDED, "сел")
	check(absf(p.glider.global_position.y - 100.0) < 0.01, "на земле — на рельефе")
	if has_anim:
		check(anim.current() == "stand", "сел — стоит: %s" % anim.current())
	check(has_anim, "у пилота есть анимации (pilot.glb)")
	rp.free()


func test_remove_and_lost() -> void:
	var rp := make()
	var removed: Array = []
	rp.pilot_removed.connect(func(id: String, why: String) -> void: removed.append([id, why]))
	rp.upsert(state("1", "flying", Vector3(0, 500, 0)))
	rp.upsert(state("2", "flying", Vector3(50, 500, 0)))
	var g1: Node = rp.get_pilot("1").glider
	rp.remove("1")
	check(not rp.has_pilot("1") and rp.count() == 1, "remove убирает пилота")
	check(g1.is_queued_for_deletion(), "и его узел")
	# «Пропал»: 2 молчит 5 с — убирается; пока шлёт — живёт.
	for i in 40:
		rp.tick(0.1)
	check(rp.has_pilot("2"), "4 с без состояний — ещё есть")
	rp.upsert(state("2", "flying", Vector3(50, 500, 0)))
	for i in 45:
		rp.tick(0.1)
	check(rp.has_pilot("2"), "свежее состояние продлевает")
	for i in 10:
		rp.tick(0.1)
	check(not rp.has_pilot("2"), "5 с без состояний — пропал")
	check(removed == [["1", "left"], ["2", "lost"]], "сигналы: %s" % str(removed))
	rp.free()


func test_ten_pilots() -> void:
	var rp := make()
	for i in 10:
		var ph := "flying" if i % 2 == 0 else "standing"
		rp.upsert(state(str(i), ph, Vector3(i * 20.0, 100.0 + (200.0 if i % 2 == 0 else 0.0), 0)))
	for k in 30:
		rp.tick(1.0 / 60.0)
	check(rp.count() == 10, "10 пилотов")
	var nodes := 0
	for c in rp.get_children():
		if c is BotGlider:
			nodes += 1
	check(nodes == 10, "10 узлов вида: %d" % nodes)
	check(rp.pilots().size() == 10, "pilots() — все 10")
	rp.clear()
	check(rp.count() == 0, "clear убирает всех")
	rp.free()


func test_proto_json_fields_and_external_pose() -> void:
	var rp := make()
	var q := Quaternion(Vector3.UP, 0.7)
	(
		rp
		. upsert(
			{
				"pilot_id": 42,
				"name": "Оля",
				"pos": {"x": 1.0, "y": 300.0, "z": -2.0},
				"rot": {"x": q.x, "y": q.y, "z": q.z, "w": q.w},
				"vel": [0.0, -1.0, -10.0],
				"phase": 4,
				"wing": "wings/sport",
				"colors": {"hue_deg": 222.0, "sat": 1.0, "value": 1.0},
			}
		)
	)
	var p := rp.get_pilot("42")
	check(p.phase == "flying", "enum 4 — flying")
	check(p.wing == "sport", "wings/sport → sport")
	check(p.basis.get_rotation_quaternion().is_equal_approx(q), "кватернион")
	# Без set_pose — последнее состояние, продлённое по скорости.
	rp.tick(0.2)
	approx(p.glider.global_position.z, -4.0, 0.01, "продление по скорости 0,2 с")
	# С set_pose — поза от интерполяции, upsert позу больше не двигает.
	rp.set_pose(42, Vector3(5, 310, 5), Basis.IDENTITY, Vector3.ZERO, "flying")
	rp.tick(0.02)
	check(p.glider.global_position.distance_to(Vector3(5, 310, 5)) < 0.01, "поза из set_pose")
	rp.upsert({"pilot_id": 42, "pos": Vector3(99, 99, 99), "name": "Оля К."})
	rp.tick(0.02)
	check(p.glider.global_position.distance_to(Vector3(5, 310, 5)) < 0.01, "upsert позу не трогает")
	check(p.agent.pilot_name == "Оля К.", "а имя обновляет")
	rp.upsert({"pilot_id": 42, "wing": "bogus"})
	check(p.wing != "bogus" and p.glider != null, "неизвестное крыло — запасное")
	rp.free()


## Как отдаёт NetMessages.decode: lowerCamelCase, фаза — имя PilotPhase, colors — WingColors.
func test_decoded_pilot_state() -> void:
	var rp := make()
	var s := {
		"pilotId": "bot-3",
		"isBot": true,
		"name": "Саша",
		"t": 12.5,
		"pos": {"x": 0.0, "y": 400.0, "z": 0.0},
		"rot": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
		"vel": {"x": 0.0, "y": 0.0, "z": -11.0},
		"phase": "PILOT_PHASE_FLY",
		"wing": "wings/atlas",
		"colors": {"hueDeg": 125.0, "sat": 0.9, "value": 0.9},
	}
	rp.upsert(s)
	var p := rp.get_pilot("bot-3")
	check(p != null and p.is_bot and p.phase == "flying", "бот, летит")
	approx(float(p.agent.scheme.hue_deg), 125.0, 1e-3, "тон из WingColors")
	s.phase = "PILOT_PHASE_TOW"
	rp.upsert(s)
	check(p.agent.model.mode == FlightModel.Mode.AIR, "буксир — поза полёта")
	s.phase = "PILOT_PHASE_CRASHED"
	s.colors = null
	rp.upsert(s)
	check(p.phase == "crashed" and p.agent.model.mode == FlightModel.Mode.LANDED, "авария")
	check(p.agent.scheme.is_empty(), "colors null — родная текстура")
	rp.free()
