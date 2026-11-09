extends Node
## Полётный замер термиков в игре (TB-14, контракт TB5 v1): автопилот-бот (BotPilot, как в xc_run)
## летит по воздуху игры (фасад Atmosphere, крейт dp-air), пока считаются сводки присутствия, притока,
## ядра и разрывов у пилота. Время кадра — отдельным прогоном flight_frame.gd (нужен дисплей).
##
##   godot --headless --path . res://tools/research/thermal_bubble/flight/flight_probe.tscn -- \
##     --bubble=0|1 --out=<json> [--location=ongudai] [--seed=1] [--sim-s=1200] [--wing=sport]
##
## --bubble=1 пишет в конфиг атмосферы thermal.bubble_template = true (флаг шаблона пузыря, TB4 v2).
## Погода — прогноз по умолчанию меню (FlightSettings.defaults(), ветер 3 м/с с запада), как у
## flight_frame.gd; час старта 13. Сид мира — --seed=N, как у игры.
## Сырой json (не TB5): flight_summary.py склеивает его с кадрами в сводку tb5/1.

const DT := 1.0 / 60.0
## Радиус «рядом с пилотом» для присутствия, м (TB5).
const NEAR_R := 2000.0
## Ядро считается подъёмным, если w на оси на 0,5 z_l больше, м/с (TB5).
const LIFT_W := 0.5
## Слабее — ядро не считаем в притоке и подъёме (деление на силу, угасший термик).
const MIN_STRENGTH := 0.5
## Опрос ядер для притока и подъёма раз в столько секунд (присутствие — раз в секунду).
const OBS_EVERY_S := 10
const RING_AZ := 8
const RING_R := [1.0, 1.5, 2.0]
const AGL_INFLOW := 10.0
const Z_FRACS := [0.2, 0.35, 0.5, 0.65, 0.8]

var _inflow_by_core := {}
var _core_by_core := {}
var _dx_by_core := {}
var _dump := false
var _dumped := 0
var _peak_by_core := {}  # диагностика: max w на оси по всей толщине столба / сила
var _near_sum := 0.0
var _near_n := 0
var _lift_cores := 0
var _all_cores := 0
var _thermal_idx := -1
var _terrain: Terrain
var _atmo: Atmosphere


func _ready() -> void:
	var opts := _parse(OS.get_cmdline_user_args())
	var res := simulate(opts)
	if res.has("error"):
		push_error("flight_probe: %s" % JSON.stringify(res))
		get_tree().quit(1)
		return
	var out := String(opts.get("out", ""))
	var text := JSON.stringify(res, "  ", false)
	if out == "":
		print(text)
	else:
		var tmp := out + ".tmp"
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			push_error("flight_probe: не открыть %s" % tmp)
			get_tree().quit(1)
			return
		f.store_string(text + "\n")
		f.close()
		DirAccess.rename_absolute(tmp, out)
	print("flight_probe: OK bubble=%s sim %.0f с" % [res.bubble, res.sim_s])
	get_tree().quit(0)


static func _parse(args: PackedStringArray) -> Dictionary:
	var o := {}
	for a in args:
		if a.begins_with("--") and "=" in a:
			var kv := a.substr(2).split("=", true, 1)
			o[kv[0]] = kv[1]
	return o


func simulate(opts: Dictionary) -> Dictionary:
	var bubble := int(opts.get("bubble", 0)) != 0
	_dump = int(opts.get("dump", 0)) != 0
	var seed_i := int(opts.get("seed", 1))
	var sim_s := float(opts.get("sim-s", 1200))
	var location := String(opts.get("location", "ongudai"))
	var wing_name := String(opts.get("wing", "sport"))
	var atmo_cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	atmo_cfg.seed = seed_i  # как --seed=N игры (Game.world_seed)
	atmo_cfg.thermal.generation_radius_m = 7000.0
	atmo_cfg.thermal.physics_radius_m = 3000.0
	atmo_cfg.thermal["bubble_template"] = bubble

	_terrain = Terrain.new()
	_terrain.location_id = ""
	if not _terrain.load_location(location):
		_terrain.free()
		return {"error": "location"}
	var height_fn: Callable = _terrain.height_at
	var site: Dictionary = _terrain.get_start_sites()[0]
	var sp: Vector3 = site.position
	var start := Vector3(sp.x, 0.0, sp.z)

	var fs := FlightSettings.defaults()
	_atmo = Atmosphere.new()
	_atmo.visuals_enabled = false
	_atmo.deterministic = int(opts.get("det", 0)) != 0  # как в игре: фоновые задачи крейта не ждём (--det=1 — как xc_run)
	_atmo.air_cache_enabled = true  # поле места считается минуты; кеш на диске (user://air_cache) общий для прогонов
	_atmo.cfg_override = atmo_cfg
	_atmo.configure(atmo_cfg)
	_atmo.configure(int(atmo_cfg.seed))
	var cond := {
		"forecast": fs.forecast(),
		"start_hour": 13.0,
		"speed": 1.0,
		"quantum_h": Weather.quantum_h(),
	}
	_atmo.set_conditions(cond)
	_atmo.set_static_thermals(PackedFloat32Array(), 0)
	var loc_cfg: Dictionary = Config.get_config("locations/" + location)
	_atmo.load_place(
		AirPlaceData.from_terrain(_terrain, float(loc_cfg.get("utc_offset_h", 6.0)), 7, 15)
	)
	var course := fposmod(fs.wind_from_deg + 180.0, 360.0)
	var start_agl := 300.0
	start.y = float(height_fn.call(start.x, start.z)) + start_agl
	var wing: Dictionary = Config.get_config("wings/" + wing_name)
	var pilot_cfg: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot_cfg.mass_kg = float(wing.pilot_mass_ref_kg)
	var fm := FlightModel.new()
	fm.setup(wing, pilot_cfg)
	_atmo.set_focuses(PackedVector3Array([start]), PackedFloat32Array([1.0]))
	var why := _wait_ready(_atmo)
	if why != "":
		_atmo.free()
		_terrain.free()
		return {"error": "air", "reason": why}
	_atmo.advance_to(_atmo.time_s + DT)
	fm.reset_in_air(start, course, 0.0, _atmo.mean_wind_at(start))
	var names := _atmo.decompose(start).names as PackedStringArray
	_thermal_idx = names.find("thermal")
	var idx := {}
	for n in ["thermal", "storm", "wave", "cloud"]:
		idx[n] = names.find(n)
	_horiz_idx = []
	for n in idx:
		if int(idx[n]) >= 0:
			_horiz_idx.append(int(idx[n]))

	var cdir := Vector2(sin(deg_to_rad(course)), -cos(deg_to_rad(course)))
	var goal := Vector2(start.x, start.z) + cdir * 60000.0
	var bot := BotPilot.new()
	bot.setup(wing, pilot_cfg, goal)
	bot.route_start = Vector2(start.x, start.z)
	bot.ground_fn = height_fn
	bot.cloudbase_msl = _atmo.cloudbase_msl()
	bot.use_clouds = false

	var steps := roundi(sim_s / DT)
	var diffs := PackedFloat32Array()
	diffs.resize(steps)
	var n_diff := 0
	var inp := ControlInput.new()
	var v_prev := Vector3.ZERO
	var have_prev := false
	var relaunch := 0
	for i in steps:
		var p := fm.position
		if i % 60 == 0:
			_atmo.set_focuses(PackedVector3Array([p]), PackedFloat32Array([1.0]))
			_observe(p, i / 60)
			if (i / 60) % 100 == 0:
				print("flight_probe: %d с, wall %.0f с, высота %.0f, ядер рядом %.1f" % [i / 60, Time.get_ticks_msec() / 1000.0, p.y, _near_sum / maxf(_near_n, 1)])
		_atmo.advance_to(_atmo.time_s + DT)
		var v := _atmo.air_velocity_at(p)
		if have_prev:
			diffs[n_diff] = (v - v_prev).length()
			n_diff += 1
		v_prev = v
		have_prev = true
		if i % 2 == 0:
			inp = bot.drive(fm.telemetry, DT * 2.0)
		fm.step(DT, inp, _air_fn, height_fn)
		if fm.mode != FlightModel.Mode.AIR:
			# приземлились — снова в воздух над тем же местом, как «ещё раз» (Q8: замер не прерывать)
			relaunch += 1
			var q := fm.position
			var np := Vector3(q.x, float(height_fn.call(q.x, q.z)) + start_agl, q.z)
			fm.reset_in_air(np, course, 0.0, _atmo.mean_wind_at(np))
			have_prev = false
	diffs.resize(n_diff)
	diffs.sort()
	var res := _summary(diffs, bubble, location, seed_i, sim_s, steps, relaunch)
	_atmo.free()
	_terrain.free()
	return res


var _horiz_idx: Array = []
var _air_p := Vector3(INF, INF, INF)
var _air_v := Vector3.ZERO


func _air_fn(p: Vector3) -> Vector3:
	if p == _air_p:
		return _air_v
	_air_p = p
	_air_v = _atmo.air_velocity_at(p)
	return _air_v


## Слагаемое термика (и сопутствующие горизонтальные: шторм, волна, облако) в точке, м/с;
## фон (поле, аналитика, рельеф) и пульсации не входят.
func _thermal_vel(p: Vector3) -> Vector3:
	var d := _atmo.decompose(p)
	return (d.vel as PackedVector3Array)[_thermal_idx]


func _horiz_sum(p: Vector3) -> Vector2:
	var d := _atmo.decompose(p)
	var vel := d.vel as PackedVector3Array
	var h := Vector2.ZERO
	for i: int in _horiz_idx:
		h += Vector2(vel[i].x, vel[i].z)
	return h


func _axis(c: PackedFloat32Array, j: int, y: float) -> Vector2:
	var dy := y - c[j + Atmosphere.CORE_Y_SRC]
	return Vector2(
		c[j + Atmosphere.CORE_X] + c[j + Atmosphere.CORE_LEAN_X] * dy,
		c[j + Atmosphere.CORE_Z] + c[j + Atmosphere.CORE_LEAN_Z] * dy
	)


## Раз в секунду: присутствие; раз в OBS_EVERY_S — приток и подъём в ядре.
func _observe(p: Vector3, sec: int) -> void:
	var c := _atmo.cores(p, NEAR_R)
	var n := c.size() / Atmosphere.CORE_STRIDE
	_near_sum += n
	_near_n += 1
	for j in range(0, c.size() - Atmosphere.CORE_STRIDE + 1, Atmosphere.CORE_STRIDE):
		var ysrc := c[j + Atmosphere.CORE_Y_SRC]
		var zl := c[j + Atmosphere.CORE_TOP] - ysrc
		if zl <= 1.0:
			continue
		var y := ysrc + 0.5 * zl
		var a := _axis(c, j, y)
		var w := _thermal_vel(Vector3(a.x, y, a.y)).y
		_all_cores += 1
		if w > LIFT_W:
			_lift_cores += 1
		var strength := c[j + Atmosphere.CORE_W]
		if sec % OBS_EVERY_S != 0 or strength < MIN_STRENGTH:
			continue
		var id := int(c[j + Atmosphere.CORE_ID])
		# подъём в ядре: max w на оси на 0,2…0,8 z_l, к силе термика
		var wmax := -INF
		for zf: float in Z_FRACS:
			var yy := ysrc + zf * zl
			var aa := _axis(c, j, yy)
			wmax = maxf(wmax, _thermal_vel(Vector3(aa.x, yy, aa.y)).y)
		_push(_core_by_core, id, wmax / strength)
		if _dump and _dumped < 12:
			_dumped += 1
			var line := "DUMP id=%d t=%d R=%.0f zl=%.0f strength=%.2f age=%.0f life=%.0f wmax=%.2f |" % [id, sec, c[j + Atmosphere.CORE_RADIUS], zl, strength, c[j + Atmosphere.CORE_AGE], c[j + Atmosphere.CORE_LIFE], wmax]
			for zf: float in [0.05, 0.1, 0.3, 0.5, 0.7, 0.9]:
				var yz := ysrc + zf * zl
				var az := _axis(c, j, yz)
				line += " w(%.2f)=%.2f" % [zf, _thermal_vel(Vector3(az.x, yz, az.y)).y]
			var a10 := _axis(c, j, ysrc + 10.0)
			for rf: float in [0.5, 1.0, 1.5, 2.0]:
				var qq := a10 + Vector2(rf * c[j + Atmosphere.CORE_RADIUS], 0.0)
				var hh := _horiz_sum(Vector3(qq.x, float(_terrain.height_at(qq.x, qq.y)) + 10.0, qq.y))
				line += " uh(%.1fR)=%.3f" % [rf, hh.x]
			var best := -INF
			var bz := 0.0
			var bdx := 0.0
			for k in 31:
				var yy2 := ysrc + k * 0.1 * zl
				var a2 := _axis(c, j, yy2)
				for dxf: float in [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5]:
					var ww := _thermal_vel(Vector3(a2.x + dxf * c[j + Atmosphere.CORE_RADIUS], yy2, a2.y)).y
					if ww > best:
						best = ww
						bz = k * 0.1
						bdx = dxf
			line += " | max w=%.2f at z/zl=%.1f dx/R=%.1f" % [best, bz, bdx]
			print(line)
		# диагностика: ядро поблизости, а не строго на оси — max w в столбе 0…1,5 z_l и в ±2 R вдоль x
		var wpk := -INF
		var dxbest := 0.0
		for k in 16:
			var yp := ysrc + k * 0.1 * zl
			var ap := _axis(c, j, yp)
			for dxf: float in [-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0]:
				var wq := _thermal_vel(Vector3(ap.x + dxf * c[j + Atmosphere.CORE_RADIUS], yp, ap.y)).y
				if wq > wpk:
					wpk = wq
					dxbest = dxf
		_push(_peak_by_core, id, wpk / strength)
		_push(_dx_by_core, id, dxbest)
		# приток на 10 м над землёй: кольца r = 1…2 радиуса ядра, + к оси
		var r0 := c[j + Atmosphere.CORE_RADIUS]
		var ax := _axis(c, j, ysrc + AGL_INFLOW)
		var sum := 0.0
		var cnt := 0
		for rk: float in RING_R:
			for k in RING_AZ:
				var phi := TAU * k / RING_AZ
				var dirv := Vector2(cos(phi), sin(phi))
				var q := ax + dirv * rk * r0
				var gy := float(_terrain.height_at(q.x, q.y)) + AGL_INFLOW
				var h := _horiz_sum(Vector3(q.x, gy, q.y))
				sum += -h.dot(dirv)
				cnt += 1
		_push(_inflow_by_core, id, sum / cnt)


static func _push(d: Dictionary, id: int, v: float) -> void:
	if not d.has(id):
		d[id] = [0.0, 0]
	d[id][0] += v
	d[id][1] += 1


static func _median_of(d: Dictionary) -> float:
	var a: Array = []
	for id in d:
		a.append(float(d[id][0]) / int(d[id][1]))
	if a.is_empty():
		return 0.0
	a.sort()
	var m := a.size() / 2
	return float(a[m]) if a.size() % 2 == 1 else 0.5 * (float(a[m - 1]) + float(a[m]))


static func _pct(sorted: PackedFloat32Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(int(ceil(q * sorted.size())) - 1, 0, sorted.size() - 1)]


func _summary(
	diffs: PackedFloat32Array, bubble: bool, location: String, seed_i: int, sim_s: float, steps: int, relaunch: int
) -> Dictionary:
	return {
		"bubble": bubble,
		"location": location,
		"weather": "menu default forecast (26 C, 3 m/s from 270, clear), start hour 13, seed %d" % seed_i,
		"sim_s": sim_s,
		"frames": steps,
		"presence":
		{
			"cores_near_mean": snappedf(_near_sum / maxf(_near_n, 1), 0.0001),
			"cores_lifting_frac": snappedf(float(_lift_cores) / maxf(_all_cores, 1), 0.0001),
			"n_observed": _all_cores,
		},
		"inflow": {"ur_in_10m_median_ms": snappedf(_median_of(_inflow_by_core), 0.0001), "n": _inflow_by_core.size()},
		"core":
		{"w_axis_over_strength_median": snappedf(_median_of(_core_by_core), 0.0001), "n": _core_by_core.size()},
		"continuity":
		{
			"dv_frame_p999_ms": snappedf(_pct(diffs, 0.999), 0.0001),
			"dv_frame_max_ms": snappedf(diffs[diffs.size() - 1] if not diffs.is_empty() else 0.0, 0.0001),
			"dt_s": DT,
		},
		"relaunches": relaunch,
		"diag":
		{
			"w_peak_near_over_strength_median": snappedf(_median_of(_peak_by_core), 0.0001),
			"peak_dx_over_R_median": snappedf(_median_of(_dx_by_core), 0.01),
		},
	}


static func _wait_ready(atmo: Atmosphere) -> String:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3600000:
		atmo.pump(4000)
		var st := atmo.status()
		var state := int(st.state)
		if state == Atmosphere.STATE_READY:
			return ""
		if state == Atmosphere.STATE_FAILED or state == Atmosphere.STATE_EMPTY:
			var why := String(st.reason)
			return "state=%d %s" % [state, why if why != "" else atmo.last_error()]
		OS.delay_usec(1000)
	return "таймаут подготовки воздуха"
