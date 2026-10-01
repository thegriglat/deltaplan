extends TestCase
## Поле под старт (air-start AS-1, C9 v3): ветер меню — на 10 м над стартом. AirRuntime грузит
## поле в два прохода (k = U меню / U поля на 10 м над стартом); на всех 10 стартах игры при
## 6 м/с «в старт» средний ветер атмосферы (Atmosphere.mean_wind_at, без болтанки) на 10 м над
## землёй старта = меню ± 10 %. Погода — прогноз по умолчанию (FlightSettings), час старта.
## tools/gpu_tests.sh --filter=test_air_start (под flock /tmp/heat_ca_gpu.lock), ~2 мин.

const LOCATIONS: Array[String] = ["altai", "askarovo", "aushkul", "ongudai"]
const WIND_MS := 6.0
const TOL := 0.10

var _c := {}


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


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


func test_start_wind_matches_menu() -> void:
	var settings := FlightSettings.defaults()
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var n_ok := 0
	var n_all := 0
	print("  старт: U₁ (проход 1), k, U поданного поля (runtime), U атмосферы на 10 м, ÷ меню, с")
	for loc_id in LOCATIONS:
		var lw := TestAirPlace.load_detail(loc_id)
		check(lw.size() == 2, "слой detail " + loc_id)
		if lw.size() != 2:
			continue
		var detail: HeightLayer = lw[0]
		var loc := TestAirPlace.load_loc(loc_id)
		var rt := AirRuntime.new()
		tree.root.add_child(rt)
		for site: Dictionary in loc.start_sites:
			var heading := float(site.heading_deg)
			var st := TerrainGeo.latlon_to_local(
				float(site.lat), float(site.lon), float(loc.center_lat), float(loc.center_lon)
			)
			var gh := detail.sample(st.x, st.y)
			var sp := Vector3(st.x, gh, st.y)
			var atmo := _atmo(detail, WIND_MS * 3.6, heading, gh)
			_c = {
				hour = settings.start_hour,
				u10 = WIND_MS,
				wdir = heading,
				t_max = settings.temperature_c,
				sky = settings.sky,
			}
			rt.setup(atmo, {detail = detail, water = lw[1], loc = loc}, _cond)
			rt.focus_fn = func() -> Vector3: return sp
			var ok: bool = await rt.load_field()
			n_all += 1
			check(ok, "%s/%s: поле посчитано (%s)" % [loc_id, site.id, rt.last_error])
			if not ok:
				atmo.free()
				continue
			var li := rt.last_info
			var v := atmo.mean_wind_at(Vector3(st.x, gh + 10.0, st.y))
			var u := Vector2(v.x, v.z).length()
			var r := u / WIND_MS
			print(
				(
					"  %s/%s: %.2f, %.3f, %.2f, %.2f м/с, %.3f, %.1f"
					% [
						loc_id,
						site.id,
						float(li.get("u_start10_first", NAN)),
						float(li.get("inflow_k", NAN)),
						float(li.get("u_start10", NAN)),
						u,
						r,
						float(li.get("wall_s", 0.0)),
					]
				)
			)
			check(int(li.get("passes", 0)) == 2, "%s/%s: два прохода" % [loc_id, site.id])
			check(
				absf(float(li.get("u_start10", NAN)) - u) < 0.05,
				"%s/%s: замер AirRuntime = атмосфера" % [loc_id, site.id]
			)
			check(absf(r - 1.0) <= TOL, "%s/%s: U на 10 м над стартом %.3f × меню" % [loc_id, site.id, r])
			if absf(r - 1.0) <= TOL:
				n_ok += 1
			atmo.free()
		rt.stop()
		rt.queue_free()
		await tree.process_frame
	print("  в допуске ±%d %%: %d из %d стартов" % [roundi(TOL * 100.0), n_ok, n_all])
	check(n_all == 10, "все 10 стартов (%d)" % n_all)


## Проход 2 не удался (таймаут — крошечный предел только для проходов ≥ 2) — в атмосфере поле
## прохода 1 (его k = 1 и U₁), не аналитика; строка «проход 2 не удался … — поле прохода 1».
func test_failed_second_pass_keeps_first() -> void:
	var lw := TestAirPlace.load_detail("ongudai")
	var detail: HeightLayer = lw[0]
	var loc := TestAirPlace.load_loc("ongudai")
	var site: Dictionary = loc.start_sites[0]
	var st := TerrainGeo.latlon_to_local(
		float(site.lat), float(site.lon), float(loc.center_lat), float(loc.center_lon)
	)
	var gh := detail.sample(st.x, st.y)
	var sp := Vector3(st.x, gh, st.y)
	var heading := float(site.heading_deg)
	var atmo := _atmo(detail, WIND_MS * 3.6, heading, gh)
	var settings := FlightSettings.defaults()
	_c = {
		hour = settings.start_hour,
		u10 = WIND_MS,
		wdir = heading,
		t_max = settings.temperature_c,
		sky = settings.sky,
	}
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var rt := AirRuntime.new()
	tree.root.add_child(rt)
	rt.setup(atmo, {detail = detail, water = lw[1], loc = loc}, _cond)
	rt.focus_fn = func() -> Vector3: return sp
	rt.timeout_later_pass_s = 0.05
	var ok: bool = await rt.load_field()
	var li := rt.last_info
	print("  проход 2 с пределом 0,05 с: ok %s, %s, k %s, U %s" % [ok, li.get("pass_failed"), li.get("inflow_k"), li.get("u_start10")])
	check(ok, "загрузка не провалилась: %s" % rt.last_error)
	check(atmo.is_air_field_on(), "в атмосфере поле, не аналитика")
	check(atmo.air_field.levels.size() == 3, "уровни прохода 1: окна и область")
	check(int(li.get("passes", 0)) == 1, "подано поле прохода 1")
	check(String(li.get("pass_failed", "")).begins_with("проход 2"), "причина отката записана")
	approx(rt.inflow_k, 1.0, 1e-9, "k поданного поля — прохода 1")
	var v := atmo.mean_wind_at(Vector3(st.x, gh + 10.0, st.y))
	approx(Vector2(v.x, v.z).length(), float(li.get("u_start10_first", NAN)), 0.05, "U над стартом = U₁")
	rt.stop()
	rt.queue_free()
	atmo.free()
