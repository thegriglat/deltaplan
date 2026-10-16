extends TestCase
## TI-8, TI-К2 v2: weather.wind_ref на учебном острове, старт lee_bowl (восточный борт чаши за главным
## хребтом, ветер 9 м/с с 270°, 12 ч, июль, clear). "inflow" — приток k = 1 без подгонки под ветер у
## старта: над чашей нет разгона до 20–28 м/с; "start" — прежняя подгонка (k до INFLOW_K_MAX).
## tools/gpu_tests.sh --filter=inflow

const LOC := "training_island"
const SITE := "lee_bowl"
const U_MS := 9.0
const WDIR := 270.0
## Окно у старта: ±HALF_M по горизонтали, шаг STEP_M, высота 10…TOP_AGL_M над землёй.
const HALF_M := 100.0
const STEP_M := 25.0
const TOP_AGL_M := 300.0

var _c := {}


func needs_gpu() -> bool:
	return true


func _cond() -> Dictionary:
	return _c


static func _atmo(detail: HeightLayer) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = Units.to_kmh(U_MS)
	w.wind_from_deg = WDIR
	w.thermal_mode = "static"
	w.static_thermals = []
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(func(x: float, z: float) -> float: return detail.sample(x, z), func(_x: float, _z: float) -> float: return 1.0)
	a.set_thermal_mode("static")
	a.turbulence_enabled = false
	a.wave.enabled = false
	a.step(0.01)
	return a


## Поле острова для wind_ref; результат {k, passes, max_u, min_w, rev_frac}.
func _run(wind_ref: String) -> Dictionary:
	var root := Locations.fixtures_root
	Locations.fixtures_root = "res://data/locations"  # остров — встроенные данные, не фикстура
	var lw := TestAirPlace.load_detail(LOC)
	Locations.fixtures_root = root
	var loc := TestAirPlace.load_loc(LOC)
	loc.month = 7
	loc.day = 15
	var detail: HeightLayer = lw[0]
	var st: Dictionary = {}
	for s: Dictionary in loc.start_sites:
		if String(s.id) == SITE:
			st = s
	var p := TerrainGeo.latlon_to_local(float(st.lat), float(st.lon), float(loc.center_lat), float(loc.center_lon))
	var pos := Vector3(p.x, detail.sample(p.x, p.y), p.y)
	var atmo := _atmo(detail)
	_c = {hour = 12.0, u10 = U_MS, wdir = WDIR, t_max = 25.0, sky = "clear", wind_ref = wind_ref}
	var rt := AirRuntime.new()
	await Engine.get_main_loop().process_frame
	(Engine.get_main_loop() as SceneTree).root.add_child(rt)
	rt.setup(atmo, {detail = detail, water = lw[1], loc = loc}, _cond)
	rt.set_focus(null, pos)
	var out := {}
	var ok: bool = await rt.load_field()
	check(ok, "%s: поле посчитано (%s)" % [wind_ref, rt.last_error])
	if ok:
		out = _stats(atmo, detail, pos)
		out.k = rt.inflow_k
		out.passes = int(rt.last_info.get("passes", 0))
		print("  wind_ref=%s: %s" % [wind_ref, out])
	rt.queue_free()
	atmo.free()
	return out


func _stats(atmo: Atmosphere, detail: HeightLayer, pos: Vector3) -> Dictionary:
	var max_u := 0.0
	var min_w := INF
	var n_rev := 0
	var n_gnd := 0
	var east := Vector3(-sin(deg_to_rad(WDIR)), 0.0, cos(deg_to_rad(WDIR)))  # куда дует ветер
	var d := -HALF_M
	while d <= HALF_M:
		var e := -HALF_M
		while e <= HALF_M:
			var x := pos.x + d
			var z := pos.z + e
			var h := detail.sample(x, z)
			var agl := 10.0
			while agl <= TOP_AGL_M:
				var m := atmo.mean_wind_at(Vector3(x, h + agl, z))
				max_u = maxf(max_u, Vector2(m.x, m.z).length())
				min_w = minf(min_w, m.y)
				if agl == 10.0:
					n_gnd += 1
					if m.x * east.x + m.z * east.z < 0.0:
						n_rev += 1
				agl += 30.0
			e += STEP_M
		d += STEP_M
	return {max_u = max_u, min_w = min_w, rev_frac = float(n_rev) / maxf(n_gnd, 1)}


func test_inflow_k1_no_rotor_boost() -> void:
	var r := await _run("inflow")
	if r.is_empty():
		return
	check(is_equal_approx(float(r.k), 1.0), "wind_ref=inflow: k = 1 (%.3f)" % float(r.k))
	check(int(r.passes) == 1, "один проход, без подгонки (%d)" % int(r.passes))
	check(float(r.max_u) <= 1.3 * U_MS, "max|u| ≤ 1,3 × %.0f м/с: %.1f" % [U_MS, float(r.max_u)])


func test_start_ref_fits_inflow() -> void:
	var r := await _run("start")
	if r.is_empty():
		return
	check(int(r.passes) == 2, "wind_ref=start: два прохода, как раньше (%d)" % int(r.passes))
	check(float(r.k) >= AirRuntime.INFLOW_K_MIN and float(r.k) <= AirRuntime.INFLOW_K_MAX, "k в пределах (%.3f)" % float(r.k))
