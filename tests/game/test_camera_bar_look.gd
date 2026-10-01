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
