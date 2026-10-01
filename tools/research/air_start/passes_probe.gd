extends Node
## air-start AS-1: сходимость подстройки притока по проходам загрузки AirRuntime на всех 10
## стартах — U на 10 м над стартом после каждого прохода (k, U, время от начала, итерации).
## Атмосфера и погода — как wind_audit.gd (Game.start: прогноз по умолчанию, час старта, ветер «в
## старт»); U — Atmosphere.mean_wind_at (как пилот) поданного поля и AirRuntime.pass_log по проходам.
##
## Аргументы (после --): --out=<csv> --winds=3,6,10 --variants=warm,cold --passes=4
##   (pass_tol = 0: все проходы до --passes; секущая с прохода 3). Готовые ключи пропускаются.
## Запуск (GPU, под замком): см. README.md.

const COLS := "location,start,wind_set_ms,variant,pass,k,u10_start_ms,ratio,wall_s,pass_s,domain_s,domain_gpu_s,iters,warm,u_atmo_final_ms"
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
	var out := String(_a.get("out", "tools/research/air_start/out/passes.csv"))
	var winds: Array[float] = []
	for t in String(_a.get("winds", "6")).split(","):
		winds.append(float(t))
	var variants := String(_a.get("variants", "warm")).split(",")
	var passes := int(_a.get("passes", "4"))
	var settings := FlightSettings.defaults()
	_load_done(out)
	var exists := FileAccess.file_exists(out)
	var fa := FileAccess.open(out, FileAccess.READ_WRITE if exists else FileAccess.WRITE)
	if exists:
		fa.seek_end()
	else:
		fa.store_line(COLS)
	for loc_id in LOCATIONS:
		var terrain := Terrain.new()
		add_child(terrain)
		if not terrain.load_location(loc_id):
			terrain.queue_free()
			continue
		var rt := AirRuntime.new()
		add_child(rt)
		await get_tree().process_frame
		for site: Dictionary in terrain.get_start_sites():
			for wv in winds:
				for variant in variants:
					var key := "%s|%s|%s|%s" % [loc_id, site.id, str(wv), variant]
					if _done.has(key):
						continue
					var rows := await _one(terrain, rt, loc_id, site, wv, variant, passes, settings)
					for r in rows:
						fa.store_line(r)
					fa.flush()
					print("passes_probe: %s, проходов %d" % [key, rows.size()])
		rt.stop()
		rt.queue_free()
		terrain.queue_free()
		await get_tree().process_frame
	fa.close()


func _one(
	terrain: Terrain,
	rt: AirRuntime,
	loc_id: String,
	site: Dictionary,
	wind_ms: float,
	variant: String,
	passes: int,
	settings: FlightSettings
) -> Array[String]:
	var heading := float(site.heading_deg)
	var sp: Vector3 = site.position
	var kmh := wind_ms * 3.6
	var g: Dictionary = Config.get_config("atmosphere").ground
	var wc := WeatherModel.config()
	var ctx := WeatherModel.ground_context(
		terrain.height_at,
		float(g.reference_radius_m),
		int(g.reference_samples),
		float(wc.valley_percentile)
	)
	var utc := _utc(terrain)
	ctx.merge(
		{
			"month": settings.month,
			"day": settings.day,
			"lat": terrain.center_lat,
			"lon": terrain.center_lon,
			"utc_offset_h": utc,
		}
	)
	var fc := settings.forecast()
	fc.wind_speed_kmh = kmh
	fc.wind_from_deg = heading
	var w := WeatherModel.derive(fc, ctx, {}, settings.start_hour)
	w.thermal_mode = "static"
	w.static_thermals = []
	w.background_sink_ms = 0.0
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.configure(Config.get_config("atmosphere"), w)
	atmo.set_ground(terrain.height_at, terrain.sun_exposure_at, terrain.surface_at)
	atmo.set_wind(kmh, heading, sp.y)
	atmo.turbulence_enabled = false
	atmo.set_focus(sp)
	atmo.step(0.01)
	var c := {
		hour = settings.start_hour,
		u10 = wind_ms,
		wdir = heading,
		t_max = settings.temperature_c,
		sky = settings.sky,
	}
	rt.setup(atmo, AirRuntime.place_of(terrain, utc), func() -> Dictionary: return c)
	rt.focus_fn = func() -> Vector3: return sp
	rt.max_passes = passes
	rt.pass_tol = 0.0
	rt.warm_second_pass = variant == "warm"
	# k прошлой загрузки (память по направлению) — сбросить: каждый замер с k₀ = 1
	rt.set("_k_mem", {})
	rt.set("_cur", {})  # иначе «те же место и условия» — поле не считается
	var ok: bool = await rt.load_field()
	var out: Array[String] = []
	if not ok:
		atmo.free()
		return out
	var h := terrain.height_at(sp.x, sp.z)
	var v := atmo.mean_wind_at(Vector3(sp.x, h + 10.0, sp.z))
	var uf := Vector2(v.x, v.z).length()
	var log: Array = rt.last_info.get("pass_log", [])
	for q in log.size():
		var e: Dictionary = log[q]
		out.append(
			",".join(
				[
					loc_id,
					site.id,
					str(wind_ms),
					variant,
					str(q + 1),
					"%.4f" % float(e.k),
					"%.3f" % float(e.u),
					"%.4f" % (float(e.u) / wind_ms),
					"%.2f" % float(e.wall_s),
					"%.2f" % float(e.pass_s),
					"%.2f" % float(e.domain_s),
					"%.2f" % float(e.gpu_s),
					'"%s"' % str(e.iters),
					str(e.warm),
					"%.3f" % uf,
				]
			)
		)
	atmo.free()
	return out


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


func _utc(terrain: Terrain) -> float:
	var v: Variant = Config.value("world", "time.utc_offset_h", null)
	if v is String and v == "solar":
		return NAN
	if v != null:
		return float(v)
	var z := float(terrain.location.get("utc_offset_h", NAN))
	return z if not is_nan(z) else roundf(terrain.center_lon / 15.0)
