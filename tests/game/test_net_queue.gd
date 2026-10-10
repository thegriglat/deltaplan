extends TestCase
## Очередь на старт в сетевой зоне (NET-43, NetQueue): живые пилоты взлетают строго по очереди,
## боты ведущего (NetBots → BotPilots) — после них; первый, простоявший 60 с, — в конец;
## «На старт» после посадки/аварии — в конец живых (пустая очередь — сразу первый); смена
## ведущего посреди очереди её не ломает; буксир — из очереди. Зона — подделка с полями NetZone
## (queue, my_id, is_leader, set_queue, peer_ids); мир — как в test_bots, без узлов.

const DT := 1.0 / 120.0
const TB := preload("res://tests/game/test_bots.gd")
const START := Vector3(0.0, 300.0, -1.0)


class FakeZone:
	extends RefCounted
	signal leader_changed(leader_id: String, is_me: bool)
	var my_id := "1"
	var leader_id := "1"
	var bots_count := 0
	var in_zone := true
	var queue: Array[String] = []
	var peers: Array[String] = ["1", "2", "3"]
	var sets := 0

	func is_leader() -> bool:
		return leader_id == my_id

	func set_queue(ids: Array) -> void:
		queue.assign(ids)
		sets += 1

	func peer_ids() -> Array[String]:
		return peers.duplicate()

	func set_leader(id: String) -> void:
		leader_id = id
		leader_changed.emit(id, is_leader())


class FakePilots:
	extends RefCounted
	signal pilot_lost(id: String)

	func send_bot_state(
		_id: String,
		_pos: Vector3,
		_rot: Quaternion,
		_vel: Vector3,
		_phase: String,
		_bot_name: String,
		_wing: String,
		_colors: Variant = null
	) -> void:
		pass

	func clear_bots() -> void:
		pass

	func get_pilot_ids() -> Array[String]:
		return []

	func has_pilot(_id: String) -> bool:
		return false

	func sample(_id: String) -> Dictionary:
		return {}


var _root: Node


## Очередь ведущего: статусы живых — словарь status (id → "wait"/"run"/"gone"), ботов — nb.
func make_queue(z: FakeZone, status: Dictionary, nb: NetBots = null) -> NetQueue:
	var q := NetQueue.new()
	q.zone = z
	q.status_fn = func(id: String) -> String:
		var a := nb.agent_for(id) if nb != null else null
		if a != null:
			return NetQueue.bot_status(a)
		return String(status.get(id, "unknown"))
	q.bot_ids_fn = func() -> Array: return nb.bot_ids() if nb != null else []
	q.spots_fn = func(n: int) -> Array[Dictionary]:
		return NetQueue.spots_for(TB.hill, START, 0.0, n)
	return q


func make_bots(z: FakeZone, q: NetQueue, count: int) -> NetBots:
	z.bots_count = count
	if _root == null:
		_root = Node.new()
	var nb := NetBots.new()
	nb.visuals = false
	_root.add_child(nb)
	nb.setup(z, FakePilots.new(), _root)
	nb.spot_fn = q.spot
	nb.start(
		func(b: BotPilots, n: int) -> void:
			b.setup(
				{
					"air_fn": TB.air,
					"ground_fn": TB.hill,
					"start": START,
					"heading_deg": 0.0,
					"count": n,
					"airborne_share": 0.0,
				}
			)
	)
	return nb


func done() -> void:
	if _root != null:
		_root.free()
		_root = null


static func standing() -> Telemetry:
	var t := Telemetry.new()
	t.phase = "standing"
	t.position = START
	return t


## Трое живых и два бота: живые — строго по очереди (бежит только первый), боты — после всех
## живых и тоже по очереди; пока живые ждут, боты стоят на своих местах за ними.
func test_humans_in_order_then_bots() -> void:
	var z := FakeZone.new()
	z.queue.assign(["1", "2", "3"])
	var st := {"1": "wait", "2": "wait", "3": "wait"}
	var q := make_queue(z, st)
	var nb := make_bots(z, q, 2)
	q.bot_ids_fn = nb.bot_ids
	q.status_fn = func(id: String) -> String:
		var a := nb.agent_for(id)
		return NetQueue.bot_status(a) if a != null else String(st.get(id, "unknown"))
	var order: Array[String] = []
	var t := 0.0
	var human_gone_t := 0.0
	var ran_early := false
	var at_spots := false
	var bot_run := {}
	var next_human_t := 3.0
	for i in int(260.0 / DT):
		t += DT
		nb.tick(DT, standing())
		if i % 12 == 0:
			q.lead(t)
		# Живой бежит, только если он первый (так держит разбег NetFlight), через 3 с.
		var first := z.queue[0] if not z.queue.is_empty() else ""
		for id: String in st:
			if st[id] == "run":
				st[id] = "gone"
				order.append(id)
				human_gone_t = t
				next_human_t = t + 35.0
			elif st[id] == "wait" and id == first and t >= next_human_t:
				st[id] = "run"
		for k in nb.ids.size():
			var a := nb.sim.agents[k]
			if a.run_start_s >= 0.0 and not bot_run.has(nb.ids[k]):
				bot_run[nb.ids[k]] = t
				order.append(nb.ids[k])
				ran_early = ran_early or order.size() <= 3
		if t > 30.0 and t < 36.0 and not at_spots:
			# «1» взлетел, «2» и «3» ещё ждут: боты шагнули вперёд — на места 2 и 3 (за живыми)
			var ok := z.queue.size() == 4
			for k in 2:
				var a := nb.sim.agents[k]
				var sp: Vector3 = q.spot(z.queue.find(nb.ids[k])).position
				ok = ok and a.state == BotAgent.State.WAIT and z.queue.find(nb.ids[k]) == 2 + k
				ok = ok and Vector2(a.model.position.x - sp.x, a.model.position.z - sp.z).length() < 3.0
			at_spots = ok
	check(z.queue.size() <= 2, "очередь разошлась: %s" % [z.queue])
	check(order.slice(0, 3) == ["1", "2", "3"], "живые по очереди: %s" % [order])
	check(order.size() == 5 and order.slice(3) == ["bot-0", "bot-1"], "боты после: %s" % [order])
	check(not ran_early, "боты не бежали раньше живых")
	check(float(bot_run.get("bot-0", 0.0)) > human_gone_t, "первый бот — после отрыва третьего")
	check(at_spots, "пока живые ждут, боты шагнули вперёд на места 2 и 3")
	var s1: Vector3 = q.spot(1).position
	check(s1.distance_to(START) > 8.0 and s1.z > START.z, "место 1 — позади старта: %s" % s1)
	check(q.spot(0).position == START, "место 0 — сам старт")
	done()


## Первый простоял 60 с — в самый конец (за ботами); бегущего не трогаем.
func test_idle_first_to_end() -> void:
	var z := FakeZone.new()
	z.queue.assign(["1", "2", "3", "bot-0"])
	var st := {"1": "wait", "2": "wait", "3": "wait", "bot-0": "wait"}
	var q := make_queue(z, st)
	q.bot_ids_fn = func() -> Array: return ["bot-0"]
	check(not q.lead(0.0), "всё на месте — не шлём")
	q.lead(59.0)
	check(z.queue[0] == "1", "59 с — ещё первый")
	check(q.lead(60.5), "простой — очередь изменилась")
	check(z.queue == ["2", "3", "bot-0", "1"], "в конец: %s" % [z.queue])
	st["2"] = "run"
	q.lead(200.0)
	check(z.queue[0] == "2", "бегущий первый остаётся: %s" % [z.queue])
	st["2"] = "wait"
	q.lead(200.5)
	check(z.queue[0] == "2", "таймер — с момента, как стал первым")
	q.lead(261.0)
	check(z.queue == ["3", "bot-0", "1", "2"], "и он — в конец: %s" % [z.queue])


## «На старт» после посадки / аварии — в конец живых (перед ботами), пустая — сразу первый;
## своё место до решения ведущего клиент предсказывает так же.
func test_return_to_end() -> void:
	var z := FakeZone.new()
	z.queue.assign(["1", "2", "3", "bot-0"])
	var st := {"1": "run", "2": "wait", "3": "wait", "bot-0": "wait"}
	var q := make_queue(z, st)
	q.bot_ids_fn = func() -> Array: return ["bot-0"]
	q.lead(0.0)
	st["1"] = "gone"  # взлетел
	q.lead(0.1)
	check(z.queue == ["2", "3", "bot-0"], "взлетел — из очереди: %s" % [z.queue])
	# У вошедшего «2» (не ведущий) — предсказание места «1» после «На старт».
	var zc := FakeZone.new()
	zc.my_id = "1"
	zc.leader_id = "2"
	zc.queue.assign(z.queue)
	var qc := make_queue(zc, st)
	check(qc.my_index() == -1 and qc.predicted_index() == 2, "клиент встанет на место 2")
	st["1"] = "wait"  # сел (или разбился), «На старт»
	q.lead(1.0)
	check(z.queue == ["2", "3", "1", "bot-0"], "в конец живых, перед ботами: %s" % [z.queue])
	# Сорванный старт: CRASHED у старта — не в очереди.
	check(NetQueue.status_of("CRASHED", START, START) == "gone", "авария — не в очереди")
	check(NetQueue.status_of("LANDED", START, START) == "gone", "сел — не в очереди")
	check(NetQueue.status_of("STAND", START + Vector3(400, 0, 0), START) == "gone", "далеко")
	check(NetQueue.status_of("WALK", START + Vector3(30, 0, 20), START) == "wait", "у старта")
	check(NetQueue.status_of("RUN", START, START) == "run", "бежит")
	# Пустая очередь — сразу первый.
	var z2 := FakeZone.new()
	var st2 := {"1": "gone", "2": "gone", "3": "gone"}
	var q2 := make_queue(z2, st2)
	q2.lead(0.0)
	check(z2.queue.is_empty(), "все в воздухе — пусто")
	st2["3"] = "wait"
	q2.lead(1.0)
	check(z2.queue == ["3"], "пустая — сразу первый: %s" % [z2.queue])
	# Бот уже идёт на старт первым — вернувшийся встаёт за ним.
	var z3 := FakeZone.new()
	z3.queue.assign(["bot-0", "bot-1"])
	var st3 := {"bot-0": "run", "bot-1": "wait", "1": "wait", "2": "gone", "3": "gone"}
	var q3 := make_queue(z3, st3)
	q3.bot_ids_fn = func() -> Array: return ["bot-0", "bot-1"]
	q3.lead(0.0)
	check(z3.queue == ["bot-0", "1", "bot-1"], "за ботом на старте: %s" % [z3.queue])


## Смена ведущего посреди очереди: новый ведущий продолжает с последнего ZoneState.queue,
## порядок тот же; бывший больше не шлёт.
func test_leader_change_keeps_order() -> void:
	var za := FakeZone.new()
	za.queue.assign(["1", "2", "3", "bot-0"])
	var st := {"1": "wait", "2": "wait", "3": "wait", "bot-0": "wait"}
	var qa := make_queue(za, st)
	qa.bot_ids_fn = func() -> Array: return ["bot-0"]
	st["1"] = "gone"
	qa.lead(10.0)
	check(za.queue == ["2", "3", "bot-0"], "ведущий «1» взлетел: %s" % [za.queue])
	# «1» вышел из зоны, ведущий — «2»: у него последний ZoneState.
	var zb := FakeZone.new()
	zb.my_id = "2"
	zb.leader_id = "1"
	zb.peers.assign(["2", "3"])
	zb.queue.assign(za.queue)
	var qb := make_queue(zb, st)
	qb.bot_ids_fn = func() -> Array: return ["bot-0"]
	check(not qb.lead(11.0) and zb.sets == 0, "не ведущий очередь не трогает")
	zb.set_leader("2")
	za.set_leader("2")
	var sets_a := za.sets
	check(not qa.lead(12.0) and za.sets == sets_a, "бывший ведущий не шлёт")
	check(not qb.lead(12.0), "новый ведущий: порядок тот же")
	check(zb.queue == ["2", "3", "bot-0"], "очередь сохранилась: %s" % [zb.queue])
	# Таймер простоя — с момента смены ведущего (не наследует чужой).
	check(not qb.lead(60.0) and zb.queue[0] == "2", "не выкинут сразу")
	st["2"] = "run"
	qb.lead(61.0)
	st["2"] = "gone"
	qb.lead(62.0)
	check(zb.queue == ["3", "bot-0"], "дальше по очереди: %s" % [zb.queue])


## Буксир поднял с земли — из очереди: у ведущего сразу (leave), у остальных — по фазе TOW.
func test_tow_leaves_queue() -> void:
	var z := FakeZone.new()
	z.queue.assign(["1", "2", "3"])
	var st := {"1": "wait", "2": "wait", "3": "wait"}
	var q := make_queue(z, st)
	q.leave("1")
	check(z.queue == ["2", "3"], "ведущий на буксире — сразу из очереди: %s" % [z.queue])
	st["1"] = NetQueue.status_of("TOW", START, START)
	st["3"] = NetQueue.status_of("TOW", START, START)
	q.lead(1.0)
	check(z.queue == ["2"], "«3» на буксире — из очереди: %s" % [z.queue])
	var zc := FakeZone.new()
	zc.leader_id = "2"
	zc.queue.assign(["2", "1"])
	var qc := make_queue(zc, st)
	qc.leave("1")
	check(zc.queue == ["2", "1"] and zc.sets == 0, "не ведущий сам очередь не меняет")
