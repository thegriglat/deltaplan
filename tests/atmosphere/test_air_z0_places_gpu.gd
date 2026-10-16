extends TestCase
## z0 по покрову на местах игры (SH-6, замер к отчёту): Алтай и Онгудай, снимок поверхности места
## (AirRuntime.place_of). Печатает z0 эффективный области (лог-среднее, среднее, p10/p90), U на 10 м
## над стартами при k = 1 с картой z0 и с прежним скаляром 0,1 м, U на 30 м над лесом и лугом (те же
## два решения), и подбор inflow_k AirRuntime со снимком (два прохода, U над стартом = меню ± 10 %).
## Решения 400 м с нагревом, mech. tools/gpu_tests.sh --filter=air_z0_places, ~3–5 мин.

const LOCATIONS: Array[String] = ["altai", "ongudai"]
const WIND_MS := 6.0
const TOL := 0.10
const EDGE := 8  # клеток от края области не берём (губки)

var _c := {}


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


func _solve(c: AirCase) -> WindField:
	var job := AirPicardJob.new()
	job.case = c
	job.mech = true
	if not job.start():
		failures.append("start: " + job.error)
		return null
	var frames := 0
	while not job.is_done() and job.error == "" and frames < 200000:
		await Engine.get_main_loop().process_frame
		job.poll()
		frames += 1
	check(job.is_done(), "%s: решено (%s)" % [c.label, job.error])
	var f := job.field()
	job.release()
	return f


static func _pct(a: PackedFloat64Array, q: float) -> float:
	var s := Array(a)
	s.sort()
	return float(s[clampi(roundi(q * (s.size() - 1)), 0, s.size() - 1)])


func test_places_z0() -> void:
	var settings := FlightSettings.defaults()
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var cfg := WeatherModel.config()
	for loc_id in LOCATIONS:
		var t := Terrain.new()
		t.location_id = ""
		t.load_location(loc_id)
		var loc := TestAirPlace.load_loc(loc_id)
		var utc := float(loc.get("utc_offset_h", NAN))
		var place := AirRuntime.place_of(t, utc)
		var sf: AirPlace.Surface = place.get("surface")
		var detail: HeightLayer = place.detail
		check(sf != null, loc_id + ": снимок поверхности")
		if sf == null:
			t.free()
			continue
		var hour := float(settings.start_hour)
		var site0: Dictionary = loc.start_sites[0]
		var wdir := float(site0.heading_deg)
		var a := AirPlace.domain_case(
			detail, place.water, place.loc, 400.0, hour, WIND_MS, wdir, NAN, "clear", true, 1.0, sf
		)
		var b := AirPlace.domain_case(
			detail, place.water, place.loc, 400.0, hour, WIND_MS, wdir, NAN, "clear", true, 1.0, sf
		)
		# b — прежний скаляр z0 = 0,1 м (α, z_sat заново по нему), H тот же
		var ctx := AirPlace.context(detail, place.loc, cfg)
		var d := AirPlace.day(ctx, hour, WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg), "clear", cfg)
		b.z0_map = PackedFloat64Array()
		b.p.z0 = AirCase.Z0
		b.set_inflow(WIND_MS, 1.0, ctx, hour, float(d.cover))
		b.label += " z0 0,1"
		var zm := a.z0_map
		var am := 0.0
		for v in zm:
			am += v
		am /= zm.size()
		print(
			"  %s: z0 области — лог-среднее %.3f м, среднее %.3f, p10 %.3f, p50 %.3f, p90 %.3f; α %.3f (скаляр %.3f), z_sat·max_profile %.3f / %.3f"
			% [loc_id, float(a.p.z0), am, _pct(zm, 0.1), _pct(zm, 0.5), _pct(zm, 0.9), float(a.p.alpha), float(b.p.alpha), a.max_profile_used(), b.max_profile_used()]
		)
		var fa: WindField = await _solve(a)
		var fb: WindField = await _solve(b)
		check(fa != null and fb != null, loc_id + ": поля решены")
		if fa == null or fb == null:
			t.free()
			continue
		# U на 10 м над стартами (k = 1)
		for site: Dictionary in loc.start_sites:
			var st := TerrainGeo.latlon_to_local(
				float(site.lat), float(site.lon), float(loc.center_lat), float(loc.center_lon)
			)
			var gh := detail.sample(st.x, st.y)
			var p := Vector3(st.x, gh + 10.0, st.y)
			var ua := Vector2(fa.sample(p, gh).x, fa.sample(p, gh).z).length()
			var ub := Vector2(fb.sample(p, gh).x, fb.sample(p, gh).z).length()
			print("  %s/%s: U10 старта k=1: карта %.2f, скаляр %.2f м/с, ×%.3f; z0 старта %.3f м" % [loc_id, site.id, ua, ub, ua / ub, fa.z0_at(p)])
		# U на 30 м над лесом и лугом (центры клеток внутри области)
		var sums := {for_a = 0.0, for_b = 0.0, gr_a = 0.0, gr_b = 0.0, nf = 0, ng = 0}
		for j in range(EDGE, a.ny - EDGE):
			for i in range(EDGE, a.nx - EDGE):
				var z0c := zm[j * a.nx + i]
				var key := "for" if z0c >= 0.8 else ("gr" if z0c <= 0.035 else "")
				if key == "":
					continue
				var hcv := a.hc[j * a.nx + i]
				var pp := Vector3(a.x0 + (i + 0.5) * a.dx, hcv + 30.0, -(a.y0 + (j + 0.5) * a.dx))
				var va := fa.sample(pp, hcv)
				var vb := fb.sample(pp, hcv)
				sums[key + "_a"] += Vector2(va.x, va.z).length()
				sums[key + "_b"] += Vector2(vb.x, vb.z).length()
				sums["nf" if key == "for" else "ng"] += 1
		var nf := maxi(int(sums.nf), 1)
		var ng := maxi(int(sums.ng), 1)
		print(
			"  %s: U(30 м) лес (%d клеток): карта %.2f, скаляр %.2f, ×%.3f; луг (%d): карта %.2f, скаляр %.2f, ×%.3f"
			% [
				loc_id, sums.nf, sums.for_a / nf, sums.for_b / nf, sums.for_a / maxf(sums.for_b, 1e-9),
				sums.ng, sums.gr_a / ng, sums.gr_b / ng, sums.gr_a / maxf(sums.gr_b, 1e-9)
			]
		)
		# подбор inflow_k AirRuntime со снимком (как test_air_start, но place с surface)
		var rt := AirRuntime.new()
		tree.root.add_child(rt)
		for site: Dictionary in loc.start_sites:
			var heading := float(site.heading_deg)
			var st := TerrainGeo.latlon_to_local(
				float(site.lat), float(site.lon), float(loc.center_lat), float(loc.center_lon)
			)
			var gh := detail.sample(st.x, st.y)
			var sp := Vector3(st.x, gh, st.y)
			var atmo := TestStartAirZ0._atmo(detail, WIND_MS * 3.6, heading, gh)
			_c = {hour = hour, u10 = WIND_MS, wdir = heading, t_max = settings.temperature_c, sky = settings.sky}
			rt.setup(atmo, place, _cond)
			rt.focus_fn = func() -> Vector3: return sp
			var ok: bool = await rt.load_field()
			check(ok, "%s/%s: поле посчитано (%s)" % [loc_id, site.id, rt.last_error])
			if ok:
				var li := rt.last_info
				var v := atmo.mean_wind_at(Vector3(st.x, gh + 10.0, st.y))
				var r := Vector2(v.x, v.z).length() / WIND_MS
				print(
					"  %s/%s подбор: U₁ %.2f, k %.3f, проходов %d, не сошёлся %s, U атм. на 10 м ÷ меню %.3f"
					% [loc_id, site.id, float(li.get("u_start10_first", NAN)), float(li.get("inflow_k", NAN)), int(li.get("passes", 0)), bool(li.get("not_converged", false)), r]
				)
				if not bool(li.get("not_converged", false)):
					check(absf(r - 1.0) <= TOL, "%s/%s: U на 10 м над стартом %.3f × меню" % [loc_id, site.id, r])
			atmo.free()
		rt.stop()
		rt.queue_free()
		await tree.process_frame
		t.free()


class TestStartAirZ0:
	static func _atmo(detail: HeightLayer, kmh: float, heading: float, ref_msl: float) -> Atmosphere:
		var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
		w.wind_speed_kmh = kmh
		w.wind_from_deg = heading
		w.thermal_mode = "static"
		w.static_thermals = []
		var a := Atmosphere.new()
		a.visuals_enabled = false
		a.configure(Config.get_config("atmosphere"), w)
		a.set_ground(func(x: float, z: float) -> float: return detail.sample(x, z), _sun)
		a.set_wind(kmh, heading, ref_msl)
		a.set_thermal_mode("static")
		a.turbulence_enabled = false
		a.wave.enabled = false
		a.step(0.01)
		return a

	static func _sun(_x: float, _z: float) -> float:
		return 1.0
