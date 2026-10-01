extends Node
## CF-2: мышь в режиме "bar" (controls.json → mouse.mode) управляет трапецией в загруженной сцене
## полёта. События идут через настоящий вьюпорт (Viewport.push_input: GUI → _unhandled_input),
## а не прямым вызовом _unhandled_input — так видно, если их съест Control интерфейса полёта
## (отладочные слои F1/F5/F6, Debug Menu F2, пасхалки, меню). Шаги физики — Game.tick() вручную.
## Знаки — контракт С1 (docs/control-fix_contracts.md): roll + вправо (мышь вправо),
## pitch + от себя / нос вверх (мышь вверх по экрану). На земле мышь не используется (С2 v1).

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Игра в воздухе (--air-start), режим bar, мышь «захвачена» (headless курсор не захватить —
## Input.mouse_mode остаётся VISIBLE, но InputController смотрит на свой mouse_captured).
func _open(air: bool) -> Node:
	var args := ["--autostart"]
	if air:
		args.append("--air-start=600,150")
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(args)))
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
	# Шагаем сами. Не PROCESS_MODE_DISABLED: выключенный узел (и InputController под ним)
	# не получает _unhandled_input — события мыши бы терялись.
	game.set_physics_process(false)
	var controls_cfg: Dictionary = Config.get_config("controls")
	main.set_meta("_orig_mouse_mode", String(controls_cfg.mouse.mode))
	controls_cfg.mouse.mode = "bar"
	game.input_controller.reload_config()
	return main


func _close(main: Node) -> void:
	if main.has_meta("_orig_mouse_mode"):
		Config.get_config("controls").mouse.mode = main.get_meta("_orig_mouse_mode")
		var game: Game = main.get_node("Game")
		game.input_controller.reload_config()
	main.queue_free()
	for i in 2:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout


## Движение мыши через вьюпорт в точке p (при захвате курсор у реальной игры — в центре окна).
func _push_motion(rel: Vector2, p: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = p
	ev.global_position = p
	ev.relative = rel
	get_viewport().push_input(ev)


func _center() -> Vector2:
	return get_viewport().get_visible_rect().size * 0.5


## Новый полёт с того же места, трапеция в нейтрали, мышь захвачена.
func _restart(game: Game) -> void:
	game.restart()
	game.input_controller.set_mouse_captured(true)


## Полёт dur секунд с мышью, сдвинутой на rel в начале; возвращает [ControlInput.pitch,
## ControlInput.roll после сдвига, крен и тангаж модели в конце].
func _fly_with_mouse(game: Game, rel: Vector2, dur: float) -> Array:
	_restart(game)
	for i in 6:
		game.tick(DT)
	_push_motion(rel, _center())
	game.tick(DT)
	var c := game.input_controller.control
	var pitch_in := c.pitch
	var roll_in := c.roll
	for i in int(dur / DT):
		game.tick(DT)
	var t := game.glider.get_telemetry()
	check(t.phase == "flying", "в воздухе всё время (rel %s): %s" % [rel, t.phase])
	return [pitch_in, roll_in, t.bank_deg, t.pitch_deg]


func test_bar_mouse_moves_bar_and_model_in_air() -> void:
	var main := await _open(true)
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var px := get_viewport().get_visible_rect().size.y * 0.5 * 0.3  # 30 % хода
	var dur := 1.5
	var neutral := _fly_with_mouse(game, Vector2.ZERO, dur)
	var right := _fly_with_mouse(game, Vector2(px, 0.0), dur)
	var left := _fly_with_mouse(game, Vector2(-px, 0.0), dur)
	var up := _fly_with_mouse(game, Vector2(0.0, -px), dur)
	var down := _fly_with_mouse(game, Vector2(0.0, px), dur)
	print(
		(
			"CF2 bar: нейтраль крен %.1f° тангаж %.1f° | вправо roll %.2f крен %.1f° | "
			+ "влево roll %.2f крен %.1f° | вверх pitch %.2f тангаж %.1f° | "
			+ "вниз pitch %.2f тангаж %.1f°"
		)
		% [
			neutral[2], neutral[3], right[1], right[2], left[1], left[2],
			up[0], up[3], down[0], down[3]
		]
	)
	check(neutral[0] == 0.0 and neutral[1] == 0.0, "без мыши трапеция в нейтрали")
	check(right[1] > 0.2, "мышь вправо → roll > 0: %.2f" % right[1])
	check(left[1] < -0.2, "мышь влево → roll < 0: %.2f" % left[1])
	check(up[0] > 0.2, "мышь вверх → pitch > 0 (от себя): %.2f" % up[0])
	check(down[0] < -0.2, "мышь вниз → pitch < 0 (на себя): %.2f" % down[0])
	check(right[2] > neutral[2] + 5.0, "мышь вправо → крен вправо: %.1f°" % right[2])
	check(left[2] < neutral[2] - 5.0, "мышь влево → крен влево: %.1f°" % left[2])
	check(up[3] > neutral[3] + 1.0, "мышь вверх → нос выше: %.1f°" % up[3])
	check(down[3] < neutral[3] - 1.0, "мышь вниз → нос ниже: %.1f°" % down[3])
	await _close(main)


## События мыши доходят до InputController в любой точке экрана при всех слоях интерфейса полёта
## по умолчанию и с отладочными слоями F1/F5/F6 (Debug Menu F2 — без рендера не создаётся, его
## сцена проверена отдельно ниже).
func test_mouse_events_reach_controller_with_all_layers() -> void:
	var main := await _open(true)
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var ic := game.input_controller
	var sz := get_viewport().get_visible_rect().size
	var points: Array[Vector2] = [
		sz * 0.5, Vector2(4, 4), Vector2(sz.x - 4, 4), Vector2(4, sz.y - 4), sz - Vector2(4, 4)
	]
	var dbg: Node = game.get("debug_overlays")
	for layers in ["нет", "F1+F5+F6"]:
		if layers != "нет" and dbg != null:
			dbg.call("enable", PackedStringArray(["perf", "wind", "thermals"]))
			for i in 3:
				await get_tree().process_frame
		for p in points:
			_restart(game)
			game.tick(DT)
			var before: Vector2 = ic._mouse_offset
			_push_motion(Vector2(2.0, -2.0), p)
			check(ic._mouse_offset != before, "слои %s: мышь в %s дошла до InputController" % [layers, p])
	await _close(main)


## Debug Menu (аддон, F2): ни один его Control не ловит мышь, а своё действие cycle_debug_menu
## без клавиш — его _input ничего не съедает.
func test_debug_menu_does_not_catch_mouse() -> void:
	if not ResourceLoader.exists("res://addons/debug_menu/debug_menu.tscn"):
		return
	var menu: Node = load("res://addons/debug_menu/debug_menu.tscn").instantiate()
	var stack: Array[Node] = [menu]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Control:
			check(
				(n as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"Debug Menu: %s не ловит мышь" % menu.get_path_to(n)
			)
		stack.append_array(n.get_children())
	menu.free()
	if InputMap.has_action("cycle_debug_menu"):
		check(InputMap.action_get_events("cycle_debug_menu").is_empty(), "cycle_debug_menu без клавиш")


## На земле мышь не используется (С2 v1): движение мыши стоя не копится и после отрыва не
## дёргает трапецию.
func test_mouse_on_ground_does_not_carry_into_air() -> void:
	var main := await _open(false)
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var ic := game.input_controller
	_restart(game)
	for i in 12:
		game.tick(DT)
	check(game.glider.phase() != "flying", "на земле")
	var px := get_viewport().get_visible_rect().size.y * 0.5
	_push_motion(Vector2(px, -px), _center())  # полный ход вправо и от себя
	game.tick(DT)
	check(game.glider.phase() != "flying", "на земле после мыши")
	print("CF2 земля: смещение мыши после движения стоя %s" % ic._mouse_offset)
	check(ic._mouse_offset == Vector2.ZERO, "стоя мышь не копит смещение: %s" % ic._mouse_offset)
	# Отрыв (фазу задаёт Game по телеметрии — здесь напрямую): трапеция в нейтрали.
	ic.on_ground = false
	var c := ic.update(DT)
	check(absf(c.roll) < 0.01 and absf(c.pitch) < 0.01, "после отрыва трапеция в нейтрали: %.2f / %.2f" % [c.pitch, c.roll])
	await _close(main)
