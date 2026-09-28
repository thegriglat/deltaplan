class_name NetBots
extends Node
## Боты сетевой зоны (NET-44, docs/plan/multiplayer.md → «Боты»): считает их только ведущий —
## тот же BotPilots, но «наблюдает» всех живых пилотов зоны (свой пилот + чужие из NetPilots,
## BotPilots.others), и каждый шаг отдаёт состояния ботов в NetPilots.send_bot_state (is_bot,
## уходят 10 Гц вместе со своим). У остальных боты приходят как чужие пилоты (NET-41, рисует
## RemotePilots) — здесь ничего не считается. Ведущий своих ботов из сети не рисует: NetPilots
## не принимает пакеты ботов, которые шлёт сам (send_bot_state), — рисует свой BotPilots.
##
## Число ботов — Zone.bots_count (настройки создателя), не пересчитывается. Имена — из пула
## языка того, кто начал их считать, и больше не меняются (BotPilots.fixed_names).
##
## Смена ведущего: новый ведущий продолжает ботов с последних полученных состояний (sample —
## то, что он сейчас рисует): положение, скорость, курс и крен, фаза (в воздухе / на земле /
## сел), имя, расцветка; id те же ("bot-3"). Недостающих до bots_count — добавляет свежими
## на местах ожидания. Бывший ведущий (если остался в зоне) перестаёт слать ботов, считает их
## у себя без отправки, пока не придут пакеты нового ведущего (не дольше HANDOVER_S), и убирает.
##
## Создаёт и ведёт NetFlight: setup(...), start_in_game(game) после join_world; teardown().
## Тесты: setup(zone, pilots, parent), start(setup_fn), tick(dt, телеметрия) вручную.
##
## Для очереди (NET-43): bot_ids() — id ботов зоны в порядке очереди ботов (у ведущего — свои,
## у остальных — из NetPilots, по номеру); is_simulating(); agent_for(id). spot_fn задан
## (NetFlight → NetQueue.spot) — боты ведущего стоят и бегут по очереди зоны (NetZone.queue):
## BotPilots.spot_index_fn — место бота в ней (не в очереди — после неё).

## Сколько бывший ведущий ждёт пакетов нового, прежде чем убрать своих ботов, с.
const HANDOVER_S := 2.0
const BOT_PREFIX := "bot-"
## Фаза BotAgent → PilotPhase (net.proto, без префикса).
const PHASES := ["STAND", "WALK", "STAND", "RUN", "FLY", "LANDED"]

## NetZone / NetPilots или объекты с теми же полями и методами (тесты).
var zone: Object
var pilots: Object
## Боты, которых считает этот клиент (ведущий); null — не считает.
var sim: BotPilots = null
## Показывать ботов (false — только физика, headless-тесты).
var visuals := true
## Id своих ботов по порядку sim.agents ("bot-0"…).
var ids: Array[String] = []
## Место ожидания k очереди зоны: (k) -> {position, heading_deg}; не задано — боты стоят и
## бегут, как в одиночной игре (после отрыва живых пилотов).
var spot_fn := Callable()

var _parent: Node
var _game: Game = null
## fn(sim: BotPilots, count: int) — поставить ботов в мир (setup / setup_in_world).
var _setup_fn := Callable()
var _started := false
## Бывший ведущий досчитывает своих до прихода чужих пакетов: сколько ещё ждать, с; < 0 — нет.
var _handover_left := -1.0


## p_zone/p_pilots — null: автозагрузки NetZone/NetPilots; parent — куда вешать BotPilots.
func setup(p_zone: Object, p_pilots: Object, parent: Node) -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	zone = p_zone if p_zone != null else root.get_node_or_null("NetZone")
	pilots = p_pilots if p_pilots != null else root.get_node_or_null("NetPilots")
	_parent = parent
	name = "NetBots"
	process_mode = Node.PROCESS_MODE_ALWAYS
	if zone != null and zone.has_signal("leader_changed"):
		zone.connect("leader_changed", _on_leader_changed)


## Мир игры построен (после NetFlight.join_world): ботов — у старта игры, шаг — сам по физике.
func start_in_game(game: Game) -> void:
	_game = game
	var st: Dictionary = game.get_start()
	start(
		func(b: BotPilots, count: int) -> void:
			b.setup_in_world(game.terrain, game.air, st.position, float(st.heading_deg), count)
	)


## Начать: fn(sim, count) ставит BotPilots в мир. Ведущий — сразу считает ботов.
func start(setup_fn: Callable) -> void:
	_setup_fn = setup_fn
	_started = true
	if _is_leader():
		_take_over()


func teardown() -> void:
	_started = false
	if zone != null and zone.has_signal("leader_changed"):
		if zone.is_connected("leader_changed", _on_leader_changed):
			zone.disconnect("leader_changed", _on_leader_changed)
	_stop_sim()


func is_simulating() -> bool:
	return sim != null and _handover_left < 0.0


## Id ботов зоны в порядке очереди ботов: у ведущего — свои по порядку BotPilots, у остальных —
## боты из NetPilots по номеру ("bot-2" раньше "bot-10").
func bot_ids() -> Array[String]:
	if is_simulating():
		return ids.duplicate()
	var out: Array[String] = []
	if pilots == null:
		return out
	for id: String in pilots.call("get_pilot_ids"):
		if id.begins_with(BOT_PREFIX):
			out.append(id)
	out.sort_custom(func(x: String, y: String) -> bool: return _num(x) < _num(y))
	return out


## Бот, которого считает этот клиент, по id (null — не свой).
func agent_for(id: String) -> BotAgent:
	var i := ids.find(id)
	return sim.agents[i] if sim != null and i >= 0 and i < sim.agents.size() else null


func _physics_process(dt: float) -> void:
	if _game != null and is_instance_valid(_game.glider):
		tick(dt, _game.glider.get_telemetry())


## Шаг ботов: у ведущего — физика и отправка; у бывшего — досчитать до передачи.
func tick(dt: float, player: Telemetry) -> void:
	if sim == null:
		return
	sim.others = _other_humans()
	sim.tick(dt, player)
	if _handover_left >= 0.0:
		_handover_left -= dt
		if _handover_left < 0.0 or _all_remote():
			_stop_sim()
		return
	send_states()


## Состояния своих ботов — в NetPilots (между шагами бота — по скорости).
func send_states() -> void:
	if sim == null or pilots == null:
		return
	for i in sim.agents.size():
		var a := sim.agents[i]
		var t := a.telemetry()
		pilots.call(
			"send_bot_state",
			ids[i],
			t.position + t.velocity * a.acc_s,
			Quaternion(t.basis.orthonormalized()),
			t.velocity,
			phase_of(a),
			a.pilot_name,
			"wings/" + a.wing_id,
			colors_of(a.scheme)
		)


## Фаза бота для PilotPhase: по модели (в воздухе / сел), на земле — по шагу очереди.
static func phase_of(a: BotAgent) -> String:
	if a.is_airborne():
		return "FLY"
	if (
		a.model.mode == FlightModel.Mode.LANDED
		or a.state in [BotAgent.State.FLY, BotAgent.State.LANDED]
	):
		return "LANDED"
	return PHASES[a.state]


static func colors_of(scheme: Dictionary) -> Variant:
	if scheme.is_empty():
		return null
	return {
		"hueDeg": float(scheme.get("hue_deg", 0.0)),
		"sat": float(scheme.get("sat", 1.0)),
		"value": float(scheme.get("value", 1.0)),
	}


## Курс, °, и крен, рад, из ориентации (Telemetry.basis = from_euler(θ, −курс, −крен)).
static func heading_bank(rot: Quaternion) -> Vector2:
	var e := Basis(rot).get_euler()
	return Vector2(fposmod(-rad_to_deg(e.y), 360.0), -e.z)


# ---------------------------------------------------------------- ведущий


func _on_leader_changed(_leader_id: String, is_me: bool) -> void:
	if not _started:
		return
	if is_me and not is_simulating():
		_take_over()
	elif not is_me and sim != null and _handover_left < 0.0:
		# Больше не ведущий: не слать, досчитать своих, пока не придут пакеты нового.
		if pilots != null and pilots.has_method("clear_bots"):
			pilots.call("clear_bots")
		_handover_left = HANDOVER_S


## Начать считать ботов: продолжить известных по последним состояниям, остальных — свежими.
func _take_over() -> void:
	_stop_sim()
	var count := int(zone.get("bots_count"))
	if count <= 0 or not _setup_fn.is_valid():
		return
	sim = BotPilots.new()
	sim.name = "NetBotPilots"
	sim.fixed_names = true
	sim.visuals_enabled = false
	_parent.add_child(sim)
	if spot_fn.is_valid():
		sim.spot_fn = spot_fn
		sim.spot_index_fn = _spot_index
	_setup_fn.call(sim, count)
	ids.clear()
	for i in sim.agents.size():
		ids.append("")
	var known := _known_states()
	var rest: Array[String] = []
	for id: String in known:
		var k := _num(id)
		if k >= 0 and k < ids.size() and ids[k] == "":
			ids[k] = id
		else:
			rest.append(id)
	for id in rest:
		var k := ids.find("")
		if k >= 0:
			ids[k] = id
	for i in ids.size():
		if ids[i] == "":
			ids[i] = _free_id(i)
		elif known.has(ids[i]):
			_continue(sim.agents[i], known[ids[i]])
	var took := known.size()
	print("NetBots: считаю ботов — %d, продолжены %d %s" % [ids.size(), took, ids])
	if visuals:
		sim.visuals_enabled = true
		sim.build_visuals()
	send_states()  # NetPilots сразу убирает чужие снимки этих ботов — без двойных


## Бот с последнего полученного состояния s (NetPilots.sample).
func _continue(a: BotAgent, s: Dictionary) -> void:
	var pos: Vector3 = s.get("pos", a.model.position)
	var hb := heading_bank(s.get("rot", Quaternion.IDENTITY))
	var n := String(s.get("name", ""))
	if n != "":
		a.pilot_name = n
	var c: Variant = s.get("colors")
	if c is Dictionary:
		a.scheme = {
			"hue_deg": float(c.get("hueDeg", 0.0)),
			"sat": float(c.get("sat", 1.0)),
			"value": float(c.get("value", 1.0)),
		}
	match String(s.get("phase", "STAND")):
		"FLY", "TOW":
			a.start_in_air(pos, hb.x, sim.sim_time_s)
			a.model.velocity = s.get("vel", a.model.velocity)
			a.model.bank = hb.y
			a.model.telemetry.velocity = a.model.velocity
		"LANDED", "CRASHED":
			a.place(pos, hb.x)
			a.state = BotAgent.State.LANDED
			a.landed_s = sim.sim_time_s
		_:
			a.place(pos, hb.x)


## Последние состояния ботов зоны, которые видит этот клиент: id → sample.
func _known_states() -> Dictionary:
	var out := {}
	if pilots == null:
		return out
	for id: String in pilots.call("get_pilot_ids"):
		var s: Dictionary = pilots.call("sample", id)
		if not s.is_empty() and bool(s.get("is_bot", false)):
			out[id] = s
	return out


## Место бота i в очереди зоны; не в очереди — после неё, по порядку ботов.
func _spot_index(i: int) -> int:
	var zq: Variant = zone.get("queue") if zone != null else null
	var q: Array = zq if zq is Array else []
	var id := ids[i] if i < ids.size() else ""
	var k := q.find(id) if id != "" else -1
	return k if k >= 0 else q.size() + i


func _free_id(i: int) -> String:
	var k := i
	while ids.has(BOT_PREFIX + str(k)):
		k += ids.size()
	return BOT_PREFIX + str(k)


## Живые пилоты зоны, кроме себя, для BotPilots.others.
func _other_humans() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if pilots == null:
		return out
	for id: String in pilots.call("get_pilot_ids"):
		if id.begins_with(BOT_PREFIX):
			continue
		var s: Dictionary = pilots.call("sample", id)
		if s.is_empty() or bool(s.get("is_bot", false)):
			continue
		var ph := String(s.get("phase", ""))
		out.append({"pos": s.pos, "vel": s.vel, "flying": ph == "FLY" or ph == "TOW"})
	return out


func _all_remote() -> bool:
	for id in ids:
		if not bool(pilots.call("has_pilot", id)):
			return false
	return true


func _stop_sim() -> void:
	_handover_left = -1.0
	if sim == null:
		return
	if pilots != null and pilots.has_method("clear_bots") and _is_leader():
		pilots.call("clear_bots")
	sim.clear()
	sim.queue_free()
	sim = null
	ids.clear()


func _is_leader() -> bool:
	return zone != null and zone.has_method("is_leader") and bool(zone.call("is_leader"))


static func _num(id: String) -> int:
	var s := id.trim_prefix(BOT_PREFIX)
	return int(s) if s.is_valid_int() else 1 << 30
