extends Node
## Прогон бота-маршрутника (FR-34a) headless и статистика полёта в JSON.
##
##   godot --headless --path . res://tests/atmosphere/xc/xc_run.tscn -- \
##     --location=ongudai --weather=medium --seed=1 --wind=15,270 --km=30 --out=out.json [--clouds]
##
## Синтетика (--synthetic): плоская земля, статичные термики сеткой вдоль курса, без ветра.
## Прочие флаги: --course=<°> (по умолчанию по ветру), --start-agl=300, --time-limit=<с>,
## --wing=sport, --no-thermals, --bg=<м/с>, --start-alt=<м AGL>, --grid=<м>, --lateral=<м>,
## --strength=<м/с>, --radius=<м>, --turbulence=0|1, --cloudbase-agl=<м>, --trace=<с>,
## --ideal (диагностика «идеальный пилот»: знает оси термиков, карточка 07), --ideal-min=<м/с>.

const DT := 1.0 / 60.0
const HIST_BIN := 0.5
const CLOUD_DENSITY := 0.3
const STRONG_VARIO := 7.0

## CPU последнего полёта, с (в JSON не пишем — JSON должен повторяться при том же сиде).
var _last_fly_cpu_s: float = 0.0
var _air_p: Vector3 = Vector3(INF, INF, INF)
var _air_v: Vector3 = Vector3.ZERO


func _ready() -> void:
	var opts := parse_args(OS.get_cmdline_user_args())
	var t0 := Time.get_ticks_usec()
	var res := simulate(opts)
	var cpu := (Time.get_ticks_usec() - t0) / 1.0e6
	var text := JSON.stringify(res, "  ", false)
	var out := String(opts.get("out", ""))
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f == null:
			push_error("xc_run: не открыть %s" % out)
		else:
			f.store_string(text + "\n")
			f.close()
	else:
		print(text)
	print(
		(
			"xc_run: %.1f км за %.0f с полёта, %s; CPU %.1f с (полёт %.1f с)"
			% [res.distance_km, res.time_s, res.end_reason, cpu, _last_fly_cpu_s]
		)
	)
	get_tree().quit(0)


static func parse_args(args: PackedStringArray) -> Dictionary:
	var o := {}
	for a in args:
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		o[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return o


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _sun(_x: float, _z: float) -> float:
	return 1.0


## Один прогон. opts — как флаги командной строки (строки или числа). Возвращает метрики.
func simulate(opts: Dictionary) -> Dictionary:
	var synthetic := opts.has("synthetic")
	var seed_i := int(opts.get("seed", 1))
	var km := float(opts.get("km", 30))
	var wing_name := String(opts.get("wing", "sport"))
	var weather: Dictionary = Config.get_config("weather/" + String(opts.get("weather", "medium")))
	weather = weather.duplicate(true)
	var atmo_cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	atmo_cfg.seed = int(atmo_cfg.seed) + seed_i * 7919
	# Профиль прогона: термики — чистые функции клетки и цикла, поэтому радиусы генерации и
	# физики влияют только на CPU, не на воздух рядом с ботом. Облака бот читает до 8 км.
	atmo_cfg.thermal.generation_radius_m = 9000.0 if opts.has("clouds") else 7000.0
	atmo_cfg.thermal.physics_radius_m = 3000.0
	if opts.has("wind"):
		var w := String(opts.wind).split(",")
		weather.wind_speed_kmh = float(w[0])
		weather.wind_from_deg = float(w[1]) if w.size() > 1 else float(weather.wind_from_deg)
	if opts.has("bg"):
		weather.background_sink_ms = float(opts.bg)
	if opts.has("cloudbase-agl"):
		weather.cloudbase_agl_m = float(opts["cloudbase-agl"])

	var terrain: Terrain = null
	var height_fn: Callable = _flat
	var start := Vector3.ZERO
	var course := fposmod(float(weather.wind_from_deg) + 180.0, 360.0)
	var static_list: Array = []
	if synthetic:
		weather.wind_speed_kmh = 0.0
		weather.thermal_mode = "static"
		course = float(opts.get("course", 90.0))
		static_list = synthetic_thermals(opts, seed_i, km, course)
		weather.static_thermals = [] if opts.has("no-thermals") else static_list
	else:
		terrain = Terrain.new()
		terrain.location_id = ""
		if not terrain.load_location(String(opts.get("location", "ongudai"))):
			terrain.free()
			return {"error": "location"}
		height_fn = terrain.height_at
		var site: Dictionary = terrain.get_start_sites()[0]
		var sp: Vector3 = site.position
		start = Vector3(sp.x, 0.0, sp.z)
		if opts.has("no-thermals"):
			weather.thermal_mode = "static"
	if opts.has("course"):
		course = float(opts.course)

	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.configure(atmo_cfg, weather)
	# Синтетика — идеальный воздух (без болтанки), если не попросили иначе.
	atmo.turbulence_enabled = int(opts.get("turbulence", 0 if synthetic else 1)) != 0
	if synthetic:
		atmo.set_ground(height_fn, _sun)
	else:
		atmo.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
	var start_agl := float(opts.get("start-alt", opts.get("start-agl", 300.0)))
	start.y = float(height_fn.call(start.x, start.z)) + start_agl

	var cdir := Vector2(sin(deg_to_rad(course)), -cos(deg_to_rad(course)))
	var start2 := Vector2(start.x, start.z)
	var goal := start2 + cdir * km * 1000.0

	var wing: Dictionary = Config.get_config("wings/" + wing_name)
	var pilot_cfg: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot_cfg.mass_kg = float(wing.pilot_mass_ref_kg)
	var fm := FlightModel.new()
	fm.setup(wing, pilot_cfg)
	atmo.set_focus(start)
	atmo.step(DT)
	fm.reset_in_air(start, course, 0.0, atmo.mean_wind_at(start))

	var bot: XcPilot = XcIdealPilot.new() if opts.has("ideal") else XcPilot.new()
	bot.setup(wing, pilot_cfg, goal)
	bot.route_start = start2
	bot.ground_fn = height_fn
	bot.cloudbase_msl = atmo.get_cloudbase_msl()
	bot.use_clouds = opts.has("clouds")
	if bot.use_clouds:
		bot.clouds_fn = _visible_clouds.bind(atmo, fm)
	if opts.has("ideal"):
		var ideal := bot as XcIdealPilot
		ideal.oracle_fn = _oracle.bind(atmo)
		ideal.min_w = float(opts.get("ideal-min", 0.8))

	var res := _fly(
		fm,
		atmo,
		bot,
		height_fn,
		start2,
		cdir,
		km,
		float(opts.get("time-limit", 14400)),
		float(opts.get("trace", 0.0))
	)
	res.config = {
		"location": "synthetic" if synthetic else String(opts.get("location", "ongudai")),
		"weather": String(opts.get("weather", "medium")),
		"seed": seed_i,
		"wind_kmh": float(weather.wind_speed_kmh),
		"wind_from_deg": float(weather.wind_from_deg),
		"course_deg": course,
		"km": km,
		"wing": wing_name,
		"clouds": bot.use_clouds,
		"start_agl_m": start_agl,
		"cloudbase_msl_m": snappedf(atmo.get_cloudbase_msl(), 0.1),
		"background_sink_ms": float(weather.background_sink_ms),
		"turbulence": atmo.turbulence_enabled,
		"generation_radius_m": float(atmo_cfg.thermal.generation_radius_m),
		"physics_radius_m": float(atmo_cfg.thermal.physics_radius_m),
	}
	res.polar = _polar_info(fm)
	if opts.has("no-thermals"):
		# Без термиков: дальность ≈ высота × качество в опускающемся воздухе (лучшее по поляре).
		var bg := -float(weather.background_sink_ms)
		var q := _best_glide_in_sink(fm, bg)
		res.no_thermals = {
			"height_m": snappedf(start_agl, 0.1),
			"glide_in_sink": snappedf(q, 0.01),
			"expected_km": snappedf(start_agl * q / 1000.0, 0.001),
			"ratio": snappedf(float(res.distance_km) / (start_agl * q / 1000.0), 0.001),
		}
	if synthetic and not opts.has("no-thermals"):
		res.synthetic = _synthetic_report(static_list, bot, start2, cdir, km * 1000.0)
		# Эталон: ядро − снижение крыла на вираже бота (штиль, та же трапеция и крен,
		# средняя высота кругов).
		var alt := 0.0
		for c: Dictionary in bot.circles:
			alt += float(c.alt_m) / bot.circles.size()
		var sink := _turn_sink(wing, pilot_cfg, bot, alt if alt > 0.0 else 1000.0)
		var core := float(opts.get("strength", 3.0))
		res.synthetic.core_ms = core
		res.synthetic.turn_sink_ms = snappedf(sink, 0.001)
		res.synthetic.climb_ratio = snappedf(float(res.avg_climb_ms) / (core - sink), 0.001)
	atmo.free()
	if terrain != null:
		terrain.free()
	return res


## Сетка статичных термиков вдоль курса: через grid м (первый — на grid/2), поперёк —
## случайное смещение ±lateral м (сид), вдоль — ±15 % шага.
static func synthetic_thermals(opts: Dictionary, seed_i: int, km: float, course: float) -> Array:
	var grid := float(opts.get("grid", 2000.0))
	var lateral := float(opts.get("lateral", 200.0))
	var strength := float(opts.get("strength", 3.0))
	var radius := float(opts.get("radius", 100.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_i * 1000003 + 17)
	var cdir := Vector2(sin(deg_to_rad(course)), -cos(deg_to_rad(course)))
	var side := Vector2(-cdir.y, cdir.x)
	var out: Array = []
	var s := grid * 0.5
	while s < km * 1000.0 + grid:
		var along := s + rng.randf_range(-0.15, 0.15) * grid
		var lat := rng.randf_range(-lateral, lateral)
		if out.is_empty():
			# Со старта (300 м AGL) первый термик должен быть досягаем и найден по пути.
			along = minf(along, 800.0)
			lat = clampf(lat, -20.0, 20.0)
		var p := cdir * along + side * lat
		out.append({"x_m": p.x, "z_m": p.y, "strength_ms": strength, "radius_m": radius})
		s += grid
	return out


func _visible_clouds(atmo: Atmosphere, fm: FlightModel) -> Array:
	var out: Array = []
	var model := atmo.cloud_phys.model
	for e: Array in model.select(atmo.field.thermals, atmo.time_s, fm.position):
		var st: Vector3 = e[2]
		out.append({"center": e[3], "radius": float(e[4]), "growth": st.x, "decay": st.y})
	return out


## Диагностика «идеальный пилот» (--ideal, карточка 07): живые термики в 2,5 км — ось на высоте p.
static func _oracle(p: Vector3, atmo: Atmosphere) -> Array:
	var out: Array = []
	for th: AtmoThermal in atmo.field.near(p, 2500.0):
		if th.env <= 0.05 or p.y < th.cut_h or p.y > th.top:
			continue
		out.append(
			{"id": th.id, "center": th.axis_at(p.y), "w": th.strength * th.env, "top": th.top}
		)
	return out


func _fly(
	fm: FlightModel,
	atmo: Atmosphere,
	bot: XcPilot,
	height_fn: Callable,
	start: Vector2,
	cdir: Vector2,
	km: float,
	time_limit: float,
	trace: float = 0.0
) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	# Воздух с памятью последней точки: FlightTelemetry после шага спрашивает воздух в новой
	# позиции, и следующий шаг — в ней же (на 1/60 с позже). Берём прошлое значение: экономия
	# четверти самых дорогих вызовов, разница — эволюция порывов за 1/60 с.
	var air_fn := _air_cached.bind(atmo)
	var goal_m := km * 1000.0
	var progress := 0.0
	var reason := "time_limit"
	var t := 0.0
	var circling_t := 0.0
	var cloud_t := 0.0
	var strong_t := 0.0
	var max_vario := -INF
	var ring := PackedFloat32Array()
	ring.resize(60)
	ring.fill(0.0)
	var ring_i := 0
	var ring_sum := 0.0
	var tr_dist := 0.0
	var tr_loss := 0.0
	var tr_time := 0.0
	var tr_vario := 0.0
	var prev := fm.position
	var h0 := fm.position.y
	var cloud_flags: Array[bool] = []
	var lift_sum := 0.0
	var air_sum := 0.0
	var vario_sum := 0.0
	var lift_n := 0
	var inp := ControlInput.new()
	var step_i := 0
	while t < time_limit:
		atmo.set_focus(fm.position)
		atmo.step(DT)
		# Пилот реагирует 30 раз в секунду (решения дорогие, физика — 60 Гц).
		if step_i % 2 == 0:
			inp = bot.drive(fm.telemetry, DT * 2.0)
		fm.step(DT, inp, air_fn, height_fn)
		t += DT
		step_i += 1
		var p := fm.position
		var tel := fm.telemetry
		# Вариометр прибора — среднее за 1 с.
		ring_sum += tel.vario - ring[ring_i]
		ring[ring_i] = tel.vario
		ring_i = (ring_i + 1) % ring.size()
		if t >= 1.0:
			var va := ring_sum / ring.size()
			max_vario = maxf(max_vario, va)
			if va >= STRONG_VARIO:
				strong_t += DT
		if bot.is_circling():
			circling_t += DT
			# Воздух в кружении (диагностика 07): подъём термика у пилота и полная вертикаль.
			if step_i % 6 == 0:
				var sm := atmo.field.sample(p)
				lift_sum += sm.x
				air_sum += atmo.air_velocity_at(p).y
				vario_sum += tel.vario
				lift_n += 1
		else:
			tr_time += DT
			tr_vario += tel.vario
			tr_dist += Vector2(p.x - prev.x, p.z - prev.z).length()
			tr_loss += prev.y - p.y
		# «В облаке» — раз в 0,1 с (дорого считать каждый шаг).
		if step_i % 6 == 0 and atmo.cloud_density_at(p) > CLOUD_DENSITY:
			cloud_t += DT * 6.0
		if trace > 0.0 and step_i % maxi(1, roundi(trace / DT)) == 0:
			print(
				(
					"%7.1f x=%7.0f z=%6.0f h=%6.1f v=%5.2f n=%5.2f m=%d b=%5.1f as=%4.1f p=%5.2f th=%5.2f %s"
					% [
						t,
						p.x,
						p.z,
						p.y,
						tel.vario,
						bot.netto(),
						bot.mode,
						tel.bank_deg,
						tel.airspeed,
						inp.pitch,
						atmo.field.sample(p).x,
						bot.debug_state()
					]
				)
			)
		# Новый термик: было ли над ним облако (смотрим сразу, пока облака рядом в физике).
		if bot.thermals.size() > cloud_flags.size():
			cloud_flags.append(_cloud_above(atmo, bot.thermals[-1].exit))
		prev = p
		progress = maxf(progress, (Vector2(p.x, p.z) - start).dot(cdir))
		if progress >= goal_m:
			reason = "goal"
			break
		if fm.mode != FlightModel.Mode.AIR:
			reason = "landed"
			break
	var climbs: Array = []
	var hist := {}
	for c: Dictionary in bot.circles:
		climbs.append(float(c.climb_ms))
		var b := floori(float(c.climb_ms) / HIST_BIN)
		var key := "%.1f" % (b * HIST_BIN)
		hist[key] = int(hist.get(key, 0)) + 1
	# Термик — заход с набором высоты (попытки без набора не считаем).
	var n_th := 0
	var no_cloud := 0
	for i in bot.thermals.size():
		if float(bot.thermals[i].gain_m) > 0.0:
			n_th += 1
			if i < cloud_flags.size() and not cloud_flags[i]:
				no_cloud += 1
	var keys := hist.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return float(a) < float(b))
	var hist_sorted := {}
	for k: String in keys:
		hist_sorted[k] = hist[k]
	var res := {
		"end_reason": reason,
		"distance_km": snappedf(minf(progress, goal_m) / 1000.0, 0.001),
		"time_s": snappedf(t, 0.01),
		"avg_speed_kmh": snappedf(minf(progress, goal_m) / maxf(t, 1.0) * 3.6, 0.01),
		"circling_fraction": snappedf(circling_t / maxf(t, 1.0), 0.0001),
		"thermals": n_th,
		"thermal_attempts": bot.thermals.size(),
		"circles": climbs.size(),
		"avg_climb_ms": snappedf(_mean(climbs), 0.001),
		"climb_histogram_0_5ms": hist_sorted,
		"glide_avg_sink_ms": snappedf(-tr_vario / maxf(tr_time / DT, 1.0), 0.001),
		"glide_ratio_eff": snappedf(tr_dist / tr_loss if tr_loss > 1.0 else 0.0, 0.01),
		"max_vario_ms": snappedf(max_vario, 0.01),
		"time_vario_ge_7_s": snappedf(strong_t, 0.01),
		"time_in_cloud_s": snappedf(cloud_t, 0.01),
		"no_cloud_thermal_fraction": snappedf(float(no_cloud) / n_th if n_th > 0 else 0.0, 0.0001),
		"start_alt_msl_m": snappedf(h0, 0.1),
		"end_alt_msl_m": snappedf(fm.position.y, 0.1),
		"thermal_list": _thermal_list(bot.thermals),
		# Средние за время кружения: подъём термика у пилота, вертикаль воздуха (с фоном и
		# болтанкой), вариометр — разность «воздух − вариометр» = снижение на вираже.
		"circling_air":
		{
			"thermal_lift_ms": snappedf(lift_sum / maxf(lift_n, 1), 0.001),
			"air_w_ms": snappedf(air_sum / maxf(lift_n, 1), 0.001),
			"vario_ms": snappedf(vario_sum / maxf(lift_n, 1), 0.001),
		},
	}
	_last_fly_cpu_s = (Time.get_ticks_usec() - t0) / 1.0e6
	return res


func _air_cached(p: Vector3, atmo: Atmosphere) -> Vector3:
	if p == _air_p:
		return _air_v
	_air_p = p
	_air_v = atmo.air_velocity_at(p)
	return _air_v


## Облако над точкой: плотность чуть выше кромки в центре и на 250 м вокруг.
static func _cloud_above(atmo: Atmosphere, p: Vector2) -> bool:
	var y := atmo.get_cloudbase_msl() + 60.0
	var offs: Array[Vector2] = [
		Vector2.ZERO, Vector2(250, 0), Vector2(-250, 0), Vector2(0, 250), Vector2(0, -250)
	]
	for o in offs:
		if atmo.cloud_density_at(Vector3(p.x + o.x, y, p.y + o.y)) > 0.0:
			return true
	return false


func _thermal_list(list: Array[Dictionary]) -> Array:
	var out: Array = []
	for th in list:
		var c: Vector2 = th.center
		(
			out
			. append(
				{
					"x_m": snappedf(c.x, 0.1),
					"z_m": snappedf(c.y, 0.1),
					"circles": th.circles,
					"gain_m": snappedf(float(th.gain_m), 0.1),
					"climb_ms": snappedf(float(th.climb_ms), 0.001),
					"top_m": snappedf(float(th.top_m), 0.1),
				}
			)
		)
	return out


## Лучшее качество по поляре в воздухе, опускающемся со скоростью sink (м/с): max v / (s(v) + sink).
static func _best_glide_in_sink(fm: FlightModel, sink: float) -> float:
	fm.rho = fm.air_density(0.0)
	var best := 0.0
	var v := 8.0
	while v < 30.0:
		best = maxf(best, v / (fm.steady_glide(v).y + sink))
		v += 0.1
	return best


func _polar_info(fm: FlightModel) -> Dictionary:
	var best := 0.0
	var best_v := 0.0
	var min_s := 1.0e9
	fm.rho = fm.air_density(0.0)
	var v := 8.0
	while v < 26.0:
		var g := fm.steady_glide(v)
		if v / g.y > best:
			best = v / g.y
			best_v = v
		min_s = minf(min_s, g.y)
		v += 0.1
	return {
		"best_glide": snappedf(best, 0.01),
		"best_glide_kmh": snappedf(best_v * 3.6, 0.1),
		"min_sink_ms": snappedf(min_s, 0.001)
	}


## Снижение на вираже бота в штиль на высоте alt, м/с (среднее за 60 с после входа в вираж).
func _turn_sink(wing: Dictionary, pilot_cfg: Dictionary, bot: XcPilot, alt: float) -> float:
	var m := FlightModel.new()
	m.setup(wing, pilot_cfg)
	m.reset_in_air(Vector3(0.0, alt, 0.0), 0.0)
	var inp := ControlInput.new()
	inp.pitch = bot.circle_pitch(alt)
	var prev := 0.0
	var sum := 0.0
	var n := 0
	for i in roundi(90.0 / DT):
		var b := m.telemetry.bank_deg
		var rate := (b - prev) / DT
		prev = b
		inp.roll = clampf((bot.circle_bank_deg - b - rate * 0.35) / 8.0, -1.0, 1.0)
		m.step(DT, inp, Callable(), Callable())
		if i * DT > 30.0:
			sum += -m.telemetry.vario
			n += 1
	return sum / maxf(n, 1)


## Найдены ли термики сетки: бот сделал хотя бы круг ближе found_r к оси.
func _synthetic_report(
	list: Array, bot: XcPilot, start: Vector2, cdir: Vector2, goal_m: float
) -> Dictionary:
	var side := Vector2(-cdir.y, cdir.x)
	var near_n := 0
	var near_found := 0
	var found_all := 0
	var items: Array = []
	for st: Dictionary in list:
		var c := Vector2(float(st.x_m), float(st.z_m))
		var lat := absf((c - start).dot(side))
		var found := false
		for ci: Dictionary in bot.circles:
			if c.distance_to(ci.center) < 150.0:
				found = true
				break
		var along := (c - start).dot(cdir)
		if along > goal_m:
			continue
		if found:
			found_all += 1
		items.append(
			{"along_m": snappedf(along, 0.1), "lateral_m": snappedf(lat, 0.1), "found": found}
		)
		if lat <= 150.0:
			near_n += 1
			if found:
				near_found += 1
	return {
		"thermals": items, "near_total": near_n, "near_found": near_found, "found_total": found_all
	}


static func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for x in a:
		s += float(x)
	return s / a.size()
