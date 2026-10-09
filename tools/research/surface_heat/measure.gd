extends Node
## SH-3: замер «до/после» для модуля surface-heat (контракт SH5, docs/contracts/surface-heat.md).
## Всё — на коде игры, в игре: Terrain.load_location → AirRuntime.load_field (AirPlace.domain_case →
## Пикар на GPU → WindField, поданное в Atmosphere) → AirThermals.build по этому полю
## (ThermalField._update_air, синхронно) → выборки Atmosphere.air_velocity_at. Python-полей нет.
## Условия — как у игры по умолчанию: FlightSettings.defaults() (15 июля, ясно, t_max 26 °C),
## ветер меню --wind м/с на 10 м над стартом, откуда --wdir (по умолчанию — типичное для места).
##
## Запуск (нужен GPU; окно маленькое — см. run.sh):
##   tools/research/surface_heat/run.sh <метка> [--places=altai,ongudai,aushkul --hours=9,12,15 …]
## Аргументы (после --): --label=<метка> --out=<папка> --places= --hours= --wind=<м/с>
##   --wdir=<°, для всех мест; иначе по месту> --radius=<км, область статистики, 10>
##   --lee-hours=<часы, в которые допускается отдельное решение с обратным ветром, 12>
##   --lee-sec=<длительность ряда σ_w, 120> --no-lee --node-step=<м, шаг узлов класса клетки, 50>
## Повторный запуск пропускает готовые <место>_h<час>.json (продолжение с места).
##
## Что и как измеряется (подробно — README.md):
##  - H — heat_flux() грубейшего уровня поля (клетка 400 м), в круге --radius км вокруг центра места;
##  - класс клетки — класс большинства узлов решётки node-step (Terrain.surface_at: вода по маске
##    10 м, лес по маске, крутой склон → скалы), SurfaceLayer.CLASS_NAMES;
##  - источники — AirThermals.build (число, плотность на км² круга, w0 — сила ядра, потолок
##    частицы top − высота земли у источника);
##  - подъём на склоне у стартов — w_mech поля (air_velocity_at, шум и термики выключены);
##  - подветренные зоны — стартовые площадки, где ветер дует «в спину» старту; минимум w по
##    линии ветра ±1 км, 10–100 м над землёй; σ_w — ряд w в этой точке с турбулентностью поля.

const OUT_VERSION := 1
## Типичное направление ветра (откуда, °) по месту: основной старт (config start_sites[0]).
const WDIR := {"altai": 276.0, "ongudai": 150.0, "aushkul": 273.0}
const AGLS: Array[float] = [10.0, 20.0, 35.0, 50.0, 65.0, 80.0, 100.0]

var _a := {}
var _label := "run"


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	await get_tree().process_frame
	await _run()
	get_tree().quit(0)


func _run() -> void:
	_label = String(_a.get("label", "run"))
	var out := String(_a.get("out", "tools/research/surface_heat/out/" + _label))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var places := String(_a.get("places", "altai,ongudai,aushkul")).split(",")
	var hours: Array[float] = []
	for t in String(_a.get("hours", "9,12,15")).split(","):
		hours.append(float(t))
	var t_all := Time.get_ticks_msec()
	for loc_id in places:
		var terrain := Terrain.new()
		add_child(terrain)
		if not terrain.load_location(loc_id):
			push_error("нет локации " + loc_id)
			terrain.queue_free()
			continue
		await get_tree().process_frame
		for hour in hours:
			var path := "%s/%s_h%s.json" % [out, loc_id, _hs(hour)]
			if FileAccess.file_exists(path):
				print("surface_heat: %s уже есть" % path)
				continue
			var t0 := Time.get_ticks_msec()
			var res: Dictionary = await _one(terrain, loc_id, hour)
			res.wall_s = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_string(JSON.stringify(res, "  "))
			f.close()
			print("surface_heat: %s h%s %.1f с" % [loc_id, _hs(hour), res.wall_s])
		terrain.queue_free()
		await get_tree().process_frame
	print("surface_heat: всего %.1f с" % ((Time.get_ticks_msec() - t_all) / 1000.0))


## Один замер: место × час. Возвращает словарь JSON по контракту SH5.
func _one(terrain: Terrain, loc_id: String, hour: float) -> Dictionary:
	var wind_ms := float(_a.get("wind", 3.0))
	var wdir := float(_a.get("wdir", WDIR.get(loc_id, 0.0)))
	var res := {
		"version": OUT_VERSION, "label": _label, "location": loc_id, "hour": hour,
		"commit": _commit(), "wind_ms": wind_ms, "wdir_deg": wdir,
		"conditions": {},
	}
	var main: Dictionary = await _solve(terrain, loc_id, hour, wind_ms, wdir)
	if not main.ok:
		res["error"] = main.err
		return res
	var atmo: Atmosphere = main.atmo
	var f: WindField = main.level
	var radius := float(_a.get("radius", 10.0)) * 1000.0
	res["conditions"] = main.cond
	res["solver"] = main.info
	res["h_wm2"] = {}
	_stats_cells(terrain, atmo, f, radius, res, hour)
	_stats_sources(atmo, f, radius, res)
	res["slope_lift"] = _slope_lift(terrain, atmo, wdir)
	var lee: Array = []
	if not _a.has("no-lee"):
		lee = await _lee(terrain, loc_id, hour, wind_ms, wdir, atmo, main.sp)
	res["lee"] = lee
	atmo.free()
	return res


## Решение поля игры (как Game._load_air_field/wind_audit field): возвращает {ok, atmo, level, ...}.
func _solve(terrain: Terrain, loc_id: String, hour: float, wind_ms: float, wdir: float) -> Dictionary:
	var settings := FlightSettings.defaults()
	var sites: Array = terrain.get_start_sites()
	var sp: Vector3 = sites[0].position
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
	fc.wind_speed_kmh = kmh
	fc.wind_from_deg = wdir
	var w := WeatherModel.derive(fc, ctx, {}, hour)
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
	var c := {
		hour = hour, u10 = wind_ms, wdir = wdir, t_max = settings.temperature_c, sky = settings.sky,
	}
	rt.setup(atmo, AirRuntime.place_of(terrain, utc), func() -> Dictionary: return c)
	rt.focus_fn = func() -> Vector3: return sp
	var why := rt.unavailable_reason()
	if why != "":
		rt.queue_free()
		atmo.free()
		return {"ok": false, "err": "поле недоступно: " + why}
	var ok: bool = await rt.load_field()
	var info: Dictionary = rt.last_info.duplicate()
	info["inflow_k"] = rt.inflow_k
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
	# грубейший уровень (клетка 400 м)
	var level: WindField = null
	for l: WindField in atmo.air_field.levels:
		if level == null or l.dx > level.dx:
			level = l
	# источники термиков поля — синхронная сборка, как в игре (ThermalField._update_air)
	atmo.field.air_async = false
	atmo.field.air = atmo.air_field
	atmo.field._update_air()
	var d := AirPlace.day(
		AirPlace.context(
			rt._place.detail, rt._place.loc, WeatherModel.config()
		), hour, settings.temperature_c, settings.sky, WeatherModel.config()
	)
	var cond := {
		"month": settings.month, "day": settings.day, "t_max_c": settings.temperature_c,
		"sky": settings.sky, "t_air_c": float(d.t), "z_i_msl_m": float(d.z_i),
		"cover": float(d.cover), "sky_heat": float(d.sky_heat),
	}
	return {
		"ok": true, "atmo": atmo, "level": level, "info": _clean(info), "cond": cond, "sp": sp,
		"err": "",
	}


## H по клеткам круга: распределение, по классам, вода.
func _stats_cells(
	terrain: Terrain, atmo: Atmosphere, f: WindField, radius: float, res: Dictionary, hour: float
) -> void:
	var heat := f.heat_flux()
	var step := float(_a.get("node-step", 50.0))
	var n := roundi(f.dx / step)
	var hs := PackedFloat64Array()
	var cls_n := PackedInt32Array()
	cls_n.resize(SurfaceLayer.CLASS_COUNT)
	var cls_h := PackedFloat64Array()
	cls_h.resize(SurfaceLayer.CLASS_COUNT)
	var cls_hs: Array = []
	for i in SurfaceLayer.CLASS_COUNT:
		cls_hs.append(PackedFloat64Array())
	var wat_n := 0
	var wat_h := 0.0
	var wat_frac_sum := 0.0
	var tot := 0
	for j in f.ny:
		for i in f.nx:
			var cx := f.x0 + (i + 0.5) * f.dx
			var cz := -(f.y0 + (j + 0.5) * f.dx)
			if Vector2(cx, cz).length() > radius:
				continue
			var h := float(heat[j * f.nx + i])
			hs.append(h)
			tot += 1
			var counts := PackedInt32Array()
			counts.resize(SurfaceLayer.CLASS_COUNT)
			var x_lo := cx - 0.5 * f.dx
			var z_lo := cz - 0.5 * f.dx
			for b in n:
				for a in n:
					var c := terrain.surface_at(x_lo + (a + 0.5) * step, z_lo + (b + 0.5) * step)
					counts[clampi(c, 0, SurfaceLayer.CLASS_COUNT - 1)] += 1
			var best := 0
			for k in SurfaceLayer.CLASS_COUNT:
				if counts[k] > counts[best]:
					best = k
			cls_n[best] += 1
			cls_h[best] += h
			cls_hs[best].append(h)
			wat_frac_sum += float(counts[SurfaceLayer.WATER]) / (n * n)
			if best == SurfaceLayer.WATER:
				wat_n += 1
				wat_h += h
	res["cells"] = {"n": tot, "dx_m": f.dx, "radius_km": radius / 1000.0}
	res["h_wm2"] = _q4(hs)
	var by := {}
	for k in SurfaceLayer.CLASS_COUNT:
		if cls_n[k] == 0:
			continue
		var e := _q4(cls_hs[k])
		by[SurfaceLayer.CLASS_NAMES[k]] = {
			"area_frac": snappedf(float(cls_n[k]) / maxi(tot, 1), 0.0001),
			"mean": e.mean, "p10": e.p10, "p90": e.p90,
		}
	res["h_by_class"] = by
	var tw: Variant = f.meta.get("t_water_c", null)
	res["water"] = {
		"area_frac": snappedf(float(wat_n) / maxi(tot, 1), 0.0001),
		"node_frac": snappedf(wat_frac_sum / maxi(tot, 1), 0.0001),
		"t_water_c": tw,
		"t_air_c": res.conditions.get("t_air_c", null),
		"h_mean_wm2": snappedf(wat_h / wat_n, 0.1) if wat_n > 0 else null,
	}


func _stats_sources(atmo: Atmosphere, f: WindField, radius: float, res: Dictionary) -> void:
	var src: AirThermals = atmo.field.air_src
	if src == null:
		res["sources"] = {"n": 0, "density_km2": 0.0, "strength_ms": null, "note": "AirThermals не собран"}
		res["ceiling_agl_m"] = null
		return
	var w0 := PackedFloat64Array()
	var ws := PackedFloat64Array()
	var ceil_agl := PackedFloat64Array()
	for s in src.count():
		var p := src.pos[s]
		if Vector2(p.x, p.z).length() > radius:
			continue
		w0.append(src.w0[s])
		ws.append(src.wstar[s])
		ceil_agl.append(src.top[s] - p.y)
	var area_km2 := PI * pow(radius / 1000.0, 2.0)
	var q := _q4(w0)
	res["sources"] = {
		"n": w0.size(), "density_km2": snappedf(w0.size() / area_km2, 0.001),
		"strength_ms": {"mean": q.mean, "p10": q.p10, "p90": q.p90},
		"wstar_ms": _q4(ws), "n_all_domain": src.count(),
		"alive_frac": snappedf(src.alive_frac, 0.001),
	}
	var qc := _q4(ceil_agl)
	res["ceiling_agl_m"] = {"p10": qc.p10, "p50": qc.p50, "p90": qc.p90, "mean": qc.mean}


## w_mech поля у каждого старта места: на 30 м над землёй в 50 м перед стартом (против ветра, вниз
## по склону — где летают сразу после отрыва) и над самим стартом на 10 м и 30 м. Шум выключен.
func _slope_lift(terrain: Terrain, atmo: Atmosphere, wdir: float) -> Array:
	var out: Array = []
	atmo.turbulence_enabled = false
	for site: Dictionary in terrain.get_start_sites():
		var hd := float(site.heading_deg)
		var face := Vector2(sin(deg_to_rad(hd)), -cos(deg_to_rad(hd)))
		var sp: Vector3 = site.position
		var dd := absf(fposmod(hd - wdir + 180.0, 360.0) - 180.0)
		var e := {"start": String(site.id), "heading_deg": hd, "dwind_deg": snappedf(dd, 0.1)}
		e["windward"] = dd <= 60.0
		atmo.set_focus(sp)
		atmo.step(0.01)
		var p0 := Vector2(sp.x, sp.z)
		var vals := {}
		for o: float in [0.0, -50.0, -150.0]:
			var p2 := p0 - face * o
			var gh := terrain.height_at(p2.x, p2.y)
			for agl: float in [10.0, 30.0]:
				var v := atmo.air_velocity_at(Vector3(p2.x, gh + agl, p2.y))
				vals["o%d_agl%d" % [int(o), int(agl)]] = snappedf(v.y, 0.001)
		e["w_ms"] = vals["o-50_agl30"]
		e["w_ms_def"] = "w_mech, 30 м над землёй, 50 м перед стартом (против ветра меню)"
		e["by_point"] = vals
		out.append(e)
	return out


## Подветренные зоны: по стартам, где ветер дует «в спину» (|wdir − (heading + 180)| ≤ 60°).
## Если таких нет в основном решении, а час входит в --lee-hours — решение с ветром с тыла
## основного старта (wdir + 180), как lee_zone в air_model_baseline/probe.gd.
func _lee(
	terrain: Terrain, loc_id: String, hour: float, wind_ms: float, wdir: float, atmo: Atmosphere, sp0: Vector3
) -> Array:
	var out: Array = []
	var sites: Array = terrain.get_start_sites()
	var lee_sites: Array = []
	for site: Dictionary in sites:
		var dd := absf(fposmod(float(site.heading_deg) + 180.0 - wdir + 180.0, 360.0) - 180.0)
		if dd <= 60.0:
			lee_sites.append(site)
	if not lee_sites.is_empty():
		for site: Dictionary in lee_sites:
			out.append(_lee_one(terrain, atmo, site, wdir, "main"))
		return out
	var hrs: Array = String(_a.get("lee-hours", "12")).split(",")
	if not hrs.has(_hs(hour)):
		return out
	var wd2 := fposmod(wdir + 180.0, 360.0)
	var r: Dictionary = await _solve(terrain, loc_id, hour, wind_ms, wd2)
	if not r.ok:
		return [{"site": "—", "error": r.err}]
	var a2: Atmosphere = r.atmo
	out.append(_lee_one(terrain, a2, sites[0], wd2, "extra_solve_wdir_%d" % int(wd2)))
	a2.free()
	return out


func _lee_one(terrain: Terrain, atmo: Atmosphere, site: Dictionary, wdir: float, how: String) -> Dictionary:
	var hd := float(site.heading_deg)
	var away := Vector2(sin(deg_to_rad(hd)), -cos(deg_to_rad(hd)))  # от ветра прочь → за стартом
	var sp: Vector3 = site.position
	atmo.turbulence_enabled = false
	atmo.set_focus(sp)
	atmo.step(0.01)
	var best_w := INF
	var best := Vector3.ZERO
	var d := -1000.0
	while d <= 1000.0:
		var p2 := Vector2(sp.x, sp.z) + away * d
		var gh := terrain.height_at(p2.x, p2.y)
		for agl in AGLS:
			var p := Vector3(p2.x, gh + agl, p2.y)
			var w := atmo.air_velocity_at(p).y
			if w < best_w:
				best_w = w
				best = p
		d += 20.0
	# ряд w в точке минимума с турбулентностью (как probe.gd: 20 Гц, СКО ряда)
	atmo.turbulence_enabled = true
	atmo.set_focus(best)
	var hz := 10.0
	var n := int(float(_a.get("lee-sec", 120.0)) * hz)
	var ws := PackedFloat64Array()
	for i in n:
		atmo.step(1.0 / hz)
		ws.append(atmo.air_velocity_at(best).y)
	atmo.turbulence_enabled = false
	var mean := 0.0
	for v in ws:
		mean += v
	mean /= maxi(n, 1)
	var var_w := 0.0
	for v in ws:
		var_w += (v - mean) * (v - mean)
	var_w /= maxi(n, 1)
	return {
		"site": String(site.id), "how": how, "wdir_deg": wdir,
		"w_min_ms": snappedf(best_w, 0.001), "sigma_w_ms": snappedf(sqrt(var_w), 0.001),
		"w_mean_series_ms": snappedf(mean, 0.001),
		"point_agl_m": snappedf(best.y - terrain.height_at(best.x, best.z), 0.1),
		"dist_from_start_m": snappedf(Vector2(best.x - sp.x, best.z - sp.z).length(), 1.0),
		"series_s": n / hz,
	}


# --- мелочи


## Среднее и квантили p10/p50/p90.
func _q4(a: PackedFloat64Array) -> Dictionary:
	if a.is_empty():
		return {"mean": null, "p10": null, "p50": null, "p90": null, "n": 0}
	var s := a.duplicate()
	s.sort()
	var m := 0.0
	for v in s:
		m += v
	m /= s.size()
	return {
		"mean": snappedf(m, 0.01), "p10": snappedf(_pct(s, 0.1), 0.01),
		"p50": snappedf(_pct(s, 0.5), 0.01), "p90": snappedf(_pct(s, 0.9), 0.01), "n": s.size(),
	}


func _pct(s: PackedFloat64Array, q: float) -> float:
	var x := q * (s.size() - 1)
	var i := int(x)
	return lerpf(s[i], s[mini(i + 1, s.size() - 1)], x - i)


func _clean(d: Dictionary) -> Dictionary:
	var o := {}
	for k in d:
		var v: Variant = d[k]
		if v is float or v is int or v is String or v is bool:
			o[k] = snappedf(v, 0.001) if v is float and is_finite(v) else (v if not v is float else null)
	return o


func _commit() -> String:
	var o := []
	OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "--short", "HEAD"], o)
	return String(o[0]).strip_edges() if not o.is_empty() else ""


func _hs(h: float) -> String:
	return str(int(h)) if is_equal_approx(h, roundf(h)) else str(h)


func _utc(terrain: Terrain) -> float:
	var v: Variant = Config.value("world", "time.utc_offset_h", null)
	if v is String and v == "solar":
		return NAN
	if v != null:
		return float(v)
	var z := float(terrain.location.get("utc_offset_h", NAN))
	return z if not is_nan(z) else roundf(terrain.center_lon / 15.0)
