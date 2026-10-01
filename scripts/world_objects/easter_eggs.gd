class_name EasterEggs
extends Node3D
## Планировщик пасхалок (docs/easter_eggs_contracts.md → К1, К4, К5, К6). Узел Game/EasterEggs.
## Ход — кадром (_process → update), не из шага физики. Только в полёте; время — Game.world_time().
## Расписание — чистая функция (ключ мира, id, окно): любой шаг кадра и прыжок времени дают то же.
## Планировщик ничего не пишет в игру: он только читает контекст и держит своих детей.

## Настройки (configs/easter_eggs.json); тесты подменяют до _ready или после.
var cfg: Dictionary = {}
## Включён ли планировщик (cfg.enabled); тесты выключают для контрольного прогона.
var enabled := true
## Журнал появлений: [[id, t0], …] с последнего reset() (для тестов).
var spawn_log: Array = []
## Сколько раз бросали кубик / проверяли условие (в меню и вне полёта — 0).
var roll_count := 0

var _game: Game
var _plan := {}  ## "id|окно" → {appear, t0, rng}: бросок сделан, ждём t0
var _done := {}  ## "id|окно" → true: рассмотрено (появилась или нет), больше не смотрим
var _forced: Array = []  ## [{id, at}] — принудительные вызовы (force)
var _last_check := {}  ## id → номер последней проверки условия (mode = condition)
var _last_t := 0.0
var _scripts := {}  ## id → загруженный скрипт
var _ctx := EggContext.new()
var _serial := 0
var _place: EggPlace  ## место: один раз на полёт, лениво


func _ready() -> void:
	_game = get_parent() as Game
	if cfg.is_empty():
		cfg = Config.get_config("easter_eggs")
	enabled = bool(cfg.get("enabled", true))


func _process(_dt: float) -> void:
	update()


## Раз в кадр: контекст → step. В меню, на загрузке, вне полёта — ничего (детей нет).
func update() -> void:
	if _game == null:
		return
	if not enabled or _game.settings == null or not _game.flying_enabled:
		if get_child_count() > 0:
			reset()
		return
	if _game.is_paused():
		return
	_fill_ctx(_game)
	step(_ctx)


## Убрать всех детей и забыть расписание (Game.start() / restart()).
func reset() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_plan.clear()
	_done.clear()
	_forced.clear()
	_last_check.clear()
	spawn_log.clear()
	_place = null


## Вызвать пасхалку id ("all" — все включённые) через delay_s с времени мира: без кубика и
## без can_appear. Ключ сида — «мир|id|force».
func force(id: String, delay_s := 0.0) -> void:
	var at := _now() + delay_s
	if id == "all":
		for k in _egg_ids():
			if bool(_egg_cfg(k).get("enabled", true)):
				_forced.append({"id": k, "at": at})
		return
	if not _egg_cfg(id).is_empty():
		_forced.append({"id": id, "at": at})
	else:
		push_warning("EasterEggs.force: нет пасхалки «%s» в configs/easter_eggs.json" % id)


## Разобрать ключ запуска: «id[:через_с][,id2[:с]…]» или «all»; «none» и пусто — ничего.
func force_spec(spec: String) -> void:
	for part in spec.split(",", false):
		var kv := part.strip_edges().split(":")
		if kv[0] == "none" or kv[0] == "":
			continue
		force(kv[0], float(kv[1]) if kv.size() > 1 else 0.0)


## Живые пасхалки.
func active() -> Array[EasterEgg]:
	var out: Array[EasterEgg] = []
	for c in get_children():
		if c is EasterEgg:
			out.append(c)
	return out


## Один шаг планировщика на контексте ctx (update() строит его из Game; тесты дают свой).
func step(ctx: EggContext) -> void:
	_last_t = ctx.t
	for egg in active():
		if not egg.update(ctx):
			_remove(egg)
	var still: Array = []
	for f in _forced:
		if ctx.t >= float(f.at):
			var rng := _rng("%s|%s|force" % [ctx.world_key, f.id])
			_spawn(String(f.id), float(f.at), rng, ctx)
		else:
			still.append(f)
	_forced = still
	for id in _egg_ids():
		var ecfg := _egg_cfg(id)
		if not bool(ecfg.get("enabled", true)):
			continue
		match String(ecfg.get("mode", "interval")):
			"interval":
				_step_interval(id, ecfg, ctx)
			"per_flight":
				_step_per_flight(id, ecfg, ctx)
			"condition":
				_step_condition(id, ecfg, ctx)


func _step_interval(id: String, ecfg: Dictionary, ctx: EggContext) -> void:
	var slot := float(ecfg.get("slot_s", 60.0))
	var mean := float(ecfg.get("mean_interval_s", 300.0))
	var life := float(ecfg.get("lifetime_s", 0.0))
	var n_hi := int(floor(ctx.t / slot))
	var n_lo := n_hi if life <= 0.0 else maxi(int(floor((ctx.t - life) / slot)), 0)
	for n in range(n_lo, n_hi + 1):
		var key := "%s|%d" % [id, n]
		if _done.has(key):
			continue
		if not _plan.has(key):
			roll_count += 1
			var rng := _rng("%s|%s|%d" % [ctx.world_key, id, n])
			var appear := rng.randf() < slot / mean
			var t0 := (n + rng.randf()) * slot
			_plan[key] = {"appear": appear, "t0": t0, "rng": rng}
		_try_plan(key, id, ecfg, ctx, life)


func _step_per_flight(id: String, ecfg: Dictionary, ctx: EggContext) -> void:
	var key := "%s|flight" % id
	if _done.has(key):
		return
	if not _plan.has(key):
		roll_count += 1
		var rng := _rng("%s|%s|flight" % [ctx.world_key, id])
		var appear := rng.randf() < float(ecfg.get("chance", 0.0))
		var w: Array = ecfg.get("window_s", [60.0, 1800.0])
		var t0 := rng.randf_range(float(w[0]), float(w[1]))
		_plan[key] = {"appear": appear, "t0": t0, "rng": rng}
	_try_plan(key, id, ecfg, ctx, float(ecfg.get("lifetime_s", 0.0)))


func _try_plan(key: String, id: String, ecfg: Dictionary, ctx: EggContext, life: float) -> void:
	var p: Dictionary = _plan[key]
	if not bool(p.appear):
		_plan.erase(key)
		_done[key] = true
		return
	if ctx.t < float(p.t0):
		return
	_plan.erase(key)
	_done[key] = true
	if life > 0.0 and ctx.t >= float(p.t0) + life:
		return  # пока не смотрели, вся жизнь прошла (прыжок времени)
	var sc := _script_for(id, ecfg)
	if sc != null and bool(sc.call("can_appear", ctx, ecfg)):
		_spawn(id, float(p.t0), p.rng, ctx)


func _step_condition(id: String, ecfg: Dictionary, ctx: EggContext) -> void:
	var idx := int(floor(ctx.t / float(ecfg.get("check_s", 1.0))))
	if _last_check.get(id, -1) == idx:
		return
	_last_check[id] = idx
	for e in active():
		if e.id == id:
			return
	roll_count += 1
	var sc := _script_for(id, ecfg)
	if sc != null and bool(sc.call("can_appear", ctx, ecfg)):
		var rng := _rng("%s|%s|%d" % [ctx.world_key, id, int(floor(ctx.t))])
		_spawn(id, ctx.t, rng, ctx)


func _spawn(id: String, t0: float, rng: RandomNumberGenerator, ctx: EggContext) -> void:
	var ecfg := _egg_cfg(id)
	var sc := _script_for(id, ecfg)
	if sc == null:
		return
	var egg := sc.new() as EasterEgg
	if egg == null:
		push_warning("EasterEggs: %s не наследует EasterEgg" % id)
		return
	_serial += 1
	egg.name = "%s_%d" % [id, _serial]
	egg.id = id
	egg.t0 = t0
	egg.lifetime_s = float(ecfg.get("lifetime_s", 0.0))
	add_child(egg)
	spawn_log.append([id, t0])
	egg.begin(ctx, ecfg, rng, t0)
	if not egg.update(ctx):
		_remove(egg)


func _remove(egg: EasterEgg) -> void:
	remove_child(egg)
	egg.queue_free()


func _script_for(id: String, ecfg: Dictionary) -> Script:
	if not _scripts.has(id):
		var path := String(ecfg.get("script", ""))
		_scripts[id] = load(path) if path != "" and ResourceLoader.exists(path) else null
		if _scripts[id] == null:
			push_warning("EasterEggs: не загрузился скрипт «%s» (%s)" % [id, path])
	return _scripts[id]


func _rng(seed_text: String) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_text.hash()
	return r


func _egg_ids() -> Array:
	var eggs: Dictionary = cfg.get("eggs", {})
	var out: Array = []
	for k in eggs:
		if not String(k).begins_with("_") and not String(k).ends_with("_doc"):
			if eggs[k] is Dictionary:
				out.append(String(k))
	return out


func _egg_cfg(id: String) -> Dictionary:
	var eggs: Dictionary = cfg.get("eggs", {})
	return eggs[id] if eggs.get(id) is Dictionary else {}


func _now() -> float:
	return _game.world_time() if _game != null and _game.settings != null else _last_t


func _fill_ctx(g: Game) -> void:
	var c := _ctx
	c.t = g.world_time()
	c.hour = g.sky.clock.hour
	c.to_sun = g.sky.clock.to_sun()
	c.world_key = g.world_key()
	c.camera = get_viewport().get_camera_3d()
	c.pilot_pos = g.glider.get_telemetry().position
	c.weather = g.air.get("weather") if "weather" in g.air else {}
	c.cloudbase_msl = (
		float(g.air.call("get_cloudbase_msl")) if g.air.has_method("get_cloudbase_msl") else NAN
	)
	c.graphics = GraphicsPresets.current()
	c.height_at = g.terrain.height_at
	if g.air.has_method("cloud_density_at"):
		c.cloud_density_at = Callable(g.air, "cloud_density_at")
	c.terrain = g.terrain
	c.air = g.air
	c.month = g.sky.clock.month
	c.day = g.sky.clock.day
	c.sun_elev_deg = rad_to_deg(asin(clampf(c.to_sun.y, -1.0, 1.0)))
	c.sky = g.settings.sky
	c.wind_ms = g.settings.wind_speed_kmh / 3.6
	c.wind_from_deg = g.settings.wind_from_deg
	if g.settings.wind_into_launch:  # «ветер в старт»: дует в курс выбранного старта (К2)
		c.wind_from_deg = float(g.get_start().heading_deg)
	c.temp_c = g.settings.temperature_c
	if _place == null:
		var objs: Node = g.world_link.objects if g.world_link != null else null
		_place = EggPlace.build(g.terrain, objs, cfg.get("place", {}))
	c.place = _place
