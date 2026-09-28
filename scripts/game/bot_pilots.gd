class_name BotPilots
extends Node3D
## «Другие пилоты в небе» (configs/bots.json, docs/game.md → «Другие пилоты»): боты стоят на
## старте позади игрока и ждут, пока он на земле; после его отрыва начинают разбег по одному
## через launch.interval_s; летают без цели (BotAgent + BotPilot), держат дистанцию друг от
## друга и от игрока, в одном термике кружат в одну сторону (задаёт первый вошедший, игрок тоже).
## Столкновений с игроком нет. Над ботами — имена (configs/bot_names.json по языку интерфейса,
## bots.json → names; при смене языка — из пула нового языка). Физика ботов — реже, чем у
## игрока (physics.*), и ещё реже далеко.
##
## Интегратор (Game): setup(...) на новый полёт, reset() на «Ещё раз», tick(dt, телеметрия
## игрока) каждый шаг физики. visuals_enabled = false — без узлов (тесты).

## Показывать ботов (BotGlider). false — только физика (headless-тесты).
var visuals_enabled := true
## Время ботов с начала полёта, с.
var sim_time_s := 0.0
## Боты (порядок = очередь на старт).
var agents: Array[BotAgent] = []
## Когда игрок оторвался (время ботов), с; < 0 — ещё на земле.
var player_liftoff_s := -1.0
## «Занятые» термики: {center: Vector2, dir: float, t: float, owner: int (−1 — игрок)}.
var claims: Array[Dictionary] = []
## Другие живые пилоты зоны, кроме игрока (сеть, NET-44; ставит NetBots перед tick):
## [{pos: Vector3, vel: Vector3, flying: bool}]. Для очереди, расхождения и частоты физики.
var others: Array[Dictionary] = []
## Имена не менять при смене языка (сеть: имена ботов зоны — из пула языка первого ведущего).
var fixed_names := false

var _cfg: Dictionary = {}
var _air_fn: Callable
var _ground_fn: Callable
var _start := Vector3.ZERO
var _heading := 0.0
var _visuals: Array[BotGlider] = []
var _sep_acc := 0.0
var _player_pos := Vector3.ZERO
var _player_vel := Vector3.ZERO
var _player_flying := false
var _p_turn := 0.0
var _p_prev_heading := NAN
var _p_center := Vector2.ZERO
var _p_center_ok := false
var _spots: Array[Dictionary] = []
var _names_seed := 0


func _ready() -> void:
	Config.reloaded.connect(_on_config_reloaded)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and not fixed_names:
		refresh_names()


## Новый полёт. opts: air_fn (pos) -> Vector3, ground_fn (x, z) -> высота, start: Vector3,
## heading_deg, count (−1 — из bots.json), seed (смешивается с bots.json → seed),
## cloudbase_msl, clouds_fn,
## obstacles: Array[Vector3] (x, z, радиус) — камни, кусты, деревья у старта.
func setup(opts: Dictionary) -> void:
	clear()
	_cfg = Config.get_config("bots")
	_air_fn = opts.get("air_fn", Callable())
	_ground_fn = opts.get("ground_fn", Callable())
	_start = opts.get("start", Vector3.ZERO)
	_heading = float(opts.get("heading_deg", 0.0))
	var count := int(opts.get("count", -1))
	if count < 0:
		count = int(_cfg.get("count", 4))
	count = clampi(count, 0, int(_cfg.get("count_max", 20)))
	if count == 0:
		return
	var rng := RandomNumberGenerator.new()
	var place_key := [snappedf(_start.x, 1.0), snappedf(_start.z, 1.0)]
	rng.seed = hash([int(_cfg.get("seed", 1)), int(opts.get("seed", 0))] + place_key)
	_names_seed = hash([int(_cfg.get("seed", 1)), int(opts.get("seed", 0)), "names"] + place_key)
	_spots = find_spots(
		_ground_fn, _start, _heading, count, _cfg.get("launch", {}), opts.get("obstacles", [])
	)
	var wings: Array = _cfg.get("wings", [])
	if wings.is_empty():
		for w in Config.list_configs("wings"):
			wings.append(String(w).get_file())
	var schemes: Array = _cfg.get("visual", {}).get("sail_schemes", [{}])
	var mass: Array = _cfg.get("mass_kg", [65.0, 95.0])
	var scheme_order := range(schemes.size())
	_shuffle(scheme_order, rng)
	for i in count:
		var a := BotAgent.new()
		a.id = i
		a.setup(
			_cfg,
			String(wings[rng.randi() % wings.size()]),
			rng.randf_range(float(mass[0]), float(mass[1])),
			_air_fn,
			_ground_fn,
			rng.randi()
		)
		a.scheme = schemes[scheme_order[i % scheme_order.size()]]
		a.set_site(_start, _heading)
		a.brain.circle_dir_fn = _circle_dir.bind(i)
		a.brain.cloudbase_msl = float(opts.get("cloudbase_msl", 1.0e9))
		var clouds_fn: Callable = opts.get("clouds_fn", Callable())
		a.brain.use_clouds = (
			bool(_cfg.get("wander", {}).get("use_clouds", true)) and clouds_fn.is_valid()
		)
		if a.brain.use_clouds:
			a.brain.clouds_fn = clouds_fn
		agents.append(a)
	refresh_names()
	reset()
	if visuals_enabled:
		build_visuals()


## Вид ботов (BotGlider) заново — по текущим agents (сеть: после подмены состояний).
func build_visuals() -> void:
	for v in _visuals:
		if is_instance_valid(v):
			v.queue_free()
	_visuals.clear()
	for a in agents:
		var v := BotGlider.new()
		v.name = "Bot%d" % a.id
		add_child(v)
		v.setup(a, _cfg.get("visual", {}))
		_visuals.append(v)
	_on_config_reloaded()


## Новый полёт в игре: воздух (Atmosphere или CalmAir), рельеф (Terrain), старт игрока;
## count < 0 — из bots.json (настройка «Другие пилоты в небе»).
func setup_in_world(
	terrain: Node, air: Node, start: Vector3, heading_deg: float, count: int = -1
) -> void:
	var opts := {
		"air_fn": Callable(air, "air_velocity_at"),
		"ground_fn": Callable(terrain, "height_at"),
		"start": start,
		"heading_deg": heading_deg,
		"count": count,
	}
	if air.has_method("get_cloudbase_msl"):
		opts.cloudbase_msl = float(air.call("get_cloudbase_msl"))
	if air is Atmosphere:
		opts.clouds_fn = _visible_clouds.bind(air)
	var lc: Dictionary = Config.get_config("bots").get("launch", {})
	var r := float(lc.get("behind_max_m", 70.0)) + float(lc.get("lateral_max_m", 40.0))
	opts.obstacles = obstacles_near(terrain, Vector2(start.x, start.z), r)
	setup(opts)


## Камни, кусты и отдельные деревья (RockScatter, ShrubScatter — дети Terrain) в радиусе r
## от c: [Vector3(x, z, радиус)] — чтобы боты не стояли с крылом в камне.
static func obstacles_near(terrain: Node, c: Vector2, r: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for pair: Array in [
		["Rocks", "build_tile", ""],
		["Shrubs", "build_tile", ""],
		["Shrubs", "build_tree_tile", "trees"]
	]:
		var n := terrain.get_node_or_null(String(pair[0]))
		if n == null or not n.has_method(String(pair[1])):
			continue
		var cfg: Variant = n.get("_cfg")
		if not cfg is Dictionary:
			continue
		if String(pair[2]) != "":
			cfg = (cfg as Dictionary).get(pair[2], {})
		var tile := float((cfg as Dictionary).get("tile_m", 96.0))
		for tz in range(floori((c.y - r) / tile), floori((c.y + r) / tile) + 1):
			for tx in range(floori((c.x - r) / tile), floori((c.x + r) / tile) + 1):
				var d: Dictionary = n.call(String(pair[1]), tx, tz)
				var xf: PackedFloat32Array = d.get("xf", PackedFloat32Array())
				var sz: PackedFloat32Array = d.get("size", PackedFloat32Array())
				for i in sz.size():
					var p := Vector2(xf[i * 12 + 3], xf[i * 12 + 11])
					if p.distance_to(c) <= r + 10.0:
						out.append(Vector3(p.x, p.y, maxf(sz[i] * 0.5, 0.5)))
	return out


## Облака, которые видит пилот (как tests/atmosphere/xc/xc_run.gd): центр, радиус, рост, распад.
static func _visible_clouds(atmo: Atmosphere) -> Array:
	var out: Array = []
	var model := atmo.cloud_phys.model
	for e: Array in model.select(atmo.field.thermals, atmo.time_s, atmo.get_focus()):
		var st: Vector3 = e[2]
		out.append({"center": e[3], "radius": float(e[4]), "growth": st.x, "decay": st.y})
	return out


## Имена ботам из пула текущего языка (на новый полёт и при смене языка).
func refresh_names() -> void:
	var names := pick_names(agents.size(), Language.current(), _names_seed)
	for i in agents.size():
		agents[i].pilot_name = names[i]


## count имён из пула языка lang (configs/bot_names.json; нет пула — en): без повторов,
## порядок — перетасовка по seed_value. Пул кончился — по кругу с номером («Саша 2»).
static func pick_names(count: int, lang: String, seed_value: int) -> PackedStringArray:
	var all: Dictionary = Config.get_config("bot_names")
	var pool: Array = all.get(lang, all.get("en", []))
	var out := PackedStringArray()
	if pool.is_empty():
		out.resize(count)
		return out
	var order := range(pool.size())
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_shuffle(order, rng)
	for i in count:
		var n := String(pool[order[i % pool.size()]])
		if i >= pool.size():
			n += " %d" % (i / pool.size() + 1)
		out.append(n)
	return out


## Настройки поменялись (в том числе из паузы): показ и вид имён — сразу.
func _on_config_reloaded() -> void:
	var nc: Dictionary = Config.get_config("bots").get("names", {})
	for v in _visuals:
		if is_instance_valid(v):
			v.set_name_config(nc)


## Убрать всех ботов.
func clear() -> void:
	for v in _visuals:
		if is_instance_valid(v):
			v.queue_free()
	_visuals.clear()
	agents.clear()
	claims.clear()
	sim_time_s = 0.0
	player_liftoff_s = -1.0


## «Ещё раз»: все обратно на места ожидания, ждут отрыва игрока.
func reset() -> void:
	sim_time_s = 0.0
	player_liftoff_s = -1.0
	claims.clear()
	_sep_acc = 0.0
	_p_turn = 0.0
	_p_prev_heading = NAN
	_p_center_ok = false
	var ph: Dictionary = _cfg.get("physics", {})
	var near_dt := 1.0 / float(ph.get("near_hz", 30.0))
	for i in agents.size():
		var a := agents[i]
		var s: Dictionary = _spots[i]
		a.place(s.position, float(s.heading_deg))
		# Разнести шаги ботов по шагам игрока — нагрузка ровнее.
		a.acc_s = near_dt * float(i) / maxf(agents.size(), 1.0)
	for v in _visuals:
		v.snap()


## Шаг физики игрока dt; player — телеметрия игрока (null — игрока нет).
func tick(dt: float, player: Telemetry) -> void:
	if agents.is_empty():
		return
	sim_time_s += dt
	_observe_player(player, dt)
	if _others_flying() and player_liftoff_s < 0.0:
		player_liftoff_s = sim_time_s
	_respawn()
	_schedule()
	_sep_acc += dt
	var ph: Dictionary = _cfg.get("physics", {})
	var sep_period := 1.0 / float(_cfg.get("separation", {}).get("check_hz", 4.0))
	if _sep_acc >= sep_period:
		_sep_acc = fmod(_sep_acc, sep_period)
		_update_separation()
		_update_claims()
	for i in agents.size():
		var a := agents[i]
		a.acc_s += dt
		var step_dt := 1.0 / _hz_for(a, ph)
		if a.acc_s >= step_dt:
			var h := a.acc_s
			a.acc_s = 0.0
			a.step(h, sim_time_s)
			if i < _visuals.size():
				_visuals[i].on_step(h)
	for v in _visuals:
		v.advance(dt)


## Сколько ботов в каждом состоянии (для отладки и тестов): {"wait": 3, "fly": 1, ...}.
func state_counts() -> Dictionary:
	var out := {}
	for a in agents:
		out[a.state_name()] = int(out.get(a.state_name(), 0)) + 1
	return out


# ---------------------------------------------------------------- старт


## Места ожидания позади старта: ровно, не в коридоре разбега, не ближе spacing_m друг к другу
## и player_clear_m к игроку, крыло не задевает препятствия (obstacles: Vector3(x, z, радиус),
## зазор obstacle_clear_m); ближние к старту — первые в очереди. Курс — как у старта.
## Возвращает [{position: Vector3, heading_deg}] длины count.
static func find_spots(
	ground_fn: Callable,
	start: Vector3,
	heading_deg: float,
	count: int,
	cfg: Dictionary,
	obstacles: Array = []
) -> Array[Dictionary]:
	var h := deg_to_rad(heading_deg)
	var fwd := Vector2(sin(h), -cos(h))
	var right := Vector2(cos(h), sin(h))
	var s2 := Vector2(start.x, start.z)
	var grid := maxf(float(cfg.get("grid_m", 3.0)), 0.5)
	var b_min := float(cfg.get("behind_min_m", 9.0))
	var b_max := float(cfg.get("behind_max_m", 70.0))
	var lat_max := float(cfg.get("lateral_max_m", 40.0))
	var spacing := float(cfg.get("spacing_m", 12.0))
	var clear := float(cfg.get("player_clear_m", 9.0))
	var corridor := float(cfg.get("corridor_half_width_m", 9.0))
	var probe := float(cfg.get("flat_probe_m", 3.0))
	var gap := float(cfg.get("obstacle_clear_m", 6.0))
	var cands: Array = []
	var b := b_min
	while b <= b_max:
		var l := -lat_max
		while l <= lat_max:
			var p := s2 - fwd * b + right * l
			var rel := p - s2
			var in_corridor := rel.dot(fwd) > -2.0 and absf(rel.dot(right)) < corridor
			if not in_corridor and p.distance_to(s2) >= clear and _free(p, obstacles, gap):
				var slope := _slope_deg(ground_fn, p, probe)
				cands.append({"p": p, "d": p.distance_to(s2), "slope": slope})
			l += grid
		b += grid
	cands.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.d < y.d)
	var out: Array[Dictionary] = []
	for max_slope: float in cfg.get("flat_max_slope_deg", [8.0, 14.0, 90.0]):
		for c: Dictionary in cands:
			if out.size() >= count:
				break
			if float(c.slope) > max_slope:
				continue
			var ok := true
			for o in out:
				if Vector2(o.position.x, o.position.z).distance_to(c.p) < spacing:
					ok = false
					break
			if ok:
				var p: Vector2 = c.p
				var y := float(ground_fn.call(p.x, p.y)) if ground_fn.is_valid() else start.y
				out.append({"position": Vector3(p.x, y, p.y), "heading_deg": heading_deg})
	# Места кончились (тесная вершина) — ставим дальше позади в ряд, как получится.
	var extra := 0
	while out.size() < count:
		var p := s2 - fwd * (b_max + spacing * (1 + extra / 3)) + right * spacing * (extra % 3 - 1)
		var y := float(ground_fn.call(p.x, p.y)) if ground_fn.is_valid() else start.y
		out.append({"position": Vector3(p.x, y, p.y), "heading_deg": heading_deg})
		extra += 1
	return out


static func _free(p: Vector2, obstacles: Array, gap: float) -> bool:
	for o: Vector3 in obstacles:
		if p.distance_to(Vector2(o.x, o.y)) < o.z + gap:
			return false
	return true


static func _slope_deg(ground_fn: Callable, p: Vector2, e: float) -> float:
	if not ground_fn.is_valid():
		return 0.0
	var gx := float(ground_fn.call(p.x + e, p.y)) - float(ground_fn.call(p.x - e, p.y))
	var gz := float(ground_fn.call(p.x, p.y + e)) - float(ground_fn.call(p.x, p.y - e))
	return rad_to_deg(atan(Vector2(gx, gz).length() / (2.0 * e)))


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## Игрок: отрыв (запускает очередь) и кружение (игрок тоже «занимает» термик).
func _observe_player(p: Telemetry, dt: float) -> void:
	if p == null:
		_player_flying = false
		return
	_player_pos = p.position
	_player_vel = p.velocity
	_player_flying = p.phase == "flying"
	if _player_flying and player_liftoff_s < 0.0:
		player_liftoff_s = sim_time_s
	if not _player_flying:
		_p_prev_heading = NAN
		_p_turn = 0.0
		return
	var pos := Vector2(p.position.x, p.position.z)
	if is_nan(_p_prev_heading):
		_p_prev_heading = p.heading_deg
		_p_center = pos
	var dh := wrapf(p.heading_deg - _p_prev_heading, -180.0, 180.0)
	_p_prev_heading = p.heading_deg
	_p_turn = _p_turn * exp(-dt / 20.0) + dh
	_p_center += (pos - _p_center) * (1.0 - exp(-dt / 15.0))
	var thr := float(_cfg.get("thermal_rule", {}).get("player_turn_deg", 300.0))
	_p_center_ok = absf(_p_turn) > thr


func _others_flying() -> bool:
	for o in others:
		if o.flying:
			return true
	return false


## Очередь на старт: разбег бота k — через interval·(k+1) после отрыва игрока (и не раньше,
## чем через interval после разбега предыдущего); к старту идёт заранее — сначала к месту
## в очереди в стороне, к самому старту — когда предыдущий побежал.
func _schedule() -> void:
	if player_liftoff_s < 0.0:
		return
	var interval := float(_cfg.get("launch", {}).get("interval_s", 30.0))
	var prev_run := player_liftoff_s
	var last_run := player_liftoff_s
	var busy := false  # кто-то стоит на старте или бежит
	for a in agents:
		last_run = maxf(last_run, a.run_start_s)
		busy = busy or a.state in [BotAgent.State.READY, BotAgent.State.RUN]
	for k in agents.size():
		var a := agents[k]
		if a.run_start_s >= 0.0:
			prev_run = a.run_start_s
			continue
		var planned := player_liftoff_s + interval * (k + 1)
		var prev_ran := k == 0 or agents[k - 1].run_start_s >= 0.0
		# Игрок снова на земле (сел у старта, идёт на разбег) — новые не бегут, ждут его.
		var flying := _player_flying or _others_flying()
		var ok := prev_ran and flying and (a.state == BotAgent.State.READY or not busy)
		a.queue_hold = not ok
		if ok and a.run_at_s == INF:
			a.run_at_s = maxf(planned, maxf(prev_run, last_run) + interval)
		if a.state == BotAgent.State.WAIT and sim_time_s >= planned - a.walk_time_s():
			a.go_to_launch()


## Коснулся земли (или сел в лес): постоял landed_stand_s («слез и пошёл домой») — убрать
## и снова в очередь на старт (новый бот — те же крыло и расцветка): в небе столько, сколько
## в настройке.
func _respawn() -> void:
	var stand := float(_cfg.get("launch", {}).get("landed_stand_s", 60.0))
	for i in agents.size():
		var a := agents[i]
		if a.state != BotAgent.State.LANDED:
			continue
		if sim_time_s - a.landed_s >= stand:
			a.place(_spots[i].position, float(_spots[i].heading_deg))
			if i < _visuals.size():
				_visuals[i].snap()


func _hz_for(a: BotAgent, ph: Dictionary) -> float:
	if not a.is_airborne():
		return float(ph.get("near_hz", 30.0))
	var d := a.model.position.distance_to(_player_pos)
	for o in others:
		d = minf(d, a.model.position.distance_to(o.pos))
	if d < float(ph.get("near_m", 1500.0)):
		return float(ph.get("near_hz", 30.0))
	if d < float(ph.get("far_m", 4000.0)):
		return float(ph.get("mid_hz", 10.0))
	return float(ph.get("far_hz", 4.0))


# ---------------------------------------------------------------- расхождение


## Прогноз сближения (ближайшая точка за lookahead): кто нарушит «ближе horizontal_m по
## горизонтали и vertical_m по высоте» — уходим от него курсом «от его будущей позиции»
## (лоб в лоб — вправо). От игрока — заранее и дальше.
func _update_separation() -> void:
	var sc: Dictionary = _cfg.get("separation", {})
	var min_agl := float(sc.get("min_agl_m", 25.0))
	for a in agents:
		a.brain.traffic_avoid = false
		if a.state != BotAgent.State.FLY:
			continue
		var t := a.telemetry()
		if t.altitude_agl < min_agl:
			continue
		var best_t := INF
		var away := Vector2.ZERO
		for b in agents:
			if b == a or not b.is_airborne():
				continue
			var bt := b.telemetry()
			var r := _conflict(
				t,
				bt.position,
				bt.velocity,
				float(sc.get("horizontal_m", 50.0)),
				float(sc.get("vertical_m", 15.0)),
				float(sc.get("lookahead_s", 12.0))
			)
			if r.x < best_t:
				best_t = r.x
				away = Vector2(r.y, r.z)
		var humans: Array[Dictionary] = []
		if _player_flying:
			humans.append({"pos": _player_pos, "vel": _player_vel})
		for o in others:
			if o.flying:
				humans.append(o)
		for hp in humans:
			var r := _conflict(
				t,
				hp.pos,
				hp.vel,
				float(sc.get("player_horizontal_m", 90.0)),
				float(sc.get("player_vertical_m", 30.0)),
				float(sc.get("player_lookahead_s", 20.0))
			)
			if r.x < best_t:
				best_t = r.x
				away = Vector2(r.y, r.z)
		if best_t < INF:
			a.brain.traffic_avoid = true
			a.brain.traffic_heading_deg = fposmod(rad_to_deg(atan2(away.x, -away.y)), 360.0)


## Сближение с другим: Vector3(время до ближайшей точки или INF, направление ухода x, z).
func _conflict(
	t: Telemetry, p: Vector3, v: Vector3, sep_h: float, sep_v: float, horizon: float
) -> Vector3:
	var dp := p - t.position
	var dv := v - t.velocity
	var dph := Vector2(dp.x, dp.z)
	var dvh := Vector2(dv.x, dv.z)
	var vv := dvh.length_squared()
	var tc := 0.0 if vv < 1.0e-4 else clampf(-dph.dot(dvh) / vv, 0.0, horizon)
	var miss := dph + dvh * tc
	var dy := absf(dp.y + dv.y * tc)
	if miss.length() >= sep_h or dy >= sep_v:
		return Vector3(INF, 0.0, 0.0)
	# Уйти от будущей позиции другого; лоб в лоб (промах почти ноль) — вправо от своего курса.
	var dir := -miss
	if dir.length() < 5.0:
		var h := deg_to_rad(t.heading_deg + 60.0)
		dir = Vector2(sin(h), -cos(h))
	dir = dir.normalized()
	return Vector3(tc, dir.x, dir.y)


# ---------------------------------------------------------------- термики: одна сторона


## BotPilot начинает кружить в pos: сторона — как у «занятого» термика рядом, иначе своя
## (и термик теперь «занят» этим ботом).
func _circle_dir(pos: Vector2, _alt: float, dir: float, bot_id: int) -> float:
	var c := _claim_near(pos)
	if c >= 0:
		claims[c].t = sim_time_s
		return float(claims[c].dir)
	claims.append({"center": pos, "dir": signf(dir), "t": sim_time_s, "owner": bot_id})
	return dir


func _claim_near(pos: Vector2) -> int:
	var tr: Dictionary = _cfg.get("thermal_rule", {})
	var radius := float(tr.get("radius_m", 300.0))
	var best := -1
	var best_d := radius
	for i in claims.size():
		var d := pos.distance_to(claims[i].center)
		if d < best_d:
			best_d = d
			best = i
	return best


## Раз в check_hz: забыть старые термики; кружащие боты и игрок освежают свой; бот, кружащий
## не в ту сторону (два термика слились), разворачивается по правилу.
func _update_claims() -> void:
	var memory := float(_cfg.get("thermal_rule", {}).get("memory_s", 60.0))
	var keep: Array[Dictionary] = []
	for c in claims:
		if sim_time_s - float(c.t) <= memory:
			keep.append(c)
	claims = keep
	if _player_flying and _p_center_ok:
		var i := _claim_near(_p_center)
		if i < 0:
			claims.append(
				{"center": _p_center, "dir": signf(_p_turn), "t": sim_time_s, "owner": -1}
			)
		else:
			claims[i].t = sim_time_s
	for a in agents:
		if a.state != BotAgent.State.FLY or not a.brain.is_circling():
			continue
		var lc := a.brain.lift_center()
		var i := _claim_near(lc)
		if i < 0:
			claims.append(
				{"center": lc, "dir": a.brain.circle_dir(), "t": sim_time_s, "owner": a.id}
			)
			continue
		claims[i].t = sim_time_s
		if int(claims[i].owner) == a.id:
			claims[i].center = (claims[i].center as Vector2).lerp(lc, 0.2)
		elif a.brain.circle_dir() != float(claims[i].dir):
			a.brain.set_circle_dir(float(claims[i].dir))
