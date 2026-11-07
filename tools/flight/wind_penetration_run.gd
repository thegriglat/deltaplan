extends Node
## WPC-3: пачка полётов против ветра и в динамике (docs/archive/plan/wing-physics-check.md, контракт К6 —
## docs/contracts/wing-physics-check.md). Мир — как в игре: рельеф места (Terrain), Atmosphere с
## ветром «в старт» (set_conditions: ветер пресета — набегающий поток, как game.gd), турбулентность
## включена (сид конфига, часы атмосферы с нуля на каждый полёт), термики выключены (static,
## пусто), FlightModel, масса пилота 85 кг (configs/pilot.json, в диапазоне крыла), плотность по
## высоте. Серии:
##   penetration — старт в воздухе над стартом на agl0 м лицом в ветер с воздушной скоростью
##     равновесия трапеции pitch, 60 с; курс держит регулятор крена (как BotPilot._steer_heading),
##     трапеция постоянна; касание земли — конец полёта (note);
##   ridge — бот-восьмёрка у гребня (BotPilot.setup_ridge, рабочая точка в полосе 50–100 м AGL,
##     как tests/atmosphere/test_ridge_starts.gd), 3 мин, трапеция — трим (pitch 0).
## Режимы: analytic (поле выключено: set_air_mode("off")) и field (поле Пикара из крейта, как в игре:
## set_air_mode("on"); час, температура и небо меню по умолчанию — FlightSettings.defaults()).
##
##   # аналитика (headless):
##   godot --headless --path . res://tools/flight/wind_penetration_run.tscn -- --mode=analytic
##   # поле (из крейта, headless, поле в режиме on):
##   godot --headless --path . res://tools/flight/wind_penetration_run.tscn -- --mode=field \
##       --wings=slavutich_ut,training,laminar,combat
## Ключи: --csv=файл (по умолчанию tools/research/wing_physics_check/out/penetration.csv; готовые
## ключи пропускаются), --wings=a,b, --sites=loc/start,…, --winds=3,6, --pitches=0,-0.5,-1,
## --agls=30,100,200, --series=penetration,ridge, --dt=0.008333,
## --stats=файл (СКО путевой, воздушной, вертикальной скорости и w воздуха за окно — не К6).

const SITES := [
	"altai/sinyukha_west",
	"askarovo/biyagoda_west",
	"aushkul/aushtau_east",
	"ongudai/kayancha_south"
]
const PEN_S := 60.0
const RIDGE_S := 180.0
const WINDOW_S := 30.0
const SAMPLE_HZ := 10.0
const BANK_MAX_DEG := 15.0
const BAND_AGL: Array[float] = [50.0, 65.0, 75.0, 90.0, 100.0]
const SCAN_D_RANGE_M := 350.0
const SCAN_D_STEP_M := 10.0
const RIDGE_LEG_M := 150.0
const HEADER := (
	"key,series,location,start,mode,wing,pilot_mass_kg,wind_set_ms,pitch,agl0_m,duration_s,"
	+ "gs_into_wind_ms,airspeed_ms,vz_ms,wind_h_ms,wind_w_ms,agl_end_m,climb_m,note"
)

var _dt := 1.0 / 120.0
var _mode := "analytic"
var _out: FileAccess
var _done := {}
var _n_new := 0
var _stats: FileAccess


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_dt = float(args.get("dt", str(_dt)))
	_mode = String(args.get("mode", "analytic"))
	var sites: Array = _list(args, "sites", ",".join(SITES))
	var winds: Array = _floats(args, "winds", "3,6")
	var t0 := Time.get_ticks_msec()
	if String(args.get("phase", "fly")) == "fields":
		print("wind_penetration: фаза fields не нужна — поле считает крейт (--mode=field, окно не обязательно)")
	else:
		var wings: Array = _list(args, "wings", "")
		if wings.is_empty():
			for p in Config.list_configs("wings"):
				wings.append(String(p).get_file())
		wings.sort()
		_open_csv(String(args.get("csv", "tools/research/wing_physics_check/out/penetration.csv")))
		if args.has("stats"):
			_stats = FileAccess.open(String(args.stats), FileAccess.WRITE)
			_stats.store_line("key,n_s,gs_sd_ms,airspeed_sd_ms,vz_sd_ms,wind_w_sd_ms")
		var plan := {
			pitches = _floats(args, "pitches", "0,-0.5,-1"),
			agls = _floats(args, "agls", "30,100,200"),
			series = _list(args, "series", "penetration,ridge"),
		}
		for s: String in sites:
			await _fly_site(s, winds, wings, plan)
		_out.close()
	print(
		(
			"wind_penetration: готово за %.0f с, новых строк %d"
			% [(Time.get_ticks_msec() - t0) / 1000.0, _n_new]
		)
	)
	get_tree().quit()


static func _list(args: Dictionary, k: String, def: String) -> Array:
	var s := String(args.get(k, def))
	return [] if s.is_empty() else Array(s.split(","))


static func _floats(args: Dictionary, k: String, def: String) -> Array:
	return _list(args, k, def).map(func(x: String) -> float: return x.to_float())


func _open_csv(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		var head := f.get_line().strip_edges()
		if head != HEADER:
			push_error("wind_penetration: заголовок %s не К6 — не дописываю" % path)
			get_tree().quit(1)
		while not f.eof_reached():
			var line := f.get_line()
			if not line.is_empty():
				_done[line.get_slice(",", 0)] = true
		f.close()
		_out = FileAccess.open(path, FileAccess.READ_WRITE)
		_out.seek_end()
	else:
		_out = FileAccess.open(path, FileAccess.WRITE)
		_out.store_line(HEADER)


# ================================================================ мир


static func _load_site(site_key: String) -> Array:
	var loc := site_key.get_slice("/", 0)
	var id := site_key.get_slice("/", 1)
	var t := Terrain.new()
	t.location_id = ""
	if not t.load_location(loc):
		t.free()
		return []
	for s: Dictionary in t.get_start_sites():
		if String(s.id) == id:
			return [t, s]
	t.free()
	return []


## Атмосфера как в игре (W2 v4): погода medium без случайных термиков, ветер «в старт» (набегающий
## поток), режим поля по --mode (field → "on", analytic → "off"), готовность ждём.
func _make_atmo(terrain: Terrain, site: Dictionary, wind_ms: float) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(wind_ms)
	w.wind_from_deg = float(site.heading_deg)
	var fs := FlightSettings.defaults()
	var a := Atmosphere.new()
	a.visuals_enabled = false
	add_child(a)
	a.configure(-1)
	var utc := float(terrain.location.get("utc_offset_h", 0.0))
	var place: AirPlaceData = await a.place_from_terrain(terrain, utc, fs.month, fs.day)
	if place == null:
		push_error("wind_penetration: у рельефа нет слоя detail")
		return a
	a.set_air_mode("on" if _mode == "field" else "off")
	a.set_static_thermals(PackedFloat32Array(), 1)
	a.set_conditions({"preset": w, "start_hour": fs.start_hour})
	a.load_place(place)
	a.set_focuses(PackedVector3Array([site.position]), PackedFloat32Array([1.0]))
	await _restart(a)
	return a


## Часы атмосферы с нуля на каждый полёт (start_at(0)), ждём READY.
func _restart(a: Atmosphere) -> void:
	a.start_at(0.0)
	while not a.is_ready() and a.status().state != Atmosphere.STATE_FAILED:
		a.pump(8000)
		await get_tree().process_frame


# ================================================================ полёты


func _fly_site(sk: String, winds: Array, wings: Array, plan: Dictionary) -> void:
	var ts := _load_site(sk)
	if ts.is_empty():
		print("wind_penetration: нет старта ", sk)
		return
	var terrain: Terrain = ts[0]
	var site: Dictionary = ts[1]
	for wind_ms: float in winds:
		var atmo := await _make_atmo(terrain, site, wind_ms)
		if _mode == "field":
			if not atmo.is_air_field_on():
				print("wind_penetration: поле %s %s м/с не включилось — пропуск" % [sk, wind_ms])
				atmo.queue_free()
				continue
		var scan := {}
		if "ridge" in plan.series:
			scan = _scan_ridge(atmo, terrain, site)
		for wid: String in wings:
			var wing: Dictionary = Config.get_config("wings/" + wid)
			var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
			pilot.mass_kg = FlightModel.clamp_pilot_mass(wing, float(pilot.mass_kg))
			var base := {
				location = sk.get_slice("/", 0),
				start = sk.get_slice("/", 1),
				mode = _mode,
				wing = wid,
				pilot_mass_kg = pilot.mass_kg,
				wind_set_ms = wind_ms,
			}
			if "penetration" in plan.series:
				for pitch: float in plan.pitches:
					for agl0: float in plan.agls:
						var r := base.duplicate()
						r.merge({series = "penetration", pitch = pitch, agl0_m = agl0})
						if _skip(r):
							continue
						r.merge(await _fly_pen(atmo, terrain, site, wing, pilot, pitch, agl0))
						_write(r)
			if "ridge" in plan.series:
				var r := base.duplicate()
				r.merge({series = "ridge", pitch = 0.0, agl0_m = scan.agl})
				if not _skip(r):
					r.merge(await _fly_ridge(atmo, terrain, site, wing, pilot, scan))
					_write(r)
		atmo.queue_free()
	terrain.free()


static func _key(r: Dictionary) -> String:
	return "|".join(
		[
			r.series,
			"%s/%s" % [r.location, r.start],
			r.mode,
			r.wing,
			_num(r.wind_set_ms),
			_num(r.pitch),
			_num(r.agl0_m)
		]
	)


static func _num(x: float) -> String:
	return str(snappedf(x, 0.01))


func _skip(r: Dictionary) -> bool:
	r.key = _key(r)
	return _done.has(r.key)


func _write(r: Dictionary) -> void:
	var vals: Array[String] = []
	for k in HEADER.split(","):
		var v: Variant = r.get(k, "")
		if v is float:
			vals.append("%.3f" % v if is_finite(v) else "")
		elif k == "note":
			vals.append('"%s"' % String(v).replace('"', "'"))
		else:
			vals.append(str(v))
	var line := ",".join(vals)
	_out.store_line(line)
	_out.flush()
	_done[r.key] = true
	_n_new += 1
	if _stats != null and r.has("sd"):
		var sd: PackedFloat32Array = r.sd
		_stats.store_line(
			(
				"%s,%.1f,%.3f,%.3f,%.3f,%.3f"
				% [r.key, minf(r.duration_s, WINDOW_S), sd[0], sd[1], sd[2], sd[3]]
			)
		)
		_stats.flush()
	print(line)


## Воздушная скорость равновесия трапеции pitch при эталонной массе и плотности (К1), м/с.
static func _v_ref(wing: Dictionary, pitch: float) -> float:
	var trim := float(wing.trim_speed_kmh)
	var to := float(wing.full_pull_speed_kmh) if pitch < 0.0 else float(wing.full_push_speed_kmh)
	return Units.kmh(lerpf(trim, to, absf(pitch)))


func _fly_pen(
	atmo: Atmosphere,
	terrain: Terrain,
	site: Dictionary,
	wing: Dictionary,
	pilot: Dictionary,
	pitch: float,
	agl0: float
) -> Dictionary:
	var heading := float(site.heading_deg)
	var p0: Vector3 = site.position
	var start := Vector3(p0.x, terrain.height_at(p0.x, p0.z) + agl0, p0.z)
	var fm := FlightModel.new()
	fm.setup(wing, pilot)
	await _restart(atmo)
	atmo.set_focuses(PackedVector3Array([start]), PackedFloat32Array([1.0]))
	atmo.advance_to(_dt)
	fm.reset_in_air(start, heading, 0.0, atmo.mean_wind_at(start))  # плотность на высоте
	var v0 := _v_ref(wing, pitch) * fm.speed_scale()
	fm.reset_in_air(start, heading, v0, atmo.mean_wind_at(start))
	var inp := ControlInput.new()
	inp.pitch = pitch
	var steer := func(t: Telemetry) -> void:
		var err := wrapf(heading - t.heading_deg, -180.0, 180.0)
		var want := clampf(err * 0.9, -BANK_MAX_DEG, BANK_MAX_DEG)
		var e := want - (t.bank_deg + rad_to_deg(fm.roll_rate) * 0.35)
		inp.roll = clampf(e / 8.0, -1.0, 1.0)
	return _fly(atmo, terrain, fm, inp, steer, PEN_S, heading)


## Рабочая точка у гребня (как test_ridge_starts._scan_best_lift / _scan_along_width): одна на
## (старт, ветер, режим) — от крыла не зависит.
func _scan_ridge(atmo: Atmosphere, terrain: Terrain, site: Dictionary) -> Dictionary:
	var heading := float(site.heading_deg)
	var p0: Vector3 = site.position
	var away := Vector2(sin(deg_to_rad(heading)), -cos(deg_to_rad(heading)))
	var best_w := -1.0e9
	var best := Vector2(p0.x, p0.z)
	var best_agl: float = BAND_AGL[0]
	var d := -SCAN_D_RANGE_M
	while d <= SCAN_D_RANGE_M:
		var p2: Vector2 = Vector2(p0.x, p0.z) + away * d
		var gh := terrain.height_at(p2.x, p2.y)
		for agl: float in BAND_AGL:
			var w := atmo.mean_wind_at(Vector3(p2.x, gh + agl, p2.y)).y
			if not atmo.is_air_field_on():
				w = atmo.air_velocity_at(Vector3(p2.x, gh + agl, p2.y)).y
			if w > best_w:
				best_w = w
				best = p2
				best_agl = agl
		d += SCAN_D_STEP_M
	var along := Vector2(cos(deg_to_rad(heading)), sin(deg_to_rad(heading)))
	var width := 0.0
	for sgn in [1.0, -1.0]:
		var s := SCAN_D_STEP_M
		while s <= 300.0:
			var p2: Vector2 = best + along * (s * sgn)
			var gh := terrain.height_at(p2.x, p2.y)
			var pw := Vector3(p2.x, gh + best_agl, p2.y)
			var w := (
				atmo.mean_wind_at(pw).y if atmo.is_air_field_on() else atmo.air_velocity_at(pw).y
			)
			if w < best_w * 0.5:
				break
			width += SCAN_D_STEP_M
			s += SCAN_D_STEP_M
	var leg := minf(RIDGE_LEG_M, clampf(width * 0.8, 60.0, 250.0))
	return {pos2 = best, agl = best_agl, w = best_w, leg = leg}


func _fly_ridge(
	atmo: Atmosphere,
	terrain: Terrain,
	site: Dictionary,
	wing: Dictionary,
	pilot: Dictionary,
	scan: Dictionary
) -> Dictionary:
	var heading := float(site.heading_deg)
	var p2: Vector2 = scan.pos2
	var start := Vector3(p2.x, terrain.height_at(p2.x, p2.y) + float(scan.agl), p2.y)
	var fm := FlightModel.new()
	fm.setup(wing, pilot)
	await _restart(atmo)
	atmo.set_focuses(PackedVector3Array([start]), PackedFloat32Array([1.0]))
	atmo.advance_to(_dt)
	fm.reset_in_air(start, heading, 0.0, atmo.mean_wind_at(start))
	var bot := BotPilot.new()
	bot.setup(wing, pilot, p2)
	bot.route_start = p2
	bot.ground_fn = terrain.height_at
	bot.cloudbase_msl = atmo.get_cloudbase_msl()
	bot.setup_ridge(
		p2,
		fposmod(heading + 90.0, 360.0),
		heading,
		float(scan.leg),
		BAND_AGL[0],
		BAND_AGL[BAND_AGL.size() - 1]
	)
	var inp := ControlInput.new()
	var n := [0]
	var steer := func(t: Telemetry) -> void:
		if n[0] % 2 == 0:
			var c := bot.drive(t, _dt * 2.0)
			inp.roll = c.roll
		inp.pitch = 0.0  # трим (бот сам держал бы min sink × 1,05)
		n[0] += 1
	var r := _fly(atmo, terrain, fm, inp, steer, RIDGE_S, heading)
	r.note = ("w_scan %.2f м/с, виток %.0f м; %s" % [scan.w, scan.leg, r.note]).trim_suffix("; ")
	return r


## Общий цикл полёта: атмосфера → управление → модель; средние — за последние WINDOW_S с.
func _fly(
	atmo: Atmosphere,
	terrain: Terrain,
	fm: FlightModel,
	inp: ControlInput,
	steer: Callable,
	dur: float,
	heading: float
) -> Dictionary:
	var air_fn := Callable(atmo, "air_velocity_at")
	var hdir := Vector3(sin(deg_to_rad(heading)), 0.0, -cos(deg_to_rad(heading)))
	var y0 := fm.position.y
	var every := maxi(1, roundi(1.0 / (SAMPLE_HZ * _dt)))
	var samples: Array[PackedFloat32Array] = []
	var t := 0.0
	var i := 0
	var note := ""
	while t < dur:
		atmo.set_focuses(PackedVector3Array([fm.position]), PackedFloat32Array([1.0]))
		atmo.advance_to(t + _dt)
		steer.call(fm.telemetry)
		fm.step(_dt, inp, air_fn, terrain.height_at)
		t += _dt
		i += 1
		if fm.mode != FlightModel.Mode.AIR:
			note = "земля на %.1f с (%s)" % [t, fm.landing_result.get("grade", fm.phase())]
			break
		if i % every == 0:
			var w := atmo.air_velocity_at(fm.position)
			var tl := fm.telemetry
			samples.append(
				PackedFloat32Array(
					[t, fm.velocity.dot(hdir), tl.airspeed, fm.velocity.y, w.x, w.z, w.y]
				)
			)
	var acc := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var m := 0
	for s in samples:
		if s[0] >= t - WINDOW_S:
			for k in 6:
				acc[k] += s[k + 1]
			m += 1
	for k in 6:
		acc[k] /= maxf(m, 1)
	# разброс за окно (болтанка): СКО путевой, воздушной, вертикальной скорости и w воздуха
	var sd := PackedFloat32Array([0, 0, 0, 0])
	for s in samples:
		if s[0] >= t - WINDOW_S:
			for j in 4:
				var k: int = [0, 1, 2, 5][j]
				sd[j] += (s[k + 1] - acc[k]) ** 2
	for j in 4:
		sd[j] = sqrt(sd[j] / maxf(m - 1, 1))
	if t < WINDOW_S:
		note += "; окно %.0f с" % t
	return {
		duration_s = t,
		gs_into_wind_ms = acc[0] if m > 0 else NAN,
		airspeed_ms = acc[1] if m > 0 else NAN,
		vz_ms = acc[2] if m > 0 else NAN,
		wind_h_ms = Vector2(acc[3], acc[4]).length() if m > 0 else NAN,
		wind_w_ms = acc[5] if m > 0 else NAN,
		agl_end_m = fm.telemetry.altitude_agl,
		climb_m = fm.position.y - y0,
		note = note.trim_prefix("; "),
		sd = sd,
	}
