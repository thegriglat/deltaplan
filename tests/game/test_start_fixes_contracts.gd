extends TestCase
## Контракты модуля start-fixes (docs/start_fixes_contracts.md): форма стыков К1–К4.
## Ломается, если формат поменяли без правки контракта.


func _has_method_args(script: Script, method: String, n_args: int) -> bool:
	for m in script.get_script_method_list():
		if String(m.name) == method:
			return (m.args as Array).size() == n_args
	return false


func test_k1_surface_classes() -> void:
	check(SurfaceLayer.FOREST == 1 and SurfaceLayer.GRASS == 2, "К1: FOREST=1, GRASS=2")
	check(SurfaceLayer.SHRUB == 4 and SurfaceLayer.CLASS_COUNT == 9, "К1: SHRUB=4, 9 классов")
	check(
		_has_method_args(SurfaceLayer, "replace_in_circle", 5),
		"К1: SurfaceLayer.replace_in_circle(cx, cz, r, from, to)"
	)
	var terrain := load("res://scripts/terrain/terrain.gd") as Script
	check(_has_method_args(terrain, "surface_at", 2), "К1: Terrain.surface_at(x, z)")
	check(_has_method_args(terrain, "forest_at", 2), "К1: Terrain.forest_at(x, z)")


func test_k2_grass_config() -> void:
	var g: Dictionary = Config.get_config("vegetation").grass
	check(g.has("shrub_density"), "К2: grass.shrub_density")
	check(g.has("blade_height_m"), "К2: grass.blade_height_m")


func test_k3_ground_run_shape() -> void:
	check(_has_method_args(GroundRun, "step", 5), "К3: GroundRun.step(m, dt, input, air, ground)")
	var gr := GroundRun.new()
	check(gr.phase == "standing", "К3: фаза стоя — standing")
	var m := FlightModel.new()
	check("bank" in m and "roll_rate" in m and "heading" in m, "К3: bank/roll_rate/heading")
	var gb: Dictionary = Config.get_config("flight").ground_bank
	check(gb.has("fail_bank_deg"), "К3: ground_bank.fail_bank_deg")
	# v2: рука пилота, инерция, скольжение
	for k in [
		"pilot_moment_max_nm",
		"pilot_response_s",
		"wing_cg_above_axis_m",
		"span_mass_fraction",
		"slip_roll_per_cl"
	]:
		check(gb.has(k), "К3 v2: ground_bank." + k)
	for k in ["crosswind_roll_dps_per_ms", "pilot_roll_rate_dps", "level_time_s"]:
		check(not gb.has(k), "К3 v2: убран ground_bank." + k)
	var run: Dictionary = Config.get_config("pilot").run
	check(run.has("turn_accel_max_ms2"), "К3 v2: pilot.run.turn_accel_max_ms2")
	check(not run.has("ground_turn_rate_dps"), "К3 v2: убран pilot.run.ground_turn_rate_dps")
	check("feet_load" in gr and gr.feet_load == 1.0, "К3 v2: GroundRun.feet_load, стоя 1")
	check("wind_moment_nm" in gr and "hold_limit_nm" in gr, "К3 v2: wind_moment_nm, hold_limit_nm")
	check(_has_method_args(GroundRun, "roll_inertia", 1), "К3 v2: GroundRun.roll_inertia(m)")
	check(_has_method_args(GroundRun, "pilot_moment", 5), "К3 v2: GroundRun.pilot_moment(...)")


func test_k4_basis_convention() -> void:
	var m := FlightModel.new()
	m.setup(Config.get_config("wings/sport"), Config.get_config("pilot"), {})
	m.reset_on_ground(Vector3(0, 100, 0), 90.0)
	m.bank = deg_to_rad(10.0)
	m.theta = deg_to_rad(5.0)
	FlightTelemetry.fill(m, Callable(), Callable())
	var want := Basis.from_euler(Vector3(m.theta, -m.heading, -m.bank))
	check(m.telemetry.basis.is_equal_approx(want), "К4: basis = from_euler(theta, −heading, −bank)")
	check(m.telemetry.position == m.position, "К4: начало координат планера — ступни (position)")
