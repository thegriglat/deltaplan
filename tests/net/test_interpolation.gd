extends Node
## NET-32. Состояния пилотов: RemotePilotState (интерполяция, экстраполяция, «пропал»,
## пакеты не по порядку), трафик своего PilotState (≤ 2 КБ/с), NetPilots с локальным
## Go-сервером (NetTestServer; нет go — SKIP этой части).
##
## Гладкость (приёмка «без рывков > 0,5 м между кадрами на 30 км/ч»): пилот 8,33 м/с на
## S-образных виражах (радиус до 20 м) и наборе 1 м/с; пакеты 10 Гц, задержка 50 мс ± 50 мс
## (случайно, сид фиксирован), отрисовка 60 кадров/с на zone_time − 0,15 с. Для каждой пары
## соседних кадров «рывок» = |Δpos_отрисованная − Δpos_истинная| (Δpos_истинная — путь
## настоящего пилота между теми же моментами); ещё проверяется отставание от истинной
## траектории |pos_отрисованная − pos_истинная(t)|. Оба ≤ 0,5 м, в том числе при потере 20 %.

const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const NET_ZONE := preload("res://scripts/net/net_zone.gd")
const NET_PILOTS := preload("res://scripts/net/net_pilots.gd")

const SPEED := 30.0 / 3.6
const MIN_RADIUS := 20.0
const CLIMB := 1.0
const SIM_S := 60.0
const FPS := 60.0
const MAX_JUMP_M := 0.5
const TRAFFIC_LIMIT := 2048.0

## Шаг истинной траектории, с.
const PATH_DT := 0.001

var failures: PackedStringArray = []

## Истинная траектория с шагом PATH_DT: позиции, скорости, курсы.
var _path_pos: PackedVector3Array = []
var _path_vel: PackedVector3Array = []
var _path_head: PackedFloat32Array = []


## Заглушка NetZone для трафика: те же сигналы и поля, отправка — в список текстов кадров.
class FakeZone:
	extends Node
	signal pilot_state_received(from_id: String, data: Dictionary)
	signal peer_left(id: String)
	signal zone_left
	signal zone_entered(code: String)
	var in_zone := true
	var has_clock := true
	var my_id := "7"
	var peers := {"7": {"id": "7", "name": "Григорий", "joinOrder": 1}}
	var leader := true
	var clock := 0.0
	var sent: PackedStringArray = []

	func zone_time() -> float:
		return clock

	func is_leader() -> bool:
		return leader

	func send_pilot_state(d: Dictionary) -> bool:
		sent.append(NetMessages.encode("pilotState", d))
		return true


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_smooth_with_jitter() -> void:
	var r := _run_stream(0.0, 11)
	print("  NET-32 джиттер ±50 мс: рывок max %.4f м, отставание max %.4f м, extrap %d кадров"
		% [r.jump, r.err, r.extrap])
	check(r.jump <= MAX_JUMP_M, "рывок %.3f м" % r.jump)
	check(r.err <= MAX_JUMP_M, "отставание от траектории %.3f м" % r.err)
	check(r.max_step <= SPEED / FPS + MAX_JUMP_M, "шаг кадра %.3f м" % r.max_step)


func test_smooth_with_loss() -> void:
	var r := _run_stream(0.2, 23)
	print(
		"  NET-32 потери 20 %%: рывок max %.4f м, отставание max %.4f м, extrap %d, потеряно %d"
		% [r.jump, r.err, r.extrap, r.lost])
	check(r.lost > 0, "потери были")
	check(r.jump <= MAX_JUMP_M, "рывок %.3f м" % r.jump)
	check(r.err <= MAX_JUMP_M, "отставание от траектории %.3f м" % r.err)
	check(r.max_step <= SPEED / FPS + MAX_JUMP_M, "шаг кадра %.3f м" % r.max_step)


func test_extrapolate_hold_lost() -> void:
	var rs := RemotePilotState.new("5")
	var vel := Vector3(SPEED, 0.0, 0.0)
	for k in 11:
		var t := k * 0.1
		rs.push(_state(t, Vector3(SPEED * t, 1000.0, 0.0), vel, "PILOT_PHASE_FLY"), 100.0 + t)
	var last := Vector3(SPEED * 1.0, 1000.0, 0.0)
	var s := rs.sample(0.95)
	check(s.mode == "interp" and s.pos.distance_to(Vector3(SPEED * 0.95, 1000.0, 0.0)) < 1e-3,
		"интерполяция: %s" % [s])
	s = rs.sample(1.5)
	check(s.mode == "extrap", "экстраполяция: %s" % s.mode)
	check(s.pos.distance_to(last + vel * 0.5) < 1e-3, "по скорости 0,5 с: %s" % [s.pos])
	s = rs.sample(2.0)
	check(s.mode == "extrap" and s.pos.distance_to(last + vel) < 1e-3, "ровно 1 с: %s" % [s])
	s = rs.sample(3.0)
	check(s.mode == "hold", "потом стоит: %s" % s.mode)
	check(s.pos.distance_to(last + vel) < 1e-3, "стоит там, где кончилась экстраполяция")
	check(s.vel == Vector3.ZERO and s.phase == "FLY", "стоит: vel 0, фаза прежняя")
	check(rs.sample(10.0).pos.distance_to(last + vel) < 1e-3, "стоит и дальше")
	check(not rs.is_lost(101.0 + 4.9), "4,9 с тишины — ещё не пропал")
	check(rs.is_lost(101.0 + 5.1), "5,1 с тишины — пропал")
	# новый пакет после паузы — снова интерполяция
	rs.push(_state(12.0, Vector3(100.0, 1000.0, 0.0), vel, ""), 112.0)
	check(not rs.is_lost(112.0), "пакет пришёл — снова виден")
	check(rs.sample(12.0).pos.distance_to(Vector3(100.0, 1000.0, 0.0)) < 1e-3, "новый снимок")


func test_out_of_order_and_meta() -> void:
	var rs := RemotePilotState.new("bot-2")
	var vel := Vector3(0.0, 0.0, -SPEED)
	var full := _state(0.0, Vector3.ZERO, vel, "PILOT_PHASE_STAND")
	full.merge({"isBot": true, "name": "Вася", "wing": "wings/sport", "colors": null}, true)
	check(rs.push(full, 0.0), "первый")
	check(rs.is_bot and rs.name == "Вася" and rs.wing == "wings/sport", "метаданные")
	check(rs.push(_state(0.2, vel * 0.2, vel, "PILOT_PHASE_RUN"), 0.25), "t=0,2")
	check(rs.push(_state(0.1, vel * 0.1, vel, ""), 0.26), "t=0,1 позже t=0,2 — ещё не поздно")
	check(not rs.push(_state(0.1, vel * 5.0, vel, ""), 0.27), "повтор t=0,1 отброшен")
	check(rs.snapshot_count() == 3, "три снимка: %d" % rs.snapshot_count())
	var s := rs.sample(0.15)
	check(s.pos.distance_to(vel * 0.15) < 1e-3, "между 0,1 и 0,2: %s" % [s.pos])
	check(s.phase == "STAND", "фаза снимка 0,1 (не было в пакете) — от 0,0: %s" % s.phase)
	check(not rs.push(_state(0.12, vel * 9.0, vel, ""), 0.3), "раньше отрисованного — отброшен")
	check(rs.sample(0.2).phase == "RUN", "фаза RUN")
	# неполный пакет не стирает метаданные; полный без colors — родная текстура
	var c := {"hueDeg": 120.0, "sat": 1.0, "value": 1.0}
	var f2 := _state(0.3, vel * 0.3, vel, "")
	f2.merge({"name": "Вася", "wing": "wings/laminar", "colors": c}, true)
	rs.push(f2, 0.35)
	rs.push(_state(0.4, vel * 0.4, vel, ""), 0.45)
	check(rs.wing == "wings/laminar" and rs.colors == c, "метаданные держатся: %s" % [rs.colors])
	var f3 := _state(0.5, vel * 0.5, vel, "")
	f3.merge({"name": "Вася", "wing": "wings/laminar", "colors": null}, true)
	rs.push(f3, 0.55)
	check(rs.colors == null, "полный пакет без colors — родная текстура")
	check(rs.sample(0.5).phase == "RUN", "фаза держится без phase в пакетах")


## Трафик своего PilotState: NetPilots → NetMessages 10 Гц за 10 с, кадр WebSocket
## клиента (маска 4 байта + заголовок 2/4 байта). Заодно приём тех же кадров — метаданные
## и фаза восстанавливаются из неполных пакетов.
func test_traffic() -> void:
	var zone := FakeZone.new()
	var np: Node = NET_PILOTS.new()
	np.setup(zone)
	add_child(zone)
	add_child(np)
	np.process_mode = Node.PROCESS_MODE_DISABLED  # _process зовём сами
	var colors := {"hueDeg": 213.7, "sat": 0.93, "value": 1.1}
	var dt := 1.0 / FPS
	var frames := int(10.0 * FPS)
	var center := Vector3(-3456.7, 1987.3, 5123.4)
	for i in frames:
		var t := i * dt
		zone.clock = 1234.5 + t
		var a := t * SPEED / MIN_RADIUS
		var pos := center + Vector3(cos(a), 0.0, sin(a)) * MIN_RADIUS + Vector3.UP * CLIMB * t
		var vel := Vector3(-sin(a), 0.0, cos(a)) * SPEED + Vector3.UP * CLIMB
		var rot := Quaternion(Vector3.UP, -a) * Quaternion(Vector3.BACK, 0.35)
		var phase := "RUN" if t < 3.0 else "FLY"
		np.set_local_state(pos, rot, vel, phase, "wings/sport", colors)
		np._process(dt)
	var bytes := 0
	var payload := 0
	for text in zone.sent:
		var n := text.to_utf8_buffer().size()
		payload += n
		bytes += n + (6 if n < 126 else 8)
	var bps := bytes / 10.0
	var sizes := []
	for text in zone.sent:
		sizes.append(text.to_utf8_buffer().size())
	print(
		"  NET-32 трафик: %d пакетов за 10 с, %.0f Б/с с кадрами WS, полезных %.0f Б/с, %d–%d Б"
		% [zone.sent.size(), bps, payload / 10.0, sizes.min(), sizes.max()])
	print("    полный: %s" % zone.sent[0])
	print("    обычный: %s" % zone.sent[5])
	check(zone.sent.size() >= 99 and zone.sent.size() <= 101, "10 Гц: %d" % zone.sent.size())
	check(bps <= TRAFFIC_LIMIT, "трафик %.0f Б/с > %.0f" % [bps, TRAFFIC_LIMIT])
	# приём тех же кадров
	var rs := RemotePilotState.new("7")
	var phases := {}
	for text in zone.sent:
		var m := NetMessages.decode(text)
		check(m.type == "pilotState", "тип")
		rs.push(m.data, 0.0)
		phases[rs.sample(m.data.t).phase] = true
	check(rs.name == "Григорий" and rs.wing == "wings/sport", "метаданные: %s %s" % [rs.name, rs.wing])
	check(rs.colors is Dictionary and absf(rs.colors.hueDeg - 213.7) < 0.05, "цвет: %s" % [rs.colors])
	check(phases.keys() == ["RUN", "FLY"], "фазы: %s" % [phases.keys()])
	np.queue_free()
	zone.queue_free()


## Два клиента в зоне через локальный Go-сервер: A шлёт своё и бота, B видит обоих;
## A уходит → pilot_lost(A) у B, бот остаётся (его продолжит новый ведущий).
func test_two_clients_server() -> void:
	if not NetTestServer.available():
		check(NetTestServer.build_error == "", NetTestServer.build_error)
		if NetTestServer.build_error == "":
			print("  SKIP test_two_clients_server: %s" % NetTestServer.skip_reason)
		return
	var srv := NetTestServer.new()
	if not srv.start():
		check(false, "сервер не запустился: %s" % srv.last_error)
		return
	var a := await _pilot(srv, "Папа")
	var b := await _pilot(srv, "Мама")
	if not (a.client.is_online and b.client.is_online):
		check(false, "не подключились")
		_free([a, b])
		srv.stop()
		return
	var appeared := []
	var lost := []
	b.pilots.pilot_appeared.connect(func(id: String, bot: bool) -> void: appeared.append([id, bot]))
	b.pilots.pilot_lost.connect(func(id: String) -> void: lost.append(id))
	var a_seen := []
	a.pilots.pilot_appeared.connect(func(id: String, _b: bool) -> void: a_seen.append(id))
	a.zone.create_zone(FlightSettings.new(), 5, 1)
	await _wait(func() -> bool: return a.zone.in_zone, 3.0)
	b.zone.join_zone(a.zone.code)
	await _wait(func() -> bool: return b.zone.in_zone and b.zone.has_clock, 3.0)
	var a_id: String = a.client.my_id
	var pos := Vector3(120.5, 2100.25, -340.75)
	var rot := Quaternion(Vector3.UP, 0.8)
	var colors := {"hueDeg": 40.0, "sat": 1.0, "value": 1.0}
	a.pilots.set_local_state(pos, rot, Vector3.ZERO, "STAND", "wings/sport", colors)
	var bot_pos := Vector3(10.0, 1900.0, 20.0)
	a.pilots.send_bot_state(
		"bot-1", bot_pos, Quaternion.IDENTITY, Vector3.ZERO, "FLY", "Бот", "wings/sport"
	)
	await _wait(func() -> bool: return b.pilots.has_pilot(a_id) and b.pilots.has_pilot("bot-1"), 3.0)
	# буфер интерполяции наполнился
	await _wait(func() -> bool: return false, 0.5)
	check(b.pilots.get_pilot_ids().size() == 2, "у B двое: %s" % [b.pilots.get_pilot_ids()])
	check(appeared.has([a_id, false]) and appeared.has(["bot-1", true]), "появились: %s" % [appeared])
	var s: Dictionary = b.pilots.sample(a_id)
	check(not s.is_empty() and s.pos.distance_to(pos) < 0.02, "позиция A у B: %s" % [s.get("pos")])
	check(s.get("rot", Quaternion()).angle_to(rot) < 0.01, "ориентация A у B")
	check(s.get("name") == "Папа" and s.get("phase") == "STAND" and not s.get("is_bot"), "A: %s" % [s])
	check(s.get("wing") == "wings/sport" and s.get("colors") is Dictionary, "крыло и цвет A")
	var sb: Dictionary = b.pilots.sample("bot-1")
	check(sb.get("is_bot") and sb.get("name") == "Бот", "бот у B: %s" % [sb])
	check(sb.get("pos", Vector3.ZERO).distance_to(bot_pos) < 0.02, "позиция бота")
	check(a_seen.is_empty(), "A не видит себя и своего бота: %s" % [a_seen])
	a.zone.leave_zone()
	await _wait(func() -> bool: return lost.has(a_id), 3.0)
	check(lost == [a_id], "A пропал у B: %s" % [lost])
	check(b.pilots.has_pilot("bot-1"), "бот остался у B")
	_free([a, b])
	srv.stop()


## Прогон потока: потери loss, сид seed → {jump, err, max_step, extrap, lost}.
func _run_stream(loss: float, seed_value: int) -> Dictionary:
	if _path_pos.is_empty():
		_build_path()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	# пакеты: время состояния t (часы зоны отправителя = получателя), время прихода
	var packets := []
	var lost := 0
	var n := int(SIM_S * 10.0)
	for k in n:
		var t := k * 0.1 + rng.randf_range(0.0, 1.0 / FPS)
		var arrive := t + 0.05 + rng.randf_range(-0.05, 0.05)
		if rng.randf() < loss:
			lost += 1
			continue
		var p := _true_at(t)
		var d := _build_state(t, p)
		# через провод: округление и разбор как у настоящего клиента
		var m := NetMessages.decode(NetMessages.encode("pilotState", d))
		packets.append({"arrive": arrive, "data": m.data})
	packets.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.arrive < y.arrive)
	var rs := RemotePilotState.new("9")
	var next := 0
	var out := {"jump": 0.0, "err": 0.0, "max_step": 0.0, "extrap": 0, "lost": lost}
	var prev_pos := Vector3.ZERO
	var prev_true := Vector3.ZERO
	var started := false
	var frames := int((SIM_S - 1.0) * FPS)
	for j in frames:
		var now := j / FPS
		while next < packets.size() and packets[next].arrive <= now:
			rs.push(packets[next].data, packets[next].arrive)
			next += 1
		var rt := now - RemotePilotState.INTERP_DELAY_S
		if rt < 0.5:
			continue
		var s := rs.sample(rt)
		var tp: Vector3 = _true_at(rt).pos
		if s.mode != "interp":
			out.extrap += 1
		out.err = maxf(out.err, s.pos.distance_to(tp))
		if started:
			var step: Vector3 = s.pos - prev_pos
			out.jump = maxf(out.jump, (step - (tp - prev_true)).length())
			out.max_step = maxf(out.max_step, step.length())
		prev_pos = s.pos
		prev_true = tp
		started = true
	return out


## PilotState, как его соберёт NetPilots (округление, полный пакет).
func _build_state(t: float, p: Dictionary) -> Dictionary:
	var st := {"pos": p.pos, "rot": p.rot, "vel": p.vel, "phase": "FLY", "wing": "wings/sport"}
	return NET_PILOTS.build_state("9", false, t, st, true, true, "Пилот")


## S-образные виражи: скорость курса меняется синусом (период 20 с), радиус до MIN_RADIUS.
func _build_path() -> void:
	var n := int((SIM_S + 2.0) / PATH_DT)
	var pos := Vector3(0.0, 1500.0, 0.0)
	var head := 0.0
	_path_pos.resize(n)
	_path_vel.resize(n)
	_path_head.resize(n)
	for i in n:
		var t := i * PATH_DT
		var vel := Vector3(sin(head), 0.0, -cos(head)) * SPEED + Vector3.UP * CLIMB
		_path_pos[i] = pos
		_path_vel[i] = vel
		_path_head[i] = head
		var turn := SPEED / MIN_RADIUS * sin(TAU * t / 20.0)
		# шаг средней точкой — траектория и скорость согласованы
		var mid_head := head + turn * PATH_DT * 0.5
		pos += (Vector3(sin(mid_head), 0.0, -cos(mid_head)) * SPEED + Vector3.UP * CLIMB) * PATH_DT
		head += turn * PATH_DT


## Истинное состояние на t: {pos, vel, rot}.
func _true_at(t: float) -> Dictionary:
	var f := t / PATH_DT
	var i := clampi(int(f), 0, _path_pos.size() - 2)
	var s := f - i
	var head := lerpf(_path_head[i], _path_head[i + 1], s)
	return {
		"pos": _path_pos[i].lerp(_path_pos[i + 1], s),
		"vel": _path_vel[i].lerp(_path_vel[i + 1], s),
		"rot": Quaternion(Vector3.UP, -head),
	}


func _state(t: float, pos: Vector3, vel: Vector3, phase: String) -> Dictionary:
	var d := NetMessages.defaults("pilotState")
	d.t = t
	d.pos = NetMessages.vec3(pos)
	d.vel = NetMessages.vec3(vel)
	d.phase = phase if phase != "" else "PILOT_PHASE_UNSPECIFIED"
	return d


func _pilot(srv: NetTestServer, pilot_name: String) -> Dictionary:
	var c: Node = NET_CLIENT.new()
	c.reconnect_delays_s = [0.3, 0.3, 0.3]
	add_child(c)
	var z: Node = NET_ZONE.new()
	z.state_interval_s = 0.5
	z.setup(c)
	add_child(z)
	var p: Node = NET_PILOTS.new()
	p.setup(z)
	add_child(p)
	c.connect_to_server(srv.address, pilot_name)
	await _wait(func() -> bool: return c.is_online, 5.0)
	return {"client": c, "zone": z, "pilots": p}


func _free(pilots: Array) -> void:
	for p: Dictionary in pilots:
		p.client.disconnect_from_server()
		p.pilots.queue_free()
		p.zone.queue_free()
		p.client.queue_free()


func _wait(cond: Callable, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
