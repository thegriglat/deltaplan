class_name NetFlight
extends Node
## Сетевой режим полёта (NET-40, docs/plan/multiplayer.md): связка Game ↔ NetZone/NetPilots.
## Создаётся главной сценой по «Лететь» в зоне, Game.enable_net() вешает её в мир; вне зоны
## (одиночная игра) её нет — Game.net == null, и всё работает как раньше.
##
## Правила режима (их держит Game, спрашивая net):
##   - мир — из ключа зоны (world_settings: worldKey → FlightSettings, крыло и масса — свои);
##     после постройки join_world(): ждёт часы зоны, Game.set_world_time(zone_time()),
##     check_world по своему ключу (не совпал — предупреждение в лог, летим дальше);
##   - время только ×1: скорость часов из настроек игнорируется (Game._lock_net_clock);
##   - мир идёт по часам зоны: воздух шагает world_dt() — ровно до zone_time() (атмосфера — чистая
##     функция времени, шаг любой), а не по шагу физики: долгие кадры и просадки FPS мир не
##     тормозят; отстал больше DRIFT_SNAP_S — Game.set_world_time заново; часы суток —
##     hour_at(время атмосферы), без своего хода; поэтому после паузы или долгого кадра нет
##     скачка времени относительно зоны;
##   - пауза и окно итога дерево не останавливают (main.gd): свой пилот летит «без рук», чужие —
##     дальше, облака и термики — по часам зоны;
##   - «Ещё раз»/«На старт» мир не сбрасывают (Game.restart в сети не трогает часы и день).
##
## Каждый кадр (_process, и на паузе): своё состояние (после join_world) —
## NetPilots.set_local_state (фаза — имя PilotPhase из net.proto, крыло, расцветка по имени
## пилота), чужие — в RemotePilots
## (sample → upsert при появлении/смене вида, set_pose — поза каждый кадр; pilot_lost → remove).
##
## Хуки для следующих задач: friends_airborne() — кнопка «Продолжить рядом» в итоге
## (airborne_changed — сменилось).
##
## Очередь на старт (NET-43, NetQueue): после join_world каждый кадр — у ведущего queue.lead
## (порядок, простой первого, боты после живых), у всех — своё место: не первый — разбег
## заблокирован (InputController.run_blocked, автопилот ждёт), место в очереди сменилось —
## идём к нему (Game.queue_walk_to). Game.restart в сети ставит на своё место в очереди
## (queue_start_spot: в очереди — своё, нет — в конец живых); буксир — leave_queue().
## Боты ведущего (NetBots → BotPilots.spot_index_fn/spot_fn) стоят на тех же местах по очереди.
##
## «Догнать» (NET-42): catch_up_list() — пилоты зоны для меню `=` (чужие из RemotePilots и у
## ведущего — свои боты), target_state(id) — "air"/"ground"/"", target_fn(id) — цель буксира
## ({position, velocity}, {} — ушла или села). Пока буксир — фаза TOW. Вход в зону: если ведущий
## в воздухе — буксир к нему от старта (ждём его состояния до AUTO_CATCH_UP_WAIT_S после
## world_joined); на земле — ничего (стоим в очереди на старт).
##
## Термики из поля воздуха (AM-07, docs/air_model.md → «Масштаб 2: термики из поля»): поле у
## каждого своё и чуть разное, а термики должны совпадать — раз в секунду (sync_thermal_sources)
## ведущий отдаёт NetZone свои источники (столбцы поля, уходят с ZoneState), остальные ставят
## их своей атмосфере (ThermalField.set_air_forced); сила, потолок и снос — по своему полю.
## Новый ведущий переходит на свой выбор.
##
## zone/pilots — NetZone/NetPilots или объекты с теми же полями и методами (тесты).

## Изменилось «есть ли в воздухе кто-то из живых пилотов» (кнопка «Продолжить рядом»).
signal airborne_changed(any: bool)
## Мир поставлен на часы зоны, полёт вот-вот начнётся (join_world). ХУК NET-42: автоматический
## «догнать» при входе, если ведущий в воздухе (его состояния приходят чуть позже — ждать их).
signal world_joined

## Фаза Telemetry → PilotPhase (net.proto, без префикса). "failed" — сорванный старт: крыло
## лежит на склоне, у других — поза после аварии.
const PROTO_PHASES := {
	"standing": "STAND",
	"walking": "WALK",
	"running": "RUN",
	"flying": "FLY",
	"landed": "LANDED",
	"failed": "CRASHED",
}
## Отставание мира от часов зоны, после которого мир ставится заново (start_at), с.
const DRIFT_SNAP_S := 30.0
## Самый длинный шаг воздуха, с (после долгого кадра мир догоняет за несколько шагов).
const MAX_STEP_S := 2.0
## Сколько ждать часов зоны у вошедшего (первый ZoneState), с.
const CLOCK_WAIT_S := 5.0
## Сколько ждать состояний ведущего после входа, чтобы решить «догнать» его или нет, с.
const AUTO_CATCH_UP_WAIT_S := 4.0
## Как часто сверять источники термиков из поля с ведущим, с.
const THERMAL_SYNC_S := 1.0

## Автоматический «догнать» ведущего при входе в зону (тесты могут выключить).
var auto_catch_up := true

var zone: Object
var pilots: Object
var game: Game
## Чужие пилоты в мире (NET-41); создаётся в setup.
var remote: RemotePilots
## Боты зоны (NET-44): считает ведущий; создаётся в setup, ботов ставит join_world.
var bots: NetBots
## Своя расцветка крыла для других ({hueDeg, sat, value}) — по имени пилота.
var colors: Variant = null
## Мир построен из ключа, отличного от ключа зоны (check_world).
var world_mismatch := false
## Очередь на старт (NET-43); создаётся в setup.
var queue: NetQueue

var _meta := {}  ## id → ключ вида (имя, крыло, расцветка, бот) — upsert только при смене
var _airborne := false
var _joined := false  ## мир на часах зоны, боты поставлены — очередь ведём
var _queue_k := -1  ## место в очереди, к которому шли в последний раз (−1 — не на старте)
var _my_status := ""
var _thermal_sync_t := 0.0
var _was_leader := false


## p_zone/p_pilots — null: автозагрузки NetZone/NetPilots.
func setup(p_game: Game, p_zone: Object = null, p_pilots: Object = null) -> void:
	game = p_game
	var root := (Engine.get_main_loop() as SceneTree).root
	zone = p_zone if p_zone != null else root.get_node_or_null("NetZone")
	pilots = p_pilots if p_pilots != null else root.get_node_or_null("NetPilots")
	name = "NetFlight"
	process_mode = Node.PROCESS_MODE_ALWAYS
	remote = RemotePilots.new()
	remote.name = "RemotePilots"
	game.add_child(remote)
	remote.setup_in_world(game.terrain)
	colors = colors_for(_my_name())
	bots = NetBots.new()
	add_child(bots)
	bots.setup(zone, pilots, game)
	queue = NetQueue.new()
	queue.zone = zone
	queue.status_fn = queue_status
	queue.bot_ids_fn = bots.bot_ids
	queue.spots_fn = _queue_spots
	bots.spot_fn = queue.spot
	if pilots != null and pilots.has_signal("pilot_lost"):
		pilots.connect("pilot_lost", _on_pilot_lost)
	world_joined.connect(_on_world_joined)


## Выключить: чужих убрать, своё не слать.
func teardown() -> void:
	_joined = false
	_set_clouds_history_free(false)
	if is_instance_valid(bots):
		bots.teardown()
	if pilots != null:
		if pilots.has_method("clear_local_state"):
			pilots.call("clear_local_state")
		if pilots.has_signal("pilot_lost") and pilots.is_connected("pilot_lost", _on_pilot_lost):
			pilots.disconnect("pilot_lost", _on_pilot_lost)
	if is_instance_valid(remote):
		remote.clear()
		remote.queue_free()
	remote = null
	_meta.clear()


## Мир зоны: из ключа мира (у всех одинаково, числа квантованы), без ключа — из полей Zone.
## Крыло и масса — свои (base).
static func world_settings(p_zone: Object, base: FlightSettings) -> FlightSettings:
	var z: Dictionary = p_zone.get("zone") if p_zone != null else {}
	var key := String(z.get("worldKey", ""))
	if key != "":
		return FlightSettings.from_world_key(key, base).settings
	if not z.is_empty():
		return FlightSettings.from_zone(z, base)
	var s: FlightSettings = p_zone.get("zone_settings") if p_zone != null else null
	if s == null:
		return base.duplicate()
	s = s.duplicate()
	s.wing = base.wing
	s.pilot_mass_kg = base.pilot_mass_kg
	return s


## После Game.start: дождаться часов зоны, поставить мир на время зоны, сверить ключ мира.
## false — из зоны вышли, пока грузились.
func join_world() -> bool:
	var waited := 0
	while zone.in_zone and not zone.has_clock and waited < int(CLOCK_WAIT_S * 1000.0):
		await get_tree().process_frame
		waited += maxi(int(get_process_delta_time() * 1000.0), 1)
	if not zone.in_zone:
		return false
	if not zone.has_clock:
		push_warning("NetFlight: часов зоны нет %.0f с — мир с начала зоны" % CLOCK_WAIT_S)
	_set_clouds_history_free(true)
	game.set_world_time(zone.zone_time())
	var key := game.settings.world_key(int(zone.world_seed), int(zone.bots_count))
	world_mismatch = not bool(zone.check_world(key))
	if world_mismatch:
		push_warning("NetFlight: мир отличается от мира зоны — летим в своём (%s)" % key)
	bots.start_in_game(game)
	_joined = true
	world_joined.emit()
	return true


## Облака без памяти о кадрах (CloudLayer.history_free) — у всех клиентов зоны одни и те же;
## в одиночной игре — выбор с гистерезисом и таянием.
func _set_clouds_history_free(on: bool) -> void:
	var air: Node = game.air if game != null and is_instance_valid(game) else null
	var clouds := air.get_node_or_null("Clouds") if air != null else null
	if clouds != null and "history_free" in clouds:
		clouds.set("history_free", on)


## Шаг воздуха за этот тик физики: до часов зоны (dt — только без часов зоны).
func world_dt(dt: float) -> float:
	if zone == null or not zone.in_zone or not zone.has_clock:
		return dt
	var lag: float = float(zone.zone_time()) - game.world_time()
	if lag > DRIFT_SNAP_S:
		push_warning("NetFlight: мир отстал от часов зоны на %.1f с — ставлю заново" % lag)
		game.set_world_time(zone.zone_time())
		return 0.0
	return step_for(lag)


## Шаг воздуха при отставании lag = часы зоны − время мира, с: убежал вперёд — стоит.
static func step_for(lag: float) -> float:
	return clampf(lag, 0.0, MAX_STEP_S)


func _process(_dt: float) -> void:
	if game == null or game.settings == null or zone == null or not zone.in_zone:
		return
	if _joined:  # до постройки мира планер не на месте — не слать (очередь сочла бы «ушёл»)
		send_local()
	feed_remote()
	update_queue()
	_thermal_sync_t -= _dt
	if _thermal_sync_t <= 0.0:
		_thermal_sync_t = THERMAL_SYNC_S
		sync_thermal_sources()
	var any := friends_airborne()
	if any != _airborne:
		_airborne = any
		airborne_changed.emit(any)


## Источники термиков из поля: ведущий — свои в NetZone, остальные — от ведущего в атмосферу.
func sync_thermal_sources() -> void:
	var air: Atmosphere = game.air as Atmosphere if game != null and is_instance_valid(game) else null
	if air == null or air.field == null or not zone.has_method("set_thermal_sources"):
		return
	var tf: ThermalField = air.field
	if zone.is_leader():
		if not _was_leader and tf.air_forced_sig != "":
			tf.set_air_forced("", PackedByteArray())  # стал ведущим — свой выбор
		_was_leader = true
		var m := tf.air_sources_mask()
		zone.call("set_thermal_sources", String(m.get("sig", "")), m.get("mask", PackedByteArray()))
		return
	_was_leader = false
	var ts: Dictionary = zone.get("thermal_sources")
	var sig := String(ts.get("grid", ""))
	var mask := Marshalls.base64_to_raw(String(ts.get("mask", ""))) if sig != "" else PackedByteArray()
	if sig != tf.air_forced_sig or mask != tf.air_forced:
		tf.set_air_forced(sig, mask)


## Своё состояние — в NetPilots (уходит 10 Гц).
func send_local() -> void:
	if pilots == null:
		return
	var t := game.glider.get_telemetry()
	var rot := Quaternion(t.basis.orthonormalized())
	var ph := "TOW" if game.is_towing() else proto_phase(t.phase, game.is_crashed())
	pilots.call("set_local_state", t.position, rot, t.velocity, ph, game.settings.wing, colors)


## Чужие пилоты из NetPilots — в RemotePilots (себя нет).
func feed_remote() -> void:
	if pilots == null or remote == null:
		return
	var me := String(zone.my_id)
	for id: String in pilots.call("get_pilot_ids"):
		if id == me:
			continue
		var s: Dictionary = pilots.call("sample", id)
		if s.is_empty():
			continue
		var mk := [s.get("name", ""), s.get("wing", ""), s.get("colors"), s.get("is_bot", false)]
		if not remote.has_pilot(id) or _meta.get(id) != mk:
			_meta[id] = mk
			remote.upsert(
				{
					"pilot_id": id,
					"name": s.get("name", ""),
					"is_bot": s.get("is_bot", false),
					"wing": s.get("wing", ""),
					"colors": s.get("colors"),
					"pos": s.get("pos", Vector3.ZERO),
					"rot": s.get("rot", Quaternion.IDENTITY),
					"vel": s.get("vel", Vector3.ZERO),
					"phase": s.get("phase", "STAND"),
				}
			)
		remote.set_pose(id, s.pos, s.rot, s.vel, s.get("phase"))


## Есть ли в воздухе кто-то из живых пилотов (не боты) — для «Продолжить рядом».
func friends_airborne() -> bool:
	return remote != null and count_airborne(remote.pilots()) > 0


# ---------------------------------------------------------------- очередь на старт (NET-43)


## Кадр очереди: ведущий ведёт, каждый — на своё место; разбег — только первому.
func update_queue() -> void:
	if not _joined or zone == null or not zone.in_zone:
		return
	queue.lead(Time.get_ticks_msec() / 1000.0)
	var me := queue_status(String(zone.my_id))
	if _my_status == "run" and me == "gone":
		print("net-queue: взлёт (зона %.1f с)" % float(zone.zone_time()))
	_my_status = me
	var k := queue.my_index()
	var at_launch := me != "gone" and not game.is_towing()
	game.input_controller.run_blocked = at_launch and k != 0 and me != "run"
	if not at_launch or me != "wait":
		if not at_launch:
			_queue_k = -1
		return
	var want := k if k >= 0 else queue.predicted_index()
	if want != _queue_k:
		_queue_k = want
		game.queue_walk_to(queue.spot(want))


## Где встать после «Ещё раз» / «На старт» / R: своё место в очереди, не в ней — конец живых.
func queue_start_spot() -> Dictionary:
	_queue_k = queue.predicted_index()
	return queue.spot(_queue_k)


## Буксир поднял с земли — из очереди (ведущий убирает сразу, остальных — по фазе TOW).
func leave_queue() -> void:
	_queue_k = -1
	game.input_controller.run_blocked = false
	if zone != null and zone.in_zone:
		queue.leave(String(zone.my_id))


## Статус пилота или бота для очереди (NetQueue): свой — по своему планеру, свои боты — по
## BotAgent, чужие — по последнему PilotState.
func queue_status(id: String) -> String:
	var launch: Vector3 = game.get_start().position
	if id == String(zone.my_id):
		var t := game.glider.get_telemetry()
		var ph := "TOW" if game.is_towing() else proto_phase(t.phase, game.is_crashed())
		return NetQueue.status_of(ph, t.position, launch)
	var a := bots.agent_for(id) if bots != null else null
	if a != null:
		return NetQueue.bot_status(a)
	if pilots == null or not bool(pilots.call("has_pilot", id)):
		return "unknown"
	var s: Dictionary = pilots.call("sample", id)
	if s.is_empty():
		return "unknown"
	return NetQueue.status_of(String(s.get("phase", "STAND")), s.get("pos", Vector3.ZERO), launch)


## Места ожидания у старта этой игры (у всех клиентов одинаковые).
func _queue_spots(count: int) -> Array[Dictionary]:
	var st: Dictionary = game.get_start()
	var p: Vector3 = st.position
	var lc: Dictionary = Config.get_config("bots").get("launch", {})
	var r := float(lc.get("behind_max_m", 70.0)) + float(lc.get("lateral_max_m", 40.0))
	var obs := BotPilots.obstacles_near(game.terrain, Vector2(p.x, p.z), r)
	return NetQueue.spots_for(game.terrain.height_at, p, float(st.heading_deg), count, obs)


# ---------------------------------------------------------------- «догнать» (NET-42)


## Пилоты зоны для меню «Догнать» (формат CatchUpMenu.set_source): чужие из RemotePilots и,
## у ведущего, свои боты (их RemotePilots не рисует — считает NetBots).
func catch_up_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = CatchUpMenu.remote_pilots_source(remote).call()
	if bots == null or bots.sim == null:
		return out
	for id: String in bots.ids:
		var a := bots.agent_for(id)
		if a == null:
			continue
		var ph := NetBots.phase_of(a)
		(
			out
			. append(
				{
					"id": id,
					"name": a.pilot_name,
					"is_bot": true,
					"pos": a.telemetry().position,
					"on_ground": not a.is_airborne(),
					"landed": ph == "LANDED",
				}
			)
		)
	return out


## Где пилот id: "air" — в воздухе (или сам на буксире), "ground" — на земле, "" — нет такого.
func target_state(id: String) -> String:
	var a := bots.agent_for(id) if bots != null else null
	if a != null:
		return "air" if a.is_airborne() else "ground"
	var p := remote.get_pilot(id) if remote != null else null
	if p == null:
		return ""
	return "ground" if RemotePilots.GROUND_PHASES.has(p.phase) else "air"


## Цель буксира: () -> {position, velocity} пилота id сейчас; {} — ушёл из зоны или сел.
func target_fn(id: String) -> Callable:
	return func() -> Dictionary:
		if target_state(id) != "air":
			return {}
		var a := bots.agent_for(id) if bots != null else null
		if a != null:
			var t := a.telemetry()
			return {"position": t.position, "velocity": t.velocity}
		var p := remote.get_pilot(id)
		return {"position": p.position, "velocity": p.velocity}


## Вход в зону: ведущий в воздухе — буксир к нему от старта. Его состояния приходят не сразу —
## ждём до AUTO_CATCH_UP_WAIT_S; на земле или не пришли — ничего (очередь — NET-43).
func _on_world_joined() -> void:
	if not auto_catch_up or zone == null or not ("leader_id" in zone):
		return
	var leader := String(zone.get("leader_id"))
	if leader == "" or leader == String(zone.my_id):
		return
	var t0 := Time.get_ticks_msec()
	while is_inside_tree() and zone.in_zone and game != null:
		var st := target_state(leader)
		if st == "air":
			if not game.is_towing():
				print("net: вход в зону — ведущий в воздухе, догоняю")
				game.start_catch_up(target_fn(leader))
			return
		if st == "ground" or Time.get_ticks_msec() - t0 > int(AUTO_CATCH_UP_WAIT_S * 1000.0):
			return
		await get_tree().process_frame


## Сколько живых пилотов в воздухе в списке RemotePilots.pilots().
static func count_airborne(list: Array) -> int:
	var n := 0
	for p: Dictionary in list:
		if not bool(p.get("is_bot", false)) and not RemotePilots.GROUND_PHASES.has(p.phase):
			n += 1
	return n


## Фаза Telemetry → PilotPhase; авария (crashed) на земле — CRASHED.
static func proto_phase(phase: String, crashed: bool = false) -> String:
	if crashed and phase in ["landed", "failed", "standing"]:
		return "CRASHED"
	return String(PROTO_PHASES.get(phase, "STAND"))


## Расцветка крыла по имени пилота (bots.json → visual.sail_schemes): у каждого своя и одна
## и та же от полёта к полёту. {hueDeg, sat, value}; схем нет — null (родная текстура).
static func colors_for(pilot_name: String) -> Variant:
	var schemes: Array = Config.value("bots", "visual.sail_schemes", [])
	if schemes.is_empty():
		return null
	var sc: Dictionary = schemes[posmod(hash(pilot_name), schemes.size())]
	return {
		"hueDeg": float(sc.get("hue_deg", 0.0)),
		"sat": float(sc.get("sat", 1.0)),
		"value": float(sc.get("value", 1.0)),
	}


## Сводка мира для сверки двух машин (отладка, кадры): время зоны и мира, час, термики с
## облаками в radius_m от точки (id, место, сила, стадия облака), по id.
func world_summary(at: Vector3, radius_m: float = 6000.0) -> String:
	var air := game.air
	var out := "zone_t=%.2f world_t=%.2f hour=%.4f" % [
		float(zone.zone_time()), game.world_time(), game.sky.clock.hour
	]
	if not ("field" in air) or air.get("field") == null:
		return out
	var t := game.world_time()
	var ths: Dictionary = air.field.thermals
	var ids: Array = ths.keys()
	ids.sort()
	var rows: PackedStringArray = []
	for id: int in ids:
		var th: AtmoThermal = ths[id]
		th.update_time(t)
		var g := Vector2(th.src.x + th.drift.x, th.src.z + th.drift.y)
		if g.distance_to(Vector2(at.x, at.z)) > radius_m:
			continue
		var st: Vector3 = air.cloud_phys.model.stage(th, t)
		var cb := "Cb" if th.is_cb else ""
		rows.append("%d@%.0f,%.0f s%.2f c%.2f%s" % [id, g.x, g.y, th.strength, st.x, cb])
	return "%s thermals=%d [%s]" % [out, rows.size(), "; ".join(rows)]


func _my_name() -> String:
	if zone == null:
		return ""
	var me: Dictionary = zone.peers.get(zone.my_id, {})
	return String(me.get("name", zone.my_id))


func _on_pilot_lost(id: String) -> void:
	_meta.erase(id)
	if remote != null:
		remote.remove(id)
