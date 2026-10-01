extends Node
## WPC-2: ветер у стартов (контракт К5) — что получает аппарат (Atmosphere.air_velocity_at, как
## Glider/FlightModel) при ветре меню «в старт», турбулентность выключена.
## Настройка атмосферы — как Game.start (scripts/game/game.gd:220–288): погода WeatherModel.derive
## из прогноза по умолчанию (FlightSettings.defaults) на час старта, set_ground, set_wind(км/ч,
## heading старта, высота старта); термики выключены (static, пусто), фоновое опускание 0 —
## w_ms = механическая вертикаль (склон аналитики / w_mech поля + волны, если включены погодой).
## Поле — AirRuntime.load_field (область 400 м + окна 100/50 м у старта), как Game._load_air_field.
##
## Аргументы (после --): --out=<csv> --meta=<jsonl> --terrain=<json> --modes=analytic,field
##   --winds=0,3,6,10 --sites=loc/site,... (пусто — все) --hour=<ч> (по умолчанию world.time.start_hour)
## Повторный запуск пропускает готовые ключи (loc, site, mode, wind) — продолжение с места.

const COLS := "location,start,mode,wind_set_ms,hour,offset_m,agl_m,msl_m,ground_msl_m,u_h_ms,u_along_ms,w_ms,u_profile_model_ms"
const AGLS: Array[float] = [1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 30.0, 50.0, 100.0, 200.0, 300.0]
## offset_m: «−» — против ветра (перед стартом, вниз по склону), «+» — за стартом.
const OFFSETS: Array[float] = [-3000.0, -1000.0, -300.0, -150.0, -50.0, -30.0, -20.0, -10.0, 0.0, 100.0, 300.0]
const LOCATIONS: Array[String] = ["altai", "askarovo", "aushkul", "ongudai"]

var _a := {}
var _done := {}


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	await get_tree().process_frame
	await _run()
	get_tree().quit(0)


func _run() -> void:
	var out := String(_a.get("out", "tools/research/wing_physics_check/out/wind_profile.csv"))
	var meta_path := String(_a.get("meta", out.get_basename() + "_meta.jsonl"))
	var terr_path := String(_a.get("terrain", ""))
	var modes := String(_a.get("modes", "analytic")).split(",")
	var winds: Array[float] = []
	for t in String(_a.get("winds", "0,3,6,10")).split(","):
		winds.append(float(t))
	var only: Array = []
	if String(_a.get("sites", "")) != "":
		only = Array(String(_a.sites).split(","))
	var settings := FlightSettings.defaults()
	var hour := float(_a.get("hour", settings.start_hour))
	_load_done(out)
	var fa := _open_append(out, COLS)
	var fm := _open_append(meta_path, "")
	var terr := {}
	for loc_id in LOCATIONS:
		var terrain := Terrain.new()
		add_child(terrain)
		if not terrain.load_location(loc_id):
			push_error("нет локации " + loc_id)
			terrain.queue_free()
			continue
		for site: Dictionary in terrain.get_start_sites():
			var key0 := "%s/%s" % [loc_id, site.id]
			if not only.is_empty() and not only.has(key0):
				continue
			if terr_path != "":
				terr[key0] = _terrain_line(terrain, site)
			for mode in modes:
				for wv in winds:
					var key := "%s|%s|%s|%s" % [loc_id, site.id, mode, _num(wv)]
					if _done.has(key):
						continue
					var t0 := Time.get_ticks_msec()
					var res: Dictionary = await _one(terrain, loc_id, site, mode, wv, hour, settings)
					res.wall_s = (Time.get_ticks_msec() - t0) / 1000.0
					fm.store_line(JSON.stringify(res.meta.merged({"wall_s": res.wall_s})))
					fm.flush()
					for row in res.rows:
						fa.store_line(row)
					fa.flush()
					print("wind_audit: %s %.1f с, строк %d" % [key, res.wall_s, res.rows.size()])
		terrain.queue_free()
		await get_tree().process_frame
	fa.close()
	fm.close()
	if terr_path != "":
		var ft := FileAccess.open(terr_path, FileAccess.WRITE)
		ft.store_string(JSON.stringify(terr))
		ft.close()


func _one(
	terrain: Terrain, loc_id: String, site: Dictionary, mode: String, wind_ms: float, hour: float,
	settings: FlightSettings
) -> Dictionary:
	var heading := float(site.heading_deg)
	var sp: Vector3 = site.position
	var kmh := wind_ms * 3.6
	# погода — как Game.start: контекст места, прогноз по умолчанию, час старта
	var g: Dictionary = Config.get_config("atmosphere").ground
	var wc := WeatherModel.config()
	var ctx := WeatherModel.ground_context(
		terrain.height_at, float(g.reference_radius_m), int(g.reference_samples),
		float(wc.valley_percentile)
	)
	var utc := _utc(terrain)
	ctx.merge({
		"month": settings.month, "day": settings.day, "lat": terrain.center_lat,
		"lon": terrain.center_lon, "utc_offset_h": utc,
	})
	var fc := settings.forecast()
	fc.wind_speed_kmh = kmh
	fc.wind_from_deg = heading
	var w := WeatherModel.derive(fc, ctx, {}, hour)
	var bg_sink := float(w.get("background_sink_ms", 0.0))
	w.thermal_mode = "static"
	w.static_thermals = []
	w.background_sink_ms = 0.0
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.configure(Config.get_config("atmosphere"), w)
	var src: Callable = (
		terrain.thermal_source_strength_at
		if terrain.has_method("thermal_source_strength_at") else terrain.sun_exposure_at
	)
	atmo.set_ground(terrain.height_at, src, terrain.surface_at)
	atmo.set_wind(kmh, heading, sp.y)
	atmo.turbulence_enabled = false
	atmo.set_focus(sp)
	atmo.step(0.01)
	var meta := {
		"location": loc_id, "start": site.id, "mode": mode, "wind_set_ms": wind_ms, "hour": hour,
		"heading_deg": heading, "start_msl": sp.y, "utc": utc,
		"alpha": atmo.wind.profile_params().x, "max_profile": atmo.wind.profile_params().y,
		"stability_class": "ABCDEF"[WindProfile.stability_class(wind_ms, atmo.wind.sun_elev_deg, atmo.wind.cover)],
		"sun_elev_deg": atmo.wind.sun_elev_deg, "cover": atmo.wind.cover,
		"bg_sink_ms_excluded": bg_sink, "wave_enabled": atmo.wave.enabled,
	}
	if mode == "field":
		var rt := AirRuntime.new()
		add_child(rt)
		await get_tree().process_frame
		var c := {
			hour = hour, u10 = kmh / 3.6, wdir = heading, t_max = settings.temperature_c,
			sky = settings.sky,
		}
		rt.setup(atmo, AirRuntime.place_of(terrain, utc), func() -> Dictionary: return c)
		rt.focus_fn = func() -> Vector3: return sp
		var why := rt.unavailable_reason()
		meta.unavailable = why
		if why == "":
			var ok: bool = await rt.load_field()
			meta.solver_ok = ok
			meta.solver_info = rt.last_info
			meta.solver_err = rt.last_error
		rt.stop()
		rt.queue_free()
		atmo.set_focus(sp)
		atmo.step(0.01)
		meta.field_on = atmo.is_air_field_on()
		var lv: Array = []
		for f in atmo.air_field.levels:
			lv.append({"dx": f.dx, "nx": f.nx, "ny": f.ny, "z0": f.z0})
		meta.levels = lv
		if not atmo.is_air_field_on():
			atmo.free()
			return {"meta": meta, "rows": []}
	else:
		atmo.set_air_mode("off")
	var face := Vector2(sin(deg_to_rad(heading)), -cos(deg_to_rad(heading)))
	var rows: Array[String] = []
	var diag: Array = []
	for o in OFFSETS:
		var p2 := Vector2(sp.x, sp.z) - face * o
		var gh := terrain.height_at(p2.x, p2.y)
		var gf := atmo.ground.sample(p2.x, p2.y)
		for agl in AGLS:
			var p := Vector3(p2.x, gh + agl, p2.y)
			var v := atmo.air_velocity_at(p)
			var uh := Vector2(v.x, v.z).length()
			var ua := -(v.x * face.x + v.z * face.y)
			var model := atmo.wind.speed_at_pos(agl, p.y)
			rows.append(",".join([
				loc_id, site.id, mode, _num(wind_ms), _num(hour), _num(o), _num(agl),
				"%.2f" % p.y, "%.2f" % gh, "%.3f" % uh, "%.3f" % ua, "%.3f" % v.y, "%.3f" % model,
			]))
			var d := [o, agl, snappedf(gf.x - gh, 0.01)]
			if mode == "field":
				var fw := atmo.air_field.sample(p, gf.x)
				d.append_array([snappedf(fw.w, 0.001), atmo.air_field.sample_dx(p, gf.x)])
			else:
				d.append(snappedf(atmo._ridge_lift(p, maxf(p.y - gf.x, 0.0), atmo.wind.speed_at_pos(maxf(p.y - gf.x, 0.0), p.y)), 0.001))
			diag.append(d)
	meta.diag_cols = (
		"offset,agl,groundfield_minus_terrain_m,field_frac,field_dx" if mode == "field"
		else "offset,agl,groundfield_minus_terrain_m,w_ridge_analytic"
	)
	meta.diag = diag
	atmo.free()
	return {"meta": meta, "rows": rows}


## Профиль рельефа по линии ветра через старт: offset −5000…+2000 м, шаг 25 м.
func _terrain_line(terrain: Terrain, site: Dictionary) -> Dictionary:
	var h := deg_to_rad(float(site.heading_deg))
	var face := Vector2(sin(h), -cos(h))
	var sp: Vector3 = site.position
	var xs: Array = []
	var hs: Array = []
	var o := -5000.0
	while o <= 2000.0:
		var p := Vector2(sp.x, sp.z) - face * o
		xs.append(o)
		hs.append(snappedf(terrain.height_at(p.x, p.y), 0.1))
		o += 25.0
	return {"heading": float(site.heading_deg), "start_msl": sp.y, "offset": xs, "h": hs}


func _utc(terrain: Terrain) -> float:
	var v: Variant = Config.value("world", "time.utc_offset_h", null)
	if v is String and v == "solar":
		return NAN
	if v != null:
		return float(v)
	var z := float(terrain.location.get("utc_offset_h", NAN))
	return z if not is_nan(z) else roundf(terrain.center_lon / 15.0)


func _num(x: float) -> String:
	return str(snappedf(x, 0.01))


func _load_done(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	f.get_line()
	while not f.eof_reached():
		var c := f.get_line().split(",")
		if c.size() >= 4:
			_done["%s|%s|%s|%s" % [c[0], c[1], c[2], c[3]]] = true
	f.close()


func _open_append(path: String, header: String) -> FileAccess:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var exists := FileAccess.file_exists(path)
	var f := FileAccess.open(path, FileAccess.READ_WRITE if exists else FileAccess.WRITE)
	if exists:
		f.seek_end()
	elif header != "":
		f.store_line(header)
	return f
