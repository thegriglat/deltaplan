extends TestCase
## Боты в сетевой зоне (NET-44, NetBots): считает только ведущий и шлёт их состояния
## (send_bot_state); не ведущий ничего не считает — боты у него только чужие пилоты; при смене
## ведущего новый продолжает ботов с последних полученных состояний — то же число, имена, id
## и места, без скачка; бывший ведущий перестаёт слать и отдаёт ботов. NetZone/NetPilots
## подменены, мир — как в test_bots (вершина, склон на север, термик), без узлов.

const DT := 1.0 / 120.0
const BOTS := 4
const TB := preload("res://tests/game/test_bots.gd")


class FakeZone:
	extends RefCounted
	signal leader_changed(leader_id: String, is_me: bool)
	var my_id := "1"
	var leader_id := "1"
	var bots_count := BOTS
	var in_zone := true

	func is_leader() -> bool:
		return leader_id == my_id

	func set_leader(id: String) -> void:
		leader_id = id
		leader_changed.emit(id, is_leader())


## NetPilots: send_bot_state запоминает; «чужие» (remote) — снимки как у sample.
class FakePilots:
	extends RefCounted
	signal pilot_lost(id: String)
	var zone: FakeZone
	var sent := {}
	var remote := {}
	var cleared := 0

	func send_bot_state(
		id: String,
		pos: Vector3,
		rot: Quaternion,
		vel: Vector3,
		phase: String,
		bot_name: String,
		wing: String,
		colors: Variant = null
	) -> void:
		sent[id] = {
			"pos": pos,
			"rot": rot,
			"vel": vel,
			"phase": phase,
			"name": bot_name,
			"wing": wing,
			"colors": colors,
			"is_bot": true,
		}
		if remote.has(id) and zone.is_leader():  # как NetPilots: свой бот — не чужой
			remote.erase(id)
			pilot_lost.emit(id)

	func clear_bots() -> void:
		sent.clear()
		cleared += 1

	func get_pilot_ids() -> Array[String]:
		var out: Array[String] = []
		out.assign(remote.keys())
		return out

	func has_pilot(id: String) -> bool:
		return remote.has(id)

	func sample(id: String) -> Dictionary:
		return remote.get(id, {})


var _root: Node


static func setup_world(b: BotPilots, count: int) -> void:
	(
		b
		. setup(
			{
				"air_fn": TB.air,
				"ground_fn": TB.hill,
				"start": Vector3(0.0, 300.0, -1.0),
				"heading_deg": 0.0,
				"count": count,
				"airborne_share": 0.0,  # все с земли, как в test_bots (main 0e07d62)
			}
		)
	)


func client(id: String, leader: String) -> NetBots:
	var z := FakeZone.new()
	z.my_id = id
	z.leader_id = leader
	var p := FakePilots.new()
	p.zone = z
	if _root == null:
		_root = Node.new()
	var nb := NetBots.new()
	nb.visuals = false
	_root.add_child(nb)
	nb.setup(z, p, _root)
	nb.start(setup_world)
	return nb


static func player(phase: String, pos: Vector3, vel: Vector3 = Vector3.ZERO) -> Telemetry:
	var t := Telemetry.new()
	t.phase = phase
	t.position = pos
	t.velocity = vel
	t.heading_deg = fposmod(rad_to_deg(atan2(vel.x, -vel.z)), 360.0)
	return t


func flying_player() -> Telemetry:
	return player("flying", Vector3(0, 500, -600), Vector3(0, -1, -10))


func run(nb: NetBots, seconds: float, p: Telemetry) -> void:
	for i in int(seconds / DT):
		nb.tick(DT, p)


func done() -> void:
	if _root != null:
		_root.free()
		_root = null


func test_leader_sends_bot_states() -> void:
	var nb := client("1", "1")
	var p: FakePilots = nb.pilots
	check(nb.is_simulating(), "ведущий считает ботов")
	check(nb.sim.fixed_names, "имена ботов в зоне не меняются со сменой языка")
	check(nb.bot_ids() == ["bot-0", "bot-1", "bot-2", "bot-3"], "id: %s" % [nb.bot_ids()])
	run(nb, 80.0, flying_player())
	check(p.sent.size() == BOTS, "шлёт всех ботов: %d" % p.sent.size())
	for i in BOTS:
		var s: Dictionary = p.sent.get("bot-%d" % i, {})
		var a := nb.sim.agents[i]
		check(s.get("name", "") == a.pilot_name and a.pilot_name != "", "имя бота %d" % i)
		check(String(s.get("wing", "")).begins_with("wings/"), "крыло: %s" % s.get("wing"))
		check(s.get("colors") is Dictionary, "расцветка")
		var want := a.telemetry().position + a.telemetry().velocity * a.acc_s
		check((s.pos as Vector3).distance_to(want) < 0.01, "место бота %d" % i)
	check(
		String(p.sent["bot-0"].phase) == "FLY", "первый бот в воздухе: %s" % p.sent["bot-0"].phase
	)
	check(String(p.sent["bot-3"].phase) == "STAND", "последний ждёт: %s" % p.sent["bot-3"].phase)
	done()


func test_non_leader_only_remote() -> void:
	var nb := client("2", "1")
	var p: FakePilots = nb.pilots
	check(nb.sim == null and not nb.is_simulating(), "не ведущий ботов не считает")
	p.remote = {
		"bot-10": {"is_bot": true, "pos": Vector3.ZERO},
		"1": {"is_bot": false, "pos": Vector3.ZERO},
		"bot-2": {"is_bot": true, "pos": Vector3.ZERO},
	}
	run(nb, 1.0, flying_player())
	check(p.sent.is_empty(), "и не шлёт")
	check(nb.bot_ids() == ["bot-2", "bot-10"], "боты — чужие, по номеру: %s" % [nb.bot_ids()])
	var own := _root.get_children().filter(func(n: Node) -> bool: return n is BotPilots)
	check(own.is_empty(), "своих BotPilots нет")
	done()


## Ведущий A летал 150 с; его последние состояния у B; A вышел — B продолжает.
func test_takeover_from_last_states() -> void:
	var a := client("1", "1")
	var pa: FakePilots = a.pilots
	run(a, 150.0, flying_player())
	var b := client("2", "1")
	var pb: FakePilots = b.pilots
	var names := {}
	for id: String in pa.sent:
		var s: Dictionary = pa.sent[id].duplicate()
		s.name = "Бот " + id  # пул языка первого ведущего — у B он другой
		names[id] = s.name
		pb.remote[id] = s
	var lost: Array[String] = []
	pb.pilot_lost.connect(func(id: String) -> void: lost.append(id))
	var airborne := 0
	for id: String in pa.sent:
		airborne += 1 if pa.sent[id].phase == "FLY" else 0
	check(airborne >= 3, "у A в воздухе ботов: %d" % airborne)
	(b.zone as FakeZone).set_leader("2")
	check(b.is_simulating(), "B считает ботов")
	check(b.sim.agents.size() == BOTS, "число то же: %d" % b.sim.agents.size())
	var before := {}
	for id: String in names:
		var ag := b.agent_for(id)
		check(ag != null, "бот %s продолжен" % id)
		if ag == null:
			continue
		check(ag.pilot_name == names[id], "имя %s: %s" % [id, ag.pilot_name])
		var src: Dictionary = pb.remote.get(id, pa.sent[id])
		approx(ag.model.position.distance_to(pa.sent[id].pos), 0.0, 0.01, "место %s" % id)
		check(ag.is_airborne() == (pa.sent[id].phase == "FLY"), "фаза %s" % id)
		if src.phase == "FLY":
			approx(ag.model.velocity.distance_to(pa.sent[id].vel), 0.0, 0.01, "скорость %s" % id)
		before[id] = ag.model.position
	check(lost.size() == BOTS, "чужие снимки ботов у B убраны сразу: %s" % [lost])
	check(pb.remote.is_empty(), "двойных нет")
	# Шаг: ни один бот не прыгнул дальше шага движения.
	b.tick(DT, flying_player())
	for id: String in before:
		var ag := b.agent_for(id)
		var v: Vector3 = pa.sent[id].vel
		var moved := (pb.sent[id].pos as Vector3).distance_to(before[id])
		check(
			moved <= v.length() * (1.0 / 30.0) * 1.5 + 0.05, "%s сдвинулся на %.2f м" % [id, moved]
		)
		check(pb.sent[id].name == names[id], "шлёт то же имя")
	# Дальше летают: через 20 с все в воздухе ещё двигаются.
	run(b, 20.0, flying_player())
	check(pb.sent.size() == BOTS, "B шлёт всех: %d" % pb.sent.size())
	done()


func test_takeover_fills_missing_bots() -> void:
	var nb := client("2", "1")
	var p: FakePilots = nb.pilots
	p.remote["bot-1"] = {
		"is_bot": true,
		"pos": Vector3(0, 600, -900),
		"vel": Vector3(0, -1, -10),
		"rot": Quaternion.IDENTITY,
		"phase": "FLY",
		"name": "Ваня",
	}
	(nb.zone as FakeZone).set_leader("2")
	check(nb.sim.agents.size() == BOTS, "недостающие добавлены: %d" % nb.sim.agents.size())
	check(nb.ids[1] == "bot-1" and nb.agent_for("bot-1").pilot_name == "Ваня", "известный на месте")
	check(nb.agent_for("bot-1").is_airborne(), "в воздухе")
	check(nb.bot_ids().size() == BOTS, "id без повторов: %s" % [nb.bot_ids()])
	done()


func test_old_leader_hands_over() -> void:
	var nb := client("1", "1")
	var p: FakePilots = nb.pilots
	run(nb, 5.0, flying_player())
	(nb.zone as FakeZone).set_leader("2")
	check(p.cleared >= 1 and p.sent.is_empty(), "бывший ведущий перестал слать ботов")
	check(not nb.is_simulating() and nb.sim != null, "досчитывает до прихода чужих")
	run(nb, 0.5, flying_player())
	check(p.sent.is_empty(), "и не шлёт")
	for id in nb.ids:
		p.remote[id] = {"is_bot": true}
	nb.tick(DT, flying_player())
	check(nb.sim == null, "пришли пакеты нового ведущего — свои убраны")
	check(nb.bot_ids().size() == BOTS, "боты — теперь чужие: %s" % [nb.bot_ids()])
	done()


## BotPilots.others: игрок на земле, в воздухе чужой живой пилот — очередь ботов идёт.
func test_others_start_queue() -> void:
	var b := BotPilots.new()
	b.visuals_enabled = false
	setup_world(b, 2)
	b.others = [{"pos": Vector3(0, 500, -600), "vel": Vector3(0, -1, -10), "flying": true}]
	var stand := player("standing", Vector3(0, 300, -1))
	for i in int(45.0 / DT):
		b.tick(DT, stand)
	check(b.player_liftoff_s >= 0.0, "отрыв чужого запускает очередь")
	check(b.agents[0].run_start_s >= 0.0, "первый бот побежал: %s" % b.agents[0].state_name())
	b.free()
