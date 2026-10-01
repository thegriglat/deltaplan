extends Node
## air-start AS-1: загрузка поля на слабом ветре (Онгудай, старт kayancha_south) — по проходам:
## k, итерации области [без нагрева, с нагревом] и окон, время, упор в предел 3000, таймаут, откат.
## Варианты: p1 — один проход (max_passes = 1, как 1.0.0), p2 — два прохода, проход 2 с тёплого
## старта от прохода 1, p2cold — два прохода, холодный старт прохода 2. Для сравнения полей —
## горизонталь среднего ветра атмосферы в 6 точках у старта.
## Аргументы (после --): --out=<csv> --cases=час:ветер:откуда;… --variants=p1,p2,p2cold
## Готовые ключи (случай, вариант) пропускаются.

const COLS := "case,variant,ok,pass,k,u10_start_ms,iters_domain,windows,wall_s,pass_s,domain_s,gpu_s,hit_3000,pass_failed,last_error,probe_u"
const ITER_MAX := 3000

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
	var out := String(_a.get("out", "tools/research/air_start/out/slow_wind.csv"))
	var cases := String(_a.get("cases", "12:3:180;12:2:270;12:1:270;9:0:270")).split(";")
	var variants := String(_a.get("variants", "p1,p2,p2cold")).split(",")
	_load_done(out)
	var exists := FileAccess.file_exists(out)
	var fa := FileAccess.open(out, FileAccess.READ_WRITE if exists else FileAccess.WRITE)
	if exists:
		fa.seek_end()
	else:
		fa.store_line(COLS)
	var terrain := Terrain.new()
	add_child(terrain)
	terrain.load_location("ongudai")
	var site: Dictionary = terrain.get_start_sites()[0]
	for s in terrain.get_start_sites():
		if s.id == "kayancha_south":
			site = s
	var rt := AirRuntime.new()
	add_child(rt)
	await get_tree().process_frame
	for cs in cases:
		var q := cs.split(":")
		for variant in variants:
			if _done.has("%s|%s" % [cs, variant]):
				continue
			var rows := await _one(terrain, rt, site, cs, float(q[0]), float(q[1]), float(q[2]), variant)
			for r in rows:
				fa.store_line(r)
			fa.flush()
			print("slow_wind_probe: %s %s, строк %d" % [cs, variant, rows.size()])
	fa.close()


func _one(
	terrain: Terrain,
	rt: AirRuntime,
	site: Dictionary,
	cs: String,
	hour: float,
	wind_ms: float,
	wdir: float,
	variant: String
) -> Array[String]:
	var settings := FlightSettings.defaults()
	var sp: Vector3 = site.position
	var kmh := wind_ms * 3.6
	var g: Dictionary = Config.get_config("atmosphere").ground
	var ctx := WeatherModel.ground_context(
		terrain.height_at,
		float(g.reference_radius_m),
		int(g.reference_samples),
		float(WeatherModel.config().valley_percentile)
	)
	var utc := float(terrain.location.get("utc_offset_h", roundf(terrain.center_lon / 15.0)))
	var wv: Variant = Config.value("world", "time.utc_offset_h", null)
	if wv is String and wv == "solar":
		utc = NAN
	elif wv != null:
		utc = float(wv)
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
	fc.wind_from_deg = wdir
	var w := WeatherModel.derive(fc, ctx, {}, hour)
	w.thermal_mode = "static"
	w.static_thermals = []
	w.background_sink_ms = 0.0
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.configure(Config.get_config("atmosphere"), w)
	atmo.set_ground(terrain.height_at, terrain.sun_exposure_at, terrain.surface_at)
	atmo.set_wind(kmh, wdir, sp.y)
	atmo.turbulence_enabled = false
	atmo.set_focus(sp)
	atmo.step(0.01)
	var c := {hour = hour, u10 = wind_ms, wdir = wdir, t_max = settings.temperature_c, sky = settings.sky}
	rt.setup(atmo, AirRuntime.place_of(terrain, utc), func() -> Dictionary: return c)
	rt.focus_fn = func() -> Vector3: return sp
	rt.max_passes = 1 if variant == "p1" else 2
	rt.warm_second_pass = variant != "p2cold"
	rt.set("_k_mem", {})
	rt.set("_cur", {})
	var t0 := Time.get_ticks_msec()
	var ok: bool = await rt.load_field()
	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	var li := rt.last_info if ok else {}
	# поле у старта: 10/50/100 м над стартом и 10 м в 500 м по сторонам
	var probe: Array[String] = []
	for d: Vector3 in [
		Vector3(0, 10, 0), Vector3(0, 50, 0), Vector3(0, 100, 0),
		Vector3(500, 10, 0), Vector3(-500, 10, 0), Vector3(0, 10, 500),
	]:
		var x := sp.x + d.x
		var z := sp.z + d.z
		var v := atmo.mean_wind_at(Vector3(x, terrain.height_at(x, z) + d.y, z))
		probe.append("%.3f" % Vector2(v.x, v.z).length())
	var out: Array[String] = []
	var log: Array = li.get("pass_log", [])
	var failed := String(li.get("pass_failed", ""))
	for q in log.size():
		var e: Dictionary = log[q]
		var it: Array = e.iters
		var hit := it.any(func(n: Variant) -> bool: return int(n) >= ITER_MAX)
		out.append(_row([
			cs, variant, str(ok), str(q + 1), "%.4f" % float(e.k), "%.3f" % float(e.u),
			" ".join(it.map(func(n: Variant) -> String: return str(n))),
			" ".join(e.get("windows", [])), "%.2f" % float(e.wall_s), "%.2f" % float(e.pass_s),
			"%.2f" % float(e.domain_s), "%.2f" % float(e.gpu_s), str(hit), failed, rt.last_error,
			" ".join(probe),
		]))
	if log.is_empty() or failed != "":
		# проход без поля (таймаут/ошибка): строка без чисел прохода
		out.append(_row([
			cs, variant, str(ok), str(log.size() + 1), "", "", "", "", "%.2f" % wall, "", "", "",
			"", failed, rt.last_error, " ".join(probe),
		]))
	atmo.free()
	return out


static func _row(cells: Array) -> String:
	return ",".join(cells.map(func(x: Variant) -> String: return '"%s"' % str(x)))


func _load_done(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	f.get_line()
	while not f.eof_reached():
		var c := f.get_line().split(",")
		if c.size() >= 2:
			_done["%s|%s" % [c[0].trim_prefix('"').trim_suffix('"'), c[1].trim_prefix('"').trim_suffix('"')]] = true
	f.close()
