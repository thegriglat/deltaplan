class_name NetQueue
extends RefCounted
## Очередь на старт в сетевой зоне (NET-43, docs/plan/multiplayer.md → п. 3, 6, 7): живая
## очередь, как у ботов. Места ожидания позади старта (место 0 — сам старт, дальше — места
## BotPilots.find_spots), сначала живые пилоты, после них боты. Бежать может только первый;
## взлетел — следующий шагает вперёд; первый простоял IDLE_S — в самый конец (за ботами, чтобы
## не держать всех); после посадки, аварии, сорванного старта «На старт» (и R, и «догнать» пилота
## на земле) — в конец живых пилотов (перед ботами; пустая очередь — сразу первый). Обходов нет.
##
## Ведёт очередь ведущий (lead): других клиентов он не спрашивает — видит их фазы (PilotState):
## у старта стоит/идёт (STAND/WALK ближе NEAR_LAUNCH_M) — в очереди, бежит (RUN) — в очереди и
## его не трогать, в воздухе / на буксире / сел / разбился / ушёл далеко — из очереди.
## Порядок рассылает NetZone.set_queue (ZoneState.queue, 1 Гц и сразу при изменении). Новый
## ведущий продолжает с последнего ZoneState.queue (таймер простоя первого — заново).
##
## Каждый клиент сам встаёт на своё место (места у всех одинаковые: из старта и рельефа):
## NetFlight по my_index() — ходьба к spot(k) (Game.queue_walk_to), разбег заблокирован, пока
## не первый (InputController.run_blocked).
##
## Статусы пилота (status_fn(id) -> String):
##   "wait" — ждёт у старта; "run" — бежит (бот — уже идёт на старт или стоит на нём): его
##   место не отдаём и за простой не двигаем; "gone" — не на старте; "unknown" — ещё не знаем
##   (только вошёл, состояний нет) — место держим, но сами не добавляем.
## Тесты: tests/game/test_net_queue.gd (зона — словарь-подделка с теми же полями).

## Простой первого, после которого он уходит в конец, с.
const IDLE_S := 60.0
## Дальше этого от старта (по горизонтали) — «не на старте», м.
const NEAR_LAUNCH_M := 250.0
## Сколько мест считать сразу (дальше — досчитываются).
const SPOTS_MIN := 32
const BOT_PREFIX := "bot-"
## Фазы PilotPhase (без префикса), в которых пилот точно не в очереди.
const GONE_PHASES := ["FLY", "TOW", "LANDED", "CRASHED"]

## NetZone или объект с полями queue, my_id и методами is_leader(), set_queue(ids), peer_ids().
var zone: Object
## (id) -> String — статус пилота или бота (см. выше).
var status_fn := Callable()
## () -> Array — id ботов зоны по порядку (у ведущего — NetBots.bot_ids()).
var bot_ids_fn := Callable()
## (count) -> Array[Dictionary] — места ожидания [{position, heading_deg}], место 0 — старт.
var spots_fn := Callable()
var idle_s := IDLE_S

var _first_id := ""
var _first_since := 0.0
var _was_leader := false
var _spots: Array[Dictionary] = []


## Ведущий: убрать ушедших, добавить вернувшихся, простой первого. now_s — монотонное время, с.
## true — очередь изменилась (разослана set_queue). Не ведущий — ничего.
func lead(now_s: float) -> bool:
	if not _is_leader():
		_was_leader = false
		return false
	if not _was_leader:
		_was_leader = true
		_first_id = ""
	var cur := _queue()
	var humans: Array = zone.call("peer_ids") if zone.has_method("peer_ids") else []
	var bots: Array = bot_ids_fn.call() if bot_ids_fn.is_valid() else []
	var q := arrange(cur, humans, bots, status_fn)
	for id in cur:
		if not q.has(id):
			print("net-queue: %s — из очереди (%s)" % [id, _status(id)])
	if q.is_empty():
		_first_id = ""
	elif q[0] != _first_id or _status(q[0]) == "run":  # бежит — не простой
		_first_id = q[0]
		_first_since = now_s
	elif q.size() > 1 and now_s - _first_since > idle_s:
		var id: String = q.pop_front()
		q.append(id)
		print("net-queue: %s простоял первым %.0f с — в конец" % [id, now_s - _first_since])
		_first_id = q[0]
		_first_since = now_s
	if same(q, cur):
		return false
	print("net-queue: %s" % [q])
	zone.call("set_queue", q)
	return true


## Ведущий: убрать себя сразу (буксир поднял с земли), не дожидаясь фазы TOW.
func leave(id: String) -> void:
	if not _is_leader():
		return
	var q := _queue().duplicate()
	if q.has(id):
		q.erase(id)
		zone.call("set_queue", q)


## Новая очередь из текущей: ушедшие (статус "gone", вышли из зоны, лишние боты) — вон,
## вернувшиеся живые — в конец живых (перед ботами, но не перед ботом, который уже идёт на
## старт первым), боты у старта не в очереди — в самый конец по порядку.
static func arrange(queue: Array, humans: Array, bots: Array, status: Callable) -> Array[String]:
	var q: Array[String] = []
	for id: String in queue:
		var known := bots.has(id) if is_bot(id) else humans.has(id)
		if known and _st(status, id) != "gone" and not q.has(id):
			q.append(id)
	for id: String in humans:
		if not q.has(id) and _st(status, id) in ["wait", "run"]:
			q.insert(human_slot(q, status), id)
	for id: String in bots:
		if not q.has(id) and _st(status, id) in ["wait", "run"]:
			q.append(id)
	return q


## Куда встать вернувшемуся живому: перед первым ботом (бот первым, который уже идёт на старт
## или бежит, — остаётся первым).
static func human_slot(q: Array, status: Callable) -> int:
	for i in q.size():
		if is_bot(String(q[i])) and not (i == 0 and _st(status, String(q[i])) == "run"):
			return i
	return q.size()


static func same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if String(a[i]) != String(b[i]):
			return false
	return true


static func is_bot(id: String) -> bool:
	return id.begins_with(BOT_PREFIX)


## Статус живого пилота по фазе (PilotPhase без префикса) и месту: launch — точка старта.
static func status_of(phase: String, pos: Vector3, launch: Vector3) -> String:
	if phase in GONE_PHASES:
		return "gone"
	if Vector2(pos.x - launch.x, pos.z - launch.z).length() > NEAR_LAUNCH_M:
		return "gone"
	return "run" if phase == "RUN" else "wait"


## Статус бота, которого считает этот клиент.
static func bot_status(a: BotAgent) -> String:
	match a.state:
		BotAgent.State.WAIT:
			return "wait"
		BotAgent.State.WALK:
			return "wait" if a.queue_hold else "run"
		BotAgent.State.READY, BotAgent.State.RUN:
			return "run"
	return "gone"


## Своё место в очереди (−1 — не в ней).
func my_index() -> int:
	if zone == null:
		return -1
	return _queue().find(String(zone.get("my_id")))


## Своё место — в очереди или куда поставит ведущий (конец живых пилотов).
func predicted_index() -> int:
	var k := my_index()
	if k >= 0 or zone == null:
		return maxi(k, 0)
	return human_slot(_queue(), status_fn)


## Место ожидания k: {position, heading_deg}; место 0 — старт.
func spot(k: int) -> Dictionary:
	k = maxi(k, 0)
	if _spots.size() <= k and spots_fn.is_valid():
		_spots.assign(spots_fn.call(maxi(SPOTS_MIN, k + 8)))
	if k < _spots.size():
		return _spots[k]
	return {"position": Vector3.ZERO, "heading_deg": 0.0}


## Места посчитать заново (другой старт).
func reset_spots() -> void:
	_spots.clear()


## Места ожидания для старта start (курс heading_deg): [старт] + BotPilots.find_spots (те же
## правила, что у ботов в одиночной игре: ровно, не в коридоре разбега, не в камнях).
static func spots_for(
	ground_fn: Callable, start: Vector3, heading_deg: float, count: int, obstacles: Array = []
) -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"position": start, "heading_deg": heading_deg}]
	if count <= 1:
		return out
	var lc: Dictionary = Config.get_config("bots").get("launch", {})
	out.append_array(BotPilots.find_spots(ground_fn, start, heading_deg, count - 1, lc, obstacles))
	return out


## Очередь зоны (нет такой — пустая).
func _queue() -> Array:
	var q: Variant = zone.get("queue") if zone != null else null
	return q if q is Array else []


func _is_leader() -> bool:
	return zone != null and zone.has_method("is_leader") and bool(zone.call("is_leader"))


func _status(id: String) -> String:
	return _st(status_fn, id)


static func _st(status: Callable, id: String) -> String:
	return String(status.call(id)) if status.is_valid() else "unknown"
