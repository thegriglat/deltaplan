extends Node
## WPC-3: пачка полётов против ветра и в динамике (docs/plan/wing-physics-check.md, контракт К6 —
## docs/wing-physics-check_contracts.md). Мир — как в игре: рельеф места (Terrain), Atmosphere с
## ветром «в старт» (set_wind(км/ч, курс старта, высота старта) — как game.gd), турбулентность
## включена (сид конфига, часы атмосферы с нуля на каждый полёт), термики выключены (static,
## пусто), FlightModel, масса пилота 85 кг (configs/pilot.json, в диапазоне крыла), плотность по
## высоте. Серии:
##   penetration — старт в воздухе над стартом на agl0 м лицом в ветер с воздушной скоростью
##     равновесия трапеции pitch, 60 с; курс держит регулятор крена (как BotPilot._steer_heading),
##     трапеция постоянна; касание земли — конец полёта (note);
##   ridge — бот-восьмёрка у гребня (BotPilot.setup_ridge, рабочая точка в полосе 50–100 м AGL,
##     как tests/atmosphere/test_ridge_starts.gd), 3 мин, трапеция — трим (pitch 0).
## Режимы: analytic (без поля) и field (поле воздуха GPU, как в игре: AirRuntime.load_field на час,
## температуру и небо меню по умолчанию — FlightSettings.defaults()). Поле считается отдельной
## фазой с окном (под flock) и сохраняется в файлы; полёты в режиме field — headless из файлов.
##
##   # аналитика (headless):
##   godot --headless --path . res://tools/flight/wind_penetration_run.tscn -- --mode=analytic
##   # поле: 1) расчёт (окно, GPU, под замком) 2) полёты по сохранённым полям (headless)
##   flock /tmp/heat_ca_gpu.lock godot --path . --resolution 320x240 --audio-driver Dummy \
##       res://tools/flight/wind_penetration_run.tscn -- --phase=fields
##   godot --headless --path . res://tools/flight/wind_penetration_run.tscn -- --mode=field \
##       --wings=slavutich_ut,training,laminar,combat
## Ключи: --csv=файл (по умолчанию tools/research/wing_physics_check/out/penetration.csv; готовые
## ключи пропускаются), --wings=a,b, --sites=loc/start,…, --winds=3,6, --pitches=0,-0.5,-1,
## --agls=30,100,200, --series=penetration,ridge, --fields-dir=build/wpc3/fields, --dt=0.008333.

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
var _fields_dir := "build/wpc3/fields"
var _out: FileAccess
var _done := {}
var _n_new := 0


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_dt = float(args.get("dt", str(_dt)))
	_mode = String(args.get("mode", "analytic"))
	_fields_dir = String(args.get("fields-dir", _fields_dir))
	var sites: Array = _list(args, "sites", ",".join(SITES))
	var winds: Array = _floats(args, "winds", "3,6")
	var t0 := Time.get_ticks_msec()
	if String(args.get("phase", "fly")) == "fields":
		await _compute_fields(sites, winds)
	else:
		var wings: Array = _list(args, "wings", "")
		if wings.is_empty():
			for p in Config.list_configs("wings"):
				wings.append(String(p).get_file())
		wings.sort()
		_open_csv(String(args.get("csv", "tools/research/wing_physics_check/out/penetration.csv")))
		var plan := {
			pitches = _floats(args, "pitches", "0,-0.5,-1"),
			agls = _floats(args, "agls", "30,100,200"),
			series = _list(args, "series", "penetration,ridge"),
		}
		for s: String in sites:
			_fly_site(s, winds, wings, plan)
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


## Атмосфера как в игре: погода medium без термиков, ветер «в старт» от высоты старта.
func _make_atmo(terrain: Terrain, site: Dictionary, wind_ms: float) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.thermal_mode = "static"
	w.static_thermals = []
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
	a.set_thermal_mode("static")
	a.turbulence_enabled = true
	a.set_wind(Units.to_kmh(wind_ms), float(site.heading_deg), Vector3(site.position).y)
	a.set_focus(site.position)
	a.step(_dt)
	return a


func _field_base(site_key: String, wind_ms: float, lvl: int) -> String:
	return "%s/%s_%sms_L%d" % [_fields_dir, site_key.replace("/", "_"), _num(wind_ms), lvl]


# ================================================================ поле (окно, GPU)


func _compute_fields(sites: Array, winds: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_fields_dir))
	var fs := FlightSettings.defaults()
	for sk: String in sites:
		var ts := _load_site(sk)
		if ts.is_empty():
			print("wind_penetration: нет старта ", sk)
			continue
		var terrain: Terrain = ts[0]
		var site: Dictionary = ts[1]
		for wind_ms: float in winds:
			if FileAccess.file_exists(_field_base(sk, wind_ms, 0) + ".json"):
				print("поле %s %s м/с — уже есть" % [sk, wind_ms])
				continue
			var atmo := _make_atmo(terrain, site, wind_ms)
			var c := {
				hour = fs.start_hour,
				u10 = wind_ms,
				wdir = float(site.heading_deg),
				t_max = fs.temperature_c,
				sky = fs.sky,
			}
			var rt := AirRuntime.new()
			add_child(rt)
			var utc := float(terrain.location.get("utc_offset_h", NAN))
			rt.setup(atmo, AirRuntime.place_of(terrain, utc), func() -> Dictionary: return c)
			var p0: Vector3 = site.position
			rt.focus_fn = func() -> Vector3: return p0
			var t0 := Time.get_ticks_msec()
			var ok: bool = await rt.load_field()
			var levels: Array[WindField] = atmo.air_field.levels if ok else []
			print(
				(
					"поле %s %s м/с: %s за %.1f с, уровней %d %s"
					% [
						sk,
						wind_ms,
						"готово" if ok else "НЕТ",
						(Time.get_ticks_msec() - t0) / 1000.0,
						levels.size(),
						rt.last_error
					]
				)
			)
			for i in levels.size():
				var base := _field_base(sk, wind_ms, i)
				_save_field(levels[i], base)
				var back := WindField.load_file(base)
				print(
					(
						"  L%d dx %.0f м: max|файл − поле| = %s м/с"
						% [i, levels[i].dx, str(_field_diff(levels[i], back, p0, terrain))]
					)
				)
			rt.stop()
			rt.queue_free()
			atmo.free()
		terrain.free()


## Записать поле в формате WindField.load_file (<base>.json + <base>.bin, float32 LE).
static func _save_field(f: WindField, base: String) -> void:
	var nxy := f.nx * f.ny
	var n := nxy * f.nz
	var vel := f.raw_vel()
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	for a in [u, v, wm]:
		a.resize(n)
	for c in n:
		u[c] = vel[c * 3]
		v[c] = vel[c * 3 + 1]
		wm[c] = vel[c * 3 + 2]
	var arrays := {
		"u": u,
		"v": v,
		"w_mech": wm,
		"w_conv": f.raw_w_conv(),
		"theta": f.raw_theta(),
		"hc": f.raw_hc()
	}
	var heat := f.heat_flux()
	if heat.size() == nxy:
		arrays["heat"] = heat
	var meta := {}
	for k in f.meta:
		if k in ["heat", "heat_array", "path", "arrays"]:
			continue
		meta[k] = _json_safe(f.meta[k])
	meta.dx = f.dx
	meta.dz = f.dz
	meta.x0 = f.x0
	meta.y0 = f.y0
	meta.z_bot = f.z_bot
	meta.nx = f.nx
	meta.ny = f.ny
	meta.nz = f.nz
	meta.z0 = f.z0
	meta.version = WindField.FORMAT_VERSION
	var all := PackedFloat32Array()
	var offs := {}
	for k in arrays:
		offs[k] = [all.size(), (arrays[k] as PackedFloat32Array).size()]
		all.append_array(arrays[k])
	meta.arrays = offs
	var fb := FileAccess.open(base + ".bin", FileAccess.WRITE)
	fb.store_buffer(all.to_byte_array())
	fb.close()
	var fj := FileAccess.open(base + ".json", FileAccess.WRITE)
	fj.store_string(JSON.stringify(meta))
	fj.close()


static func _json_safe(x: Variant) -> Variant:
	if x is float:
		return x if is_finite(x) else null
	if x is Dictionary:
		var d := {}
		for k in x:
			d[k] = _json_safe(x[k])
		return d
	if x is Array or x is PackedFloat32Array or x is PackedFloat64Array or x is PackedInt32Array:
		return Array(x).map(_json_safe)
	return x


static func _field_diff(a: WindField, b: WindField, p0: Vector3, t: Terrain) -> float:
	if b == null:
		return INF
	var e := 0.0
	for i in range(-6, 7):
		for j in range(-6, 7):
			var x := p0.x + i * 150.0
			var z := p0.z + j * 150.0
			var h := t.height_at(x, z)
			for agl in [5.0, 30.0, 100.0, 300.0]:
				var p := Vector3(x, h + agl, z)
				e = maxf(e, (a.sample(p, h) - b.sample(p, h)).length())
	return e


func _load_levels(site_key: String, wind_ms: float) -> Array[WindField]:
	var out: Array[WindField] = []
	var i := 0
	while FileAccess.file_exists(_field_base(site_key, wind_ms, i) + ".json"):
		var f := WindField.load_file(_field_base(site_key, wind_ms, i))
		if f == null:
			return []
		out.append(f)
		i += 1
	return out


# ================================================================ полёты


func _fly_site(sk: String, winds: Array, wings: Array, plan: Dictionary) -> void:
	var ts := _load_site(sk)
	if ts.is_empty():
		print("wind_penetration: нет старта ", sk)
		return
	var terrain: Terrain = ts[0]
	var site: Dictionary = ts[1]
	for wind_ms: float in winds:
		var atmo := _make_atmo(terrain, site, wind_ms)
		if _mode == "field":
			var levels := _load_levels(sk, wind_ms)
			if levels.is_empty():
				print("wind_penetration: нет поля %s %s м/с — пропуск" % [sk, wind_ms])
				atmo.free()
				continue
			atmo.set_air_field(levels, 0.0)
			if not atmo.is_air_field_on():
				print("wind_penetration: поле %s %s м/с не включилось — пропуск" % [sk, wind_ms])
				atmo.free()
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
						r.merge(_fly_pen(atmo, terrain, site, wing, pilot, pitch, agl0))
						_write(r)
			if "ridge" in plan.series:
				var r := base.duplicate()
				r.merge({series = "ridge", pitch = 0.0, agl0_m = scan.agl})
				if not _skip(r):
					r.merge(_fly_ridge(atmo, terrain, site, wing, pilot, scan))
					_write(r)
		atmo.free()
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
	atmo.time_s = 0.0
	atmo.set_focus(start)
	atmo.step(_dt)
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
	atmo.time_s = 0.0
	atmo.set_focus(start)
	atmo.step(_dt)
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
		atmo.set_focus(fm.position)
		atmo.step(_dt)
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
	}
