extends Node
## CLF-1: день поля облачности над местом — слепки для карт (docs/research/cloud_field.md).
## Ход: Terrain.load_location / load_point → для каждого часа (9…17) поле воздуха как в игре
## (AirRuntime.load_field: фазы + Пикар на GPU; копия _solve из tools/research/thermal_drainage/dump.gd)
## → AirThermals (c_top, Φ, источники) → CloudField.set_inputs; поле облачности интегрируется
## от 9:00 до 17:00, поле воздуха часа H действует с H − 0,5 до H + 0,5 ч. Кадры — out/<место>_<погода>_h<час>.json
## (сетка, рельеф, cover/depth/stage/activity, источники, LCL, ветер основания), ход покрытия —
## в кадре h17 (series). Погоды: weak (+20 °C, 6 км/ч), strong (+31 °C, 18 км/ч), windy (+31 °C,
## 8 м/с с типичного для места направления).
## Запуск (GPU, окно): tools/research/cloud_field/run.sh [--places=… --weathers=… --out=…]
## CLF-9: --zi_alpha=<α> подменяет air_model.zi_terrain_alpha (0 — плоский z_i, «до»); в кадре —
## z_i_col по столбцам и zi_alpha; места ongudai, askarovo, training_island, almaty.

const ALMATY := Vector2(43.2, 76.9)
## Ветер ветреного дня: откуда, °: Онгудай и остров — запад/северо-запад; Алматы — запад, вдоль
## главного хребта Заилийского Алатау (синоптический перенос на уровне хребта).
const WDIR_WINDY := {"ongudai": 300.0, "training_island": 270.0, "almaty": 270.0, "askarovo": 270.0}
const WEATHERS := {
	"weak": {"temperature_c": 20.0, "wind_speed_kmh": 6.0, "wind_from_deg": 270.0},
	"strong": {"temperature_c": 31.0, "wind_speed_kmh": 18.0, "wind_from_deg": 270.0},
	"windy": {"temperature_c": 31.0, "wind_speed_kmh": 28.8, "wind_from_deg": NAN},
}
const H0 := 9.0
const H1 := 17.0
const SERIES_S := 600.0

var _a := {}


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	await get_tree().process_frame
	await _run()
	get_tree().quit(0)


func _run() -> void:
	var out := String(_a.get("out", "tools/research/cloud_field/out"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	if _a.has("zi_alpha"):
		# конфиг — живой словарь кеша Config: подмена действует на все расчёты этого запуска
		Config.get_config("atmosphere").air_model.zi_terrain_alpha = float(_a.zi_alpha)
	print("cloud_field: zi_terrain_alpha = %s" % Config.get_config("atmosphere").air_model.zi_terrain_alpha)
	var places := String(_a.get("places", "ongudai,training_island,almaty")).split(",")
	var weathers := String(_a.get("weathers", "weak,strong,windy")).split(",")
	var frames: Array[int] = []
	for t in String(_a.get("frames", "11,13,15")).split(","):
		frames.append(int(t))
	for loc_id in places:
		var terrain := Terrain.new()
		add_child(terrain)
		var ok := false
		if loc_id == "almaty":
			terrain.load_point(ALMATY.x, ALMATY.y)
			var res: Variant = await _wait_loaded(terrain)
			ok = res == true
		else:
			ok = terrain.load_location(loc_id)
		if not ok:
			push_error("cloud_field: нет места " + loc_id)
			terrain.queue_free()
			continue
		await get_tree().process_frame
		for wname in weathers:
			var t0 := Time.get_ticks_msec()
			await _day(terrain, loc_id, wname, out, frames)
			print("cloud_field: %s %s %.0f с" % [loc_id, wname, (Time.get_ticks_msec() - t0) / 1000.0])
		terrain.queue_free()
		await get_tree().process_frame


## Ждать loaded/load_failed места с карты (сборка тайлов); true — загружено.
func _wait_loaded(terrain: Terrain) -> bool:
	var state := {"done": false, "ok": false}
	terrain.loaded.connect(func() -> void: state.done = true; state.ok = true, CONNECT_ONE_SHOT)
	terrain.load_failed.connect(
		func(msg: String) -> void:
			push_error("cloud_field: место не собрано: " + msg)
			state.done = true,
		CONNECT_ONE_SHOT
	)
	var t0 := Time.get_ticks_msec()
	while not state.done and Time.get_ticks_msec() - t0 < 900000:
		await get_tree().process_frame
	return state.ok


func _day(terrain: Terrain, loc_id: String, wname: String, out: String, frames: Array[int]) -> void:
	var wx: Dictionary = WEATHERS[wname]
	var kmh := float(wx.wind_speed_kmh)
	var wdir := float(wx.wind_from_deg)
	if is_nan(wdir):
		wdir = float(WDIR_WINDY.get(loc_id, 270.0))
	var cfg: Dictionary = Config.get_config("atmosphere").cloud_field
	var cf := CloudField.new(cfg)
	var series := []
	var hours: Array[float] = []
	var h0 := float(_a.get("h0", H0))
	var h1 := float(_a.get("h1", H1))
	var h := h0
	while h <= h1 + 1.0e-6:
		hours.append(h)
		h += 1.0
	# рельеф для карты: сетка 200 м по области региона (заполняется с первым полем)
	var relief := {}
	var errors := []
	var t_switch := h0 * 3600.0
	for hour in hours:
		var sol: Dictionary = await _solve(terrain, hour, kmh / 3.6, wdir, float(wx.temperature_c))
		if not sol.ok:
			errors.append("h%s: %s" % [hour, sol.err])
			continue
		var atmo: Atmosphere = sol.atmo
		var level: WindField = sol.level
		var air: AirThermals = atmo.field.air_src
		if relief.is_empty():
			relief = _relief(terrain, level)
		cf.set_inputs({
			air = air, wind_field = level, weather = sol.weather,
			seed = int(Config.get_config("atmosphere").seed),
		})
		if hour == h0:
			cf.reset(h0 * 3600.0)
		# это поле действует до H + 0,5 ч (последнее — до конца дня)
		var t_end := minf((hour + 0.5) * 3600.0, h1 * 3600.0) if hour < h1 else h1 * 3600.0
		var t := t_switch
		while t < t_end - 1.0e-6:
			t = minf(t + SERIES_S, t_end)
			cf.step_to(t)
			series.append([t / 3600.0, _mean(cf.cover), _frac(cf.cover, 0.3), _mean(cf.depth)])
			var fh := int(round(t / 3600.0))
			if frames.has(fh) and absf(t - fh * 3600.0) < 1.0:
				_write(out, loc_id, wname, fh, cf, air, level, sol, relief, series)
		t_switch = t_end
		atmo.free()
	if not errors.is_empty():
		push_error("cloud_field: %s %s: %s" % [loc_id, wname, ", ".join(errors)])
	var f := FileAccess.open("%s/%s_%s_series.json" % [out, loc_id, wname], FileAccess.WRITE)
	f.store_string(JSON.stringify({"series": series, "errors": errors}))
	f.close()


func _write(
	out: String, loc_id: String, wname: String, fh: int, cf: CloudField, air: AirThermals,
	level: WindField, sol: Dictionary, relief: Dictionary, series: Array
) -> void:
	var srcs := []
	if air != null:
		for s in air.count():
			var p := air.pos[s]
			srcs.append([snappedf(p.x, 1.0), snappedf(p.z, 1.0), snappedf(air.w0[s], 0.01), snappedf(air.top[s], 1.0)])
	var mv := Vector2.ZERO
	for c in cf.nx * cf.ny:
		mv += Vector2(cf._vx[c], cf._vz[c])
	mv /= maxf(cf.nx * cf.ny, 1)
	var res := {
		"location": loc_id, "weather": wname, "hour": fh,
		"nx": cf.nx, "ny": cf.ny, "dx": cf.dx, "x0": cf.x0, "y0": cf.y0,
		"base_msl": cf.base_msl, "bg_cover": cf.bg_cover, "bg_depth": cf.bg_depth,
		"wind_base": [mv.x, mv.y], "z_i": level.z_i(),
		"z_i_col": _r(level.z_i_col(), 1.0), "zi_alpha": level.zi_alpha(),
		"cond": sol.cond, "solver": sol.info,
		"hc": _r(level.raw_hc(), 1.0), "phi": _r(air.phi, 0.0001) if air != null else [],
		"c_top": _r(air.c_top, 1.0) if air != null else [],
		"au": _r(cf._au1, 0.0001), "cover": _r(cf.cover, 0.001), "depth": _r(cf.depth, 1.0),
		"stage": _r(cf.stage, 0.01), "activity": _r(cf.activity, 0.01),
		"sources": srcs, "relief": relief, "series": series.duplicate(),
	}
	var path := "%s/%s_%s_h%d.json" % [out, loc_id, wname, fh]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(res))
	f.close()
	print("cloud_field: %s %s h%d: cover %.3f, облако ≥0,3 %.3f, LCL %.0f → %s" % [
		loc_id, wname, fh, _mean(cf.cover), _frac(cf.cover, 0.3), cf.base_msl, path
	])


## Рельеф 200 м по области уровня региона (настоящая высота земли, Terrain.height_at).
func _relief(terrain: Terrain, level: WindField) -> Dictionary:
	var step := 200.0
	var nx := int(round(level.nx * level.dx / step))
	var ny := int(round(level.ny * level.dx / step))
	var hgt := PackedFloat32Array()
	for j in ny:
		for i in nx:
			var x := level.x0 + (i + 0.5) * step
			var z := -(level.y0 + (j + 0.5) * step)
			hgt.append(terrain.height_at(x, z))
	return {"step": step, "nx": nx, "ny": ny, "x0": level.x0, "y0": level.y0, "height": _r(hgt, 1.0)}


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(a.size(), 1)


func _frac(a: PackedFloat32Array, thr: float) -> float:
	var n := 0
	for v in a:
		if v >= thr:
			n += 1
	return float(n) / maxf(a.size(), 1)


func _r(a: PackedFloat32Array, q: float) -> Array:
	var out := []
	out.resize(a.size())
	for i in a.size():
		var v := a[i]
		out[i] = null if is_nan(v) else snappedf(v, q)
	return out


## Решение поля игры на час — копия tools/research/thermal_drainage/dump.gd::_solve (оттуда —
## из tools/research/surface_heat/measure.gd), плюс погода часа для CloudField.
func _solve(terrain: Terrain, hour: float, wind_ms: float, wdir: float, t_max: float) -> Dictionary:
	var settings := FlightSettings.defaults()
	settings.temperature_c = t_max
	var sites: Array = terrain.get_start_sites()
	var sp: Vector3 = sites[0].position if not sites.is_empty() else Vector3(0.0, terrain.height_at(0.0, 0.0), 0.0)
	var kmh := wind_ms * 3.6
	var g: Dictionary = Config.get_config("atmosphere").ground
	var wc := WeatherModel.config()
	var ctx := WeatherModel.ground_context(
		terrain.height_at, float(g.reference_radius_m), int(g.reference_samples), float(wc.valley_percentile)
	)
	var utc := _utc(terrain)
	ctx.merge({
		"month": settings.month, "day": settings.day, "lat": terrain.center_lat,
		"lon": terrain.center_lon, "utc_offset_h": utc,
	})
	var fc := settings.forecast()
	fc.temperature_c = t_max
	fc.wind_speed_kmh = kmh
	fc.wind_from_deg = wdir
	var w := WeatherModel.derive(fc, ctx, {}, hour)
	var weather := w.duplicate(true)
	w.thermal_mode = "static"
	w.static_thermals = []
	w.background_sink_ms = 0.0
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.configure(Config.get_config("atmosphere"), w)
	atmo.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
	atmo.set_wind(kmh, wdir, sp.y)
	atmo.turbulence_enabled = false
	atmo.set_focus(sp)
	atmo.step(0.01)
	var rt := AirRuntime.new()
	add_child(rt)
	await get_tree().process_frame
	var c := {hour = hour, u10 = wind_ms, wdir = wdir, t_max = t_max, sky = settings.sky}
	rt.setup(atmo, AirRuntime.place_of(terrain, utc), func() -> Dictionary: return c)
	rt.focus_fn = func() -> Vector3: return sp
	rt.baked_enabled = false
	var why := rt.unavailable_reason()
	if why != "":
		rt.queue_free()
		atmo.free()
		return {"ok": false, "err": "поле недоступно: " + why}
	var ok: bool = await rt.load_field()
	var info: Dictionary = rt.last_info.duplicate()
	info["solver_err"] = rt.last_error
	rt.stop()
	rt.queue_free()
	if not ok:
		atmo.free()
		return {"ok": false, "err": "решатель: " + rt.last_error}
	atmo.set_focus(sp)
	atmo.step(0.01)
	if not atmo.is_air_field_on():
		atmo.free()
		return {"ok": false, "err": "поле не включилось"}
	var level: WindField = null
	for l: WindField in atmo.air_field.levels:
		if level == null or l.dx > level.dx:
			level = l
	atmo.field.air_async = false
	atmo.field.air = atmo.air_field
	atmo.field._update_air()
	var dv: Dictionary = weather.get("_derived", {})
	var cond := {
		"hour": hour, "wind_ms": wind_ms, "wdir": wdir, "t_max": t_max,
		"z_lcl_msl_m": dv.get("z_lcl_msl_m"), "z_dry_msl_m": dv.get("z_dry_msl_m"),
		"temperature_c": dv.get("temperature_c"), "dew_point_c": dv.get("dew_point_c"),
		"cloudbase_agl_m": weather.get("cloudbase_agl_m"), "cloud_depth_m": weather.get("cloud_depth_m"),
		"overdevelopment_chance": weather.get("overdevelopment_chance"),
		"stability_n_per_s": weather.get("stability_n_per_s"), "blue": dv.get("blue"),
		"z_i_msl_m": level.z_i(), "valley_msl_m": ctx.get("valley_msl_m"), "mean_msl_m": ctx.get("mean_msl_m"),
	}
	return {"ok": true, "atmo": atmo, "level": level, "weather": weather, "info": _clean(info), "cond": cond, "err": ""}


func _clean(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		var v: Variant = d[k]
		if v is float and (is_nan(v) or is_inf(v)):
			out[k] = null
		elif v is Dictionary:
			out[k] = _clean(v)
		elif v is PackedFloat32Array or v is PackedByteArray or v is PackedInt32Array:
			continue
		else:
			out[k] = v
	return out


func _utc(terrain: Terrain) -> float:
	var v: Variant = Config.value("world", "time.utc_offset_h", null)
	if v is String and v == "solar":
		return NAN
	if v != null:
		return float(v)
	var z := float(terrain.location.get("utc_offset_h", NAN))
	return z if not is_nan(z) else roundf(terrain.center_lon / 15.0)
