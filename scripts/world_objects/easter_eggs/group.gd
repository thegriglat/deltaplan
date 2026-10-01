class_name EggGroup
extends EasterEgg
## «Другая группа на дальнем склоне» (E10, docs/easter_eggs_contracts.md → К9): над другим,
## далёким стартом локации уже летают 1–3 чужих дельтаплана. Это обычные боты (BotPilots без
## изменений) в СВОЁМ экземпляре — дочернем узле пасхалки, не в game.bots: ключ мира, боты игры,
## воздух и физика игрока не меняются (только чтение air_velocity_at, как у ботов игры).
## Все боты стартуют сразу в воздухе (airborne_share = 1.0); дальше — существующая логика:
## парят, садятся, снова встают в очередь на своём старте.
## Ход — из update() кадра (К1) подшагами 1/120 с по времени мира: floor(t·120) − сделано,
## не больше max_catchup_s за кадр (прыжок времени не догоняется — группа локальная).
## Порядок бросков rng в begin: число ботов, выбор старта, сид ботов.

const SUB_HZ := 120.0

## Выбранный старт группы ({} — группы нет: нет места или дальнего старта).
var site: Dictionary = {}
## Свои боты (null — пусто).
var bots: BotPilots
## Сколько подшагов 1/120 с уже сделано (абсолютный номер по времени мира).
var substeps_done := 0

var _cfg: Dictionary = {}


## Условия: день, лётная погода, есть реальный дальний старт с ветром на его склон.
static func can_appear(ctx: EggContext, cfg: Dictionary) -> bool:
	if ctx.sun_elev_deg < float(cfg.get("min_sun_deg", 10.0)):
		return false
	if ctx.sky == "overcast":
		return false
	if ctx.wind_ms > float(cfg.get("max_wind_ms", 9.0)):
		return false
	if ctx.place == null:
		return false
	return not far_sites(ctx, cfg, true).is_empty()


## Игра, к которой принадлежит узел (для старта игрока и телеметрии; только чтение).
static func game_of(n: Node) -> Game:
	while n != null:
		if n is Game:
			return n
		n = n.get_parent()
	return null


## Старт игрока {position, heading_deg}: из игры; без игры — ближайший к пилоту старт локации.
static func player_start(ctx: EggContext) -> Dictionary:
	var g := game_of(ctx.terrain)
	if g != null and g.settings != null:
		return g.get_start()
	var best := {"position": ctx.pilot_pos, "heading_deg": ctx.wind_from_deg}
	var best_d := INF
	for s in ctx.place.start_sites() if ctx.place != null else []:
		var p: Vector3 = s.position
		var d := Vector2(p.x - ctx.pilot_pos.x, p.z - ctx.pilot_pos.z).length()
		if d < best_d:
			best_d = d
			best = s
	return best


## Откуда ветер, °: «ветер в старт» игрока — его курс (так ставит воздух Game), иначе прогноз.
static func wind_from(ctx: EggContext) -> float:
	var g := game_of(ctx.terrain)
	if g != null and g.settings != null and g.settings.wind_into_launch:
		return float(g.get_start().heading_deg)
	return ctx.wind_from_deg


## Угол между ветром «откуда» и курсом старта, ° (0 — ветер прямо в склон).
static func wind_angle(ctx: EggContext, s: Dictionary) -> float:
	return absf(wrapf(wind_from(ctx) - float(s.heading_deg), -180.0, 180.0))


## Реальные старты локации дальше min_site_dist_m от старта игрока; need_wind — ещё и ветер на
## склон (угол ≤ max_wind_angle_deg; почти штиль — любой склон).
static func far_sites(ctx: EggContext, cfg: Dictionary, need_wind: bool) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if ctx.place == null:
		return out
	var ps: Vector3 = player_start(ctx).position
	var calm := ctx.wind_ms < float(cfg.get("calm_ms", 1.5))
	for s in ctx.place.start_sites():
		var p: Vector3 = s.position
		if Vector2(p.x - ps.x, p.z - ps.z).length() < float(cfg.get("min_site_dist_m", 2000.0)):
			continue
		if need_wind and not calm and wind_angle(ctx, s) > float(cfg.get("max_wind_angle_deg", 50.0)):
			continue
		out.append(s)
	return out


func begin(ctx: EggContext, cfg: Dictionary, rng: RandomNumberGenerator, at_t: float) -> void:
	_cfg = cfg
	substeps_done = floori(at_t * SUB_HZ)
	var nc: Array = cfg.get("bots_count", [1, 3])
	var n := rng.randi_range(int(nc[0]), int(nc[1]))
	var cands := far_sites(ctx, cfg, true)
	if cands.is_empty():
		# форс без условий: лучший по ветру дальний старт; нет дальних — пусто
		var all := far_sites(ctx, cfg, false)
		all.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				return wind_angle(ctx, a) < wind_angle(ctx, b)
		)
		cands = all.slice(0, 1)
	var pick := rng.randi()
	var bot_seed := rng.randi()
	if cands.is_empty():
		return
	site = cands[pick % cands.size()]
	bots = BotPilots.new()
	bots.name = "GroupBots"
	bots.top_level = true  # боты — в мировых координатах; сама пасхалка — центр группы
	add_child(bots)
	var air: Node = ctx.air
	var opts := {
		"air_fn":
		(
			Callable(air, "air_velocity_at")
			if air != null and air.has_method("air_velocity_at")
			else func(_p: Vector3) -> Vector3: return Vector3.ZERO
		),
		"ground_fn": ctx.place.height_at,
		"start": site.position,
		"heading_deg": float(site.heading_deg),
		"count": n,
		"seed": bot_seed,
		"airborne_share": 1.0,
		"cloudbase_msl": ctx.cloudbase_msl if is_finite(ctx.cloudbase_msl) else 1.0e9,
	}
	if air is Atmosphere:
		var atmo := air as Atmosphere
		opts.clouds_fn = func() -> Array: return BotPilots._visible_clouds(atmo)
	bots.setup(opts)
	_place_center()


func update(ctx: EggContext) -> bool:
	if bots == null:
		return true
	var target := floori(ctx.t * SUB_HZ)
	var max_n := int(float(_cfg.get("max_catchup_s", 0.5)) * SUB_HZ)
	if target - substeps_done > max_n:
		substeps_done = target - max_n  # прыжок времени: не догоняем
	var g := game_of(self)
	var tel: Telemetry = g.glider.get_telemetry() if g != null and g.glider != null else null
	while substeps_done < target:
		bots.tick(1.0 / SUB_HZ, tel)
		substeps_done += 1
	substeps_done = maxi(substeps_done, target)  # время назад — просто ждём
	_place_center()
	return true


## Сколько ботов в группе.
func bot_count() -> int:
	return bots.agents.size() if bots != null else 0


## Центр группы (для --look-at=egg): средняя точка ботов в воздухе, иначе всех.
func _place_center() -> void:
	if bots == null or bots.agents.is_empty():
		return
	var sum := Vector3.ZERO
	var k := 0
	for pass_i in 2:
		for a in bots.agents:
			if pass_i == 1 or a.is_airborne():
				sum += a.model.position
				k += 1
		if k > 0:
			break
	position = sum / k
