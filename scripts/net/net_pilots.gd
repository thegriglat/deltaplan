extends Node
## NetPilots (автозагрузка) — состояния пилотов зоны по сети (NET-32): отправка своего
## состояния (и ботов у ведущего) 10 Гц через NetZone, приём чужих, буферы интерполяции
## RemotePilotState, появление и пропажа пилотов.
##
## Отправка (игровой код, NET-40/41/44):
##   set_local_state(pos, rot, vel, phase, wing, colors = null) — своё состояние; звать
##       каждый кадр (или при изменении) — уходит последнее, 10 Гц, пока в зоне и часы зоны
##       известны. phase — "FLY" или "PILOT_PHASE_FLY" (STAND WALK RUN FLY LANDED CRASHED
##       TOW); wing — конфиг крыла ("wings/sport"); colors — {hueDeg, sat, value} или null
##       (родная текстура). Имя — своё из NetZone.peers (Hello.name).
##   set_local_provider(fn: Callable) — вместо set_local_state: fn() → словарь
##       {pos, rot, vel, phase, wing, colors} или {} (не слать); зовётся перед отправкой.
##   clear_local_state() — перестать слать своё (провайдер тоже снимается).
##   send_bot_state(bot_id, pos, rot, vel, phase, bot_name, wing, colors = null) — только
##       у ведущего (NET-44): последнее состояние бота ("bot-3"), уходит 10 Гц вместе со своим.
##       Не ведущий — не шлётся. Чужой снимок этого бота при этом убирается (pilot_lost):
##       бота теперь рисует тот, кто его считает.
##   remove_bot(bot_id) — перестать слать бота; clear_bots() — всех.
##
## Приём:
##   get_pilot_ids() -> Array[String] — чужие пилоты и боты, которых сейчас видно (без себя);
##   has_pilot(id) -> bool; is_bot(id) -> bool;
##   sample(id) -> Dictionary — состояние на zone_time() − interp_delay_s, формат —
##       RemotePilotState.sample: {pos: Vector3, rot: Quaternion, vel: Vector3,
##       phase: "FLY"…, id, name, wing, colors (словарь или null), is_bot, t, mode};
##       {} — такого пилота нет;
##   get_state(id) -> RemotePilotState — сам буфер (null — нет).
##
## Сигналы:
##   pilot_appeared(id, is_bot) — пришёл первый пакет пилота/бота;
##   pilot_lost(id) — 5 с без пакетов, PeerLeft, выход из зоны или бота начали считать здесь.
##
## Id: живой пилот — Envelope.fromId (id от сервера), бот — PilotState.pilotId ("bot-3").
## Свои пакеты (fromId == свой id) не принимаются. Уход ведущего ботов не убирает: новый
## ведущий продолжает их с тем же id.
##
## Трафик (docs/guide/net-protocol.md, PilotState): числа округляются (pos — 1 см, vel — 1 см/с,
## rot — 0,001, t — 1 мс); name/wing/colors — раз в секунду и сразу при изменении, phase —
## при изменении (3 пакета подряд) и раз в секунду. Получатель держит последние известные.
##
## Экземпляры для тестов: load("res://scripts/net/net_pilots.gd").new(), setup(zone),
## add_child. Автозагрузка без setup берёт автозагрузку NetZone.

signal pilot_appeared(id: String, is_bot: bool)
signal pilot_lost(id: String)

## Частота отправки, Гц.
const SEND_HZ := 10.0
## Метаданные (name/wing/colors/phase) не реже, с.
const META_INTERVAL_S := 1.0
## Сколько пакетов подряд повторять phase после смены (на случай потерь).
const PHASE_REPEAT := 3

## Задержка отрисовки, с (тесты меняют).
var interp_delay_s := RemotePilotState.INTERP_DELAY_S

var _zone: Node
var _remotes: Dictionary = {}
var _local: Dictionary = {}
var _provider := Callable()
## bot_id → последнее состояние бота (у ведущего).
var _bots: Dictionary = {}
## id потока ("" — свой, иначе bot_id) → {meta_at, meta_key, phase, phase_left}.
var _streams: Dictionary = {}
var _send_acc := 0.0


func setup(zone: Node) -> void:
	_zone = zone
	_zone.pilot_state_received.connect(_on_pilot_state)
	_zone.peer_left.connect(_drop)
	_zone.zone_left.connect(_on_zone_left)
	_zone.zone_entered.connect(func(_c: String) -> void: _streams.clear())


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _zone == null:
		setup(get_node("/root/NetZone"))


func set_local_state(
	pos: Vector3, rot: Quaternion, vel: Vector3, phase: String, wing: String, colors: Variant = null
) -> void:
	_local = {"pos": pos, "rot": rot, "vel": vel, "phase": phase, "wing": wing, "colors": colors}


func set_local_provider(fn: Callable) -> void:
	_provider = fn


func clear_local_state() -> void:
	_local = {}
	_provider = Callable()


func send_bot_state(
	bot_id: String,
	pos: Vector3,
	rot: Quaternion,
	vel: Vector3,
	phase: String,
	bot_name: String,
	wing: String,
	colors: Variant = null
) -> void:
	_bots[bot_id] = {
		"pos": pos,
		"rot": rot,
		"vel": vel,
		"phase": phase,
		"name": bot_name,
		"wing": wing,
		"colors": colors,
	}
	if _remotes.has(bot_id) and _zone.is_leader():
		_drop(bot_id)


func remove_bot(bot_id: String) -> void:
	_bots.erase(bot_id)
	_streams.erase(bot_id)


func clear_bots() -> void:
	for bot_id: String in _bots.keys():
		remove_bot(bot_id)


func get_pilot_ids() -> Array[String]:
	var ids: Array[String] = []
	ids.assign(_remotes.keys())
	return ids


func has_pilot(id: String) -> bool:
	return _remotes.has(id)


func is_bot(id: String) -> bool:
	return _remotes.has(id) and (_remotes[id] as RemotePilotState).is_bot


func get_state(id: String) -> RemotePilotState:
	return _remotes.get(id)


func sample(id: String) -> Dictionary:
	var r: RemotePilotState = _remotes.get(id)
	if r == null:
		return {}
	return r.sample(_zone.zone_time() - interp_delay_s)


## Данные PilotState для NetMessages.encode: округление чисел, неполный пакет (full = false —
## без name/wing/colors; with_phase = false — без phase). Для ботов is_bot = true.
static func build_state(
	pilot_id: String,
	is_bot_state: bool,
	t: float,
	st: Dictionary,
	full: bool,
	with_phase: bool,
	pilot_name: String = ""
) -> Dictionary:
	var rot: Quaternion = st.get("rot", Quaternion.IDENTITY)
	var d := {
		"pilotId": pilot_id,
		"isBot": is_bot_state,
		"t": snappedf(t, 0.001),
		"pos": _round_vec(st.get("pos", Vector3.ZERO), 0.01),
		"rot":
		{
			"x": snappedf(rot.x, 0.001),
			"y": snappedf(rot.y, 0.001),
			"z": snappedf(rot.z, 0.001),
			"w": snappedf(rot.w, 0.001),
		},
		"vel": _round_vec(st.get("vel", Vector3.ZERO), 0.01),
	}
	if with_phase:
		d["phase"] = RemotePilotState.PHASE_PREFIX + RemotePilotState.short_phase(st.phase)
	if full:
		d["name"] = pilot_name
		d["wing"] = st.get("wing", "")
		var c: Variant = st.get("colors")
		if c is Dictionary:
			d["colors"] = {
				"hueDeg": snappedf(float(c.get("hueDeg", 0.0)), 0.1),
				"sat": snappedf(float(c.get("sat", 0.0)), 0.001),
				"value": snappedf(float(c.get("value", 0.0)), 0.001),
			}
	return d


func _process(delta: float) -> void:
	_check_lost()
	if not (_zone.in_zone and _zone.has_clock):
		_send_acc = 0.0
		return
	_send_acc += delta
	if _send_acc < 1.0 / SEND_HZ:
		return
	_send_acc = minf(_send_acc - 1.0 / SEND_HZ, 1.0 / SEND_HZ)
	_send_all()


func _send_all() -> void:
	var t: float = _zone.zone_time()
	var st := _local
	if _provider.is_valid():
		st = _provider.call()
	if not st.is_empty():
		var me: Dictionary = _zone.peers.get(_zone.my_id, {})
		_send_stream("", _zone.my_id, false, t, st, str(me.get("name", "")))
	if _zone.is_leader():
		for bot_id: String in _bots:
			var b: Dictionary = _bots[bot_id]
			_send_stream(bot_id, bot_id, true, t, b, b.name)


func _send_stream(
	key: String, pilot_id: String, bot: bool, t: float, st: Dictionary, pilot_name: String
) -> void:
	var s: Dictionary = _streams.get(key, {"meta_at": -INF, "meta_key": null, "phase": ""})
	var meta_key := [pilot_name, st.get("wing", ""), st.get("colors")]
	var full: bool = t - s.meta_at >= META_INTERVAL_S or s.meta_key != meta_key
	var phase := RemotePilotState.short_phase(str(st.get("phase", "")))
	if phase != s.phase:
		s.phase = phase
		s["phase_left"] = PHASE_REPEAT
	var with_phase: bool = full or s.get("phase_left", 0) > 0
	var d := build_state(pilot_id, bot, t, st, full, with_phase, pilot_name)
	if _zone.send_pilot_state(d):
		if full:
			s.meta_at = t
			s.meta_key = meta_key
		if s.get("phase_left", 0) > 0:
			s.phase_left -= 1
	_streams[key] = s


func _on_pilot_state(from_id: String, data: Dictionary) -> void:
	if from_id == _zone.my_id:
		return
	var bot: bool = data.get("isBot", false)
	var id: String = str(data.get("pilotId", "")) if bot else from_id
	if id == "" or (bot and _bots.has(id) and _zone.is_leader()):
		return
	var r: RemotePilotState = _remotes.get(id)
	var fresh := r == null
	if fresh:
		r = RemotePilotState.new(id)
		r.is_bot = bot
		_remotes[id] = r
	r.push(data, _now())
	if fresh:
		pilot_appeared.emit(id, bot)


func _check_lost() -> void:
	if _remotes.is_empty():
		return
	var now := _now()
	for id: String in _remotes.keys():
		if (_remotes[id] as RemotePilotState).is_lost(now):
			_drop(id)


func _drop(id: String) -> void:
	if _remotes.erase(id):
		pilot_lost.emit(id)


func _on_zone_left() -> void:
	_streams.clear()
	for id: String in _remotes.keys():
		_drop(id)


static func _round_vec(v: Vector3, step: float) -> Dictionary:
	return {"x": snappedf(v.x, step), "y": snappedf(v.y, step), "z": snappedf(v.z, step)}


static func _now() -> float:
	return Time.get_ticks_usec() / 1e6
