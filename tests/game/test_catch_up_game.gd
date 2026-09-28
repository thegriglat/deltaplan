extends Node
## «Догнать» в игре (NET-42): меню `=`, буксир в Game.tick, «Продолжить рядом», авто-«догнать»
## при входе — в главной сцене на подменённой зоне (без сервера). Чужие пилоты — FakePilots
## (как NetPilots: get_pilot_ids + sample), двигает их тест; мир шагаем сами (Game.tick).
## Основные случаи плана: (1) с посадочной площадки к другу на 1500 м над стартом; (2) из долины
## в 50 м над рельефом к другу в 2 км в стороне и на 1000 м выше — прибытие в 30–80 м от цели на
## её высоте, ни разу не касаясь рельефа, после передачи управления крыло летит без сваливания.

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const FRIEND := "2"
const FRIEND2 := "3"

var failures: PackedStringArray = []
var main: Node
var game: Game
var zone: FakeZone
var pilots: FakePilots
var ended: Array = []  ## flight_ended: [kind, info]
var tow_ends: Array[String] = []
## id → Callable(t) -> [pos, vel]: как движется чужой пилот
var motions := {}
var t_sim := 0.0


## Зона: часы задаёт тест, ведущий — leader_id; is_leader — считаем ли ботов сами.
class FakeZone:
	extends RefCounted
	var in_zone := true
	var has_clock := true
	var clock := 0.0
	var world_seed := 4711
	var bots_count := 0
	var my_id := "1"
	var leader_id := "1"
	var peers := {"1": {"id": "1", "name": "Коля", "joinOrder": 1}}
	var zone := {}

	func zone_time() -> float:
		return clock

	func check_world(_key: String) -> bool:
		return true

	func is_leader() -> bool:
		return leader_id == my_id


## NetPilots: чужие — states (id → sample), своё — local.
class FakePilots:
	extends RefCounted
	signal pilot_lost(id: String)
	var local := {}
	var states := {}

	func set_local_state(
		pos: Vector3, rot: Quaternion, vel: Vector3, phase: String, wing: String, colors: Variant
	) -> void:
		local = {"pos": pos, "rot": rot, "vel": vel, "phase": phase, "wing": wing, "colors": colors}

	func clear_local_state() -> void:
		local = {}

	func get_pilot_ids() -> Array[String]:
		var out: Array[String] = []
		for id: String in states:
			out.append(id)
		return out

	func sample(id: String) -> Dictionary:
		return states.get(id, {})

	func has_pilot(id: String) -> bool:
		return states.has(id)

	func send_bot_state(
		_id: String,
		_pos: Vector3,
		_rot: Quaternion,
		_vel: Vector3,
		_phase: String,
		_name: String,
		_wing: String,
		_colors: Variant
	) -> void:
		pass

	func clear_bots() -> void:
		pass


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Друг: по кругу радиуса r вокруг c со скоростью v (r ≤ 0 — по прямой со скоростью vel).
func _circle(c: Vector3, r: float, v: float) -> Callable:
	return func(t: float) -> Array:
		var w := v / r
		var a := w * t
		var pos := c + Vector3(cos(a), 0.0, sin(a)) * r
		var vel := Vector3(-sin(a), 0.0, cos(a)) * v
		return [pos, vel]


func _put(id: String, pilot_name: String, phase: String, is_bot := false) -> void:
	var pv: Array = motions[id].call(t_sim)
	pilots.states[id] = {
		"name": pilot_name,
		"is_bot": is_bot,
		"wing": "wings/sport",
		"colors": null,
		"pos": pv[0],
		"rot": Quaternion.IDENTITY,
		"vel": pv[1],
		"phase": phase,
	}


## Шаг: чужие пилоты сдвинулись → RemotePilots, потом шаг игры.
func _step() -> void:
	t_sim += DT
	for id: String in pilots.states:
		if motions.has(id):
			var pv: Array = motions[id].call(t_sim)
			pilots.states[id].pos = pv[0]
			pilots.states[id].vel = pv[1]
	game.net.feed_remote()
	game.tick(DT)


## Буксир до конца: минимальная высота над рельефом, фаза TOW в PilotState, итог кончившегося.
func _run_tow(max_s: float = 40.0) -> Dictionary:
	var min_agl := INF
	var tow_phase := true
	var last: Dictionary = {}
	var n := 0
	while game.is_towing() and n < int(max_s / DT):
		_step()
		n += 1
		if game.is_towing():
			last = game.tow.last
			var p := game.glider.model.position
			min_agl = minf(min_agl, p.y - game.terrain.height_at(p.x, p.z))
			game.net.send_local()
			tow_phase = tow_phase and String(pilots.local.get("phase", "")) == "TOW"
	return {"min_agl": min_agl, "tow_phase": tow_phase, "t": n * DT, "last": last}


## После передачи управления: 10 с полёта без рук — без сваливания, скорость не ниже трима.
func _fly_after(label: String) -> void:
	var trim := game.glider.model.trim_speed()
	var min_as := INF
	var stalled := false
	var ended_before := ended.size()
	for i in int(10.0 / DT):
		_step()
		var t := game.glider.get_telemetry()
		min_as = minf(min_as, t.airspeed)
		stalled = stalled or t.stalled
	check(game.glider.phase() == "flying", "%s: 10 с после буксира — в воздухе" % label)
	check(not stalled, "%s: без сваливания" % label)
	check(min_as >= 0.8 * trim, "%s: скорость ≥ трима (%.1f из %.1f)" % [label, min_as, trim])
	check(ended.size() == ended_before, "%s: без аварии и посадки" % label)


func _arrival(label: String, id: String) -> void:
	var tgt: Vector3 = pilots.states[id].pos
	var own := game.glider.model.position
	var d := own.distance_to(tgt)
	check(d >= 30.0 and d <= 80.0, "%s: прибытие в 30–80 м от цели (%.1f м)" % [label, d])
	check(absf(own.y - tgt.y) < 12.0, "%s: на высоте цели (Δ %.1f м)" % [label, own.y - tgt.y])


func _key(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	main.call("_unhandled_input", e)


func _setup_main() -> bool:
	main = MAIN_SCENE.instantiate()
	add_child(main)
	game = main.get_node("Game")
	for i in 600:
		if game.settings != null:
			break
		await get_tree().process_frame
	if game.settings == null:
		return false
	(main.get("opts") as LaunchOptions).autostart = true  # не запоминать выбор в user://
	game.flight_ended.connect(func(k: String, info: Dictionary) -> void: ended.append([k, info]))
	game.catch_up_ended.connect(func(st: String) -> void: tow_ends.append(st))
	return true


func _enter_zone(z: FakeZone, auto := false) -> void:
	main.call("_show_menu")
	game.process_mode = Node.PROCESS_MODE_INHERIT
	var s := FlightSettings.defaults()
	s.wind_speed_kmh = 5.0
	s.start_hour = 10.0  # утро: термики слабые — «без рук» после буксира не болтает до сваливания
	game.enable_net(NetFlight.new(), z, pilots)
	game.net.auto_catch_up = auto
	await main.call("_fly", s)


func _teardown() -> void:
	main.call("_show_menu")
	get_tree().paused = false
	main.queue_free()
	await get_tree().process_frame


## Основные случаи, меню, отмена, потеря цели, «Продолжить рядом»; ведущий считает 2 бота.
func test_catch_up_in_main_scene() -> void:
	pilots = FakePilots.new()
	if not await _setup_main():
		check(false, "мир за меню загружен")
		main.queue_free()
		return
	zone = FakeZone.new()
	zone.bots_count = 2
	zone.clock = 50.0
	await _enter_zone(zone)
	check(main.get("state") == 2, "сетевой полёт начался")
	game.process_mode = Node.PROCESS_MODE_DISABLED  # дальше шагаем сами
	var launch: Vector3 = game.get_start().position
	var sites := game.terrain.get_landing_sites()
	check(not sites.is_empty(), "у локации есть посадочная площадка")
	var field: Vector3 = sites[0].position if not sites.is_empty() else launch + Vector3(2000, 0, 0)

	# Друг кружит на 1500 м над стартом, второй — на земле на старте; боты ведущего — у старта.
	motions[FRIEND] = _circle(launch + Vector3(0, 1500, 0), 150.0, 11.0)
	_put(FRIEND, "Маша", "FLY")
	motions[FRIEND2] = func(_t: float) -> Array: return [launch + Vector3(5, 0, 5), Vector3.ZERO]
	_put(FRIEND2, "Петя", "STAND")
	_step()

	# Список меню: боты ведущего — в нём, себя нет; бот в воздухе — цель буксира.
	var list := game.net.catch_up_list()
	var ids := list.map(func(p: Dictionary) -> String: return p.id)
	check(ids.has(FRIEND) and ids.has(FRIEND2), "чужие пилоты в списке (%s)" % [ids])
	check(ids.has("bot-0") and ids.has("bot-1"), "свои боты ведущего в списке (%s)" % [ids])
	check(not ids.has("1"), "себя в списке нет")
	var bot := game.net.bots.agent_for("bot-0")
	if bot != null:
		bot.start_in_air(launch + Vector3(100, 300, 0), 90.0, 0.0)
		check(game.net.target_state("bot-0") == "air", "бот ведущего в воздухе")
		check(not game.net.target_fn("bot-0").call().is_empty(), "бот ведущего — цель буксира")
	check(game.net.target_state(FRIEND2) == "ground", "друг на старте — на земле")
	check(game.net.target_state("nobody") == "", "нет такого")

	# (1) С посадочной площадки: `=` → Enter — к ближайшему живому в воздухе.
	game.glider.reset_on_ground(field, 0.0)
	game.stats.reset(field)
	check(game.glider.phase() == "standing", "стоим на посадке (%s)" % game.glider.phase())
	var menu: CatchUpMenu = main.get("catch_up_menu")
	_key("catch_up")
	check(menu.is_open(), "`=` открывает меню")
	check(game.hands_off, "меню открыто — руки с трапеции")
	_step()
	check(game.input_controller.hands_off, "InputController без рук")
	check(
		menu.selected_id() == FRIEND, "выделен ближайший живой в воздухе (%s)" % menu.selected_id()
	)
	var enter := InputEventAction.new()
	enter.action = "ui_accept"
	enter.pressed = true
	menu.call("_input", enter)
	check(not menu.is_open(), "Enter закрыл меню")
	check(not game.hands_off, "руки снова на трапеции")
	check(game.is_towing(), "Enter — буксир к другу")
	var ended0 := ended.size()
	var r := _run_tow()
	check(tow_ends.back() == "done", "буксир дошёл (%s)" % [tow_ends])
	check(r.tow_phase, "на буксире другим уходит фаза TOW")
	check(r.min_agl > -0.5, "с посадки: не под рельефом (%.1f м)" % r.min_agl)
	check(ended.size() == ended0, "на буксире нет итога полёта (посадка/авария не срабатывают)")
	print("case1: %.1f с, min AGL %.1f м" % [r.t, r.min_agl])
	_arrival("с посадки", FRIEND)
	check(not game.stats.is_finished() and not game.stats.touched, "буксир — не посадка в итоге")
	_fly_after("с посадки")

	# (2) Из долины в 50 м над рельефом к другу в 2 км в стороне и на 1000 м выше.
	var h := deg_to_rad(float(game.get_start().heading_deg))
	var fwd := Vector3(sin(h), 0.0, -cos(h))
	var side := Vector3(cos(h), 0.0, sin(h))
	var low := launch + fwd * 3000.0
	low.y = game.terrain.height_at(low.x, low.z) + 50.0
	game.glider.reset_in_air(low, rad_to_deg(h))
	var fc := low + side * 2000.0 + Vector3(0, 1000, 0)
	motions[FRIEND] = _circle(fc, 120.0, 11.0)
	_step()
	check(game.catch_up_to(FRIEND) == "tow", "из долины — буксир")
	r = _run_tow()
	check(tow_ends.back() == "done", "из долины: дошли")
	check(r.min_agl > 10.0, "из долины: ни разу не касаясь рельефа (min %.1f м)" % r.min_agl)
	print("case2: %.1f с, min AGL %.1f м" % [r.t, r.min_agl])
	_arrival("из долины", FRIEND)
	_fly_after("из долины")

	# Esc на буксире: физика возвращается на месте, пауза не открывается.
	game.glider.reset_in_air(low, rad_to_deg(h))
	check(game.catch_up_to(FRIEND) == "tow", "снова буксир")
	for i in int(3.0 / DT):
		_step()
	var at := game.glider.model.position
	_key("pause")
	check(not game.is_towing(), "Esc — буксир отменён")
	check(main.get("state") == 2, "Esc на буксире не открывает паузу")
	check(tow_ends.back() == "aborted", "отмена")
	check(game.glider.model.position.distance_to(at) < 0.5, "физика — на месте")
	check(game.glider.phase() == "flying", "в воздухе")
	var p0 := game.glider.model.position
	_step()
	var moved := game.glider.model.position.distance_to(p0)
	check(moved > 0.01 and moved < 1.0, "физика шагает сама (%.3f м за шаг)" % moved)

	# `=` на буксире — тоже отмена.
	check(game.catch_up_to(FRIEND) == "tow", "ещё буксир")
	_step()
	_key("catch_up")
	check(not game.is_towing() and not menu.is_open(), "`=` на буксире — отмена, меню не открылось")

	# Цель ушла посреди буксира — стоп и управление пилоту.
	game.glider.reset_in_air(low, rad_to_deg(h))
	check(game.catch_up_to(FRIEND) == "tow", "буксир перед уходом цели")
	for i in int(2.0 / DT):
		_step()
	var saved: Dictionary = pilots.states[FRIEND]
	pilots.states.erase(FRIEND)
	pilots.pilot_lost.emit(FRIEND)
	_step()
	check(not game.is_towing(), "цель ушла — буксир остановлен")
	check(tow_ends.back() == "lost", "состояние lost (%s)" % [tow_ends])
	check(game.glider.phase() == "flying", "управление вернулось в воздухе")
	pilots.states[FRIEND] = saved
	_step()

	# Цель на земле — вместо буксира на старт (NET-43: в конец очереди).
	check(game.catch_up_to(FRIEND2) == "launch", "цель на земле — на старт")
	check(not game.is_towing(), "без буксира")
	check(game.glider.model.position.distance_to(launch) < 5.0, "стоим на старте")

	# После аварии — «Продолжить рядом»: один друг в воздухе — буксир с места.
	game.glider.reset_on_ground(field, 0.0)
	_step()
	game.call("_on_collision", {"kind": "tree"})
	check(game.is_crashed(), "разбились")
	main.call("_show_result", "landed", ended.back()[1] if not ended.is_empty() else {})
	check(main.get("state") == 4, "окно итога")
	main.call("_on_result_continue_near")
	check(main.get("state") == 2, "«Продолжить рядом» закрыл итог")
	check(game.is_towing(), "один друг в воздухе — сразу буксир")
	r = _run_tow()
	check(tow_ends.back() == "done", "после аварии: дошли")
	_arrival("после аварии", FRIEND)

	# Несколько друзей в воздухе — «Продолжить рядом» открывает меню.
	motions[FRIEND2] = _circle(launch + Vector3(800, 900, 0), 100.0, 10.0)
	_put(FRIEND2, "Петя", "FLY")
	_step()
	main.call("_show_result", "landed", {"grade": "soft"})
	main.call("_on_result_continue_near")
	check(not game.is_towing(), "несколько — без буксира сразу")
	check(menu.is_open(), "несколько — меню «Догнать»")
	menu.close()
	check(not game.hands_off, "меню закрыто — руки на трапеции")
	await _teardown()


## Вход в зону, где ведущий в воздухе, — сразу буксир от старта к нему; ведущий на земле — ничего.
func test_auto_catch_up_on_join() -> void:
	pilots = FakePilots.new()
	if not await _setup_main():
		check(false, "мир за меню загружен")
		main.queue_free()
		return
	var launch: Vector3 = game.get_start().position
	zone = FakeZone.new()
	zone.leader_id = FRIEND
	zone.clock = 30.0
	motions[FRIEND] = _circle(launch + Vector3(0, 800, 0), 150.0, 11.0)
	_put(FRIEND, "Маша", "FLY")
	await _enter_zone(zone, true)
	for i in 30:
		if game.is_towing():
			break
		await get_tree().process_frame
	check(game.is_towing(), "ведущий в воздухе — буксир при входе")
	game.abort_catch_up()

	# Ведущий на земле — не догоняем.
	_put(FRIEND, "Маша", "STAND")
	await _enter_zone(zone, true)
	for i in 30:
		await get_tree().process_frame
	check(not game.is_towing(), "ведущий на земле — буксира нет")
	await _teardown()
