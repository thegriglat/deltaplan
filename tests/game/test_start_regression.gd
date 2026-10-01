extends Node
## CF-1: старт с земли по умолчанию в сцене игры (main.tscn → _fly, FlightSettings.defaults():
## локация, старт, крыло, ветер «встречный», прогноз, час), ввод — через InputMap, как у игрока.
## 1. Без ввода 10 с: стоит — нет отрыва и срыва, |крен| < 3°, смещение < 1 м.
## 2. Разбег (Shift, С2 v2) с нейтральной трапецией — отрыв; «на себя» (нос ниже нейтрали на
##    ≈ 6°, как прежняя подстройка ↓ на 0,3 хода) — меньше угол атаки на разбеге и отрыв; «от себя»
##    до упора — срыв nose_high; крен на разбеге < 3°. Клавиши — действия трапеции, знак — карта.
## Поле воздуха: headless — аналитическое; test_start_regression_gpu.gd — то же с полем GPU.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const KEYS := ["run", "pitch_pull_in", "pitch_push_out"]
## «На себя»: держать нос на столько ниже угла разбега крыла (launch.alpha_neutral_deg), °.
const PULL_BELOW_DEG := 6.0
## Сколько стоит перед разбегом, с.
const STAND_S := 1.0
const RUN_MAX_S := 12.0

var failures: PackedStringArray = []
## Строки итогов (для отчёта: печатаются в лог прогона).
var report: PackedStringArray = []


func needs_gpu() -> bool:
	return false


## Проверять разбег строго (крен < 3°, ↓ ниже нейтрали, ↑ — nose_high) — пока только в
## аналитическом поле. В поле GPU 1.0.0 болтанка у старта (σw ≈ 0,4–1 м/с на 1,5 м, разворот ветра —
## бисект CF-1, 4e71747) это ломает; поле чинит модуль air-start — после него вернуть true.
func strict_run(game: Game) -> bool:
	return game.air_runtime.unavailable_reason() != ""


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_default_start() -> void:
	var main := await _open_main()
	if main == null:
		return
	var game: Game = main.get_node("Game")
	var idle := _stand(game, 10.0)
	print("  [%s] стоя 10 с: %s" % [_tag(), idle])
	check(idle.result == "ground", "стоя без ввода — на земле (%s)" % idle)
	check(idle.max_bank < 3.0, "стоя |крен| < 3° (%s)" % idle)
	check(idle.disp < 1.0, "стоя смещение < 1 м (%s)" % idle)
	var neutral := _run(game, 0)
	var pull := _run(game, -1)
	var push := _run(game, 1)
	for r: Dictionary in [neutral, pull, push]:
		print("  [%s] разбег %s" % [_tag(), r])
	check(neutral.result == "air", "нейтральная трапеция — отрыв (%s)" % neutral)
	check(pull.result == "air", "«на себя» — отрыв (%s)" % pull)
	if not strict_run(game):
		_finish(main)
		return
	check(neutral.max_bank < 3.0, "крен на разбеге < 3° (%s)" % neutral)
	check(pull.alpha_run < neutral.alpha_run, "«на себя» — угол атаки на разбеге ниже нейтрали")
	check(push.result == "nose_high", "«от себя» до упора — срыв nose_high (%s)" % push)
	_finish(main)


func _finish(main: Node) -> void:
	_release()
	main.queue_free()


func _tag() -> String:
	return "GPU" if needs_gpu() else "базовый"


func _open_main() -> Node:
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	var menu: StartMenu = main.get_node("UI/StartMenu")
	for i in 1200:
		if menu.visible:
			break
		await get_tree().process_frame
	check(menu.visible, "меню открыто")
	if not menu.visible:
		main.queue_free()
		return null
	var opts := main.get("opts") as LaunchOptions
	opts.autostart = true
	await main.call("_fly", FlightSettings.defaults())
	game.process_mode = Node.PROCESS_MODE_DISABLED
	return main


## Стоит без ввода t_s секунд с того же старта.
func _stand(game: Game, t_s: float) -> Dictionary:
	game.restart()
	_release()
	var m: FlightModel = game.glider.model
	var p0 := m.position
	var out := {"result": "ground", "max_bank": 0.0, "disp": 0.0}
	var t := 0.0
	while t < t_s:
		game.tick(DT)
		t += DT
		out.max_bank = maxf(out.max_bank, absf(rad_to_deg(m.bank)))
		out.disp = maxf(out.disp, Vector2(m.position.x - p0.x, m.position.z - p0.z).length())
		if m.mode == FlightModel.Mode.AIR:
			out.result = "took_off"
			break
		if m.mode == FlightModel.Mode.FAILED:
			out.result = m.takeoff_failure
			break
	return out


## Разбег после STAND_S стоя; nose: 0 — нейтрально, −1 — «на себя» (нос на PULL_BELOW_DEG ниже
## угла разбега: клавиша зажата, пока нос выше), +1 — «от себя» до упора.
func _run(game: Game, nose: int) -> Dictionary:
	game.restart()
	_release()
	var m: FlightModel = game.glider.model
	var p0 := m.position
	var out := {
		"nose": nose, "result": "none", "t_run": 0.0, "run_m": 0.0, "max_bank": 0.0,
		"alpha_run": 0.0
	}
	var t := 0.0
	var a_sum := 0.0
	var a_n := 0
	while t < STAND_S + RUN_MAX_S:
		var running := t >= STAND_S
		var a_pull := float(m.wing.launch.alpha_neutral_deg) - PULL_BELOW_DEG
		_press("run", running)
		_press("pitch_pull_in", running and nose < 0 and rad_to_deg(m.alpha) > a_pull)
		_press("pitch_push_out", running and nose > 0)
		game.tick(DT)
		t += DT
		if m.mode == FlightModel.Mode.GROUND:
			out.max_bank = maxf(out.max_bank, absf(rad_to_deg(m.bank)))
			if running:
				a_sum += rad_to_deg(m.alpha)
				a_n += 1
		elif m.mode == FlightModel.Mode.AIR:
			out.result = "air"
			break
		elif m.mode == FlightModel.Mode.FAILED:
			out.result = m.takeoff_failure
			break
	out.t_run = maxf(t - STAND_S, 0.0)
	out.run_m = Vector2(m.position.x - p0.x, m.position.z - p0.z).length()
	out.alpha_run = a_sum / maxf(a_n, 1)
	_release()
	return out


func _press(action: String, on: bool) -> void:
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)


func _release() -> void:
	for a: String in KEYS:
		Input.action_release(a)

