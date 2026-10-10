extends Node
## G05. Столкновения (VR-10, VR-12): посадка в лес → crash_trees, посадка на поле → landed.
## Проверка — CollisionCheck за шаг ≤ 0,1 мс. Физика — Game.tick() вручную (как test_gameplay).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _open() -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart"])))
	add_child(main)
	for i in 1200:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт — в полёте")
	if main.get("state") != 2:
		await _close(main)
		return null
	var game: Game = main.get_node("Game")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	return main


func _close(main: Node) -> void:
	main.queue_free()
	for i in 2:
		await get_tree().process_frame


static func _heading(dir: Vector3) -> float:
	return rad_to_deg(atan2(dir.x, -dir.z))


## Полёт из pos курсом heading_deg до итога или seconds: [kind, info] или [].
func _fly(game: Game, pos: Vector3, heading_deg: float, seconds: float) -> Array:
	var ended: Array = []
	var cb := func(k: String, i: Dictionary) -> void: ended.append([k, i])
	game.flight_ended.connect(cb)
	game.restart()
	game.glider.reset_in_air(pos, heading_deg)
	for i in int(seconds / DT):
		game.tick(DT)
		if not ended.is_empty():
			break
	game.flight_ended.disconnect(cb)
	return ended[0] if not ended.is_empty() else []


## Точка и курс, где впереди 150 м сплошного леса.
func _pick_forest(game: Game) -> Array:
	var st: Vector3 = game.get_start().position
	for r in range(100, 4000, 100):
		for a in range(0, 360, 30):
			var p := st + Vector3(sin(deg_to_rad(a)), 0.0, cos(deg_to_rad(a))) * r
			for h in [0.0, 90.0, 180.0, 270.0]:
				var dir := Vector3(sin(deg_to_rad(h)), 0.0, -cos(deg_to_rad(h)))
				var ok := true
				for k in range(-20, 160, 10):
					var q := p + dir * k
					if game.terrain.forest_at(q.x, q.z) < 0.9:
						ok = false
						break
				if ok:
					return [p, h]
	return []


func test_collisions_in_real_world() -> void:
	var main: Node = await _open()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var t := game.terrain
	# Игра при открытии выставляет язык из настроек — тексты проверяем по-русски.
	var was_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("ru")

	# 1. Снижение в лес — задел кроны, crash_trees.
	var f := _pick_forest(game)
	check(not f.is_empty(), "есть лес")
	if not f.is_empty():
		var p: Vector3 = f[0]
		p.y = t.height_at(p.x, p.z) + game.collisions.crown_agl_m + 4.0
		var r := _fly(game, p, float(f[1]), 12.0)
		check(
			not r.is_empty() and r[1].finish_reason == "crash_trees",
			"в лес → crash_trees: %s" % [r]
		)

	# 2. Посадка на поле — обычная посадка.
	var sites: Array = game.world_link.objects.get_landing_sites()
	check(not sites.is_empty(), "есть посадочная площадка")
	if not sites.is_empty():
		var s: Dictionary = sites[0]
		var ax := float(s.axis_deg)
		var dir := Vector3(sin(deg_to_rad(ax)), 0.0, -cos(deg_to_rad(ax)))
		var p: Vector3 = s.position - dir * float(s.length_m) * 0.35
		check(t.forest_at(p.x, p.z) < CollisionCheck.FOREST_MIN, "поле не в лесу")
		p.y = t.height_at(p.x, p.z) + 3.0
		var r := _fly(game, p, ax, 20.0)
		check(not r.is_empty() and r[0] == "landed", "посадка: %s" % [r])
		if not r.is_empty():
			check(r[1].finish_reason == "landed", "finish_reason: %s" % r[1].get("finish_reason"))
			check(not r[1].has("collision"), "без столкновения: %s" % r[1].get("collision"))
	TranslationServer.set_locale(was_locale)
	await _close(main)


## Без сцены: выше 60 м и стоя на земле — не проверяется; высота крон из пород.
func test_collision_check_unit() -> void:
	var cc := CollisionCheck.new()
	var forest := func(_x: float, _z: float) -> float: return 1.0
	cc.setup(null, forest, 10.0, 2.0)
	var trees := {"sink_fraction": 0.4, "species": {"a": {"height_m": [12, 20]}}}
	check(is_equal_approx(CollisionCheck.crown_height(trees), 7.2), "кроны 12 × 0,6 м")
	var t := Telemetry.new()
	t.phase = "flying"
	t.on_ground = false
	t.altitude_agl = cc.crown_agl_m + 1.0
	check(cc.check(t).is_empty(), "над кронами")
	t.altitude_agl = cc.crown_agl_m - 1.0
	check(cc.check(t).get("reason", "") == "crash_trees", "в кронах")
	t.on_ground = true
	t.phase = "standing"
	check(cc.check(t).is_empty(), "стоя на земле — нет")
