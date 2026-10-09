extends Node
## Мышь — всегда трапеция (У1 v3, InputController._mouse_offset), но пока зажата правая кнопка —
## крутит голову в кабине (CameraRig._head, FR-31). Отпустил — трапеция снова от мыши, голова
## остаётся там, куда повернул. Камеры "сзади"/"свободная" здесь не участвуют — правая кнопка
## там уже орбита (см. tests/game/test_gameplay.gd).

const MAIN_SCENE := preload("res://scenes/main.tscn")

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Заводит игру, мышь захвачена, камера — кабина.
func _open_bar() -> Node:
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
	game.camera.set_mode("cockpit")
	var ic := game.input_controller
	# Game выключен и tick не идёт — фазу задаём сами (в воздухе).
	ic.on_ground = false
	ic.set_mouse_captured(true)
	return main


func _close(main: Node) -> void:
	main.queue_free()
	for i in 2:
		await get_tree().process_frame


static func _motion(dx: float) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(dx, 0.0)
	return ev


static func _right_button(pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = pressed
	return ev


## Событие идёт на оба узла (в игре его получают оба через _unhandled_input дерева сцены).
## Мышь мышью: headless-движок не даёт реально захватить курсор (Input.mouse_mode всегда
## остаётся VISIBLE без окна), поэтому обход камеры вокруг проверки "captured" в _unhandled_input
## воспроизводит остаток той же логики напрямую — _mouse_looks() и _look() — то, что и является
## новым поведением этой задачи. Трапеция (InputController) капture-независима и идёт через
## настоящий _unhandled_input целиком.
func _dispatch(game: Game, ev: InputEvent) -> void:
	game.camera._unhandled_input(ev)
	if ev is InputEventMouseMotion and game.camera._mouse_looks():
		game.camera._look(ev.relative)
	game.input_controller._unhandled_input(ev)


func test_bar_mode_right_button_looks_without_moving_bar() -> void:
	var main := await _open_bar()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var ic := game.input_controller
	var cam := game.camera

	# Небольшой шаг мыши — трапеция копит смещение доли хода за раз (не насыщается до предела
	# ±1 сразу, иначе последующие движения было бы не отличить от насыщенного предыдущего).
	# Без ПКМ: мышь двигает трапецию, голова стоит.
	check(not cam._mouse_looks(), "без ПКМ: голова не в режиме обзора")
	var offset0 := ic._mouse_offset
	var head0 := cam._head
	_dispatch(game, _motion(3.0))
	check(ic._mouse_offset != offset0, "без ПКМ: трапеция реагирует на мышь")
	check(cam._head == head0, "без ПКМ: голова не двигается")

	# Зажали ПКМ: мышь крутит голову, трапеция держит положение.
	_dispatch(game, _right_button(true))
	check(cam._mouse_looks(), "с ПКМ: включился обзор головой")
	var offset1 := ic._mouse_offset
	var head1 := cam._head
	_dispatch(game, _motion(3.0))
	check(cam._head != head1, "с ПКМ: голова поворачивается")
	check(ic._mouse_offset == offset1, "с ПКМ: трапеция держит положение")

	# Отпустили ПКМ: трапеция снова от мыши, голова остаётся, куда повернули.
	_dispatch(game, _right_button(false))
	check(not cam._mouse_looks(), "после отпускания: обзор головой выключен")
	var head2 := cam._head
	var offset2 := ic._mouse_offset
	_dispatch(game, _motion(3.0))
	check(ic._mouse_offset != offset2, "после отпускания: трапеция снова реагирует на мышь")
	check(cam._head == head2, "после отпускания: голова не сдвинулась сама")

	await _close(main)


## V (look_center) / средняя кнопка возвращают голову вперёд и в bar-режиме — как раньше.
func test_bar_mode_look_center_still_works() -> void:
	var main := await _open_bar()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var cam := game.camera
	_dispatch(game, _right_button(true))
	_dispatch(game, _motion(80.0))
	check(cam._head != Vector2.ZERO, "голова повёрнута перед проверкой центрирования")
	_dispatch(game, _right_button(false))
	var ev := InputEventAction.new()
	ev.action = "look_center"
	ev.pressed = true
	cam._unhandled_input(ev)
	check(cam._recentering, "V — начал возврат головы вперёд")
	await _close(main)


## Отрыв от земли (glider.took_off) возвращает голову по центру; клавиша обзора, зажатая ещё на
## разбеге (W шагает), после отрыва голову вверх не уводит.
func test_takeoff_recenters_head_and_ignores_held_key() -> void:
	var main := await _open_bar()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var cam := game.camera
	cam._head = Vector2(0.3, 0.9)
	game.glider.took_off.emit()
	check(cam._recentering, "отрыв — возврат головы вперёд")
	# разбег: на земле клавиша обзора вверх зажата, обзор с клавиш выключен
	var ic := game.input_controller
	ic.on_ground = true
	cam._head = Vector2.ZERO
	Input.action_press("look_up")
	cam._keys_head(0.1, cam._cfg.cockpit)
	ic.on_ground = false
	cam._keys_head(0.5, cam._cfg.cockpit)
	check(cam._head.y == 0.0, "зажатая с земли клавиша голову не крутит: %.2f" % cam._head.y)
	Input.action_release("look_up")
	cam._keys_head(0.1, cam._cfg.cockpit)
	Input.action_press("look_up")
	cam._keys_head(0.1, cam._cfg.cockpit)
	check(cam._head.y > 0.0, "после отпускания и нового нажатия обзор работает")
	Input.action_release("look_up")
	await _close(main)


## Q (look_instrument) — взгляд на приборы на трапеции: цель берётся из положения смонтированных
## приборов в рантайме; клавиша привязана; в воздухе камера смотрит на середину приборов, отпустил — назад.
func test_q_glance_looks_at_mounted_instruments() -> void:
	var main := await _open_bar()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var cam := game.camera
	var keys := InputMap.action_get_events("look_instrument")
	var has_q := false
	for e in keys:
		if e is InputEventKey and (e.keycode == KEY_Q or e.physical_keycode == KEY_Q):
			has_q = true
	check(has_q, "look_instrument привязана к Q")
	check(not game.mounted.is_empty(), "приборы смонтированы")
	check(cam.glance_nodes.size() == game.mounted.size(), "цель взгляда — смонтированные приборы")
	var p := cam._glance_point()
	check(p.is_finite(), "точка взгляда определена")
	var mid := Vector3.ZERO
	for n in game.mounted:
		mid += n.global_position
	check(p.distance_to(mid / game.mounted.size()) < 0.001, "точка взгляда — середина приборов")
	# сдвиг прибора сдвигает цель (не захардкожено)
	game.mounted[0].global_position += Vector3(0, 1.0, 0)
	check(cam._glance_point().distance_to(p) > 0.1, "цель следует за положением приборов")
	Input.action_press("look_instrument")
	for i in 40:
		cam._process(0.05)
	var look := cam._angles_to(cam._glance_point(), cam.global_position, cam._cfg.cockpit)
	check(absf(cam._glance - 1.0) < 0.001, "взгляд на приборах выдержан")
	check(absf(cam.head_look_deg().x) < 0.01, "голова (_head) не тронута взглядом")
	Input.action_release("look_instrument")
	for i in 40:
		cam._process(0.05)
	check(cam._glance < 0.001, "отпустил — взгляд вернулся")
	check(look.is_finite(), "углы на цель конечны")
	await _close(main)


## Дымка (квад SkyEnvironment.haze на своём слое) видна из всех режимов камеры: слой «только
## кабина», который внешние камеры не рисуют, совпадал со слоем дымки — из вида сзади её не было.
func test_haze_visible_in_every_camera_mode() -> void:
	var main := await _open_bar()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var haze: MeshInstance3D = game.sky.haze
	check(haze != null, "дымка включена")
	if haze != null:
		for m: String in ["cockpit", "chase", "free"]:
			game.camera.set_mode(m)
			check(game.camera.cull_mask & haze.layers != 0, "дымка видна в режиме камеры %s" % m)
	game.camera.set_mode("cockpit")
	await _close(main)
